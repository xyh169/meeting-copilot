import Foundation

@main
enum PortableWorkspaceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appending(path: "Backend")
        let target = root.appending(path: "Workspace")
        try FileManager.default.createDirectory(at: bundled.appending(path: "rules"), withIntermediateDirectories: true)
        try Data("original rule".utf8).write(to: bundled.appending(path: "rules/default.md"))
        try Data("version 1".utf8).write(to: bundled.appending(path: "server.py"))
        try PortableWorkspace.prepare(from: bundled, to: target)
        let firstCode = try String(contentsOf: target.appending(path: "server.py"), encoding: .utf8)
        precondition(firstCode == "version 1")
        try Data("user rule".utf8).write(to: target.appending(path: "rules/default.md"))
        try Data("local settings".utf8).write(to: target.appending(path: "settings.json"))
        try Data("version 2".utf8).write(to: bundled.appending(path: "server.py"))
        try PortableWorkspace.prepare(from: bundled, to: target)
        let updatedCode = try String(contentsOf: target.appending(path: "server.py"), encoding: .utf8)
        let rule = try String(contentsOf: target.appending(path: "rules/default.md"), encoding: .utf8)
        let settings = try String(contentsOf: target.appending(path: "settings.json"), encoding: .utf8)
        precondition(updatedCode == "version 2")
        precondition(rule == "user rule")
        precondition(settings == "local settings")
        print("Portable workspace: install, code update, rules and settings preservation passed")
    }
}
