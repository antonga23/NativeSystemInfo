import Foundation

/// Table columns for a system_profiler pane.
///
/// Apple declares these on disk rather than leaving them to be guessed: every reporter
/// bundle under /System/Library/SystemProfiler carries
///   Contents/Info.plist                        -> SPDataType (reporter <-> data type, 1:1)
///   Contents/Resources/SPProperties.plist      -> per-field _isColumn / _isOutlineColumn / _order
///   Contents/Resources/Localizable.loctable    -> the header string for each field key
/// Read at runtime rather than baked in at build time, so the app tracks whatever macOS
/// it is running on.
enum SPColumns {

    struct Column {
        let key: String
        let title: String
        let isOutline: Bool
    }

    private static let reporterRoot = "/System/Library/SystemProfiler"

    /// data type -> reporter bundle URL, built once by scanning every bundle's Info.plist.
    private static let bundlesByDataType: [String: URL] = {
        var map: [String: URL] = [:]
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: reporterRoot) else { return map }
        for name in names where name.hasSuffix(".spreporter") {
            let bundle = URL(fileURLWithPath: reporterRoot).appendingPathComponent(name)
            let info = bundle.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: info),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let type = dict["SPDataType"] as? String else { continue }
            map[type] = bundle
        }
        return map
    }()

    /// Header strings pooled across every bundle: some field keys are blank in their own
    /// bundle but labelled in another (obtained_from, arch_kind), so a single-bundle lookup
    /// leaves columns unnamed.
    private static let pooledTitles: [String: String] = {
        var pooled: [String: String] = [:]
        // Prefer the running locale - system_profiler localises its output, so an en_ZA
        // machine emits "Organisation" and matching against en's "Organization" fails.
        var preferred = ["en"]
        if let id = Locale.current.identifier as String?, !id.isEmpty {
            preferred.insert(id, at: 0)
            preferred.insert(id.replacingOccurrences(of: "_", with: "-"), at: 1)
        }
        if let lang = Locale.current.language.languageCode?.identifier { preferred.insert(lang, at: 0) }

        for bundle in Set(bundlesByDataType.values) {
            let table = bundle.appendingPathComponent("Contents/Resources/Localizable.loctable")
            guard let data = try? Data(contentsOf: table),
                  let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            for locale in preferred.reversed() {          // reversed: preferred wins, written last
                guard let strings = root[locale] as? [String: String] else { continue }
                for (key, value) in strings where !value.isEmpty { pooled[key] = value }
            }
        }
        return pooled
    }()

    /// Titles from one bundle's own loctable. The pooled table is a fallback only: keys like
    /// `_name` are reused across bundles with different meanings, so pooling first makes the
    /// Profiles outline header come out as "Apple Internal Card Readers".
    private static func ownTitles(_ bundle: URL) -> [String: String] {
        let table = bundle.appendingPathComponent("Contents/Resources/Localizable.loctable")
        guard let data = try? Data(contentsOf: table),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        var out: [String: String] = [:]
        var preferred = ["en"]
        if let lang = Locale.current.language.languageCode?.identifier { preferred.append(lang) }
        preferred.append(Locale.current.identifier)
        for locale in preferred {
            guard let strings = root[locale] as? [String: String] else { continue }
            for (k, v) in strings where !v.isEmpty { out[k] = v }
        }
        return out
    }

    private static var cache: [String: [Column]] = [:]
    private static let lock = NSLock()

    /// Columns for a data type, empty when the pane has no table (Hardware, Language & Region).
    static func columns(for dataType: String) -> [Column] {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[dataType] { return hit }

        var result: [Column] = []
        defer { cache[dataType] = result }

        guard let bundle = bundlesByDataType[dataType] else { return result }
        let propsURL = bundle.appendingPathComponent("Contents/Resources/SPProperties.plist")
        guard let data = try? Data(contentsOf: propsURL),
              let props = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return result }

        let own = ownTitles(bundle)
        var found: [(order: Double, column: Column)] = []
        for (key, raw) in props {
            guard let field = raw as? [String: Any], truthy(field["_isColumn"]) else { continue }
            let title = own[key] ?? pooledTitles[key] ?? prettify(key)
            found.append((number(field["_order"]),
                          Column(key: key, title: title, isOutline: truthy(field["_isOutlineColumn"]))))
        }
        result = found.sorted { $0.order < $1.order }.map(\.column)

        // The outline column always leads; when none is flagged the first column does.
        if let idx = result.firstIndex(where: { $0.isOutline }), idx != 0 {
            let outline = result.remove(at: idx)
            result.insert(outline, at: 0)
        }
        return result
    }

    /// `_isColumn` is a Bool in some bundles and the string "YES"/"NO" in others; a
    /// string-only test silently drops USB, Storage, Memory, Audio and the Profiles outline.
    private static func truthy(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s.uppercased() == "YES" || s == "1" || s.lowercased() == "true" }
        return false
    }

    /// `_order` is a string in some bundles and an int in others.
    private static func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let d = Double(s) { return d }
        return .greatestFiniteMagnitude
    }

    private static func prettify(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
