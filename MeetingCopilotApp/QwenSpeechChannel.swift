import AVFoundation
import Foundation

enum CopilotTranscriber: String, CaseIterable {
    case apple, qwen
    var title: String { self == .apple ? "Apple Live transcript" : "Qwen English transcription" }
}

protocol LiveTranscriptionChannel: AnyObject, Sendable {
    var audioFormat: AVAudioFormat { get }
    func append(_ buffer: AVAudioPCMBuffer, startTime: CMTime?)
    func finish() async
}

private func qwenError(_ message: String) -> NSError {
    NSError(domain: "CopilotQwen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

final class QwenSpeechWorker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "copilot.qwen.requests", qos: .userInitiated)
    private var received = Data()
    private var failure: Error?
    private let errorLog: FileHandle

    init() throws {
        let root = appDirectory
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingCopilot/qwen-asr.log")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        errorLog = try FileHandle(forWritingTo: log)
        try errorLog.seekToEnd()
        process.executableURL = root.appendingPathComponent(".venv-asr/bin/python")
        process.arguments = ["-u", root.appendingPathComponent("copilot_qwen_stream.py").path]
        process.currentDirectoryURL = root
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorLog
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        try process.run()
    }

    deinit { if process.isRunning { process.terminate() }; try? errorLog.close() }

    private func exchange(_ body: [String: Any]) throws -> [String: Any] {
        if let failure { throw failure }
        guard process.isRunning else { throw qwenError("Qwen Transcription process exited; stop and restart or switch engines Apple") }
        // Killing a stuck child unblocks both pipe reads and pending stop requests.
        let timeout = DispatchWorkItem { [weak self] in
            if let self, self.process.isRunning { self.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
        defer { timeout.cancel() }
        do {
            var data = try JSONSerialization.data(withJSONObject: body)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
            while received.firstIndex(of: 10) == nil {
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw qwenError("Qwen Transcription interrupted; stop and retry. Existing text is preserved.") }
                received.append(chunk)
                guard received.count < 4_000_000 else { throw qwenError("Qwen Invalid response") }
            }
            let end = received.firstIndex(of: 10)!
            let line = received.prefix(upTo: end)
            let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
            received.removeSubrange(...end)
            guard result["ok"] as? Bool == true else { throw qwenError(result["error"] as? String ?? "Qwen Transcription failed") }
            return result
        } catch {
            failure = error
            throw error
        }
    }

    func request(_ body: [String: Any], completion: @escaping @Sendable (Result<[String: Any], Error>) -> Void) {
        queue.async { completion(Result { try self.exchange(body) }) }
    }

    func request(_ body: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            request(body) { continuation.resume(with: $0) }
        }
    }
}

final class QwenSpeechChannel: LiveTranscriptionChannel, @unchecked Sendable {
    let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let worker: QwenSpeechWorker
    private let channel = UUID().uuidString
    private let session: String
    private let speaker: String
    private let offset: Double
    private let onResult: @Sendable (TranscriptUpdate) -> Void
    private let onError: @Sendable (String) -> Void
    private let onWarning: @Sendable (String) -> Void
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var pending = Data()
    private var closed = false
    private var reportedError = false
    private var queuedSeconds = 0.0
    private var warned = false

    init(worker: QwenSpeechWorker, session: String, speaker: String, offset: Double,
         onResult: @escaping @Sendable (TranscriptUpdate) -> Void, onError: @escaping @Sendable (String) -> Void,
         onWarning: @escaping @Sendable (String) -> Void = { _ in }) {
        self.worker = worker; self.session = session; self.speaker = speaker; self.offset = offset
        self.onResult = onResult; self.onError = onError
        self.onWarning = onWarning
    }

    func prepare() async throws { _ = try await worker.request(["command": "open", "channel": channel]) }

    func append(_ buffer: AVAudioPCMBuffer, startTime: CMTime?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        do {
            if sourceFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: audioFormat)
                sourceFormat = buffer.format
            }
            guard let converter else { throw qwenError("Unable to convert microphone audio") }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 8
            let converted = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: capacity)!
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            if status == .error { throw conversionError ?? qwenError("Audio conversion failed") }
            if let floats = converted.floatChannelData?[0] {
                pending.append(Data(bytes: floats, count: Int(converted.frameLength) * 4))
            }
            while pending.count >= 128000 {
                let block = Data(pending.prefix(128000))
                pending.removeFirst(128000)
                queuedSeconds += 2
                worker.request(["command": "feed", "channel": channel, "pcm": block.base64EncodedString()]) { [weak self] result in
                    self?.receive(result, seconds: 2)
                }
            }
            if queuedSeconds > 12 && !warned {
                warned = true
                onWarning("Qwen Processing is behind by more than12seconds; pause capture to let processing catch up")
            }
        } catch {
            if !reportedError { reportedError = true; onError(error.localizedDescription) }
        }
    }

    private func receive(_ result: Result<[String: Any], Error>, seconds: Double = 0) {
        lock.lock()
        queuedSeconds = max(0, queuedSeconds - seconds)
        let caughtUp = warned && queuedSeconds < 4
        if queuedSeconds < 4 { warned = false }
        lock.unlock()
        if caughtUp { onWarning("Qwen Caught up; transcribing live") }
        switch result {
        case .success(let response):
            for event in response["events"] as? [[String: Any]] ?? [] {
                guard let start = event["start"] as? Double, let end = event["end"] as? Double,
                      let text = event["text"] as? String, let final = event["final"] as? Bool else { continue }
                onResult(TranscriptUpdate(session: session, speaker: speaker, text: text,
                    start: offset + start, end: offset + end, isFinal: final,
                    finalizedThrough: offset + (final ? end : start)))
            }
        case .failure(let error):
            lock.lock()
            let shouldReport = !reportedError
            reportedError = true
            lock.unlock()
            if shouldReport { onError(error.localizedDescription) }
        }
    }

    private func closeInput() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        closed = true
        let tail = pending
        pending.removeAll()
        return tail
    }

    func finish() async {
        guard let tail = closeInput() else { return }
        do {
            let result = try await worker.request(["command": "finish", "channel": channel, "pcm": tail.base64EncodedString()])
            receive(.success(result))
        } catch { receive(.failure(error)) }
    }
}
