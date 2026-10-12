import Foundation

struct ResearchRevision: Codable, Identifiable {
    let id: String
    let date: String
    let sections: [ResearchSection]
    let sources: [ResearchSource]
}

extension ResearchReport {
    var latestTimestamp: String { updated_at ?? created_at }

    static func newestFirst(_ reports: [ResearchReport]) -> [ResearchReport] {
        let parser = ISO8601DateFormatter()
        func date(_ value: String) -> Date {
            parser.formatOptions = [.withInternetDateTime]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withFullDate]
            return parser.date(from: value) ?? .distantPast
        }
        return reports.enumerated().sorted {
            let left = date($0.element.latestTimestamp), right = date($1.element.latestTimestamp)
            return left == right ? $0.offset < $1.offset : left > right
        }.map(\.element)
    }

    static func restoringLegacyQuestions(_ reports: [ResearchReport]) -> [ResearchReport] {
        var result = reports
        var known = Set(reports.map(\.id))
        for report in reports {
            for (index, notice) in report.notices.enumerated() where notice.hasPrefix("Follow-up question (") {
                guard let separator = notice.range(of: "): ") else { continue }
                let date = String(notice[notice.index(notice.startIndex, offsetBy: 5)..<separator.lowerBound])
                let question = String(notice[separator.upperBound...])
                let id = report.id + "-legacy-question-\(index)"
                guard !question.isEmpty, known.insert(id).inserted else { continue }
                // The revision at this timestamp is the answer before a later automatic update.
                let snapshot = report.revisions?.first { $0.date == date }
                let isCurrent = report.latestTimestamp == date
                let sections = snapshot?.sections ?? (isCurrent ? report.sections : [])
                let sources = snapshot?.sources ?? (isCurrent ? report.sources : [])
                var recovered = ResearchReport(id: id, topic: question, question: question, created_at: date,
                    sections: sections, sources: sources,
                    notices: [sections.isEmpty ? "Question restored without a historical answer snapshot; later research is not the original answer." : "Restored from the historical research snapshot, including prior research on this topic. No new model call; usage belongs to the original run."],
                    usage: ResearchUsage(calls: 0, input_tokens: 0, output_tokens: 0))
                recovered.rule_id = report.rule_id
                recovered.rule_version = report.rule_version
                result.append(recovered)
            }
        }
        return newestFirst(result)
    }

    var contextForUpdate: [String: Any] {
        // Only the current version goes to the local backend; revision history stays on disk.
        let sectionData = (try? JSONEncoder().encode(sections)) ?? Data("[]".utf8)
        let sourceData = (try? JSONEncoder().encode(sources)) ?? Data("[]".utf8)
        return ["id": id, "topic": topic, "question": question, "direction": direction ?? "", "method": method ?? "",
                "rule_id": rule_id ?? "default", "rule_version": rule_version ?? "",
                "summary": String(sections.map { $0.title }.joined(separator: "; ").prefix(260)),
                "sections": (try? JSONSerialization.jsonObject(with: sectionData)) ?? [],
                "sources": (try? JSONSerialization.jsonObject(with: sourceData)) ?? []]
    }

    func merging(_ update: ResearchReport) -> ResearchReport {
        var merged = self
        merged.revisions = (revisions ?? []) + [ResearchRevision(id: UUID().uuidString,
            date: updated_at ?? created_at, sections: sections, sources: sources)]
        var replaced = Set<String>()
        for var section in update.sections {
            if let target = section.replaces_section_id, !replaced.contains(target),
               let index = merged.sections.firstIndex(where: { $0.id == target }) {
                replaced.insert(target)
                section.id = target
                section.replaces_section_id = nil
                merged.sections[index] = section
            } else {
                section.replaces_section_id = nil
                merged.sections.append(section)
            }
        }
        var sourceIDs = Set(merged.sources.map(\.id))
        for source in update.sources where sourceIDs.insert(source.id).inserted { merged.sources.append(source) }
        for notice in update.notices where !merged.notices.contains(notice) { merged.notices.append(notice) }
        if !update.question.isEmpty {
            merged.notices.append("Follow-up question (\(update.created_at)): \(update.question)")
        }
        merged.updated_at = update.latestTimestamp
        merged.direction = update.direction ?? direction
        merged.method = update.method ?? method
        merged.rule_version = update.rule_version
        merged.usage.calls += update.usage.calls
        merged.usage.input_tokens += update.usage.input_tokens
        merged.usage.output_tokens += update.usage.output_tokens
        merged.applied_update_ids = (applied_update_ids ?? []) + [update.id]
        merged.update_report_id = nil
        return merged
    }
}
