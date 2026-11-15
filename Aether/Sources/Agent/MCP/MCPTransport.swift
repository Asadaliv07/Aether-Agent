import Foundation
import os

/// Protocol defining the transport layer for JSON-RPC 2.0 communication in MCP.
public protocol MCPTransport: Sendable {
    /// Sends raw message data over the transport.
    func send(data: Data) async throws
    /// Asynchronous stream of incoming message data.
    var incomingMessages: AsyncStream<Data> { get }
    /// Closes the transport connection.
    func close() async
}

// MARK: - In-Memory Transport

/// High-performance, zero-overhead, strictly sandboxed in-memory transport connecting an MCP Client and Server.
public actor MCPInMemoryTransport: MCPTransport {
    private let sendContinuation: AsyncStream<Data>.Continuation
    public nonisolated let incomingMessages: AsyncStream<Data>
    private var isClosed = false

    private init(
        sendContinuation: AsyncStream<Data>.Continuation,
        incomingMessages: AsyncStream<Data>
    ) {
        self.sendContinuation = sendContinuation
        self.incomingMessages = incomingMessages
    }

    /// Creates a bidirectional paired transport for client and server.
    public static func createPair() -> (client: MCPInMemoryTransport, server: MCPInMemoryTransport) {
        var clientIncomingContinuation: AsyncStream<Data>.Continuation!
        let clientIncoming = AsyncStream<Data> { continuation in
            clientIncomingContinuation = continuation
        }

        var serverIncomingContinuation: AsyncStream<Data>.Continuation!
        let serverIncoming = AsyncStream<Data> { continuation in
            serverIncomingContinuation = continuation
        }

        // What client sends goes to server incoming; what server sends goes to client incoming
        let client = MCPInMemoryTransport(
            sendContinuation: serverIncomingContinuation,
            incomingMessages: clientIncoming
        )
        let server = MCPInMemoryTransport(
            sendContinuation: clientIncomingContinuation,
            incomingMessages: serverIncoming
        )

        return (client, server)
    }

    public func send(data: Data) async throws {
        guard !isClosed else {
            throw JSONRPCError(code: -32000, message: "Transport is closed")
        }
        sendContinuation.yield(data)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        sendContinuation.finish()
    }
}

// MARK: - Stdio Transport (For External MCP Processes)

/// Subprocess stdio transport communicating via newline-delimited JSON-RPC over stdin/stdout pipes.
public actor MCPStdioTransport: MCPTransport {
    private let process: Process?
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    public nonisolated let incomingMessages: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private var isClosed = false

    public init(process: Process? = nil, stdinPipe: Pipe = Pipe(), stdoutPipe: Pipe = Pipe()) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { cont in
            continuation = cont
        }
        self.incomingMessages = stream
        self.incomingContinuation = continuation

        // Listen on stdoutPipe
        let capturedContinuation = continuation!
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let availableData = handle.availableData
            guard !availableData.isEmpty else { return }

            var remaining = availableData
            let newline = UInt8(ascii: "\n")
            while let idx = remaining.firstIndex(of: newline) {
                let lineData = remaining[..<idx]
                remaining = remaining[remaining.index(after: idx)...]
                if !lineData.isEmpty {
                    capturedContinuation.yield(Data(lineData))
                }
            }
            if !remaining.isEmpty {
                capturedContinuation.yield(Data(remaining))
            }
        }
    }

    public func send(data: Data) async throws {
        guard !isClosed else {
            throw JSONRPCError(code: -32000, message: "Stdio transport is closed")
        }
        var framedData = data
        framedData.append(contentsOf: [UInt8(ascii: "\n")])
        try stdinPipe.fileHandleForWriting.write(contentsOf: framedData)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        incomingContinuation.finish()
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }
}
