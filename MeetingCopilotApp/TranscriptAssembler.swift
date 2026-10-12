import Foundation

enum TranscriptChannel {
    static func displayName(_ channel: String) -> String {
        switch channel {
        case "Me", "Microphone": return "Microphone"
        case "Other", "System": return "System"
        default: return channel
        }
    }
}

struct TranscriptCorrection: Codable {
    let original: String
    let replacement: String

    func apply(to text: String) -> String {
        guard let range = text.range(of: original) else { return text }
        return text.replacingCharacters(in: range, with: replacement)
    }
}

struct TranscriptSuggestion: Codable, Identifiable {
    let id: String
    let anchor: String
    let original: String
    let replacement: String
    let reason: String
    var resolution: String? = nil
    var editedText: String? = nil

    func applying(to text: String) -> String? {
        guard let anchorRange = text.range(of: anchor),
              let originalRange = text.range(of: original, range: anchorRange) else { return nil }
        return text.replacingCharacters(in: originalRange, with: replacement)
    }
}

struct TranscriptFollowState {
    var followsLatest = true
    var userScrolling = false
    var atBottom = true

    mutating func beginUserScroll() {
        userScrolling = true
        followsLatest = false
    }

    mutating func endUserScroll() {
        guard userScrolling else { return }
        userScrolling = false
        followsLatest = atBottom
    }

    mutating func pause() {
        followsLatest = false
        userScrolling = false
    }

    mutating func resume() {
        followsLatest = true
        userScrolling = false
    }
}

enum TranscriptOffsets {
    static func rebase(_ offsets: [String: Int], from before: String, to after: String) -> [String: Int] {
        let old = Array(before.unicodeScalars), new = Array(after.unicodeScalars)
        var left = 0
        while left < min(old.count, new.count) && old[left] == new[left] { left += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - left && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let oldEnd = old.count - suffix, newEnd = new.count - suffix
        return offsets.mapValues { offset in
            if offset <= left { return offset }
            if offset >= oldEnd { return max(0, offset + new.count - old.count) }
            return newEnd
        }
    }
}

struct TranscriptUpdate: Sendable {
    let session: String
    let speaker: String
    let text: String
    let start: Double
    let end: Double
    let isFinal: Bool
    let finalizedThrough: Double
}

struct TranscriptSegment: Identifiable, Codable {
    let id: String
    let session: String
    let speaker: String
    let start: Double
    var end: Double
    var text: String
    var isFinal: Bool
}

struct TranscriptAssembler {
    private(set) var fragments: [TranscriptSegment] = []

    init(fragments: [TranscriptSegment] = []) {
        self.fragments = fragments
    }

    mutating func accept(_ update: TranscriptUpdate) {
        guard update.start.isFinite, update.end.isFinite, update.end >= update.start else { return }
        let cleaned = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameRange: (TranscriptSegment) -> Bool = {
            $0.session == update.session && $0.speaker == update.speaker
                && (abs($0.start - update.start) < 0.025
                    || min($0.end, update.end) - max($0.start, update.start) > 0.025)
        }
        // Revisions replace the audio range, even when the corrected text is shorter.
        let replaced = fragments.filter { sameRange($0) && !$0.isFinal }
        if fragments.contains(where: { sameRange($0) && $0.isFinal }) {
            finalize(update)
            return
        }
        let stableID = replaced.first?.id ?? UUID().uuidString
        fragments.removeAll { sameRange($0) && !$0.isFinal }

        if !cleaned.isEmpty {
            let echoes: (TranscriptSegment) -> Bool = {
                $0.session == update.session && abs($0.start - update.start) < 10
                    && Self.similarity($0.text, cleaned) >= 0.72
            }
            if update.speaker == "Me", fragments.contains(where: { $0.speaker == "Other" && echoes($0) }) {
                finalize(update)
                return
            }
            if update.speaker == "Other" {
                fragments.removeAll { $0.speaker == "Me" && echoes($0) }
            }
            fragments.append(TranscriptSegment(id: stableID, session: update.session, speaker: update.speaker,
                start: update.start, end: update.end, text: cleaned, isFinal: update.isFinal))
        }
        finalize(update)
    }

    private mutating func finalize(_ update: TranscriptUpdate) {
        guard update.finalizedThrough.isFinite else { return }
        for index in fragments.indices where fragments[index].session == update.session
            && fragments[index].speaker == update.speaker && fragments[index].end <= update.finalizedThrough {
            fragments[index].isFinal = true
        }
    }

    func paragraphs(finalOnly: Bool = false) -> [TranscriptSegment] {
        let ordered = fragments.sorted {
            if $0.start == $1.start { return $0.speaker < $1.speaker }
            return $0.start < $1.start
        }
        var result: [TranscriptSegment] = []
        var interrupted = false
        for fragment in ordered {
            if finalOnly && !fragment.isFinal {
                interrupted = true
                continue
            }
            if let last = result.last, !interrupted,
               last.session == fragment.session, last.speaker == fragment.speaker,
               fragment.start - last.end <= 1.5, fragment.start >= last.end - 0.025,
               last.text.count + fragment.text.count <= 320, fragment.end - last.start <= 45 {
                let index = result.count - 1
                result[index].text = Self.join(last.text, fragment.text)
                result[index].end = max(last.end, fragment.end)
                result[index].isFinal = last.isFinal && fragment.isFinal
            } else {
                result.append(fragment)
            }
            interrupted = false
        }
        return result
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        let asciiWord: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let space = lhs.last.map(asciiWord) == true && rhs.first.map(asciiWord) == true
        return lhs + (space ? " " : "") + rhs
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        func bigrams(_ text: String) -> Set<String> {
            let chars = Array(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            guard chars.count >= 5 else { return [] }
            return Set((0..<(chars.count - 1)).map { String(chars[$0...($0 + 1)]) })
        }
        let left = bigrams(lhs), right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(min(left.count, right.count))
    }
}
