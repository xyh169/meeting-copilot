import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private let backendURL = URL(string: "http://127.0.0.1:8766")!
let appDirectory: URL = {
    if let root = ProcessInfo.processInfo.environment["COPILOT_APP_DIR"], !root.isEmpty {
        return URL(fileURLWithPath: root, isDirectory: true)
    }
    if let resources = Bundle.main.resourceURL,
       FileManager.default.fileExists(atPath: resources.appending(path: "Backend").path) {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "io.github.xyh169.meeting-copilot/Workspace")
    }
    if let root = Bundle.main.object(forInfoDictionaryKey: "CopilotSourceDirectory") as? String,
       !root.isEmpty {
        return URL(fileURLWithPath: root, isDirectory: true)
    }
    return Bundle.main.bundleURL.deletingLastPathComponent()
}()

@MainActor
final class BackendService {
    static let shared = BackendService()

    private var process: Process?
    private var launchTask: Task<Void, Error>?

    func ensureRunning() async throws {
        if let launchTask { return try await launchTask.value }
        let task = Task { try await self.startBackendIfNeeded() }
        launchTask = task
        defer { launchTask = nil }
        try await task.value
    }

    private func startBackendIfNeeded() async throws {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appending(path: "Backend")
            if FileManager.default.fileExists(atPath: bundled.path) {
                try PortableWorkspace.prepare(from: bundled, to: appDirectory)
            }
        }
        if await isAvailable() { return }
        let process = Process()
        let bundledPython = Bundle.main.resourceURL?.appending(path: "python/bin/python3")
        if let bundledPython, FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            process.executableURL = bundledPython
        } else {
            process.executableURL = appDirectory.appending(path: ".venv/bin/python")
        }
        process.arguments = ["obs_audio_web_gui.py", "--no-open"]
        process.currentDirectoryURL = appDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(200))
            if await isAvailable() { return }
        }
        throw CopilotError.backendUnavailable
    }

    private func isAvailable() async -> Bool {
        var request = URLRequest(url: backendURL.appending(path: "/api/config"))
        request.timeoutInterval = 0.6
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

struct VerificationResult: Codable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let snippet: String
}

struct QuestionCard: Codable, Identifiable {
    let id: String
    let category: String
    let priority: String
    let question: String
    let reason: String
    let verification: String
    let status: String?
    let answer_summary: String?
    let verification_claim: String?
    let verification_verdict: String?
    let search_query: String?
    let verification_results: [VerificationResult]?
    let anchor: String?
    let evidence_needed: String?
    let answer_kind: String?
    let missing_conditions: [String]?
    let source_kind: String?

    var isAnswered: Bool { status == "answered" }
    var needsAttention: Bool { answer_kind == "nonresponsive" || answer_kind == "needs_review" }
    var answerLabel: String { answer_kind == "nonresponsive" ? "Nonresponsive answer" : answer_kind == "needs_review" ? "Review after correction" : "Answered" }
}

struct APITokenUsage: Codable {
    var calls = 0
    var input_tokens = 0
    var output_tokens = 0
    var cached_tokens = 0
}

private struct CopilotDetails: Codable {
    let cards: [QuestionCard]
    let analysis_status: String?
    let token_usage: APITokenUsage?
    let analysis_error: String?
    let correction_suggestions: [TranscriptSuggestion]?
    let term_fixes: [TranscriptSuggestion]?
    let analysis_checkpoint: String?
}

private struct CopilotResponse: Codable {
    let ok: Bool
    let details: CopilotDetails
}

private struct AIConfig: Codable {
    let copilot_reasoning_provider: String
    let copilot_reasoning_model: String
    let copilot_api_base_url: String
    let copilot_api_model: String
    let api_key_configured: Bool
}

private struct AIConfigResponse: Codable {
    let ok: Bool
    let message: String?
    let error: String?
    let config: AIConfig?
}

@MainActor
final class AISettingsViewModel: ObservableObject {
    @Published var provider = "openai_compatible"
    @Published var localModel = ""
    @Published var apiBaseURL = "https://api.deepseek.com"
    @Published var apiModel = ""
    @Published var apiKey = ""
    @Published var apiKeyConfigured = false
    @Published var isLoading = true
    @Published var isWorking = false
    @Published var message = ""
    @Published var messageIsError = false

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await BackendService.shared.ensureRunning()
            var request = URLRequest(url: backendURL.appending(path: "/api/copilot_ai_config"))
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CopilotError.backendUnavailable
            }
            let result = try JSONDecoder().decode(AIConfigResponse.self, from: data)
            guard result.ok, let config = result.config else {
                throw NSError(domain: "AISettings", code: 1, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Unable to read settings"])
            }
            apply(config)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func useDeepSeekPreset() {
        apiBaseURL = "https://api.deepseek.com"
        apiModel = ""
    }

    func save() async -> Bool {
        let saved = await submit(path: "/api/copilot_ai_config", successMessage: "Settings saved")
        if saved { UserDefaults.standard.set(true, forKey: "copilotAIConfigured") }
        return saved
    }

    func testConnection() async {
        _ = await submit(path: "/api/copilot_ai_test", successMessage: "Connected")
    }

    func removeAPIKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await send(path: "/api/copilot_ai_config", removeKey: true)
            guard result.ok, let config = result.config else {
                throw NSError(domain: "AISettings", code: 2, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Unable to remove key"])
            }
            apply(config)
            message = "API Key removed from Keychain"
            messageIsError = false
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func submit(path: String, successMessage: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await send(path: path, removeKey: false)
            guard result.ok, let config = result.config else {
                throw NSError(domain: "AISettings", code: 3, userInfo: [NSLocalizedDescriptionKey: result.error ?? "Save failed"])
            }
            apply(config)
            apiKey = ""
            message = successMessage
            messageIsError = false
            return true
        } catch {
            showError(error.localizedDescription)
            return false
        }
    }

    private func send(path: String, removeKey: Bool) async throws -> AIConfigResponse {
        try await BackendService.shared.ensureRunning()
        var request = URLRequest(url: backendURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 100
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "copilot_reasoning_provider": provider,
            "copilot_reasoning_model": localModel,
            "copilot_api_base_url": apiBaseURL,
            "copilot_api_model": apiModel,
            "api_key": apiKey,
            "remove_api_key": removeKey,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(AIConfigResponse.self, from: data)
    }

    private func apply(_ config: AIConfig) {
        provider = config.copilot_reasoning_provider
        localModel = config.copilot_reasoning_model
        apiBaseURL = config.copilot_api_base_url
        apiModel = config.copilot_api_model
        apiKeyConfigured = config.api_key_configured
    }

    private func showError(_ text: String) {
        message = text
        messageIsError = true
    }
}

struct AISettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = AISettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AI settings").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Close")
            }
            .padding(16)
            Divider()

            if model.isLoading {
                ProgressView("Reading settings...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Picker("Analysis mode", selection: $model.provider) {
                        Text("Local model").tag("ollama")
                        Text("Cloud API").tag("openai_compatible")
                    }
                    .pickerStyle(.segmented)

                    if model.provider == "ollama" {
                        TextField("Local model", text: $model.localModel)
                    } else {
                        HStack {
                            TextField("API address", text: $model.apiBaseURL)
                            Button("DeepSeek preset") { model.useDeepSeekPreset() }
                        }
                        TextField("Model name", text: $model.apiModel)
                        SecureField(
                            model.apiKeyConfigured ? "Leave blank to use the saved Keychain key" : "API Key",
                            text: $model.apiKey
                        )
                        Label(
                            "Cloud analysis receives transcript text, background, terminology, Q&A and source snippets. Raw audio stays local.",
                            systemImage: "lock.doc"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if model.apiKeyConfigured {
                            HStack {
                                Label("Key saved to Keychain", systemImage: "checkmark.shield.fill")
                                    .foregroundStyle(Color.green)
                                Spacer()
                                Button("Remove key") { Task { await model.removeAPIKey() } }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 12)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.caption)
                        .foregroundStyle(model.messageIsError ? Color.red : Color.green)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                Divider()
                HStack {
                    if model.provider == "openai_compatible" {
                        Button("Test connection") { Task { await model.testConnection() } }
                            .disabled(model.isWorking)
                    }
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Save") {
                        Task {
                            if await model.save() { dismiss() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
                .padding(16)
            }
        }
        .frame(width: 540, height: 410)
        .task { await model.load() }
    }
}

enum CopilotAudioSource: String, CaseIterable {
    case both, microphone, system

    var includesMicrophone: Bool { self != .system }
    var includesSystem: Bool { self != .microphone }
    var title: String {
        switch self {
        case .both: return "Mic + system"
        case .microphone: return "Microphone only"
        case .system: return "System audio only"
        }
    }
    var listeningStatus: String {
        switch self {
        case .both: return "Listening to microphone and system audio"
        case .microphone: return "Listening to microphone"
        case .system: return "Listening to system audio"
        }
    }
}

@MainActor
final class CopilotViewModel: ObservableObject {
    let research = ResearchModel()
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var isTransitioning = false
    @Published private(set) var audioSource = CopilotAudioSource(
        rawValue: UserDefaults.standard.string(forKey: "copilotAudioSource") ?? "both") ?? .both
    var canChangeAudioSource: Bool { !isRunning && !isTransitioning }
    @Published var transcriptionEngine = CopilotTranscriber(
        rawValue: UserDefaults.standard.string(forKey: "copilotTranscriptionEngine") ?? "apple") ?? .apple {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "copilotTranscriptionEngine") }
    }

    func selectAudioSource(_ source: CopilotAudioSource) {
        guard canChangeAudioSource else { return }
        audioSource = source
        UserDefaults.standard.set(source.rawValue, forKey: "copilotAudioSource")
    }
    @Published var status = "Ready"
    @Published var segments: [TranscriptSegment] = []
    @Published var cards: [QuestionCard] = []
    @Published var isPinned = false
    @Published var interviewMode = UserDefaults.standard.string(forKey: "interviewMode") ?? "initial"
    @Published var projectContext = ""
    @Published var showsStartChoice = false
    private var requiresResumeChoice = false
    @Published var analysisStatus = "Waiting for meeting content"
    @Published var analysisError = ""
    @Published private(set) var questionUpdatesEnabled = UserDefaults.standard.object(forKey: "copilotQuestionUpdatesEnabled") as? Bool ?? true
    @Published var draftStatus = ""
    @Published var isEditingTranscript = false
    @Published var apiUsage = APITokenUsage()
    @Published var terminologyNotes = ""
    @Published var questionerSpeaker = "Microphone"
    @Published var askedQuestions: [String: Int] = [:]
    @Published var corrections: [String: TranscriptCorrection] = [:]
    @Published var correctionSuggestions: [TranscriptSuggestion] = []
    @Published var termFixes: [TranscriptSuggestion] = []
    private var analysisCheckpoint = ""
    private var correctionRevision = ""
    private var analysisRevision = 0
    private var meetingSessionID = UUID().uuidString
    private var cardPayload = Data("[]".utf8)
    private var questionMemory = Data("[]".utf8)
    private var questionOrder: [String] = []
    private let draftURL: URL
    private let automaticallyAnalyze: Bool
    private var researchWatchTask: Task<Void, Never>?
    private var allowsAutomaticResearch = false
    private var lastDraftSave = Date.distantPast
    private lazy var transcriptEditor = TranscriptEditorController()

    var openCards: [QuestionCard] {
        let positions = Dictionary(questionOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { _, last in last })
        return cards.filter { !$0.isAnswered }.sorted {
            let left = positions[$0.id] ?? -1, right = positions[$1.id] ?? -1
            return left == right ? $0.id < $1.id : left > right
        }
    }

    var analysisScope: String {
        let values: [String: Any] = ["session": meetingSessionID, "mode": interviewMode,
            "rule_version": RuleLibrary.shared.entry("interview", interviewMode)?.version ?? "",
            "background": projectContext, "terminology": terminologyNotes, "speaker": questionerSpeaker,
            "asked": askedQuestions, "correction": correctionRevision]
        let data = try? JSONSerialization.data(withJSONObject: values, options: .sortedKeys)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? meetingSessionID
    }

    var researchScope: String {
        let data = try? JSONEncoder().encode([meetingSessionID, projectContext, terminologyNotes, correctionRevision,
            research.ruleID, RuleLibrary.shared.entry("research", research.ruleID)?.version ?? ""])
        return data?.base64EncodedString() ?? meetingSessionID
    }

    func editTranscript(_ segment: TranscriptSegment, suggestion: TranscriptSuggestion? = nil) {
        guard !isEditingTranscript,
              let window = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else { return }
        isEditingTranscript = true
        let initial = suggestion?.applying(to: correctedText(segment)) ?? correctedText(segment)
        transcriptEditor.present(original: segment.text, corrected: initial, parent: window,
            onSave: { [weak self] replacement in
                if let suggestion { self?.saveEditedSuggestion(suggestion, segment: segment, replacement: replacement) }
                else { self?.correct(segment, to: replacement) }
            },
            onClose: { [weak self] in self?.isEditingTranscript = false })
    }

    func saveEditedSuggestion(_ suggestion: TranscriptSuggestion, segment: TranscriptSegment, replacement: String) {
        guard let index = correctionSuggestions.firstIndex(where: { $0.id == suggestion.id }),
              correctionSuggestions[index].resolution == nil else { return }
        correctionSuggestions[index].resolution = "edited"
        correctionSuggestions[index].editedText = replacement
        correct(segment, to: replacement)
    }

    var modeLabel: String { RuleLibrary.shared.title("interview", interviewMode) }

    func updateResearchRule() {
        research.invalidate(scope: researchScope)
        if isRunning || !projectContext.isEmpty { allowsAutomaticResearch = true }
        persistDraft()
    }

    func updateInterviewContext() {
        allowsAutomaticResearch = !projectContext.isEmpty || allowsAutomaticResearch
        UserDefaults.standard.set(interviewMode, forKey: "interviewMode")
        analysisStatus = "Analyzing meeting context"
        persistDraft()
        scheduleAnalysis()
    }

    func markAsked(_ card: QuestionCard) {
        askedQuestions[card.id] = evidenceTranscriptText.unicodeScalars.count
        persistDraft()
        scheduleAnalysis()
    }

    func correctedText(_ segment: TranscriptSegment) -> String {
        if let correction = corrections[segment.id] { return correction.apply(to: segment.text) }
        return termFixes.reduce(segment.text) { text, fix in fix.applying(to: text) ?? text }
    }

    func mergeTermFixes(_ fixes: [TranscriptSuggestion]) {
        var known = Set(termFixes.map(\.id))
        for fix in fixes where known.insert(fix.id).inserted && terminologyNotes.contains(fix.replacement) {
            termFixes.append(fix)
        }
    }

    func pendingSuggestions(for segment: TranscriptSegment) -> [TranscriptSuggestion] {
        let text = correctedText(segment)
        return correctionSuggestions.filter { $0.resolution == nil && $0.applying(to: text) != nil }
    }

    func mergeSuggestions(_ suggestions: [TranscriptSuggestion]) {
        var known = Set(correctionSuggestions.map(\.id))
        for suggestion in suggestions where known.insert(suggestion.id).inserted {
            correctionSuggestions.append(suggestion)
        }
    }

    func resolveSuggestion(_ suggestion: TranscriptSuggestion, segment: TranscriptSegment, accept: Bool) {
        guard let index = correctionSuggestions.firstIndex(where: { $0.id == suggestion.id }),
              correctionSuggestions[index].resolution == nil else { return }
        if accept {
            guard let replacement = suggestion.applying(to: correctedText(segment)) else { return }
            correctionSuggestions[index].resolution = "accepted"
            correct(segment, to: replacement)
        } else {
            correctionSuggestions[index].resolution = "dismissed"
            persistDraft()
        }
    }

    func correct(_ segment: TranscriptSegment, to replacement: String) {
        guard replacement != correctedText(segment) else { return }
        let before = evidenceTranscriptText
        corrections[segment.id] = TranscriptCorrection(original: segment.text, replacement: replacement)
        correctionRevision = UUID().uuidString
        askedQuestions = TranscriptOffsets.rebase(askedQuestions, from: before, to: evidenceTranscriptText)
        analysisStatus = "Reviewing corrected content"
        persistDraft()
        scheduleAnalysis()
    }

    private let capture = LiveCaptureCoordinator()
    private var transcriptAssembler = TranscriptAssembler()
    private var analysisTask: Task<Void, Never>?
    private var captureStartedAt: Date?
    private var capturedDuration: TimeInterval = 0

    init(draftURL: URL = MeetingDraft.defaultURL, automaticallyAnalyze: Bool = true) {
        self.draftURL = draftURL
        self.automaticallyAnalyze = automaticallyAnalyze
        capture.onTranscript = { [weak self] update in
            Task { @MainActor in
                self?.acceptTranscript(update)
            }
        }
        capture.onStatus = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused else { return }
                self.status = message
            }
        }
        capture.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self, self.isRunning, !self.isPaused, !self.isTransitioning else { return }
                self.isPaused = true
                self.isTransitioning = true
                if let started = self.captureStartedAt { self.capturedDuration += Date().timeIntervalSince(started) }
                self.captureStartedAt = nil
                await self.capture.stop()
                self.isTransitioning = false
                self.status = "Transcription paused: " + message
                self.persistDraft()
            }
        }
        if FileManager.default.fileExists(atPath: draftURL.path) {
            do {
                let draft = try MeetingDraft.load(from: draftURL)
                let restoredCards = try JSONDecoder().decode([QuestionCard].self, from: draft.cards)
                meetingSessionID = draft.sessionID
                transcriptAssembler = TranscriptAssembler(fragments: draft.fragments)
                segments = transcriptAssembler.paragraphs()
                corrections = draft.corrections
                correctionSuggestions = draft.correctionSuggestions ?? []
                termFixes = draft.termFixes ?? []
                analysisCheckpoint = draft.analysisCheckpoint ?? ""
                cards = restoredCards
                cardPayload = draft.cards
                questionMemory = draft.questionMemory
                questionOrder = draft.questionOrder
                interviewMode = draft.interviewMode
                // Background is deliberately per launch; meeting records may still be restored.
                projectContext = ""
                terminologyNotes = draft.terminologyNotes
                questionerSpeaker = TranscriptChannel.displayName(draft.questionerSpeaker)
                askedQuestions = draft.askedQuestions
                correctionRevision = draft.correctionRevision
                apiUsage = draft.apiUsage
                research.reports = ResearchReport.restoringLegacyQuestions(draft.researchReports ?? [])
                research.gateUsage = draft.researchGateUsage ?? ResearchUsage(calls: 0, input_tokens: 0, output_tokens: 0)
                research.observeDiscussion(researchDiscussion)
                if !segments.isEmpty || !cards.isEmpty || !research.reports.isEmpty {
                    requiresResumeChoice = true
                    status = "Previous meeting restored; capture has not started"
                    draftStatus = "Local draft restored"
                }
            } catch {
                draftStatus = "Unable to read the previous draft; original file preserved"
            }
        }
        if automaticallyAnalyze {
            researchWatchTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, let self else { return }
                    guard self.allowsAutomaticResearch else { continue }
                    self.research.consider(transcript: self.transcriptText, background: self.projectContext,
                        scope: self.researchScope, save: { [weak self] in self?.persistDraft() })
                }
            }
        }
        if !questionUpdatesEnabled { analysisStatus = "Question updates off" }
    }

    @discardableResult func persistDraft() -> Bool {
        do {
            try MeetingDraft(sessionID: meetingSessionID, fragments: transcriptAssembler.fragments,
                corrections: corrections, cards: cardPayload, questionMemory: questionMemory,
                questionOrder: questionOrder, interviewMode: interviewMode, projectContext: projectContext,
                terminologyNotes: terminologyNotes, questionerSpeaker: questionerSpeaker,
                askedQuestions: askedQuestions, correctionRevision: correctionRevision, apiUsage: apiUsage,
                researchReports: research.reports, researchGateUsage: research.gateUsage,
                correctionSuggestions: correctionSuggestions, termFixes: termFixes,
                analysisCheckpoint: analysisCheckpoint).save(to: draftURL)
            lastDraftSave = Date()
            draftStatus = "Draft saved locally"
            return true
        } catch {
            draftStatus = "Draft save failed; export your notes soon"
            return false
        }
    }

    var transcriptText: String {
        formattedTranscript(standardizeTerms: true)
    }

    var evidenceTranscriptText: String {
        formattedTranscript(standardizeTerms: false)
    }

    private func formattedTranscript(standardizeTerms: Bool) -> String {
        transcriptAssembler.paragraphs(finalOnly: true)
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.id < rhs.id }
                return lhs.start < rhs.start
            }
            .map { segment in
                let text = standardizeTerms ? correctedText(segment) : (corrections[segment.id]?.apply(to: segment.text) ?? segment.text)
                return "\(TranscriptChannel.displayName(segment.speaker)): \(text)"
            }
            .joined(separator: "\n")
    }

    func start() {
        guard !isRunning, !isTransitioning else { return }
        if requiresResumeChoice { showsStartChoice = true; return }
        isRunning = true
        isPaused = false
        isTransitioning = true
        capturedDuration = (segments.map(\.end).max() ?? 0) + (segments.isEmpty ? 0 : 1)
        status = "Preparing live transcription..."
        Task {
            do {
                try await BackendService.shared.ensureRunning()
                capture.transcriptOffset = capturedDuration
                try await capture.start(source: audioSource, engine: transcriptionEngine)
                captureStartedAt = Date()
                isTransitioning = false
                status = audioSource.listeningStatus
            } catch {
                await capture.stop()
                isRunning = false
                isPaused = false
                isTransitioning = false
                status = friendly(error)
            }
        }
    }

    func continueMeeting() {
        requiresResumeChoice = false
        showsStartChoice = false
        start()
    }

    func startNewMeeting() {
        guard !isRunning, !isTransitioning else { return }
        guard clear() else { return }
        start()
    }

    func pause() {
        guard isRunning, !isPaused, !isTransitioning else { return }
        isPaused = true
        isTransitioning = true
        status = "Pausing..."
        if let captureStartedAt {
            capturedDuration += Date().timeIntervalSince(captureStartedAt)
        }
        captureStartedAt = nil
        Task {
            await capture.stop()
            isTransitioning = false
            status = "Paused; current content preserved"
            persistDraft()
        }
    }

    func resume() {
        guard isRunning, isPaused, !isTransitioning else { return }
        isTransitioning = true
        status = "Resuming live transcription..."
        Task {
            do {
                capture.transcriptOffset = capturedDuration
                try await capture.start(source: audioSource, engine: transcriptionEngine)
                captureStartedAt = Date()
                isPaused = false
                isTransitioning = false
                status = audioSource.listeningStatus
            } catch {
                await capture.stop()
                isTransitioning = false
                status = "Resume failed: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        guard isRunning, !isTransitioning else { return }
        isTransitioning = true
        Task {
            if !isPaused {
                await capture.stop()
            }
            captureStartedAt = nil
            isRunning = false
            isPaused = false
            isTransitioning = false
            status = "Stopped"
            requiresResumeChoice = true
            persistDraft()
            scheduleAnalysis()
        }
    }

    @discardableResult func clear() -> Bool {
        guard !isRunning, !isTransitioning else { return false }
        guard archiveCurrentMeeting() else { return false }
        let previousSession = meetingSessionID
        apiUsage = APITokenUsage()
        analysisTask?.cancel()
        analysisTask = nil
        analysisRevision += 1
        analysisStatus = questionUpdatesEnabled ? "Waiting for meeting content" : "Question updates off"
        segments = []
        transcriptAssembler = TranscriptAssembler()
        cards = []
        corrections = [:]
        correctionSuggestions = []
        termFixes = []
        analysisCheckpoint = ""
        askedQuestions = [:]
        terminologyNotes = ""
        projectContext = ""
        UserDefaults.standard.removeObject(forKey: "projectContext")
        requiresResumeChoice = false
        showsStartChoice = false
        correctionRevision = ""
        meetingSessionID = UUID().uuidString
        research.invalidate(scope: researchScope, clear: true)
        allowsAutomaticResearch = false
        cardPayload = Data("[]".utf8)
        questionMemory = Data("[]".utf8)
        questionOrder = []
        analysisError = ""
        persistDraft()
        status = isPaused ? "Paused; current content preserved" : (isRunning ? audioSource.listeningStatus : "Ready")
        guard automaticallyAnalyze else { return true }
        let clearedSession = meetingSessionID
        Task {
            do {
                try await BackendService.shared.ensureRunning()
                var request = URLRequest(url: backendURL.appending(path: "/api/copilot_live_reset"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["session_id": clearedSession, "previous_session_id": previousSession])
                _ = try await URLSession.shared.data(for: request)
            } catch {
                return
            }
        }
        return true
    }

    private func archiveCurrentMeeting() -> Bool {
        guard !segments.isEmpty || !cards.isEmpty || !projectContext.isEmpty || !research.reports.isEmpty else { return true }
        guard persistDraft() else { return false }
        do {
            let draft = try MeetingDraft.load(from: draftURL)
            let archive = try draft.archive(beside: draftURL)
            try exportDocument().write(to: archive.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
            return true
        } catch {
            draftStatus = "Backup failed; current meeting preserved"
            return false
        }
    }

    func reanalyzeCurrentMeeting() {
        guard questionUpdatesEnabled else { return }
        guard archiveCurrentMeeting() else { return }
        analysisTask?.cancel()
        analysisTask = nil
        meetingSessionID = UUID().uuidString
        cards = []
        cardPayload = Data("[]".utf8)
        questionMemory = Data("[]".utf8)
        questionOrder = []
        askedQuestions = [:]
        analysisError = ""
        analysisStatus = "Regenerating questions from this meeting"
        analysisCheckpoint = ""
        persistDraft()
        scheduleAnalysis()
    }

    func togglePin() {
        isPinned.toggle()
        NSApp.windows.first?.level = isPinned ? .floating : .normal
    }

    func exportMeeting() {
        let panel = NSSavePanel()
        panel.title = "Export meeting notes"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Meeting notes_\(fileTimestamp()).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportDocument().write(to: url, atomically: true, encoding: .utf8)
            status = "Exported: \(url.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func exportDocument() -> String {
        let orderedSegments = segments.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id < rhs.id }
            return lhs.start < rhs.start
        }
        let openCards = self.openCards
        let answeredCards = cards.filter(\.isAnswered)
        var lines = [
            "# Meeting notes",
            "",
            "- Exported at: \(displayTimestamp())",
            "- Meeting scenario: \(modeLabel)",
            "- Meeting background: \(projectContext.isEmpty ? "Not provided" : projectContext)",
            "- User terminology (not recorded speech): \(terminologyNotes.isEmpty ? "None" : terminologyNotes)",
            "- Transcript segments: \(orderedSegments.count)",
            "- Open questions: \(openCards.count)",
            "- Answered: \(answeredCards.count)",
            "",
            "## Meeting transcript",
            "",
        ]
        if orderedSegments.isEmpty {
            lines.append("No transcript yet.")
        } else {
            for segment in orderedSegments {
                lines.append("**[\(clock(segment.start))] \(TranscriptChannel.displayName(segment.speaker)): ** \(correctedText(segment))")
                if correctedText(segment) != segment.text { lines.append("\n- ASR original (before correction): \(segment.text)") }
                lines.append("")
            }
        }

        if !correctionSuggestions.isEmpty {
            lines.append(contentsOf: ["## Suggested corrections", ""])
            for suggestion in correctionSuggestions {
                let state = suggestion.resolution == "edited" ? "Saved after editing" : suggestion.resolution == "accepted" ? "Accepted by user" : suggestion.resolution == "dismissed" ? "Dismissed by user" : "Needs confirmation"
                lines.append("- [\(state)] Original: \(suggestion.original); Possible correction: \(suggestion.replacement)")
                lines.append("  Evidence/Uncertainty: \(suggestion.reason)")
                if let edited = suggestion.editedText { lines.append("  User correction: \(edited)") }
            }
            lines.append("")
        }
        lines.append(contentsOf: ["## Follow-up questions", ""])
        if openCards.isEmpty {
            lines.append("No open questions yet.")
            lines.append("")
        } else {
            for (index, card) in openCards.enumerated() {
                lines.append("### \(index + 1). [\(card.category)] \(card.question)")
                lines.append("")
                lines.append("- Priority: \(card.priority)")
                lines.append("- Why ask: \(card.reason)")
                if let anchor = card.anchor, !anchor.isEmpty { lines.append("- Quoted evidence: \(anchor)") }
                if let evidence = card.evidence_needed, !evidence.isEmpty { lines.append("- Evidence needed: \(evidence)") }
                if let answer = card.answer_summary, !answer.isEmpty { lines.append("- Answered parts: \(answer)") }
                appendVerification(card, to: &lines)
                lines.append("")
            }
        }

        lines.append(contentsOf: ["## Answered questions", ""])
        if answeredCards.isEmpty {
            lines.append("No answered questions yet.")
        } else {
            for (index, card) in answeredCards.enumerated() {
                lines.append("### \(index + 1). [\(card.category)] \(card.question)")
                lines.append("")
                lines.append("- Answer: \(card.answer_summary ?? card.reason)")
                lines.append("- Answer status: \(card.answerLabel)")
                if let missing = card.missing_conditions, !missing.isEmpty { lines.append("- Still missing: \(missing.joined(separator: ", "))") }
                if let anchor = card.anchor, !anchor.isEmpty { lines.append("- Quoted evidence: \(anchor)") }
                if let evidence = card.evidence_needed, !evidence.isEmpty { lines.append("- Evidence needed: \(evidence)") }
                appendVerification(card, to: &lines)
                lines.append("")
            }
        }
        lines.append(research.markdown)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func appendVerification(_ card: QuestionCard, to lines: inout [String]) {
        if !card.verification.isEmpty {
            lines.append("- Web verification: \(card.verification)")
        }
        for result in card.verification_results ?? [] {
            lines.append("- Sources: [\(result.title)](\(result.url))")
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return formatter.string(from: Date())
    }

    private func displayTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private var researchDiscussion: [ResearchDiscussion] {
        transcriptAssembler.fragments.filter(\.isFinal).map {
            ResearchDiscussion(id: $0.id, session: $0.session, start: $0.start, end: $0.end,
                               text: corrections[$0.id]?.apply(to: $0.text) ?? $0.text)
        }
    }

    func acceptTranscript(_ update: TranscriptUpdate) {
        if update.isFinal { allowsAutomaticResearch = true }
        transcriptAssembler.accept(update)
        segments = transcriptAssembler.paragraphs()
        research.observeDiscussion(researchDiscussion)
        if update.isFinal || Date().timeIntervalSince(lastDraftSave) >= 2 { persistDraft() }
        scheduleAnalysis()
    }

    func runResearch(manual: Bool) {
        research.run(transcript: transcriptText, background: projectContext, scope: researchScope,
            manual: manual, save: { [weak self] in self?.persistDraft() })
    }

    func setQuestionUpdatesEnabled(_ enabled: Bool) {
        guard enabled != questionUpdatesEnabled else { return }
        questionUpdatesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "copilotQuestionUpdatesEnabled")
        analysisTask?.cancel()
        analysisTask = nil
        analysisError = ""
        analysisStatus = enabled ? "Waiting to batch new content" : "Question updates off"
        persistDraft()
        if enabled { scheduleAnalysis() }
    }

    private func scheduleAnalysis() {
        analysisRevision += 1
        research.invalidate(scope: researchScope)
        guard questionUpdatesEnabled else {
            analysisStatus = "Question updates off"
            return
        }
        guard automaticallyAnalyze else { return }
        guard analysisTask == nil else { return }
        analysisTask = Task {
            var stablePolls = 0
            var lastRevision = analysisRevision
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if lastRevision == analysisRevision { stablePolls += 1 } else { stablePolls = 0 }
                lastRevision = analysisRevision
                if (transcriptText + projectContext).count >= 20 {
                    await requestCards(transcript: evidenceTranscriptText)
                } else {
                    analysisStatus = "Waiting for more details"
                }
                if stablePolls >= 3 && (analysisStatus.hasPrefix("Using") || analysisStatus.hasPrefix("Waiting") || analysisStatus.hasPrefix("No new items")) { break }
                if stablePolls >= 60 { break }
            }
            if !Task.isCancelled { analysisTask = nil }
        }
    }

    private func requestCards(transcript: String) async {
        guard questionUpdatesEnabled, !Task.isCancelled else { return }
        var request = URLRequest(url: backendURL.appending(path: "/api/copilot_live_transcript"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestScope = analysisScope
        let sessionID = meetingSessionID
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "transcript": transcript, "interview_mode": interviewMode, "project_context": projectContext,
            "terminology_notes": terminologyNotes, "questioner_speaker": questionerSpeaker,
            "asked_questions": askedQuestions, "correction_revision": correctionRevision,
            "session_id": sessionID,
            "restore_cards": (try? JSONSerialization.jsonObject(with: questionMemory)) ?? [],
            "restore_checkpoint": analysisCheckpoint,
            "restore_usage": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(apiUsage))) ?? [:]
        ])
        do {
            try await BackendService.shared.ensureRunning()
            guard questionUpdatesEnabled, !Task.isCancelled else { return }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard questionUpdatesEnabled, !Task.isCancelled, requestScope == analysisScope, sessionID == meetingSessionID else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let result = try JSONDecoder().decode(CopilotResponse.self, from: data)
            if result.ok {
                applyCardResponse(data, decoded: result.details.cards)
                analysisStatus = result.details.analysis_status ?? "Waiting for analysis"
                analysisError = result.details.analysis_error ?? ""
                apiUsage = result.details.token_usage ?? APITokenUsage()
                mergeTermFixes(result.details.term_fixes ?? [])
                if let checkpoint = result.details.analysis_checkpoint { analysisCheckpoint = checkpoint }
                persistDraft()
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            guard questionUpdatesEnabled, !Task.isCancelled else { return }
            analysisStatus = "Analysis unavailable; existing Q&A preserved"
        }
    }

    func applyCardResponse(_ data: Data, decoded: [QuestionCard]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = root["details"] as? [String: Any],
              let rawCards = details["cards"],
              let payload = try? JSONSerialization.data(withJSONObject: rawCards) else { return }
        cards = decoded
        cardPayload = payload
        questionMemory = (try? JSONSerialization.data(withJSONObject: details["question_memory"] ?? rawCards)) ?? payload
        var known = Set(questionOrder)
        for card in decoded where known.insert(card.id).inserted { questionOrder.append(card.id) }
    }

    private func friendly(_ error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("permission") || message.contains("Authorize") {
            return "Allow screen and system audio, microphone and speech recognition in System Settings"
        }
        return "Start failed: \(message)"
    }
}

enum CopilotError: LocalizedError {
    case noDisplay
    case microphoneDenied
    case speechDenied
    case unsupportedLocale
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No system audio source available"
        case .microphoneDenied: return "Microphone access denied"
        case .speechDenied: return "Speech recognition access denied"
        case .unsupportedLocale: return "English speech recognition resources are not installed"
        case .backendUnavailable: return "Meeting analysis service unavailable"
        }
    }
}

final class LiveSpeechChannel: LiveTranscriptionChannel, @unchecked Sendable {
    let speaker: String
    let audioFormat: AVAudioFormat

    private let analyzer: SpeechAnalyzer
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private let lock = NSLock()

    static func create(
        speaker: String,
        session: String,
        offset: Double,
        onResult: @escaping @Sendable (TranscriptUpdate) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws -> LiveSpeechChannel {
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "en_US")
        ) else {
            throw CopilotError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CopilotError.unsupportedLocale
        }
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        try await analyzer.prepareToAnalyze(in: format)
        let (inputStream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let channel = LiveSpeechChannel(
            speaker: speaker,
            audioFormat: format,
            analyzer: analyzer,
            continuation: continuation
        )

        Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    onResult(TranscriptUpdate(session: session, speaker: speaker, text: text,
                        start: result.range.start.seconds + offset, end: result.range.end.seconds + offset,
                        isFinal: result.isFinal, finalizedThrough: result.resultsFinalizationTime.seconds + offset))
                }
            } catch {
                onError("\(speaker): Speech recognition failed: \(error.localizedDescription)")
            }
        }
        Task.detached(priority: .userInitiated) {
            do {
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                onError("\(speaker): Speech analyzer failed: \(error.localizedDescription)")
            }
        }
        return channel
    }

    private init(
        speaker: String,
        audioFormat: AVAudioFormat,
        analyzer: SpeechAnalyzer,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.speaker = speaker
        self.audioFormat = audioFormat
        self.analyzer = analyzer
        self.continuation = continuation
    }

    func append(_ buffer: AVAudioPCMBuffer, startTime: CMTime?) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let converted = try convert(buffer)
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
        } catch { }
    }

    func finish() async {
        continuation.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == audioFormat { return input }
        if converter == nil || converterSourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: audioFormat)
            converterSourceFormat = input.format
        }
        guard let converter else { throw CopilotError.unsupportedLocale }
        let ratio = audioFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 8
        guard let output = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: capacity) else {
            throw CopilotError.unsupportedLocale
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw conversionError ?? CopilotError.unsupportedLocale }
        return output
    }
}

final class LiveCaptureCoordinator: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    var transcriptOffset: Double = 0

    private var stream: SCStream?
    private var systemChannel: (any LiveTranscriptionChannel)?
    private var microphoneChannel: (any LiveTranscriptionChannel)?
    private var qwenWorker: QwenSpeechWorker?
    private let microphoneEngine = AVAudioEngine()
    private let systemQueue = DispatchQueue(label: "meeting-copilot.system-audio", qos: .userInitiated)
    private var receivedSystemAudio = false
    private var receivedMicrophoneAudio = false
    private var microphoneTapInstalled = false

    func start(source: CopilotAudioSource, engine: CopilotTranscriber = .apple) async throws {
        receivedSystemAudio = false
        receivedMicrophoneAudio = false
        if source.includesMicrophone {
            guard await requestMicrophonePermission() else { throw CopilotError.microphoneDenied }
        }
        if engine == .apple {
            guard await requestSpeechPermission() else { throw CopilotError.speechDenied }
        }

        onStatus?(engine == .apple ? "Loading Mac live speech model..." : "Loading local Qwen speech model...")
        if engine == .qwen {
            let worker = try QwenSpeechWorker()
            qwenWorker = worker
            _ = try await worker.request(["command": "load"])
        }
        let segmentOffset = transcriptOffset
        let session = UUID().uuidString
        let resultHandler: @Sendable (TranscriptUpdate) -> Void = { [weak self] update in
            self?.onTranscript?(update)
        }
        let errorHandler: @Sendable (String) -> Void = { [weak self] message in
            if engine == .qwen { self?.onFailure?(message) }
            else { self?.onStatus?(message) }
        }
        func channel(_ speaker: String) async throws -> any LiveTranscriptionChannel {
            if let worker = qwenWorker, engine == .qwen {
                let channel = QwenSpeechChannel(worker: worker, session: session, speaker: speaker, offset: segmentOffset,
                    onResult: resultHandler, onError: errorHandler,
                    onWarning: { [weak self] message in self?.onStatus?(message) })
                try await channel.prepare()
                return channel
            }
            return try await LiveSpeechChannel.create(speaker: speaker, session: session, offset: segmentOffset,
                onResult: resultHandler, onError: errorHandler)
        }
        if source.includesMicrophone {
            microphoneChannel = try await channel("Me")
            try startMicrophoneCapture()
        }

        guard source.includesSystem else { return }
        systemChannel = try await channel("Other")

        onStatus?("Connecting system audio...")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw CopilotError.noDisplay }
        let ownApplications = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(systemChannel?.audioFormat.sampleRate ?? 16_000)
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: systemQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        if microphoneTapInstalled {
            microphoneEngine.inputNode.removeTap(onBus: 0)
            microphoneTapInstalled = false
        }
        microphoneEngine.stop()
        microphoneEngine.reset()
        await systemChannel?.finish()
        await microphoneChannel?.finish()
        systemChannel = nil
        microphoneChannel = nil
        qwenWorker = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid, let buffer = makePCMBuffer(sampleBuffer) else { return }
        switch outputType {
        case .audio:
            if !receivedSystemAudio {
                receivedSystemAudio = true
                onStatus?(receivedMicrophoneAudio
                    ? "Both audio channels connected; transcribing live"
                    : "System audio connected; transcribing live")
            }
            systemChannel?.append(buffer, startTime: nil)
        case .microphone:
            if !receivedMicrophoneAudio {
                receivedMicrophoneAudio = true
                onStatus?(receivedSystemAudio
                    ? "Both audio channels connected; transcribing live"
                    : "Microphone connected; transcribing live")
            }
            microphoneChannel?.append(buffer, startTime: nil)
        default:
            break
        }
    }

    private func startMicrophoneCapture() throws {
        let input = microphoneEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if !self.receivedMicrophoneAudio {
                self.receivedMicrophoneAudio = true
                self.onStatus?(self.receivedSystemAudio
                    ? "Both audio channels connected; transcribing live"
                    : "Microphone connected; transcribing live")
            }
            self.microphoneChannel?.append(buffer, startTime: nil)
        }
        microphoneTapInstalled = true
        microphoneEngine.prepare()
        try microphoneEngine.start()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStatus?("Audio capture stopped: \(error.localizedDescription)")
    }

    private func makePCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard
            let description = CMSampleBufferGetFormatDescription(sampleBuffer),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func requestSpeechPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }
}

struct QuestionCardView: View {
    let card: QuestionCard
    let textScale: CGFloat
    var markedAsked = false
    var onMarkAsked: (() -> Void)? = nil

    var priorityColor: Color {
        if card.isAnswered { return card.needsAttention ? .red : .green }
        return card.priority == "High" ? .red : (card.priority == "Medium" ? .orange : .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Circle().fill(priorityColor).frame(width: 7, height: 7)
                Text(card.category).font(.system(size: 13 * textScale, weight: .semibold))
                Spacer()
                Text(card.isAnswered ? card.answerLabel : "\(card.priority) priority")
                    .font(.system(size: 11 * textScale))
                    .foregroundStyle(priorityColor)
            }
            if card.isAnswered {
                Text(card.question).font(.system(size: 13 * textScale)).textSelection(.enabled)
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: card.needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(priorityColor)
                    Text(card.answer_summary ?? card.reason)
                        .font(.system(size: 14 * textScale))
                        .foregroundStyle(priorityColor)
                        .textSelection(.enabled)
                }
            } else {
                Text(card.question)
                    .font(.system(size: 14 * textScale))
                    .textSelection(.enabled)
                if let answer = card.answer_summary, !answer.isEmpty {
                    Text("Answered parts: \(answer)").font(.system(size: 12 * textScale)).foregroundStyle(.secondary)
                }
                Text(card.reason).font(.system(size: 12 * textScale)).foregroundStyle(.secondary)
                if let onMarkAsked {
                    Button(action: onMarkAsked) {
                        Label(markedAsked ? "Marked as asked" : "Mark as asked", systemImage: markedAsked ? "checkmark.bubble" : "questionmark.bubble")
                    }
                    .disabled(markedAsked)
                    .help("Mark this question as asked; related but incomplete answers will be flagged as nonresponsive")
                }
            }
            if let missing = card.missing_conditions, !missing.isEmpty {
                Text("Still missing: \(missing.joined(separator: ", "))")
                    .font(.system(size: 12 * textScale)).foregroundStyle(card.needsAttention ? Color.red : Color.secondary)
            }
            if let anchor = card.anchor, !anchor.isEmpty {
                Text("\(card.source_kind == "project_background" ? "Background" : "Original"): \(anchor)").font(.system(size: 11 * textScale)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let evidence = card.evidence_needed, !evidence.isEmpty {
                Text("Evidence needed: \(evidence)").font(.system(size: 12 * textScale)).textSelection(.enabled)
            }
            if !card.verification.isEmpty {
                Text(card.verification)
                    .font(.system(size: 11 * textScale))
                    .foregroundStyle(.secondary)
            }
            ForEach(card.verification_results ?? []) { result in
                if let url = URL(string: result.url) {
                    Link(result.title, destination: url)
                        .font(.system(size: 11 * textScale))
                        .lineLimit(2)
                }
            }
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(priorityColor).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case copilot
    case recorder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copilot: return "Copilot"
        case .recorder: return "OBS Recording settings"
        }
    }
}

struct CopilotTabView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var model: CopilotViewModel
    var obsEnabled = false
    @State private var textScale: CGFloat = 1
    @State private var showsAISettings = !UserDefaults.standard.bool(forKey: "copilotAIConfigured")
    @State private var showsProjectContext = false
    @State private var projectDraft = ""
    @State private var showsTerminology = false
    @State private var terminologyDraft = ""
    @State private var editingSegment: TranscriptSegment?
    @State private var transcriptEditText = ""
    @State private var questionerDraft = "Microphone"
    @State private var confirmsNewMeeting = false
    @State private var confirmsReanalysis = false
    @State private var showsResearch = true
    @State private var transcriptFollow = TranscriptFollowState()

    private var openCards: [QuestionCard] { model.openCards }
    private var answeredCards: [QuestionCard] { model.cards.filter(\.isAnswered) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meeting Copilot").font(.system(size: 15, weight: .semibold))
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { textScale = max(0.8, textScale - 0.1) } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .disabled(textScale <= 0.8)
                .help("Smaller text")
                Button { textScale = min(1.5, textScale + 0.1) } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .disabled(textScale >= 1.5)
                .help("Larger text")
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                }
                .help(model.isPinned ? "Unpin window" : "Pin window")
                Button { showsAISettings = true } label: {
                    Image(systemName: "brain.head.profile")
                }
                .help("AI settings")
                Button { model.exportMeeting() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(model.segments.isEmpty && model.cards.isEmpty && model.research.reports.isEmpty)
                .help("Export transcript, questions and answers")
                Button { confirmsNewMeeting = true } label: { Image(systemName: "doc.badge.plus") }
                .help("New meeting: back up notes and clear transcript, Q&A and background")
                .disabled(model.isRunning || model.isTransitioning)
                Button { confirmsReanalysis = true } label: { Image(systemName: "arrow.clockwise") }
                .help("Reanalyze: keep transcript, back up Q&A and regenerate questions")
                .disabled(model.segments.isEmpty || !model.questionUpdatesEnabled)
                if obsEnabled {
                    Button { selectedTab = .recorder } label: { Image(systemName: "slider.horizontal.3") }
                        .help("Switch to OBS Recording settings")
                }
                Button { showsResearch.toggle() } label: { Image(systemName: "sidebar.right") }
                    .help(showsResearch ? "Hide research" : "Show research")
                if model.isRunning {
                    Button { model.pause() } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .disabled(model.isPaused || model.isTransitioning)
                    Button { model.resume() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .disabled(!model.isPaused || model.isTransitioning)
                    Button { model.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.isTransitioning)
                } else {
                    Button { model.start() } label: {
                        Label("Start", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTransitioning)
                }
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                RuleSelection(kind: "interview", label: "Meeting scenario", selection: $model.interviewMode,
                              onContentChanged: { model.updateInterviewContext() })
                .onChange(of: model.interviewMode) { _, _ in model.updateInterviewContext() }
                Button {
                    projectDraft = model.projectContext
                    showsProjectContext = true
                } label: {
                    Label("Meeting background", systemImage: model.projectContext.isEmpty ? "doc.badge.plus" : "doc.text")
                }
                Picker("Capture audio", selection: Binding(
                    get: { model.audioSource }, set: { model.selectAudioSource($0) }
                )) {
                    ForEach(CopilotAudioSource.allCases, id: \.self) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .frame(width: 142)
                .disabled(!model.canChangeAudioSource)
                .help("Copilot Audio capture, independent of OBS; Stop transcription to switch")
                Spacer()
                Text(model.analysisStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(model.analysisError)
                Button {
                    NSWorkspace.shared.open(appDirectory.appending(path: "docs/meeting-guide.md"))
                } label: { Image(systemName: "book") }
                .help("Meeting guidance and references")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()

            ResizableSplit(horizontal: true, key: "copilotResearchWidth", minimumFirst: 330, minimumSecond: 300,
                           secondVisible: showsResearch) {
            ResizableSplit(horizontal: false, key: "copilotTranscriptHeight", minimumFirst: 145, minimumSecond: 145) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Live transcript").font(.system(size: 13, weight: .semibold))
                        Menu {
                            Picker("Transcription engine", selection: $model.transcriptionEngine) {
                                ForEach(CopilotTranscriber.allCases, id: \.self) { engine in
                                    Text(engine.title).tag(engine)
                                }
                            }.disabled(!model.canChangeAudioSource)
                        } label: {
                            Label(model.transcriptionEngine == .qwen ? "Qwen" : "Apple", systemImage: "waveform")
                        }.fixedSize().help("Local transcription engine; stop to switch. Analysis settings are separate.")
                        if !model.draftStatus.isEmpty {
                            Image(systemName: model.draftStatus.contains("Failed") ? "exclamationmark.triangle" : "internaldrive")
                                .foregroundStyle(.secondary).help(model.draftStatus)
                        }
                        Spacer()
                        if model.apiUsage.calls > 0 {
                            Text("API · Input \(model.apiUsage.input_tokens.formatted()) / Output \(model.apiUsage.output_tokens.formatted())")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Meeting total \(model.apiUsage.calls) calls API responses; cached input \(model.apiUsage.cached_tokens.formatted()) tokens.Resets for a new meeting; consult your provider for billing.")
                        }
                        Button {
                            terminologyDraft = model.terminologyNotes
                            questionerDraft = model.questionerSpeaker
                            showsTerminology = true
                        } label: { Image(systemName: "text.badge.checkmark") }
                        .help("Terminology and questioner settings")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if model.segments.isEmpty {
                                    ContentUnavailableView(
                                        "Waiting for meeting audio",
                                        systemImage: "waveform",
                                        description: Text("Start capture to see live transcription here")
                                    )
                                    .frame(maxWidth: .infinity, minHeight: 180)
                                } else {
                                    ForEach(model.segments.sorted(by: { $0.start < $1.start })) { segment in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(TranscriptChannel.displayName(segment.speaker))
                                                .font(.system(size: 11 * textScale, weight: .semibold))
                                                .foregroundStyle(segment.speaker == "Other" ? Color.blue : Color.green)
                                                .frame(width: 44 * textScale, alignment: .leading)
                                            VStack(alignment: .leading, spacing: 5) {
                                                if editingSegment?.id == segment.id {
                                                    TranscriptInlineEditor(text: $transcriptEditText)
                                                        .frame(height: 140)
                                                    HStack {
                                                        Spacer()
                                                        Button("Cancel") {
                                                            editingSegment = nil
                                                            model.isEditingTranscript = false
                                                        }
                                                        Button("Save") {
                                                            if let original = editingSegment { model.correct(original, to: transcriptEditText) }
                                                            editingSegment = nil
                                                            model.isEditingTranscript = false
                                                        }
                                                        .disabled(transcriptEditText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || transcriptEditText.count > 2000)
                                                    }
                                                } else {
                                                    Text(model.correctedText(segment))
                                                        .font(.system(size: 14 * textScale))
                                                        .textSelection(.enabled)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            if segment.isFinal {
                                                Button {
                                                    transcriptFollow.pause()
                                                    editingSegment = segment
                                                    transcriptEditText = model.correctedText(segment)
                                                    model.isEditingTranscript = true
                                                } label: { Image(systemName: "pencil") }
                                                .buttonStyle(.borderless)
                                                .help("Correct this segment")
                                                .disabled(model.isEditingTranscript)
                                            }
                                        }
                                        .id(segment.id)
                                    }
                                }
                                Color.clear.frame(height: 1).id("transcript-bottom")
                            }
                            .padding(12)
                        }
                        .scrollIndicators(.visible)
                        .onScrollGeometryChange(for: Bool.self) { geometry in
                            geometry.contentSize.height - geometry.visibleRect.maxY <= 30
                        } action: { _, atBottom in
                            transcriptFollow.atBottom = atBottom
                        }
                        .onScrollPhaseChange { _, phase in
                            switch phase {
                            case .tracking, .interacting, .decelerating:
                                transcriptFollow.beginUserScroll()
                            case .idle:
                                transcriptFollow.endUserScroll()
                            default: break
                            }
                        }
                        .onChange(of: model.isEditingTranscript) { _, editing in
                            if editing { transcriptFollow.pause() }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if !transcriptFollow.followsLatest && !model.segments.isEmpty {
                                Button {
                                    transcriptFollow.resume()
                                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                                } label: { Image(systemName: "arrow.down.to.line") }
                                .buttonStyle(.bordered).help("Jump to latest and follow transcript")
                                .padding(10)
                            }
                        }
                        .task(id: model.segments.last?.text) {
                            // Never mutate scroll layout synchronously during text editing or a layout pass.
                            try? await Task.sleep(for: .milliseconds(180))
                            guard !Task.isCancelled, transcriptFollow.followsLatest,
                                  !model.isEditingTranscript, selectedTab == .copilot else { return }
                            proxy.scrollTo("transcript-bottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } second: {
                VStack(spacing: 0) {
                    HStack {
                        Text("Follow-up questions").font(.system(size: 13, weight: .semibold))
                        Toggle("Auto-update", isOn: Binding(
                            get: { model.questionUpdatesEnabled },
                            set: { model.setQuestionUpdatesEnabled($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .fixedSize()
                            .help("Turn off to preserve Q&A and pause corrections, answer updates and new questions. Transcription and research continue. Sent requests may still be billed.")
                        Spacer()
                        Text("\(openCards.count) open · \(answeredCards.count) answered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if model.cards.isEmpty {
                                ContentUnavailableView(
                                    model.questionUpdatesEnabled ? "Waiting for analysis" : "Question updates off",
                                    systemImage: "text.bubble",
                                    description: Text(model.questionUpdatesEnabled ? "Follow-up questions appear here as the meeting progresses" : "")
                                )
                                .frame(maxWidth: .infinity, minHeight: 180)
                            }
                            ForEach(openCards) { card in
                                QuestionCardView(card: card, textScale: textScale,
                                    markedAsked: model.askedQuestions[card.id] != nil,
                                    onMarkAsked: { model.markAsked(card) })
                            }
                            if !answeredCards.isEmpty {
                                HStack {
                                    Text("Answered")
                                        .font(.system(size: 12 * textScale, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Divider()
                                }
                                .padding(.top, 4)
                                ForEach(answeredCards) { card in
                                    QuestionCardView(card: card, textScale: textScale)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .scrollIndicators(.visible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            } second: {
                ResearchPanel(research: model.research, onAsk: { model.runResearch(manual: true) },
                              onRefresh: { model.runResearch(manual: false) },
                              onRuleChange: { model.updateResearchRule() })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showsAISettings) {
            AISettingsView()
        }
        .confirmationDialog("Continue the previous meeting or start a new one?", isPresented: $model.showsStartChoice) {
            Button("Continue previous meeting") { model.continueMeeting() }
            Button("New meeting (back up previous notes)") { model.startNewMeeting() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("The current meeting will be backed up. A new meeting starts with empty background and questions.", isPresented: $confirmsNewMeeting) {
            Button("Back up and start new meeting") { model.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Keep this transcript, back up Q&A and regenerate questions. Check the meeting background first.", isPresented: $confirmsReanalysis) {
            Button("Reanalyze meeting") { model.reanalyzeCurrentMeeting() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showsTerminology) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Terminology").font(.headline)
                TextEditor(text: $terminologyDraft).font(.body).border(Color.secondary.opacity(0.3))
                Picker("Questioner channel", selection: $questionerDraft) {
                    Text("Microphone").tag("Microphone")
                    Text("System").tag("System")
                    Text("Manual marking only").tag("")
                }
                .help("Audio channels are not speakers; use manual marking for a shared microphone")
                HStack {
                    Text("\(terminologyDraft.count) / 2000 characters").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { showsTerminology = false }
                    Button("Save") {
                        model.terminologyNotes = terminologyDraft
                        model.questionerSpeaker = questionerDraft
                        model.updateInterviewContext()
                        showsTerminology = false
                    }.buttonStyle(.borderedProminent).disabled(terminologyDraft.count > 2000)
                }
            }.padding(20).frame(width: 580, height: 360)
        }
        .sheet(isPresented: $showsProjectContext) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Meeting background").font(.headline)
                Text("Meeting title, BP summary, known conclusions and meeting goals").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $projectDraft)
                    .font(.body)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Text("\(projectDraft.count) / 6000 characters").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { showsProjectContext = false }
                    Button("Save") {
                        model.projectContext = projectDraft
                        model.updateInterviewContext()
                        showsProjectContext = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(projectDraft.count > 6000)
                }
            }
            .padding(20)
            .frame(width: 580, height: 420)
        }
    }
}

struct OBSWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: UUID

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        } else if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(reloadToken: reloadToken) }

    final class Coordinator {
        var lastReloadToken: UUID
        init(reloadToken: UUID) { self.lastReloadToken = reloadToken }
    }
}

struct OBSSettingsTabView: View {
    @State private var isReady = false
    @State private var errorMessage = ""
    @State private var reloadToken = UUID()

    var body: some View {
        ZStack {
            if isReady {
                OBSWebView(url: backendURL, reloadToken: reloadToken)
            } else if errorMessage.isEmpty {
                ProgressView("Starting OBS configuration service...")
            } else {
                ContentUnavailableView(
                    "Unable to open recording settings",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await prepareAndReload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Reload settings")
            .padding(12)
        }
        .task { await prepareAndReload() }
    }

    private func prepareAndReload() async {
        errorMessage = ""
        do {
            try await BackendService.shared.ensureRunning()
            isReady = true
            reloadToken = UUID()
        } catch {
            isReady = false
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .copilot
    @AppStorage("copilotOBSEnabled") private var obsEnabled = false
    @StateObject private var copilot: CopilotViewModel

    @MainActor init(model: CopilotViewModel? = nil) {
        _copilot = StateObject(wrappedValue: model ?? CopilotViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selectedTab) {
                    Label("Copilot", systemImage: "waveform.and.mic").tag(AppTab.copilot)
                    if obsEnabled {
                        Label("OBS Recording settings", systemImage: "slider.horizontal.3").tag(AppTab.recorder)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
                Menu {
                    Toggle("Enable OBS Module", isOn: $obsEnabled)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Optional module")
                if copilot.isRunning {
                    Label(copilot.isPaused ? "Copilot Paused" : "Copilot Transcribing",
                          systemImage: copilot.isPaused ? "pause.circle" : "waveform")
                        .font(.caption).foregroundStyle(copilot.isPaused ? Color.secondary : Color.green)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ZStack {
                CopilotTabView(selectedTab: $selectedTab, model: copilot, obsEnabled: obsEnabled)
                    .opacity(selectedTab == .copilot ? 1 : 0)
                    .allowsHitTesting(selectedTab == .copilot)
                    .accessibilityHidden(selectedTab != .copilot)
                if obsEnabled {
                    OBSSettingsTabView()
                        .opacity(selectedTab == .recorder ? 1 : 0)
                        .allowsHitTesting(selectedTab == .recorder)
                        .accessibilityHidden(selectedTab != .recorder)
                }
            }
        }
        .frame(
            minWidth: 780,
            idealWidth: 980,
            maxWidth: .infinity,
            minHeight: 700,
            idealHeight: 820,
            maxHeight: .infinity
        )
        .task {
            try? await BackendService.shared.ensureRunning()
        }
        .onAppear {
            selectedTab = .copilot
        }
        .onChange(of: obsEnabled) { _, enabled in
            if !enabled { selectedTab = .copilot }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            copilot.persistDraft()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.level = .normal
            window.collectionBehavior = [.fullScreenPrimary]
            window.title = "Meeting Copilot"
            window.minSize = NSSize(width: 780, height: 700)
            window.setContentSize(NSSize(width: 980, height: 820))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !COPILOT_TESTING
@main
struct MeetingCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 980, height: 820)
    }
}
#endif
