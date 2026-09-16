import Foundation

/// Timing log for the interception path. Written to a file because the interesting window
/// is a few hundred milliseconds around a launch, which is awkward to observe any other way.
enum Log {
    static let path = "/tmp/nsi.log"
    private static let queue = DispatchQueue(label: "nsi.log")
    private static let startedAt = CFAbsoluteTimeGetCurrent()

    static func mark(_ message: String) {
        let t = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        let epoch = Date().timeIntervalSince1970 * 1000
        queue.async {
            let line = String(format: "[epoch %.0f] [%10.1f ms] %@\n", epoch, t, message)
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
