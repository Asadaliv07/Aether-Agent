import Foundation
import os

/// Actor-isolated MCP Client managing JSON-RPC 2.0 communication over an `MCPTransport`.
public actor MCPClient {
    // MARK: - Properties

    private var transport: MCPTransport?
    private var pendingRequests: [JSONRPCID: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var nextRequestId: Int = 1
    private var readingTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MCPClient")
    private var isConnected: Bool = false

    // MARK: - Initializer

    public init() {}

    deinit {
        readingTask?.cancel()
    }

    // MARK: - Connection Lifecycle

    public func connect(transport: MCPTransport) {
        self.transport = transport
        self.isConnected = true

        self.readingTask = Task { [weak self] in
            for await messageData in transport.incomingMessages {
                guard let self = self else { break }
                await self.handleIncomingMessage(messageData)
            }
        }
    }

    public func disconnect() async {
        readingTask?.cancel()
        readingTask = nil
        isConnected = false

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: CancellationError())
        }
        pendingRequests.removeAll()

        await transport?.close()
        transport = nil
    }

    // MARK: - High-Level MCP Operations

    /// Initializes the MCP session with the server.
    public func initialize(
        clientInfo: MCPImplementation = MCPImplementation(name: "AetherClient", version: "1.0.0")
    ) async throws -> MCPInitializeResult {
        let params = MCPInitializeParams(
            protocolVersion: MCPConstants.defaultProtocolVersion,
            capabilities: MCPClientCapabilities(roots: .init(listChanged: true)),
            clientInfo: clientInfo
        )
        let paramData = try JSONEncoder().encode(params)
        let paramAnyCodable = try JSONDecoder().decode(AnyCodableSendable.self, from: paramData)

        let response = try await sendRequest(method: "initialize", params: paramAnyCodable)
        guard let resultAny = response.result else {
            throw response.error ?? JSONRPCError.internalError
        }

        let resultData = try JSONEncoder().encode(resultAny)
        let initResult = try JSONDecoder().decode(MCPInitializeResult.self, from: resultData)

        // Send initialized notification
        try await sendNotification(method: "notifications/initialized", params: nil)
        return initResult
    }

    /// Discovers all tools exposed by the connected MCP server.
    public func listTools() async throws -> [MCPTool] {
        let response = try await sendRequest(method: "tools/list", params: nil)
        guard let resultAny = response.result else {
            throw response.error ?? JSONRPCError.internalError
        }

        let resultData = try JSONEncoder().encode(resultAny)
        let listResult = try JSONDecoder().decode(MCPListToolsResult.self, from: resultData)
        return listResult.tools
    }

    /// Invokes a tool on the connected MCP server with structured arguments.
    public func callTool(name: String, arguments: [String: AnyCodableSendable]) async throws -> MCPCallToolResult {
        let callParams = MCPCallToolParams(name: name, arguments: arguments)
        let paramData = try JSONEncoder().encode(callParams)
        let paramAnyCodable = try JSONDecoder().decode(AnyCodableSendable.self, from: paramData)

        let response = try await sendRequest(method: "tools/call", params: paramAnyCodable)
        guard let resultAny = response.result else {
            throw response.error ?? JSONRPCError.internalError
        }

        let resultData = try JSONEncoder().encode(resultAny)
        return try JSONDecoder().decode(MCPCallToolResult.self, from: resultData)
    }

    /// Sends a ping request to check server health.
    public func ping() async throws {
        _ = try await sendRequest(method: "ping", params: nil)
    }

    // MARK: - Low-Level Request / Response Engine

    private func sendRequest(method: String, params: AnyCodableSendable?) async throws -> JSONRPCResponse {
        guard let transport = self.transport, isConnected else {
            throw JSONRPCError(code: -32000, message: "MCPClient is not connected")
        }

        let id = JSONRPCID.int(nextRequestId)
        nextRequestId += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation
            Task {
                do {
                    try await transport.send(data: requestData)
                } catch {
                    self.pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendNotification(method: String, params: AnyCodableSendable?) async throws {
        guard let transport = self.transport, isConnected else {
            throw JSONRPCError(code: -32000, message: "MCPClient is not connected")
        }

        let notif = JSONRPCNotification(method: method, params: params)
        let notifData = try JSONEncoder().encode(notif)
        try await transport.send(data: notifData)
    }

    private func handleIncomingMessage(_ data: Data) {
        guard let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) else {
            logger.error("[MCPClient] Failed to decode incoming JSON-RPC response.")
            return
        }

        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }
}
