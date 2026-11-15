import Foundation
import os

/// Actor managing the lifecycle, communication, and event dispatching for the Python multi-agent sidecar.
public actor MultiAgentSidecarManager {
    public let transport: MultiAgentTransport
    public let toolBridge: MultiAgentToolBridge
    private let logger = Logger(subsystem: "com.aether.Aether", category: "MultiAgentSidecarManager")

    private var pendingRequests: [String: CheckedContinuation<SidecarResponse, Error>] = [:]
    private var eventContinuation: AsyncStream<SidecarEvent>.Continuation?
    public let events: AsyncStream<SidecarEvent>

    private var listeningTask: Task<Void, Never>?
    public private(set) var isInitialized: Bool = false
    public private(set) var frameworkVersion: String? = nil

    // Optional local inference provider closure
    public var inferenceHandler: (@Sendable (String, [PromptMessage]) async throws -> String)?

    public var currentGenerationId: UUID {
        get async {
            await transport.generationId
        }
    }

    public init(
        transport: MultiAgentTransport,
        toolBridge: MultiAgentToolBridge
    ) {
        self.transport = transport
        self.toolBridge = toolBridge

        var eCont: AsyncStream<SidecarEvent>.Continuation?
        self.events = AsyncStream(SidecarEvent.self, bufferingPolicy: .bufferingNewest(500)) { c in eCont = c }
        self.eventContinuation = eCont
        self.listeningTask = nil
    }

    private func ensureListening() {
        if listeningTask == nil {
            listeningTask = Task { [weak self] in
                await self?.listenLoop()
            }
        }
    }

    deinit {
        listeningTask?.cancel()
        eventContinuation?.finish()
    }

    // MARK: - Message Loop

    private func listenLoop() async {
        let stream = await transport.receive()
        do {
            for try await line in stream {
                guard !Task.isCancelled else { break }
                await handleIncomingLine(line)
            }
        } catch {
            logger.error("[MultiAgentManager] Read stream terminated: \(error.localizedDescription)")
        }

        // Process stream termination and cleanup
        self.isInitialized = false
        let gen = await transport.generationId
        eventContinuation?.yield(SidecarEvent(
            sessionId: "system",
            eventType: .runtimeCrashed,
            timestamp: Date().timeIntervalSince1970,
            data: ["generation_id": AnyCodableSendable(gen.uuidString)]
        ))

        for (_, cont) in pendingRequests {
            cont.resume(throwing: NSError(
                domain: "MultiAgentSidecarManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Python sidecar subprocess (generation \(gen.uuidString.prefix(8))) terminated unexpectedly."]
            ))
        }
        pendingRequests.removeAll()
    }

    private func handleIncomingLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("[MultiAgentManager] Failed to parse JSON: \(line)")
            return
        }

        let msgType = json["type"] as? String ?? ""

        switch msgType {
        case "response":
            if let respDict = json["response"] as? [String: Any] {
                do {
                    let respData = try JSONSerialization.data(withJSONObject: respDict)
                    let response = try JSONDecoder().decode(SidecarResponse.self, from: respData)
                    let reqId = response.requestId
                    if let cont = pendingRequests.removeValue(forKey: reqId) {
                        cont.resume(returning: response)
                    }
                } catch {
                    logger.error("[MultiAgentManager] Error decoding SidecarResponse: \(error.localizedDescription)")
                    let reqId = respDict["request_id"] as? String ?? ""
                    if let cont = pendingRequests.removeValue(forKey: reqId) {
                        cont.resume(throwing: error)
                    }
                }
            }

        case "event":
            if let evDict = json["event"] as? [String: Any],
               let evData = try? JSONSerialization.data(withJSONObject: evDict),
               let event = try? JSONDecoder().decode(SidecarEvent.self, from: evData) {
                eventContinuation?.yield(event)
            }

        case "tool_request":
            let callId = json["call_id"] as? String ?? ""
            let toolName = json["tool_name"] as? String ?? ""
            let rawParams = json["parameters"] as? [String: Any] ?? [:]
            let strParams = rawParams.mapValues { "\($0)" }
            let agentRole = json["agent_role"] as? String ?? "specialist"
            let taskId = json["task_id"] as? String ?? ""

            let toolReq = SidecarToolRequest(
                callId: callId,
                toolName: toolName,
                parameters: strParams,
                agentRole: agentRole,
                taskId: taskId
            )

            let result = await toolBridge.handleToolRequest(toolReq)
            await sendToolResponse(result)

        case "model_request":
            let callId = json["call_id"] as? String ?? ""
            let roleName = json["role_name"] as? String ?? ""
            let rawMessages = json["messages"] as? [[String: Any]] ?? []

            var promptMsgs: [PromptMessage] = []
            for m in rawMessages {
                let r = m["role"] as? String ?? "user"
                let c = m["content"] as? String ?? ""
                promptMsgs.append(PromptMessage(role: r, content: c))
            }

            if let handler = inferenceHandler {
                do {
                    let text = try await handler(roleName, promptMsgs)
                    await sendModelResponse(callId: callId, text: text, error: nil)
                } catch {
                    await sendModelResponse(callId: callId, text: "", error: error.localizedDescription)
                }
            } else {
                await sendModelResponse(callId: callId, text: "", error: "No local inference handler attached.")
            }

        default:
            logger.debug("[MultiAgentManager] Unhandled message type: \(msgType)")
        }
    }

    private func sendToolResponse(_ response: SidecarToolResponse) async {
        let payload: [String: Any] = [
            "type": "tool_response",
            "call_id": response.callId,
            "is_success": response.isSuccess,
            "result": response.result,
            "error": response.error as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            try? await transport.send(line: str)
        }
    }

    private func sendModelResponse(callId: String, text: String, error: String?) async {
        let payload: [String: Any] = [
            "type": "model_response",
            "call_id": callId,
            "text": text,
            "error": error as Any
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let str = String(data: data, encoding: .utf8) {
            try? await transport.send(line: str)
        }
    }

    // MARK: - RPC Execution

    public func sendRequest(_ request: SidecarRequest, timeoutSeconds: Double = 60.0) async throws -> SidecarResponse {
        ensureListening()
        let reqId = request.requestId
        let payloadDict: [String: Any] = [
            "type": "request",
            "request": [
                "protocol_version": request.protocolVersion,
                "request_id": request.requestId,
                "session_id": request.sessionId,
                "task_id": request.taskId as Any,
                "operation": request.operation,
                "payload": request.payload.mapValues { $0.rawObject }
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: payloadDict)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "MultiAgentSidecarManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize request."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[reqId] = continuation

            Task {
                do {
                    try await self.transport.send(line: line)
                } catch {
                    self.pendingRequests.removeValue(forKey: reqId)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - High-Level Lifecycle Operations

    /// Performs the handshake with the Python sidecar and validates protocol compatibility.
    public func initialize(checkpointDirectory: String? = nil) async throws -> SidecarResponse {
        var payload: [String: AnyCodableSendable] = [:]
        payload["enable_live_inference"] = AnyCodableSendable(inferenceHandler != nil)

        if let cpDir = checkpointDirectory {
            payload["checkpoint_dir"] = AnyCodableSendable(cpDir)
        } else if let resolved = try? SidecarRuntimeLocator.resolve() {
            payload["checkpoint_dir"] = AnyCodableSendable(resolved.checkpointDirectory)
        }

        let gen = await transport.generationId
        let req = SidecarRequest(sessionId: "init", generationId: gen, operation: "initialize", payload: payload)
        let response = try await sendRequest(req, timeoutSeconds: 15.0)

        if response.isSuccess {
            self.isInitialized = true
            if let ver = response.payload["framework_version"]?.stringValue {
                self.frameworkVersion = ver
            }
            logger.info("[MultiAgentManager] Handshake complete: Framework \(self.frameworkVersion ?? "unknown") (Gen: \(gen.uuidString.prefix(8)))")
        }
        return response
    }

    public func ping() async throws -> Bool {
        let req = SidecarRequest(sessionId: "ping", operation: "ping")
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        return resp.isSuccess
    }

    public func createSession(
        sessionId: String = UUID().uuidString,
        limits: MultiAgentLimits = MultiAgentLimits(),
        customAgents: [[String: AnyCodableSendable]] = []
    ) async throws -> SidecarResponse {
        var payload: [String: AnyCodableSendable] = [:]
        payload["limits"] = AnyCodableSendable([
            "max_concurrent_agents": limits.maxConcurrentAgents,
            "max_delegation_depth": limits.maxDelegationDepth,
            "max_retries": limits.maxRetries,
            "timeout_seconds": limits.timeoutSeconds,
            "max_context_tokens": limits.maxContextTokens
        ])
        if !customAgents.isEmpty {
            payload["custom_agents"] = AnyCodableSendable(customAgents)
        }

        let req = SidecarRequest(sessionId: sessionId, operation: "create_session", payload: payload)
        return try await sendRequest(req)
    }

    public func runSequential(
        goal: String,
        roles: [AgentRoleType],
        sessionId: String,
        framework: OrchestrationFramework = .maf,
        timeoutSeconds: Double = 60.0
    ) async throws -> SidecarResponse {
        let payload: [String: AnyCodableSendable] = [
            "goal": AnyCodableSendable(goal),
            "roles": AnyCodableSendable(roles.map { $0.rawValue }),
            "framework": AnyCodableSendable(framework.rawValue),
            "timeout_seconds": AnyCodableSendable(timeoutSeconds)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "run_sequential", payload: payload)
        return try await sendRequest(req, timeoutSeconds: timeoutSeconds + 5.0)
    }

    public func runParallel(
        goal: String,
        plannerRole: AgentRoleType = .planner,
        parallelRoles: [AgentRoleType] = [.researcher, .coder],
        reviewerRole: AgentRoleType = .reviewer,
        sessionId: String,
        framework: OrchestrationFramework = .maf,
        timeoutSeconds: Double = 60.0
    ) async throws -> SidecarResponse {
        let payload: [String: AnyCodableSendable] = [
            "goal": AnyCodableSendable(goal),
            "planner_role": AnyCodableSendable(plannerRole.rawValue),
            "parallel_roles": AnyCodableSendable(parallelRoles.map { $0.rawValue }),
            "reviewer_role": AnyCodableSendable(reviewerRole.rawValue),
            "framework": AnyCodableSendable(framework.rawValue),
            "timeout_seconds": AnyCodableSendable(timeoutSeconds)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "run_parallel", payload: payload)
        return try await sendRequest(req, timeoutSeconds: timeoutSeconds + 5.0)
    }

    public func runHandoff(
        goal: String,
        triageRole: AgentRoleType = .supervisor,
        targetRole: AgentRoleType = .coder,
        sessionId: String,
        framework: OrchestrationFramework = .maf,
        timeoutSeconds: Double = 60.0
    ) async throws -> SidecarResponse {
        let payload: [String: AnyCodableSendable] = [
            "goal": AnyCodableSendable(goal),
            "triage_role": AnyCodableSendable(triageRole.rawValue),
            "target_role": AnyCodableSendable(targetRole.rawValue),
            "framework": AnyCodableSendable(framework.rawValue),
            "timeout_seconds": AnyCodableSendable(timeoutSeconds)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "run_handoff", payload: payload)
        return try await sendRequest(req, timeoutSeconds: timeoutSeconds + 5.0)
    }

    public func resumeGraph(
        sessionId: String,
        approvalData: [String: AnyCodableSendable] = [:],
        timeoutSeconds: Double = 60.0
    ) async throws -> SidecarResponse {
        let payload: [String: AnyCodableSendable] = [
            "approval_data": AnyCodableSendable(approvalData),
            "timeout_seconds": AnyCodableSendable(timeoutSeconds)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "resume_graph", payload: payload)
        return try await sendRequest(req, timeoutSeconds: timeoutSeconds + 5.0)
    }

    public func invokeAgent(
        agentRole: String,
        input: String,
        sessionId: String = UUID().uuidString,
        timeoutSeconds: Double = 60.0
    ) async throws -> AgentInvocationResult {
        let payload: [String: AnyCodableSendable] = [
            "agent_role": AnyCodableSendable(agentRole),
            "input": AnyCodableSendable(input)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "invoke_agent", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: timeoutSeconds + 5.0)
        guard resp.isSuccess else {
            throw NSError(domain: "MultiAgentSidecarManager", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.error ?? "invoke_agent failed."])
        }

        let output = resp.payload["output"]?.stringValue ?? ""
        let elapsed = resp.payload["elapsed_seconds"]?.doubleValue ?? 0.0
        let role = resp.payload["agent_role"]?.stringValue ?? agentRole
        return AgentInvocationResult(output: output, elapsedSeconds: elapsed, agentRole: role)
    }

    public func listAgents(
        role: String? = nil,
        capability: String? = nil,
        activeOnly: Bool = false
    ) async throws -> [AgentMetadata] {
        var payload: [String: AnyCodableSendable] = [
            "active_only": AnyCodableSendable(activeOnly)
        ]
        if let r = role { payload["role"] = AnyCodableSendable(r) }
        if let c = capability { payload["capability"] = AnyCodableSendable(c) }

        let req = SidecarRequest(sessionId: "list_agents", operation: "list_agents", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess else { return [] }

        guard let agentsAny = resp.payload["agents"]?.arrayValue else { return [] }
        var result: [AgentMetadata] = []
        for item in agentsAny {
            if let dict = item.dictionaryValue,
               let data = try? JSONSerialization.data(withJSONObject: dict.mapValues { $0.rawObject }),
               let meta = try? JSONDecoder().decode(AgentMetadata.self, from: data) {
                result.append(meta)
            }
        }
        return result
    }

    public func getAgent(name: String) async throws -> AgentMetadata? {
        let req = SidecarRequest(
            sessionId: "get_agent",
            operation: "get_agent",
            payload: ["name": AnyCodableSendable(name)]
        )
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess,
              let agentAny = resp.payload["agent"]?.dictionaryValue,
              let data = try? JSONSerialization.data(withJSONObject: agentAny.mapValues { $0.rawObject }) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentMetadata.self, from: data)
    }

    public func registerAgent(
        name: String,
        instructions: String,
        description: String? = nil,
        capabilities: [String] = [],
        allowedTools: [String] = []
    ) async throws -> AgentMetadata {
        var payload: [String: AnyCodableSendable] = [
            "name": AnyCodableSendable(name),
            "instructions": AnyCodableSendable(instructions),
            "capabilities": AnyCodableSendable(capabilities),
            "allowed_tools": AnyCodableSendable(allowedTools)
        ]
        if let d = description { payload["description"] = AnyCodableSendable(d) }

        let req = SidecarRequest(sessionId: "register_agent", operation: "register_agent", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess,
              let agentAny = resp.payload["agent"]?.dictionaryValue,
              let data = try? JSONSerialization.data(withJSONObject: agentAny.mapValues { $0.rawObject }),
              let meta = try? JSONDecoder().decode(AgentMetadata.self, from: data) else {
            throw NSError(domain: "MultiAgentSidecarManager", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.error ?? "Failed to register agent."])
        }
        return meta
    }

    public func updateAgent(name: String, isActive: Bool) async throws -> Bool {
        let payload: [String: AnyCodableSendable] = [
            "name": AnyCodableSendable(name),
            "is_active": AnyCodableSendable(isActive)
        ]
        let req = SidecarRequest(sessionId: "update_agent", operation: "update_agent", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        return resp.isSuccess
    }

    public func deleteAgent(name: String) async throws -> Bool {
        let payload: [String: AnyCodableSendable] = [
            "name": AnyCodableSendable(name)
        ]
        let req = SidecarRequest(sessionId: "delete_agent", operation: "delete_agent", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        return resp.isSuccess
    }

    public func checkpointSession(
        sessionId: String,
        stepIndex: Int,
        activeAgent: String,
        statePayload: [String: AnyCodableSendable] = [:]
    ) async throws -> CheckpointRecord {
        let payload: [String: AnyCodableSendable] = [
            "step_index": AnyCodableSendable(stepIndex),
            "active_agent": AnyCodableSendable(activeAgent),
            "state_payload": AnyCodableSendable(statePayload)
        ]
        let req = SidecarRequest(sessionId: sessionId, operation: "checkpoint_session", payload: payload)
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess,
              let chkAny = resp.payload["checkpoint"]?.dictionaryValue,
              let data = try? JSONSerialization.data(withJSONObject: chkAny.mapValues { $0.rawObject }),
              let chk = try? JSONDecoder().decode(CheckpointRecord.self, from: data) else {
            throw NSError(domain: "MultiAgentSidecarManager", code: -1, userInfo: [NSLocalizedDescriptionKey: resp.error ?? "Failed to save checkpoint."])
        }
        return chk
    }

    public func restoreSession(sessionId: String) async throws -> CheckpointRecord? {
        let req = SidecarRequest(sessionId: sessionId, operation: "restore_session")
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess,
              let chkAny = resp.payload["checkpoint"]?.dictionaryValue,
              let data = try? JSONSerialization.data(withJSONObject: chkAny.mapValues { $0.rawObject }) else {
            return nil
        }
        return try? JSONDecoder().decode(CheckpointRecord.self, from: data)
    }

    public func getMetrics() async throws -> ExecutionMetricsRecord {
        let req = SidecarRequest(sessionId: "metrics", operation: "get_metrics")
        let resp = try await sendRequest(req, timeoutSeconds: 5.0)
        guard resp.isSuccess,
              let metAny = resp.payload["metrics"]?.dictionaryValue,
              let data = try? JSONSerialization.data(withJSONObject: metAny.mapValues { $0.rawObject }),
              let metrics = try? JSONDecoder().decode(ExecutionMetricsRecord.self, from: data) else {
            return ExecutionMetricsRecord()
        }
        return metrics
    }

    public func cancelSession(sessionId: String) async throws -> SidecarResponse {
        await toolBridge.setCancelled(true)
        let req = SidecarRequest(sessionId: sessionId, operation: "cancel")
        return try await sendRequest(req, timeoutSeconds: 5.0)
    }

    public func pauseSession(sessionId: String) async throws -> SidecarResponse {
        await toolBridge.setPaused(true)
        let req = SidecarRequest(sessionId: sessionId, operation: "pause")
        return try await sendRequest(req, timeoutSeconds: 5.0)
    }

    public func resumeSession(sessionId: String) async throws -> SidecarResponse {
        await toolBridge.setPaused(false)
        let req = SidecarRequest(sessionId: sessionId, operation: "resume")
        return try await sendRequest(req, timeoutSeconds: 5.0)
    }

    public func shutdown() async {
        let req = SidecarRequest(sessionId: "shutdown", operation: "shutdown")
        _ = try? await sendRequest(req, timeoutSeconds: 3.0)
        await transport.close()
    }
}
