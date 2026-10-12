import Foundation

enum PortableWorkspace {
    static func prepare(from bundled: URL, to workspace: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: workspace, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        guard let entries = files.enumerator(atPath: bundled.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        for case let relative as String in entries {
            let source = bundled.appending(path: relative)
            guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let target = workspace.appending(path: relative)
            let exists = files.fileExists(atPath: target.path)
            // Update application code, but never overwrite user-edited Markdown rules.
            if exists && source.pathExtension != "py" { continue }
            let data = try Data(contentsOf: source)
            if exists && (try? Data(contentsOf: target)) == data { continue }
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
    }
}
