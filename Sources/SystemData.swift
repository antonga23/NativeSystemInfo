import Foundation

// Shared low-level helpers. Report content itself comes from SPReport.

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
}

func sysctlInt(_ name: String) -> Int64? {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    if sysctlbyname(name, &v, &size, nil, 0) == 0, size == MemoryLayout<Int64>.size { return v }
    var v32: Int32 = 0
    var s32 = MemoryLayout<Int32>.size
    if sysctlbyname(name, &v32, &s32, nil, 0) == 0 { return Int64(v32) }
    return nil
}

func runTool(_ path: String, _ args: [String]) -> String {
    guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }

    // Drain before waiting: a full pipe buffer deadlocks large reports such as Applications.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
