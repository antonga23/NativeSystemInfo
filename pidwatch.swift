import Darwin
import Foundation

// Mirrors Interceptor's detection exactly, standalone, so the pid-diff logic can be
// checked without the app in the way.

var buffer = [pid_t](repeating: 0, count: 8192)

func allPIDs() -> [pid_t] {
    let byteSize = Int32(buffer.count * MemoryLayout<pid_t>.size)
    let count = proc_listallpids(&buffer, byteSize)
    if count <= 0 { return [] }
    return Array(buffer.prefix(Int(count)))
}

func path(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "<no path>"
}

let start = Date()
var known = Set(allPIDs())
print("primed with \(known.count) pids")

while Date().timeIntervalSince(start) < 12 {
    let cur = Set(allPIDs())
    let new = cur.subtracting(known)
    known = cur
    for pid in new {
        let p = path(pid)
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "[%7.0f ms] new pid %d  %@", ms, pid, p))
    }
    usleep(8_000)
}
print("done")
