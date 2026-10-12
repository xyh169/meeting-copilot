import Foundation

@main
struct QuestionUpdateTests {
    @MainActor static func main() throws {
        let key = "copilotQuestionUpdatesEnabled"
        let preference = UserDefaults.standard.object(forKey: key)
        defer {
            if let preference { UserDefaults.standard.set(preference, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "draft.json")
        let model = CopilotViewModel(draftURL: url, automaticallyAnalyze: false)
        assert(model.questionUpdatesEnabled)
        let rows: [[String: Any]] = [
            ["id": "open", "category": "test", "priority": "high", "question": "Next step?",
             "reason": "test", "verification": "", "status": "open"],
            ["id": "answered", "category": "test", "priority": "high", "question": "Current stage?",
             "reason": "test", "verification": "", "status": "answered", "answer_summary": "Prototype"]
        ]
        let cards = try JSONDecoder().decode([QuestionCard].self, from: JSONSerialization.data(withJSONObject: rows))
        let response = try JSONSerialization.data(withJSONObject: ["details": ["cards": rows, "question_memory": rows]])
        model.applyCardResponse(response, decoded: cards)
        let researchEnabled = model.research.automatic
        let scope = model.analysisScope
        model.setQuestionUpdatesEnabled(false)
        assert(!model.questionUpdatesEnabled && model.analysisStatus == "Question updates off")
        assert(model.analysisScope == scope)
        assert(model.research.automatic == researchEnabled)
        assert(model.cards.map(\.id) == ["open", "answered"] && model.cards.last?.isAnswered == true)
        model.acceptTranscript(TranscriptUpdate(session: "test", speaker: "microphone", text: "The prototype is ready.",
            start: 0, end: 5, isFinal: true, finalizedThrough: 5))
        assert(model.transcriptText.contains("prototype"))
        model.correct(model.segments[0], to: "The prototype is under testing.")
        model.updateInterviewContext()
        model.reanalyzeCurrentMeeting()
        assert(model.analysisStatus == "Question updates off")
        assert(model.cards.count == 2, "Disabled reanalysis must preserve existing answers")
        let before = try MeetingDraft.load(from: url)
        let restored = CopilotViewModel(draftURL: url, automaticallyAnalyze: false)
        assert(!restored.questionUpdatesEnabled && restored.analysisStatus == "Question updates off")
        assert(restored.cards.count == 2 && restored.transcriptText.contains("under testing"))
        model.setQuestionUpdatesEnabled(true)
        let after = try MeetingDraft.load(from: url)
        assert(model.questionUpdatesEnabled && model.analysisStatus == "Waiting to batch new content")
        assert(after.sessionID == before.sessionID && after.analysisCheckpoint == before.analysisCheckpoint)
        assert(after.questionMemory == before.questionMemory && after.cards == before.cards)
        assert(model.research.automatic == researchEnabled)
        model.setQuestionUpdatesEnabled(false)
        assert(model.clear() && !model.questionUpdatesEnabled)
        assert(model.analysisStatus == "Question updates off")
        print("Question update toggle: defaults, preservation, editing, restoration, resume and clear passed")
    }
}
