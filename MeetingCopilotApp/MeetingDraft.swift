import Foundation

struct MeetingDraft: Codable {
    var sessionID: String
    var fragments: [TranscriptSegment]
    var corrections: [String: TranscriptCorrection]
    var cards: Data
    var questionMemory: Data
    var questionOrder: [String]
    var interviewMode: String
    var projectContext: String
    var terminologyNotes: String
    var questionerSpeaker: String
    var askedQuestions: [String: Int]
    var correctionRevision: String
    var apiUsage: APITokenUsage
    var researchReports: [ResearchReport]? = nil
    var researchGateUsage: ResearchUsage? = nil
    var correctionSuggestions: [TranscriptSuggestion]? = nil
    var termFixes: [TranscriptSuggestion]? = nil
    var analysisCheckpoint: String? = nil

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MeetingCopilot/meeting-draft.json")
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(from url: URL) throws -> MeetingDraft {
        try JSONDecoder().decode(MeetingDraft.self, from: Data(contentsOf: url))
    }

    func archive(beside url: URL) throws -> URL {
        let name = "meeting-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString + ".json"
        let archiveURL = url.deletingLastPathComponent().appending(path: "History/" + name)
        try save(to: archiveURL)
        return archiveURL
    }
}
