import Foundation
import os

/// Protocol abstracting bidirectional line-delimited communication with the multi-agent sidecar.
public protocol MultiAgentTransport: Actor {
    func send(line: String) async throws
    func receive() async -> AsyncThrowingStream<String, Error>
    func close() async
    var isRunning: Bool { get }
    var generationId: UUID { get }
}

/// Transport utilizing an external child Process connected via standard pipes (stdin/stdout/stderr).
public actor MultiAgentSubprocessTransport: MultiAgentTransport {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    public private(set) var generationId: UUID = UUID()
    public private(set) var lastTerminationStatus: Int32? = nil
    private var streamContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MultiAgentSubprocessTransport")

    private var _isRunning: Bool = false
    public var isRunning: Bool {
        return _isRunning && (process?.isRunning ?? false)
    }

    public init() {}

    /// Launches the Python sidecar process.
    public func start(pythonPath: String, scriptPath: String, workingDirectory: String? = nil) throws {
        guard !isRunning else { return }
        self.generationId = UUID()
        self.lastTerminationStatus = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [scriptPath]
        if let wd = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
        self._isRunning = true

        proc.terminationHandler = { [weak self] p in
            Task { [weak self] in
                await self?.handleProcessTerminated(status: p.terminationStatus)
            }
        }

        try proc.run()
        logger.info("[MultiAgentTransport] Subprocess launched (PID: \(proc.processIdentifier), Gen: \(self.generationId.uuidString.prefix(8))) using \(pythonPath)")

        // Start background stderr logger
        Task.detached { [weak self] in
            for try await line in errPipe.fileHandleForReading.bytes.lines {
                guard let self else { break }
                await self.logStderr(line)
            }
        }
    }

    private func handleProcessTerminated(status: Int32) {
        self._isRunning = false
        self.lastTerminationStatus = status
        logger.info("[MultiAgentTransport] Subprocess (Gen: \(self.generationId.uuidString.prefix(8))) exited with status \(status)")
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func logStderr(_ line: String) {
        logger.debug("[Sidecar STDERR] \(line)")
    }

    public func send(line: String) async throws {
        guard let inPipe = self.stdinPipe, isRunning else {
            throw NSError(domain: "MultiAgentTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Sidecar process is not running."])
        }

        let lineWithNewline = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = lineWithNewline.data(using: .utf8) else { return }

        try inPipe.fileHandleForWriting.write(contentsOf: data)
    }

    public func receive() -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            self.streamContinuation = continuation

            guard let outPipe = self.stdoutPipe else {
                continuation.finish()
                return
            }

            Task.detached {
                do {
                    for try await line in outPipe.fileHandleForReading.bytes.lines {
                        // Enforce 16 MB maximum message size guard
                        if line.utf8.count > MultiAgentConstants.maxMessageSizeBytes {
                            continue
                        }
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            continuation.yield(trimmed)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func close() async {
        guard let proc = self.process else { return }
        self._isRunning = false

        if proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            Task.detached {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Force kill if process does not exit within grace period
                kill(pid, SIGKILL)
            }
        }

        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()

        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        streamContinuation?.finish()
        streamContinuation = nil
    }
}

/// In-memory transport for deterministic testing without external sub-processes.
public actor MultiAgentInMemoryTransport: MultiAgentTransport {
    public let generationId: UUID = UUID()
    private var toOtherContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var fromOtherStream: AsyncThrowingStream<String, Error>

    public private(set) var isRunning: Bool = true

    public init(
        stream: AsyncThrowingStream<String, Error>,
        continuation: AsyncThrowingStream<String, Error>.Continuation?
    ) {
        self.fromOtherStream = stream
        self.toOtherContinuation = continuation
    }

    /// Creates a linked pair of in-memory transports (e.g. client and simulated sidecar).
    public static func createPair() -> (client: MultiAgentInMemoryTransport, server: MultiAgentInMemoryTransport) {
        var clientCont: AsyncThrowingStream<String, Error>.Continuation?
        let clientStream = AsyncThrowingStream<String, Error> { c in clientCont = c }

        var serverCont: AsyncThrowingStream<String, Error>.Continuation?
        let serverStream = AsyncThrowingStream<String, Error> { c in serverCont = c }

        let client = MultiAgentInMemoryTransport(stream: clientStream, continuation: serverCont)
        let server = MultiAgentInMemoryTransport(stream: serverStream, continuation: clientCont)
        return (client, server)
    }

    public func send(line: String) async throws {
        guard isRunning else {
            throw NSError(domain: "MultiAgentInMemoryTransport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transport closed"])
        }
        toOtherContinuation?.yield(line)
    }

    public func receive() -> AsyncThrowingStream<String, Error> {
        return fromOtherStream
    }

    public func close() async {
        self.isRunning = false
        toOtherContinuation?.finish()
        toOtherContinuation = nil
    }
}
