#!/bin/bash
# One-shot setup on a fresh Mac: signing identity, build, install, LaunchAgent.
# Requirements: macOS 26 (Tahoe), Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

LABEL=com.alatha.nativesysteminfo
IDENTITY="NativeSystemInfo Local Signing"
APP_DST="$HOME/Applications/System Information.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

command -v swiftc >/dev/null || { echo "Install Command Line Tools first: xcode-select --install"; exit 1; }

# 1. Stable signing identity (TCC grants are bound to it). Self-signed, local to this Mac.
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "creating signing identity..."
  T=$(mktemp -d)
  cat > "$T/csr.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
O = NativeSystemInfo
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "$T/k.key" -out "$T/c.crt" -config "$T/csr.cnf" 2>/dev/null
  # legacy PKCS#12 algorithms: OpenSSL 3 defaults produce a file macOS rejects
  openssl pkcs12 -export -inkey "$T/k.key" -in "$T/c.crt" -out "$T/id.p12" \
      -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout pass:nsi -name "$IDENTITY"
  security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P nsi -T /usr/bin/codesign -T /usr/bin/security
  security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$T/c.crt"   # may prompt
  rm -rf "$T"
fi

# 2. Build and install
./build.sh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "build/System Information.app" "$APP_DST"

# 3. LaunchAgent (RunAtLoad + KeepAlive) pointing at this user's copy
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DST/Contents/MacOS/NativeSystemInfo</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
launchctl print "gui/$(id -u)/$LABEL" | grep -E "^\s*(state|pid)" | head -2

cat <<MSG

Installed. Remaining manual step (one time):
  System Settings > Privacy & Security > Accessibility > enable "System Information"
  (the one in ~/Applications). The agent prompts for it on first launch. Without it,
  System Report works fully; Device Management detection loses only its title fallback.

Verify: System Settings > General > About > System Report should open the replacement.
Uninstall: ./uninstall.sh
MSG
