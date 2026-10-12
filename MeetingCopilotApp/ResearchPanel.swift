import AppKit
import SwiftUI

struct ResearchSource: Codable, Identifiable {
    var id: String
    var title: String
    var url: String
    var snippet: String
    var kind: String
    var status: String
    var date: String
    var full_text: Bool?
    var locator: String?
}

struct ResearchSection: Codable, Identifiable {
    var id: String
    var category: String
    var title: String
    var body: String
    var status: String
    var source_ids: [String]
    var replaces_section_id: String? = nil
}

struct ResearchUsage: Codable {
    var calls: Int
    var input_tokens: Int
    var output_tokens: Int
}

struct ResearchReport: Codable, Identifiable {
    var id: String
    var topic: String
    var question: String
    var created_at: String
    var sections: [ResearchSection]
    var sources: [ResearchSource]
    var notices: [String]
    var usage: ResearchUsage
    var skipped: Bool? = nil
    var skip_reason: String? = nil
    var rule_id: String? = nil
    var rule_version: String? = nil
    var direction: String? = nil
    var method: String? = nil
    var update_report_id: String? = nil
    var updated_at: String? = nil
    var revisions: [ResearchRevision]? = nil
    var applied_update_ids: [String]? = nil
}

private struct ResearchResponse: Decodable {
    var ok: Bool
    var report: ResearchReport?
    var message: String?
    var error: String?
}

@MainActor
final class ResearchModel: ObservableObject {
    @Published var reports: [ResearchReport] = []
    @Published var question = ""
    @Published var busy = false
    @Published var status = "Waiting for research"
    @Published var ruleID = UserDefaults.standard.string(forKey: "researchRuleID") ?? "default" {
        didSet { UserDefaults.standard.set(ruleID, forKey: "researchRuleID") }
    }
    @Published var automatic = UserDefaults.standard.object(forKey: "researchAutomaticTopics") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "researchAutomaticTopics")
            if !automatic && automaticRequest { cancel() }
            resetDiscussion()
            status = automatic ? "Waiting for more than3minutes of new discussion" : "Auto-update paused"
        }
    }
    @Published var gateUsage = ResearchUsage(calls: 0, input_tokens: 0, output_tokens: 0)
    @Published var webEnabled = true
    @Published var shareLocal = UserDefaults.standard.bool(forKey: "researchShareLocalExcerpts") {
        didSet { UserDefaults.standard.set(shareLocal, forKey: "researchShareLocalExcerpts") }
    }
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var lastText = ""
    private var lastResearchedTranscript = ""
    private var lastRun = Date.distantPast
    private var scopeKey = ""
    private var automaticRequest = false
    private var discussion: [ResearchDiscussion] = []
    private var discussionFloor = 0.0
    private var checkedThrough = 0.0
    private var lastFailure: String?

    var orderedReports: [ResearchReport] { ResearchReport.newestFirst(reports) }

    var pendingDiscussionSeconds: Double {
        ResearchDiscussion.seconds(discussion, after: checkedThrough)
    }

    func observeDiscussion(_ items: [ResearchDiscussion]) {
        discussion = items
    }

    private func resetDiscussion() {
        discussionFloor = discussion.map(\.end).max() ?? 0
        checkedThrough = discussionFloor
    }

    func stopUpdates() {
        automatic = false
        cancel()
        status = "Research updates stopped; existing results preserved"
    }

    func invalidate(scope: String, clear: Bool = false) {
        guard scope != scopeKey || clear else { return }
        scopeKey = scope
        cancel()
        lastText = ""
        lastResearchedTranscript = ""
        lastRun = .distantPast
        resetDiscussion()
        if clear {
            reports = []; question = ""
            discussion = []; discussionFloor = 0; checkedThrough = 0
            gateUsage = ResearchUsage(calls: 0, input_tokens: 0, output_tokens: 0)
        }
    }

    func cancel() {
        let cancelledID = requestID.uuidString
        if busy {
            Task {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/api/copilot_research/cancel")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 5
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["request_id": cancelledID])
                _ = try? await URLSession.shared.data(for: request)
            }
        }
        requestID = UUID()
        task?.cancel()
        task = nil
        busy = false
        lastFailure = nil
        status = automatic ? "Stopped waiting; existing research preserved" : "Auto-update paused"
    }

    func consider(transcript: String, background: String, scope: String, save: @escaping () -> Void) {
        invalidate(scope: scope)
        guard automatic, !busy else { return }
        let text = transcript + background
        let added = text.count - lastText.count
        guard pendingDiscussionSeconds > 180 else {
            let seconds = Int(pendingDiscussionSeconds)
            status = lastFailure ?? String(format: "Discussion collected %d:%02d / 3:00", seconds / 60, seconds % 60)
            return
        }
        guard (lastText.isEmpty ? text.count >= 100 : added >= 180),
              Date().timeIntervalSince(lastRun) > 180 else { return }
        run(transcript: transcript, background: background, scope: scope, manual: false, automaticCheck: true, save: save)
    }

    func run(transcript: String, background: String, scope: String, manual: Bool, automaticCheck: Bool = false,
             save: @escaping () -> Void) {
        guard !busy else { return }
        invalidate(scope: scope)
        let prompt = manual ? question.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !(transcript + background + prompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter a question or meeting background first"
            return
        }
        busy = true
        lastFailure = nil
        automaticRequest = automaticCheck
        status = manual ? "Answering your question" : (automaticCheck ? "Assessing new discussion topics" : "Searching and researching")
        if !manual {
            lastRun = Date()
            lastText = transcript + background
        }
        let identity = UUID()
        requestID = identity
        let through = discussion.map(\.end).max() ?? 0
        if automaticCheck { checkedThrough = through }
        let timed = discussion.filter { $0.start >= discussionFloor && $0.end > through - 900 }.suffix(180)
        let fresh = transcript.hasPrefix(lastResearchedTranscript)
            ? String(transcript.dropFirst(lastResearchedTranscript.count)) : transcript
        let history = reports.filter {
            $0.question.isEmpty && !$0.sections.isEmpty && ($0.rule_id ?? "default") == ruleID
        }.prefix(24).reversed().map { report in
            report.contextForUpdate
        }
        let body: [String: Any] = ["transcript": String(transcript.suffix(7000)), "project_context": background,
            "question": prompt, "web_enabled": webEnabled, "share_local": shareLocal, "research_rule": ruleID,
            "automatic": automaticCheck, "new_discussion": String(fresh.suffix(5000)), "previous_research": history,
            "request_id": identity.uuidString,
            "discussion_segments": timed.enumerated().map { index, item in
                ["id": "D\(index + 1)", "session": item.session, "start": item.start, "end": item.end, "text": item.text] as [String: Any]
            }]
        task = Task {
            defer {
                if requestID == identity { busy = false; task = nil }
            }
            do {
                try await BackendService.shared.ensureRunning()
                var request = URLRequest(url: URL(string: "http://127.0.0.1:8766/api/copilot_research")!)
                request.timeoutInterval = 360
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, requestID == identity, scopeKey == scope else { return }
                let decoded = try JSONDecoder().decode(ResearchResponse.self, from: data)
                guard (response as? HTTPURLResponse)?.statusCode == 200, decoded.ok, let report = decoded.report else {
                    status = decoded.error ?? decoded.message ?? "Research failed; existing results preserved"
                    lastFailure = status + "; Refresh or resend your question"
                    return
                }
                if report.skipped == true {
                    gateUsage.calls += report.usage.calls
                    gateUsage.input_tokens += report.usage.input_tokens
                    gateUsage.output_tokens += report.usage.output_tokens
                    status = report.skip_reason ?? "No new discussion to research"
                    save()
                    return
                }
                applyReport(report)
                if !manual && !report.sections.isEmpty {
                    lastResearchedTranscript = transcript
                    discussionFloor = through
                    checkedThrough = through
                }
                if manual && question.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { question = "" }
                status = report.sections.isEmpty ? "Insufficient information; see notes" : (manual ? "Question answered; see latest results" : "Research updated")
                save()
            } catch {
                guard !Task.isCancelled, requestID == identity else { return }
                status = "Research incomplete; existing results preserved: \(error.localizedDescription)"
                lastFailure = status + "; Refresh or resend your question"
            }
        }
    }

    func applyReport(_ report: ResearchReport) {
        guard report.skipped != true else { return }
        if report.question.isEmpty, let target = report.update_report_id,
           let index = reports.firstIndex(where: { $0.id == target && $0.question.isEmpty && ($0.rule_id ?? "default") == (report.rule_id ?? "default") }) {
            guard !report.sections.isEmpty else { return }
            guard !(reports[index].applied_update_ids ?? []).contains(report.id) else { return }
            let merged = reports[index].merging(report)
            reports.remove(at: index)
            reports.insert(merged, at: 0)
        } else if !reports.contains(where: { $0.id == report.id }) {
            var independent = report
            independent.update_report_id = nil
            reports.insert(independent, at: 0)
        }
        reports = orderedReports
    }

    var markdown: String {
        var lines = ["\n## Research and Q&A\n"]
        if gateUsage.calls > 0 {
            lines.append("Topic assessment (full research not started): \(gateUsage.calls) callsAPIresponses; input \(gateUsage.input_tokens) / Output \(gateUsage.output_tokens)")
        }
        for report in orderedReports {
            lines += ["### \(report.topic)", report.created_at, "Question: \(report.question.isEmpty ? "Automatic research" : report.question)"]
            if let updated = report.updated_at { lines.append("Updated: " + updated) }
            for section in report.sections {
                lines += ["#### [\(section.category)] \(section.title) · \(researchStatus(section.status))", section.body,
                          "Evidence: \(section.source_ids.joined(separator: ", "))"]
            }
            for source in report.sources {
                lines += ["- [\(source.id)] \(source.title) · \(source.date) · \(researchStatus(source.status))",
                          source.url, source.locator ?? "", source.snippet]
            }
            lines += report.notices.map { "- " + $0 }
            for revision in report.revisions ?? [] {
                lines += ["#### Previous version · " + revision.date]
                for section in revision.sections {
                    lines += ["##### " + section.title, section.body, "Evidence: " + section.source_ids.joined(separator: ", ")]
                }
                for source in revision.sources { lines.append("- [\(source.id)] \(source.title) · \(source.url)") }
            }
            lines += ["APIInput \(report.usage.input_tokens) / Output \(report.usage.output_tokens)", ""]
        }
        return lines.joined(separator: "\n")
    }
}

private func researchStatus(_ value: String) -> String {
    ["inferred": "Inference", "unverified": "Unverified", "disputed": "Disputed",
     "confirmed": "Confirmed in local library", "deprecated": "Historical context"][value] ?? "Unverified"
}

struct ResearchPanel: View {
    @ObservedObject var research: ResearchModel
    var onAsk: () -> Void
    var onRefresh: () -> Void
    var onRuleChange: () -> Void = {}
    @State private var showsSettings = false
    @State private var category = "All"

    private var categories: [String] {
        ["All"] + Array(Set(research.reports.flatMap { $0.sections.map(\.category) } + ["Local connections", "Manual Q&A"])).sorted()
    }

    private func openSource(_ source: ResearchSource) {
        guard let url = URL(string: source.url), ["http", "https", "file"].contains(url.scheme ?? "") else { return }
        if url.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
    }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            HStack {
                Text("Research").font(.headline)
                Text(research.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(research.status + "\nSkipped full research: \(research.gateUsage.calls) callsAPIresponses; input \(research.gateUsage.input_tokens) / Output \(research.gateUsage.output_tokens)")
                if research.busy { ProgressView().controlSize(.small) }
                Button { research.automatic.toggle() } label: {
                    Image(systemName: research.automatic ? "pause.fill" : "play.fill")
                }.help(research.automatic ? "Pause research updates; recording and questions continue" : "Resume auto-update and collect more than3minutes of discussion")
                Button { research.stopUpdates() } label: { Image(systemName: "stop.fill") }
                    .disabled(!research.automatic && !research.busy)
                    .help("Stop this research and disable auto-update; requests already sent may still be billed")
                Button { showsSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Research settings")
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(research.busy).help("Research current discussion")
            }.frame(width: max(0, geometry.size.width - 20)).padding(10)
            HStack(spacing: 8) {
                RuleSelection(kind: "research", label: "Rules", selection: $research.ruleID,
                              onContentChanged: onRuleChange)
                    .frame(width: max(0, geometry.size.width - 124), alignment: .leading)
                    .onChange(of: research.ruleID) { _, _ in onRuleChange() }
                Picker("Section", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0) }
                }.labelsHidden().frame(width: 96).help("Filter research")
            }.frame(width: max(0, geometry.size.width - 20)).padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if research.reports.isEmpty {
                        Text("No research yet").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 130)
                    }
                    ForEach(research.orderedReports) { report in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(report.topic).font(.headline).textSelection(.enabled)
                            Text("Recently updated " + report.latestTimestamp + (report.question.isEmpty ? " · Automatic research" : " · Ask a question"))
                                .font(.caption2).foregroundStyle(.secondary)
                            if !report.question.isEmpty { Text("Question: " + report.question).textSelection(.enabled) }
                            ForEach(report.sections.filter { category == "All" || $0.category == category }) { section in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        Text(section.category).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(researchStatus(section.status)).font(.caption)
                                            .foregroundStyle(section.status == "disputed" ? Color.red : Color.secondary)
                                    }
                                    Text(section.title).font(.system(size: 13, weight: .semibold))
                                    Text(section.body).font(.system(size: 13)).textSelection(.enabled)
                                    ForEach(report.sources.filter { section.source_ids.contains($0.id) }) { source in
                                        Button { openSource(source) } label: {
                                            Label("[\(source.id)] \(source.title)", systemImage: source.kind == "web" ? "globe" : "doc.text")
                                                .font(.caption).multilineTextAlignment(.leading)
                                        }.buttonStyle(.link).disabled(source.url.isEmpty)
                                    }
                                }
                                Divider()
                            }
                            if category == "All" || category == "Local connections" {
                                ForEach(report.sources.filter { $0.kind != "web" }) { source in
                                    DisclosureGroup("[\(source.id)] \(source.title) · Local candidates") {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("\(source.date) · \(researchStatus(source.status))").font(.caption)
                                            Text(source.snippet).font(.caption).textSelection(.enabled)
                                            Text(source.locator ?? "Project files").font(.caption2).foregroundStyle(.secondary)
                                            Button("View sources") { openSource(source) }.disabled(source.url.isEmpty)
                                        }
                                    }
                                }
                            }
                            DisclosureGroup("Search scope and evidence (\(report.sources.count))") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(report.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                                    Text("ResearchAPI · Input \(report.usage.input_tokens) / Output \(report.usage.output_tokens)").font(.caption)
                                    ForEach(report.sources) { source in
                                        Text("[\(source.id)] \(source.title) · \(source.date) · \(source.kind == "web" ? (source.full_text == true ? "Page excerpt" : "Search snippet only") : researchStatus(source.status))")
                                            .font(.caption).fontWeight(.semibold)
                                        Text(source.snippet).font(.caption).textSelection(.enabled)
                                    }
                                }
                            }
                            if let revisions = report.revisions, !revisions.isEmpty {
                                DisclosureGroup("Update history (\(revisions.count))") {
                                    ForEach(revisions.reversed()) { revision in
                                        DisclosureGroup(revision.date) {
                                            ForEach(revision.sections) { section in
                                                Text(section.title).font(.caption).bold()
                                                Text(section.body).font(.caption).textSelection(.enabled)
                                            }
                                            ForEach(revision.sources) { source in
                                                Button("[\(source.id)] " + source.title) { openSource(source) }
                                                    .buttonStyle(.link).font(.caption)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        Divider()
                    }
                }.frame(width: max(0, geometry.size.width - 24), alignment: .leading).padding(12)
            }.frame(width: geometry.size.width).scrollIndicators(.visible)
            Divider()
            HStack(alignment: .bottom) {
                TextField("Enter a research question", text: $research.question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    .onChange(of: research.question) { _, value in
                        if value.count > 1500 { research.question = String(value.prefix(1500)) }
                    }
                Button(action: onAsk) { Image(systemName: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                    .disabled(research.busy || research.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Search and answer")
            }.frame(width: max(0, geometry.size.width - 20)).padding(10)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(isPresented: $showsSettings) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Research settings").font(.headline)
                Toggle("Research new topics automatically / New application", isOn: $research.automatic)
                Toggle("Search public sources online", isOn: $research.webEnabled)
                Toggle("Allow matching local excerpts to be sent to the configured cloud model", isOn: $research.shareLocal)
                Text("New substantive discussion on the same topic exceeds3minutes before automatic research. Silence, pauses and background waiting do not count. Recording, transcription and questions continue. Manual questions and refresh bypass this threshold; sent requests may still be billed.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Done") { showsSettings = false } }
            }.padding(24).frame(width: 460)
        }
    }
}
