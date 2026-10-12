import Foundation

@main
struct TranscriptAssemblerTests {
    static func update(_ text: String, _ start: Double, _ end: Double,
                       final: Bool = true, speaker: String = "Me", session: String = "meeting",
                       finalizedThrough: Double = -.infinity) -> TranscriptUpdate {
        TranscriptUpdate(session: session, speaker: speaker, text: text, start: start,
            end: end, isFinal: final, finalizedThrough: finalizedThrough)
    }

    static func main() {
        var a = TranscriptAssembler()
        a.accept(update("Our prototype is", 0, 2, final: false))
        let originalID = a.paragraphs()[0].id
        a.accept(update("The prototype is a feedback tool", 0.03, 3, final: false))
        assert(a.fragments.count == 1)
        assert(a.paragraphs()[0].id == originalID)
        assert(a.paragraphs()[0].text == "The prototype is a feedback tool")
        assert(a.paragraphs(finalOnly: true).isEmpty)
        a.accept(update("Feedback tool", 0, 3))
        assert(a.fragments.count == 1 && a.paragraphs()[0].text == "Feedback tool")
        assert(a.paragraphs(finalOnly: true).count == 1)
        a.accept(update("for precision tasks", 3.4, 5))
        a.accept(update("detects wear.", 5.8, 8))
        assert(a.paragraphs().count == 1)
        assert(a.paragraphs()[0].text == "Feedback tool for precision tasks detects wear.")
        assert(a.paragraphs()[0].id == originalID)

        var pause = TranscriptAssembler()
        pause.accept(update("First sentence", 0, 1))
        pause.accept(update("Second sentence", 3, 4))
        assert(pause.paragraphs().count == 2)
        pause.accept(update("Resumed speech", 4.2, 5, session: "resumed"))
        assert(pause.paragraphs().count == 3)

        var turns = TranscriptAssembler()
        turns.accept(update("Our prototype", 0, 1))
        turns.accept(update("Please continue", 1.2, 2, speaker: "Other"))
        turns.accept(update("Used for manufacturing", 2.2, 3))
        assert(turns.paragraphs().count == 3)

        var repeated = TranscriptAssembler()
        repeated.accept(update("No customers", 0, 1))
        repeated.accept(update("No customers", 1.2, 2))
        assert(repeated.fragments.count == 2)
        assert(repeated.paragraphs()[0].text == "No customers No customers")

        var overlap = TranscriptAssembler()
        overlap.accept(update("We plan", 0, 1, final: false))
        overlap.accept(update("a pilot", 1.1, 2, final: false))
        overlap.accept(update("We plan a pilot.", 0, 2))
        assert(overlap.fragments.count == 1)
        assert(overlap.paragraphs()[0].text == "We plan a pilot.")
        overlap.accept(update("Stale interim result", 0, 2, final: false))
        assert(overlap.paragraphs()[0].text == "We plan a pilot.")

        var finalization = TranscriptAssembler()
        finalization.accept(update("Prior interim text", 0, 1, final: false))
        finalization.accept(update("Next text", 2, 3, final: false, finalizedThrough: 1))
        assert(finalization.paragraphs(finalOnly: true).count == 1)
        assert(finalization.paragraphs(finalOnly: true)[0].text == "Prior interim text")

        var english = TranscriptAssembler()
        english.accept(update("customer", 0, 1))
        english.accept(update("validation", 1.3, 2))
        assert(english.paragraphs()[0].text == "customer validation")

        var echo = TranscriptAssembler()
        echo.accept(update("We plan a pilot next month", 0, 2, speaker: "Other"))
        echo.accept(update("We plan a pilot next month", 0.3, 2.3))
        assert(echo.fragments.count == 1 && echo.fragments[0].speaker == "Other")

        var longMeeting = TranscriptAssembler()
        for i in 0..<350 {
            longMeeting.accept(update("Note \(i)", Double(i * 4), Double(i * 4 + 1)))
        }
        assert(longMeeting.paragraphs().count == 350)
        assert(longMeeting.paragraphs().first?.text == "Note 0")

        var empty = TranscriptAssembler()
        empty.accept(update("Recognition error", 0, 2, final: false))
        empty.accept(update("", 0, 2))
        assert(empty.fragments.isEmpty)
        empty.accept(update("Invalid time", .nan, 2))
        assert(empty.fragments.isEmpty)
        let correction = TranscriptCorrection(original: "Precision is half a millisecond.", replacement: "Precision is half a millinewton.")
        assert(correction.apply(to: "Precision is half a millisecond.") == "Precision is half a millinewton.")
        assert(correction.apply(to: "Precision is half a millisecond.Later content.") == "Precision is half a millinewton.Later content.")
        assert(correction.apply(to: "Different paragraphs stay unchanged") == "Different paragraphs stay unchanged")
        print("Transcript assembler: 12 scenario groups passed")
    }
}
