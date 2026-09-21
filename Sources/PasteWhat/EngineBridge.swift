import Darwin
import Foundation

enum EngineBridgeError: LocalizedError {
    case invalidConfiguration
    case missingWorker
    case launchFailed
    case connectionClosed
    case invalidResponse
    case responseMismatch
    case oversizedMessage
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "请在设置中检查 Python、模型路径和推理后端。"
        case .missingWorker: "找不到推荐引擎，请重新构建或安装 PasteWhat。"
        case .launchFailed: "无法启动本地 Python，请检查路径与执行权限。"
        case .connectionClosed: "本地推荐引擎已断开，下次推荐时会重新启动。"
        case .invalidResponse: "推荐引擎返回了无效响应，下次推荐时会重新启动。"
        case .responseMismatch: "推荐结果与当前请求不一致，已丢弃。"
        case .oversizedMessage: "推荐请求或响应超过大小限制。"
        case .timeout: "推荐引擎响应超时，请检查设置后重试。"
        }
    }
}

@MainActor
final class EngineBridge {
    var onStatus: ((String) -> Void)?
    private(set) var configuration: EngineConfiguration

    private struct Pending: Sendable {
        let token: UUID
        let requestID: String
        let candidateIDs: Set<String>
        let data: Data
        let continuation: CheckedContinuation<RecommendationResponse, any Error>
    }

    private var process: Process?
    private var input: FileHandle?
    private var outputSource: (any DispatchSourceRead)?
    private var generation = UUID()
    private var buffer = Data()
    private var pending: [Pending] = []
    private var active: Pending?
    private var readerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let writeQueue = DispatchQueue(label: "PasteWhat.engine.input", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "PasteWhat.engine.output", qos: .userInitiated)
    private var maximumMessageBytes: Int { configuration.backend == "ranker" ? 4_194_304 : 1_048_576 }

    init(configuration: EngineConfiguration) {
        self.configuration = configuration
    }

    func configure(_ configuration: EngineConfiguration) {
        stop()
        self.configuration = configuration
    }

    func rank(_ request: RecommendationRequest) async throws -> RecommendationResponse {
        try Task.checkCancellation()
        var data = try JSONEncoder().encode(request)
        guard data.count < maximumMessageBytes else { throw EngineBridgeError.oversizedMessage }
        data.append(0x0A)
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending.append(Pending(
                    token: token, requestID: request.id,
                    candidateIDs: Set(request.entries.map(\.id)),
                    data: data, continuation: continuation
                ))
                startNext()
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancel(token) }
        }
    }

    func stop() {
        failAll(CancellationError())
        onStatus?("推荐引擎已停止")
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        active = pending.removeFirst()
        do {
            try startProcessIfNeeded()
        } catch {
            failAll(error)
            onStatus?(error.localizedDescription)
            return
        }
        guard let active, let input else { return }
        let currentGeneration = generation
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            guard let self, self.generation == currentGeneration, self.active?.token == active.token else { return }
            self.failAll(EngineBridgeError.timeout)
            self.onStatus?(EngineBridgeError.timeout.localizedDescription)
        }
        // Pipe writes can wait for the worker to read; never perform them on the UI actor.
        writeQueue.async { [weak self, data = active.data] in
            do { try input.write(contentsOf: data) }
            catch {
                Task { @MainActor [weak self] in
                    self?.connectionFailed(generation: currentGeneration, error: .connectionClosed)
                }
            }
        }
    }

    private func startProcessIfNeeded() throws {
        if process?.isRunning == true { return }
        closeProcess()
        let manager = FileManager.default
        let pythonPath = (configuration.pythonPath as NSString).expandingTildeInPath
        let modelPath = (configuration.modelPath as NSString).expandingTildeInPath
        guard ["mlx", "coreml", "jev", "ranker"].contains(configuration.backend),
              pythonPath.hasPrefix("/"), (configuration.isRemote || modelPath.hasPrefix("/")),
              manager.isExecutableFile(atPath: pythonPath) else {
            throw EngineBridgeError.invalidConfiguration
        }
        let bundledWorker = Bundle.main.resourceURL?.appendingPathComponent("engine/worker.py")
        let workerCandidates = [bundledWorker].compactMap { $0 }
            + EngineConfiguration.workspaceURLs.map { $0.appendingPathComponent("engine/worker.py") }
        guard let worker = workerCandidates.first(where: { manager.fileExists(atPath: $0.path) }) else {
            throw EngineBridgeError.missingWorker
        }

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let currentGeneration = generation
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = ["-u", worker.path, "--backend", configuration.backend, "--model", modelPath]
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        // Discard stderr at the OS boundary. It cannot fill a pipe or expose clipboard data in logs.
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        input = inputPipe.fileHandleForWriting
        process = child
        // A closed worker input should become a recoverable write error, never SIGPIPE in the app.
        guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            closeProcess()
            throw EngineBridgeError.launchFailed
        }
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let outputHandle = outputPipe.fileHandleForReading
        let descriptor = outputHandle.fileDescriptor
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1 else {
            closeProcess()
            throw EngineBridgeError.launchFailed
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
        source.setEventHandler { @Sendable in
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                // A single consumer preserves byte order; separate callback Tasks do not promise FIFO.
                let data = Data(bytes.prefix(count))
                if case .dropped = continuation.yield(data) { continuation.finish() }
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                continuation.finish()
            }
        }
        // Closing here is serialized after the last read, so an old reader cannot touch a reused fd.
        source.setCancelHandler { @Sendable in
            continuation.finish()
            try? outputHandle.close()
        }
        outputSource = source
        source.activate()
        readerTask = Task { [weak self] in
            for await data in stream {
                guard let self, self.generation == currentGeneration else { return }
                self.receive(data, generation: currentGeneration)
            }
            self?.connectionFailed(generation: currentGeneration, error: .connectionClosed)
        }
        child.terminationHandler = { @Sendable [weak self] _ in
            // Give the stdout reader a chance to deliver a final complete response before EOF.
            Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                self?.connectionFailed(generation: currentGeneration, error: .connectionClosed)
            }
        }
        do { try child.run() }
        catch {
            closeProcess()
            throw EngineBridgeError.launchFailed
        }
        onStatus?(configuration.isRemote ? "正在连接 Jev 云端推荐…" : "正在准备本地 \(configuration.displayName) 模型…")
    }

    private func receive(_ data: Data, generation receivedGeneration: UUID) {
        guard generation == receivedGeneration else { return }
        guard !data.isEmpty else {
            connectionFailed(generation: receivedGeneration, error: .connectionClosed)
            return
        }
        buffer.append(data)
        guard buffer.count <= maximumMessageBytes else {
            connectionFailed(generation: receivedGeneration, error: .oversizedMessage)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let active else {
                connectionFailed(generation: receivedGeneration, error: .invalidResponse)
                return
            }
            guard let response = try? JSONDecoder().decode(RecommendationResponse.self, from: line) else {
                connectionFailed(generation: receivedGeneration, error: .invalidResponse)
                return
            }
            guard response.id == active.requestID,
                  response.recommendedID.map({ active.candidateIDs.contains($0) }) ?? true,
                  response.rankings.allSatisfy({ active.candidateIDs.contains($0.id) && $0.score.isFinite }),
                  Set(response.rankings.map(\.id)).count == response.rankings.count,
                  response.shortlistedIDs.allSatisfy({ active.candidateIDs.contains($0) }),
                  response.inferenceCount >= 0,
                  (response.decision == "recommended") == (response.recommendedID != nil) else {
                connectionFailed(generation: receivedGeneration, error: .responseMismatch)
                return
            }
            timeoutTask?.cancel()
            timeoutTask = nil
            self.active = nil
            active.continuation.resume(returning: response)
            onStatus?(response.statusText)
            startNext()
            guard generation == receivedGeneration else { return }
        }
    }

    private func cancel(_ token: UUID) {
        if let index = pending.firstIndex(where: { $0.token == token }) {
            pending.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if active?.token == token {
            let cancelled = active
            active = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            closeProcess()
            cancelled?.continuation.resume(throwing: CancellationError())
            startNext()
        }
    }

    private func connectionFailed(generation failedGeneration: UUID, error: EngineBridgeError) {
        guard generation == failedGeneration else { return }
        failAll(error)
        onStatus?(error.localizedDescription)
    }

    private func failAll(_ error: any Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let failed = (active.map { [$0] } ?? []) + pending
        active = nil
        pending.removeAll()
        closeProcess()
        for request in failed { request.continuation.resume(throwing: error) }
    }

    private func closeProcess() {
        generation = UUID()
        buffer.removeAll(keepingCapacity: true)
        readerTask?.cancel()
        readerTask = nil
        outputSource?.cancel()
        outputSource = nil
        if let input {
            writeQueue.async { try? input.close() }
        }
        input = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
    }
}
