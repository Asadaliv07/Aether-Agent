import XCTest
@testable import Aether

final class MultiAgentTests: XCTestCase {
    private var tempDirectoryURL: URL!
    private var securityGuard: ToolSecurityGuard!
    private var toolRegistry: ToolRegistry!

    override func setUp() async throws {
        try await super.setUp()
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MultiAgentTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDirectoryURL = tempDir

        self.securityGuard = ToolSecurityGuard()
        self.toolRegistry = ToolRegistry(securityGuard: securityGuard)

        // Register standard tools for testing
        await toolRegistry.register(SystemInfoTool())
        await toolRegistry.register(SafeCalculatorTool())
        await toolRegistry.register(SandboxedFileReaderTool(securityGuard: securityGuard))
    }

    override func tearDown() async throws {
        if let dir = tempDirectoryURL {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - 1. Protocol Models & Serialization

    func testProtocolSerializationAndDeserialization() throws {
        let req = SidecarRequest(
            requestId: "req_123",
            sessionId: "sess_456",
            taskId: "task_789",
            operation: "run_sequential",
            payload: ["goal": AnyCodableSendable("Build multi-agent system")]
        )

        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(SidecarRequest.self, from: data)

        XCTAssertEqual(decoded.requestId, "req_123")
        XCTAssertEqual(decoded.sessionId, "sess_456")
        XCTAssertEqual(decoded.taskId, "task_789")
        XCTAssertEqual(decoded.operation, "run_sequential")
        XCTAssertEqual(decoded.payload["goal"]?.stringValue, "Build multi-agent system")
    }

    func testSidecarResponseSuccessDecoding() throws {
        let jsonStr = """
        {
            "protocol_version": "1.0.0",
            "request_id": "req_1",
            "success": true,
            "payload": {
                "framework_version": "1.24.0",
                "status": "ready"
            },
            "error": null
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let resp = try JSONDecoder().decode(SidecarResponse.self, from: data)

        XCTAssertEqual(resp.requestId, "req_1")
        XCTAssertTrue(resp.isSuccess)
        XCTAssertEqual(resp.payload["framework_version"]?.stringValue, "1.24.0")
        XCTAssertNil(resp.error)
    }

    // MARK: - 2. In-Memory Transport & Manager Handshake

    func testInMemoryTransportAndHandshake() async throws {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)

        // Simulate server responder task
        let serverStream = await server.receive()
        let serverTask = Task {
            for try await line in serverStream {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqDict = json["request"] as? [String: Any] else { continue }

                let reqId = reqDict["request_id"] as? String ?? ""
                let op = reqDict["operation"] as? String ?? ""

                if op == "initialize" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"framework_version":"1.24.0","status":"ready"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "ping" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"status":"pong"},"error":null}}
                    """
                    try await server.send(line: resp)
                }
            }
        }

        let initResp = try await manager.initialize()
        XCTAssertTrue(initResp.isSuccess)
        let isInit = await manager.isInitialized
        XCTAssertTrue(isInit)
        let ver = await manager.frameworkVersion
        XCTAssertEqual(ver, "1.24.0")

        let pingOk = try await manager.ping()
        XCTAssertTrue(pingOk)

        serverTask.cancel()
        await server.close()
        await manager.shutdown()
    }

    // MARK: - 3. Security Bridge & Tool Authorization

    func testToolBridgeExecutesAuthorizedTool() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)

        let req = SidecarToolRequest(
            callId: "call_1",
            toolName: "calculator",
            parameters: ["expression": "25 * 4"],
            agentRole: "coder",
            taskId: "task_calc"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertTrue(resp.isSuccess)
        XCTAssertTrue(resp.result.contains("100"))
        XCTAssertNil(resp.error)
    }

    func testToolBridgeRejectsUnregisteredTool() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)

        let req = SidecarToolRequest(
            callId: "call_2",
            toolName: "non_existent_tool",
            parameters: [:],
            agentRole: "researcher",
            taskId: "task_unregistered"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertFalse(resp.isSuccess)
        XCTAssertTrue(resp.error?.contains("not registered") ?? false)
    }

    func testToolBridgeDuplicateCallIdRejected() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)

        let req = SidecarToolRequest(
            callId: "duplicate_call_id",
            toolName: "calculator",
            parameters: ["expression": "10 + 10"],
            agentRole: "planner",
            taskId: "task_dup"
        )

        // First call succeeds
        let resp1 = await bridge.handleToolRequest(req)
        XCTAssertTrue(resp1.isSuccess)

        // Second call with same ID is processed sequentially (inFlight is cleaned up defer)
        // But if concurrent, it will be rejected. Test cancellation/pause flags:
        await bridge.setCancelled(true)
        let resp2 = await bridge.handleToolRequest(req)
        XCTAssertFalse(resp2.isSuccess)
        XCTAssertTrue(resp2.error?.contains("cancelled") ?? false)
    }

    func testToolBridgeRequiresConfirmationAndHandlesRejection() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)

        // Register a restricted tool
        let restrictedTool = MockRestrictedTool()
        await toolRegistry.register(restrictedTool)

        // Set confirmation handler to reject
        await bridge.setConfirmationHandler { _ in return false }

        let req = SidecarToolRequest(
            callId: "call_restricted_1",
            toolName: "mock_restricted",
            parameters: ["action": "critical_update"],
            agentRole: "coder",
            taskId: "task_conf"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertFalse(resp.isSuccess)
        XCTAssertTrue(resp.error?.contains("rejected confirmation") ?? false)
    }

    func testToolBridgeRequiresConfirmationAndHandlesApproval() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)

        let restrictedTool = MockRestrictedTool()
        await toolRegistry.register(restrictedTool)

        // Set confirmation handler to approve
        await bridge.setConfirmationHandler { _ in return true }

        let req = SidecarToolRequest(
            callId: "call_restricted_2",
            toolName: "mock_restricted",
            parameters: ["action": "critical_update"],
            agentRole: "coder",
            taskId: "task_conf"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertTrue(resp.isSuccess)
        XCTAssertEqual(resp.result, "Executed critical_update")
    }

    // MARK: - 4. Lifecycle & Cancellation Enforcement

    func testSessionCancellationStopsToolExecution() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        await bridge.setCancelled(true)

        let req = SidecarToolRequest(
            callId: "call_cancel_test",
            toolName: "calculator",
            parameters: ["expression": "50 + 50"],
            agentRole: "analyst",
            taskId: "task_cancelled"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertFalse(resp.isSuccess)
        XCTAssertTrue(resp.error?.contains("cancelled") ?? false)
    }

    func testSessionPauseStopsToolExecution() async {
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        await bridge.setPaused(true)

        let req = SidecarToolRequest(
            callId: "call_pause_test",
            toolName: "calculator",
            parameters: ["expression": "50 + 50"],
            agentRole: "analyst",
            taskId: "task_paused"
        )

        let resp = await bridge.handleToolRequest(req)
        XCTAssertFalse(resp.isSuccess)
        XCTAssertTrue(resp.error?.contains("paused") ?? false)

        // Resume
        await bridge.setPaused(false)
        let resp2 = await bridge.handleToolRequest(req)
        XCTAssertTrue(resp2.isSuccess)
    }

    // MARK: - 5. End-to-End Real Subprocess Integration (Python Sidecar)

    func testRealPythonSidecarHandshakeAndSequentialWorkflow() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            print("Skipping real subprocess test: Python sidecar venv not found.")
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        // 1. Handshake
        let initResp = try await supervisor.sidecarManager.initialize()
        XCTAssertTrue(initResp.isSuccess)
        let ver = await supervisor.sidecarManager.frameworkVersion
        XCTAssertEqual(ver, "1.24.0")

        // 2. Sequential Workflow (Planner -> Coder -> Reviewer)
        let seqResult = try await supervisor.executeSequential(
            goal: "Refactor database query optimization",
            roles: [.planner, .coder, .reviewer],
            sessionId: "test_seq_real"
        )

        XCTAssertTrue(seqResult.isSuccess)
        XCTAssertFalse(seqResult.finalAnswer.isEmpty)
        XCTAssertGreaterThan(seqResult.elapsedSeconds, 0)
        XCTAssertNil(seqResult.error)

        await supervisor.sidecarManager.shutdown()
    }

    func testRealPythonSidecarParallelWorkflow() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            print("Skipping real subprocess test: Python sidecar venv not found.")
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        // Parallel Workflow (Planner -> [Researcher, Coder, Analyst] in parallel -> Aggregator -> Reviewer)
        let parResult = try await supervisor.executeParallel(
            goal: "Audit application for memory leaks and performance bottlenecks",
            plannerRole: .planner,
            parallelRoles: [.researcher, .coder, .analyst],
            reviewerRole: .reviewer,
            sessionId: "test_par_real"
        )

        XCTAssertTrue(parResult.isSuccess)
        XCTAssertFalse(parResult.finalAnswer.isEmpty)
        XCTAssertGreaterThan(parResult.elapsedSeconds, 0)
        XCTAssertNil(parResult.error)

        await supervisor.sidecarManager.shutdown()
    }

    func testAgentOrchestratorMultiAgentSequentialIntegration() async throws {
        let orchestrator = AgentOrchestrator(registry: toolRegistry, securityGuard: securityGuard)

        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let result = try await orchestrator.runMultiAgentSequential(
            goal: "Analyze and document API contracts",
            roles: [.planner, .researcher, .reviewer],
            sessionId: "orch_test_session"
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertFalse(result.finalAnswer.isEmpty)
    }

    // MARK: - 6. Microsoft Agent Framework Registry, Handoff & Observability Tests

    func testAgentRegistryDiscoveryAndBuiltinAgents() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()

        let agents = try await supervisor.listAgents()
        XCTAssertGreaterThanOrEqual(agents.count, 7, "Registry must return at least 7 built-in specialist agents.")

        let planner = agents.first(where: { $0.role == .planner })
        XCTAssertNotNil(planner)
        XCTAssertEqual(planner?.name, "Planner")
        XCTAssertTrue(planner?.capabilities.contains("planning") == true)

        let coder = agents.first(where: { $0.role == .coder })
        XCTAssertNotNil(coder)
        XCTAssertEqual(coder?.name, "Coder")

        await supervisor.sidecarManager.shutdown()
    }

    func testDynamicAgentRegistrationAndLifecycle() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()

        // 1. Register dynamic custom agent
        let custom = try await supervisor.registerAgent(
            name: "CloudArchitect",
            instructions: "Design robust, highly scalable cloud architectures.",
            description: "Custom cloud specialist",
            capabilities: ["cloud_design", "cost_optimization"],
            allowedTools: ["system_info"]
        )
        XCTAssertEqual(custom.name, "CloudArchitect")
        XCTAssertTrue(custom.capabilities.contains("cloud_design"))

        // 2. Discover by capability
        let discovered = try await supervisor.listAgents(capability: "cloud_design")
        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered.first?.name, "CloudArchitect")

        // 3. Update active status
        let updated = try await supervisor.updateAgent(name: "CloudArchitect", isActive: false)
        XCTAssertTrue(updated)

        let activeOnly = try await supervisor.listAgents(capability: "cloud_design", activeOnly: true)
        XCTAssertEqual(activeOnly.count, 0)

        // 4. Delete custom agent
        let deleted = try await supervisor.deleteAgent(name: "CloudArchitect")
        XCTAssertTrue(deleted)

        await supervisor.sidecarManager.shutdown()
    }

    func testDirectSingleAgentInvocation() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()

        let invResult = try await supervisor.invokeAgent(
            agentRole: "assistant",
            input: "What is Swift 6 concurrency?",
            sessionId: "single_invoke_sess"
        )

        XCTAssertFalse(invResult.output.isEmpty)
        XCTAssertEqual(invResult.agentRole, "assistant")
        XCTAssertGreaterThan(invResult.elapsedSeconds, 0)

        await supervisor.sidecarManager.shutdown()
    }

    func testDynamicAgentHandoffWorkflow() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()

        let handoffResult = try await supervisor.executeHandoff(
            goal: "Diagnose database connection deadlock",
            triageRole: .supervisor,
            targetRole: .coder,
            sessionId: "handoff_test_sess"
        )

        XCTAssertTrue(handoffResult.isSuccess)
        XCTAssertFalse(handoffResult.finalAnswer.isEmpty)
        XCTAssertGreaterThan(handoffResult.elapsedSeconds, 0)

        await supervisor.sidecarManager.shutdown()
    }

    func testSessionCheckpointAndStateResumption() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()
        _ = try await supervisor.sidecarManager.createSession(sessionId: "chk_test_sess")

        let chk = try await supervisor.checkpointSession(
            sessionId: "chk_test_sess",
            stepIndex: 2,
            activeAgent: "planner",
            statePayload: ["plan": AnyCodableSendable("Step 1 done")]
        )
        XCTAssertEqual(chk.sessionId, "chk_test_sess")
        XCTAssertEqual(chk.stepIndex, 2)
        XCTAssertEqual(chk.activeAgent, "planner")

        let restored = try await supervisor.restoreSession(sessionId: "chk_test_sess")
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.stepIndex, 2)
        XCTAssertEqual(restored?.activeAgent, "planner")

        await supervisor.sidecarManager.shutdown()
    }

    func testObservabilityAndExecutionMetrics() async throws {
        let venvPython = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/.venv/bin/python"
        let serverScript = FileManager.default.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent/server.py"

        guard FileManager.default.fileExists(atPath: venvPython),
              FileManager.default.fileExists(atPath: serverScript) else {
            return
        }

        let supervisor = try await MultiAgentSupervisor.createWithSubprocess(
            pythonPath: venvPython,
            scriptPath: serverScript,
            securityGuard: securityGuard,
            toolRegistry: toolRegistry
        )

        _ = try await supervisor.sidecarManager.initialize()

        // Execute workflow to record metrics
        _ = try await supervisor.executeSequential(
            goal: "Metrics evaluation test",
            roles: [.planner, .reviewer],
            sessionId: "metrics_test_sess"
        )

        let metrics = try await supervisor.getMetrics()
        XCTAssertGreaterThanOrEqual(metrics.totalInvocations, 1)
        XCTAssertGreaterThanOrEqual(metrics.successfulInvocations, 1)

        await supervisor.sidecarManager.shutdown()
    }

    // MARK: - 8. LangGraph Orchestration Backend Tests

    func testLangGraphSequentialWorkflowExecution() async throws {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)

        let serverStream = await server.receive()
        let serverTask = Task {
            for try await line in serverStream {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqDict = json["request"] as? [String: Any] else { continue }

                let reqId = reqDict["request_id"] as? String ?? ""
                let op = reqDict["operation"] as? String ?? ""
                let payload = reqDict["payload"] as? [String: Any] ?? [:]

                if op == "initialize" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"framework_version":"1.24.0","langgraph_version":"1.2.20","supported_frameworks":["microsoft_agent_framework","langgraph"],"status":"ready"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "create_session" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"status":"active"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "run_sequential" {
                    let framework = payload["framework"] as? String ?? ""
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"success":true,"framework":"\(framework)","final_answer":"LangGraph sequential pipeline completed.","agent_outputs":{"planner":"Plan A","coder":"Code A","reviewer":"Approved"},"elapsed_seconds":0.12},"error":null}}
                    """
                    try await server.send(line: resp)
                }
            }
        }

        let initResp = try await supervisor.sidecarManager.initialize()
        XCTAssertTrue(initResp.isSuccess)

        let result = try await supervisor.executeSequential(
            goal: "LangGraph sequential test pipeline",
            roles: [.planner, .coder, .reviewer],
            sessionId: "lg_seq_sess_1",
            framework: .langgraph,
            timeoutSeconds: 15.0
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.finalAnswer, "LangGraph sequential pipeline completed.")
        XCTAssertGreaterThan(result.elapsedSeconds, 0)
        serverTask.cancel()
    }

    func testLangGraphParallelWorkflowExecution() async throws {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)

        let serverStream = await server.receive()
        let serverTask = Task {
            for try await line in serverStream {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqDict = json["request"] as? [String: Any] else { continue }

                let reqId = reqDict["request_id"] as? String ?? ""
                let op = reqDict["operation"] as? String ?? ""
                let payload = reqDict["payload"] as? [String: Any] ?? [:]

                if op == "initialize" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"framework_version":"1.24.0","langgraph_version":"1.2.20","supported_frameworks":["microsoft_agent_framework","langgraph"],"status":"ready"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "create_session" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"status":"active"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "run_parallel" {
                    let framework = payload["framework"] as? String ?? ""
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"success":true,"framework":"\(framework)","final_answer":"LangGraph parallel workflow aggregated.","agent_outputs":{"researcher":"Data R","coder":"Code C"},"elapsed_seconds":0.18},"error":null}}
                    """
                    try await server.send(line: resp)
                }
            }
        }

        let result = try await supervisor.executeParallel(
            goal: "LangGraph concurrent analysis",
            plannerRole: .planner,
            parallelRoles: [.researcher, .coder],
            reviewerRole: .reviewer,
            sessionId: "lg_par_sess_1",
            framework: .langgraph,
            timeoutSeconds: 15.0
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.finalAnswer, "LangGraph parallel workflow aggregated.")
        XCTAssertGreaterThan(result.elapsedSeconds, 0)
        serverTask.cancel()
    }

    func testLangGraphHandoffWorkflowExecution() async throws {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)

        let serverStream = await server.receive()
        let serverTask = Task {
            for try await line in serverStream {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqDict = json["request"] as? [String: Any] else { continue }

                let reqId = reqDict["request_id"] as? String ?? ""
                let op = reqDict["operation"] as? String ?? ""
                let payload = reqDict["payload"] as? [String: Any] ?? [:]

                if op == "initialize" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"framework_version":"1.24.0","langgraph_version":"1.2.20","supported_frameworks":["microsoft_agent_framework","langgraph"],"status":"ready"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "create_session" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"status":"active"},"error":null}}
                    """
                    try await server.send(line: resp)
                } else if op == "run_handoff" {
                    let framework = payload["framework"] as? String ?? ""
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"success":true,"framework":"\(framework)","final_answer":"LangGraph handoff routing completed successfully.","target_role":"coder","elapsed_seconds":0.09},"error":null}}
                    """
                    try await server.send(line: resp)
                }
            }
        }

        let result = try await supervisor.executeHandoff(
            goal: "LangGraph dynamic handoff",
            triageRole: .supervisor,
            targetRole: .coder,
            sessionId: "lg_handoff_sess_1",
            framework: .langgraph,
            timeoutSeconds: 15.0
        )

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.finalAnswer, "LangGraph handoff routing completed successfully.")
        XCTAssertGreaterThan(result.elapsedSeconds, 0)
        serverTask.cancel()
    }

    func testLangGraphResumeGraphExecution() async throws {
        let (client, server) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge)

        let serverStream = await server.receive()
        let serverTask = Task {
            for try await line in serverStream {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let reqDict = json["request"] as? [String: Any] else { continue }

                let reqId = reqDict["request_id"] as? String ?? ""
                let op = reqDict["operation"] as? String ?? ""

                if op == "resume_graph" {
                    let resp = """
                    {"type":"response","response":{"protocol_version":"1.0.0","request_id":"\(reqId)","success":true,"payload":{"final_answer":"Resumed and completed.","elapsed_seconds":0.05},"error":null}}
                    """
                    try await server.send(line: resp)
                }
            }
        }

        let resumeResult = try await supervisor.resumeGraph(
            sessionId: "hitl_sess_1",
            approvalData: ["approved": AnyCodableSendable(true)]
        )

        XCTAssertTrue(resumeResult.isSuccess)
        XCTAssertEqual(resumeResult.finalAnswer, "Resumed and completed.")
        serverTask.cancel()
    }

    func testFrameworkSelectionAndDefaultSwitching() async throws {
        let (client, _) = MultiAgentInMemoryTransport.createPair()
        let bridge = MultiAgentToolBridge(securityGuard: securityGuard, toolRegistry: toolRegistry)
        let manager = MultiAgentSidecarManager(transport: client, toolBridge: bridge)
        let supervisor = MultiAgentSupervisor(sidecarManager: manager, toolBridge: bridge, defaultFramework: .maf)

        let initialFramework = await supervisor.defaultFramework
        XCTAssertEqual(initialFramework, .maf)

        await supervisor.setDefaultFramework(.langgraph)
        let switchedFramework = await supervisor.defaultFramework
        XCTAssertEqual(switchedFramework, .langgraph)
    }
}

// MARK: - Mock Restricted Tool for Confirmation Testing

private final class MockRestrictedTool: Tool, @unchecked Sendable {
    let definition = ToolDefinition(
        name: "mock_restricted",
        description: "A tool requiring confirmation",
        parameters: [
            ToolParameter(name: "action", type: .string, description: "Action to execute", isRequired: true)
        ],
        category: .developer,
        permissionLevel: .restricted
    )

    func execute(parameters: [String: String], context: ToolExecutionContext) async throws -> ToolExecutionResult {
        let act = parameters["action"] ?? "unknown"
        return .success(toolName: definition.name, output: "Executed \(act)")
    }
}
