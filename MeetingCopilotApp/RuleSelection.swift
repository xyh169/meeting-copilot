import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RuleEntry: Decodable, Identifiable {
    var id: String
    var title: String
    var path: String
    var version: String
    var error: String
}

private struct RuleCatalogResponse: Decodable {
    var ok: Bool
    var rules: [RuleEntry]?
    var directory: String?
    var selected: String?
    var error: String?
}

@MainActor
final class RuleLibrary: ObservableObject {
    static let shared = RuleLibrary()
    @Published var catalogs: [String: [RuleEntry]] = [:]
    @Published var directories: [String: String] = [:]
    @Published var errors: [String: String] = [:]

    func entry(_ kind: String, _ id: String) -> RuleEntry? {
        catalogs[kind]?.first { $0.id == id }
    }

    func title(_ kind: String, _ id: String) -> String {
        entry(kind, id)?.title ?? ["initial": "General meeting", "diligence": "Evidence review", "default": "General research"][id] ?? "Selected rule unavailable"
    }

    private func receive(_ request: URLRequest, kind: String) async throws -> RuleCatalogResponse {
        try await BackendService.shared.ensureRunning()
        let (data, response) = try await URLSession.shared.data(for: request)
        let value = try JSONDecoder().decode(RuleCatalogResponse.self, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, value.ok else {
            throw NSError(domain: "RuleLibrary", code: 1, userInfo: [NSLocalizedDescriptionKey: value.error ?? "Unable to read rules"])
        }
        catalogs[kind] = value.rules ?? []
        directories[kind] = value.directory
        errors[kind] = nil
        return value
    }

    func refresh(_ kind: String) async {
        do {
            _ = try await receive(URLRequest(url: URL(string: "http://127.0.0.1:8766/api/copilot_rules?kind=\(kind)")!), kind: kind)
        } catch { errors[kind] = error.localizedDescription }
    }

    func importFile(_ url: URL, kind: String) async throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 120000 else {
            throw NSError(domain: "RuleLibrary", code: 2, userInfo: [NSLocalizedDescriptionKey: "Rule limit: 30000characters or fewer"])
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/api/copilot_rules/import")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["kind": kind, "filename": url.lastPathComponent, "content": content])
        let result = try await receive(request, kind: kind)
        guard let selected = result.selected else { throw CocoaError(.fileReadUnknown) }
        return selected
    }
}

struct RuleSelection: View {
    let kind: String
    let label: String
    @Binding var selection: String
    var onContentChanged: () -> Void = {}
    @ObservedObject private var library = RuleLibrary.shared
    @State private var importError = ""
    @State private var showsError = false
    @State private var importing = false

    private var selectedEntry: RuleEntry? { library.entry(kind, selection) }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Import a separate rule copy; edit the imported file to customize it."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                importing = true
                defer { importing = false }
                do { selection = try await library.importFile(url, kind: kind) }
                catch { importError = error.localizedDescription; showsError = true }
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(label, selection: $selection) {
                if selectedEntry == nil {
                    Text(library.title(kind, selection)).tag(selection)
                }
                ForEach(library.catalogs[kind] ?? []) { item in
                    Text(item.title + (item.error.isEmpty ? "" : "(invalid files)"))
                        .tag(item.id).disabled(!item.error.isEmpty)
                }
            }
            .pickerStyle(.menu)
            .lineLimit(1)
            .frame(minWidth: 100, maxWidth: 260)
            .help(selectedEntry?.path ?? "Select rules")
            Menu {
                Button("Import Markdown…", systemImage: "doc.badge.plus", action: chooseFile)
                    .disabled(importing)
                Button("Open selected rule", systemImage: "doc.text") {
                    if let path = selectedEntry?.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }.disabled(selectedEntry == nil)
                Button("Open rules folder", systemImage: "folder") {
                    if let path = library.directories[kind] { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }.disabled(library.directories[kind] == nil)
                Button("Refresh rules", systemImage: "arrow.clockwise") { Task { await library.refresh(kind) } }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help(kind == "interview" ? "Import or manage meeting scenarios" : "Import or manage research rules")
            if let error = library.errors[kind] ?? (selectedEntry?.error.isEmpty == false ? selectedEntry?.error : nil) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(error)
            }
        }
        .task {
            while !Task.isCancelled {
                await library.refresh(kind)
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
            }
        }
        .onChange(of: selectedEntry?.version ?? "") { old, new in
            if !old.isEmpty && old != new { onContentChanged() }
        }
        .alert("Unable to import rules", isPresented: $showsError) { Button("OK", role: .cancel) {} }
            message: { Text(importError) }
    }
}
