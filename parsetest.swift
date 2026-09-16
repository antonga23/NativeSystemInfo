import Foundation

// Prints the parsed tree for a data type so it can be diffed against system_profiler's
// own output. Verifies the UI model without relying on screenshots.

let type = CommandLine.arguments.dropFirst().first ?? "SPHardwareDataType"
let nodes = SPReport.load(dataType: type)

func dump(_ n: SPNode, _ depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    if let v = n.value {
        print("\(pad)\(n.label): \(v)")
    } else {
        print("\(pad)\(n.label):")
    }
    for c in n.children { dump(c, depth + 1) }
}

print("=== parsed tree for \(type) ===")
for n in nodes { dump(n, 0) }
print("=== \(nodes.count) root node(s) ===")
