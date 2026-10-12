import Foundation

struct ResearchDiscussion: Codable {
    let id: String
    let session: String
    let start: Double
    let end: Double
    let text: String

    static func seconds(_ items: [ResearchDiscussion], after boundary: Double) -> Double {
        var total = 0.0
        var right = boundary
        for item in items.sorted(by: { $0.start < $1.start }) {
            guard item.start.isFinite, item.end.isFinite, item.end > item.start else { continue }
            total += max(0, item.end - max(right, item.start))
            right = max(right, item.end)
        }
        return total
    }
}
