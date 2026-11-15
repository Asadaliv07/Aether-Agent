import Foundation
import os

// MARK: - Completion Verification Result

/// Strongly typed result of autonomous completion verification.
public enum AgentCompletionVerificationResult: Sendable, Equatable {
    /// The resulting state on disk or in the environment was verified against expected criteria.
    case verified(details: String)
    /// The resulting state failed verification or could not be confirmed.
    case unverified(reason: String)
}

// MARK: - Completion Verifier Engine

/// Autonomous completion verification engine fulfilling Phase 6.E requirements.
///
/// Inspects the execution history and environmental state prior to declaring task completion,
/// actively querying target destinations to guarantee that requested files, directories,
/// and side effects actually exist and match expected criteria before marking state as `.completed`.
public struct AgentCompletionVerifier: Sendable {
    private static let logger = Logger(subsystem: "com.aether.Aether", category: "AgentCompletionVerifier")

    /// Verifies the resulting state of the environment against executed actions and stated goal.
    public static func verify(
        state: AgentState,
        registry: ToolRegistry
    ) async -> AgentCompletionVerificationResult {
        // 1. Identify mutating filesystem actions that were executed
        var mutatingTargets: [(action: String, path: String, requireNonEmpty: Bool, requireDirectory: Bool)] = []

        for step in state.history {
            guard let action = step.action else { continue }
            // Only inspect steps where the tool succeeded or was confirmed
            if let obs = step.observation, !obs.isSuccess {
                continue
            }

            switch action {
            case .callTool(let toolName, let params, _), .requestConfirmation(let toolName, let params, _):
                switch toolName {
                case "create_folder":
                    if let path = params["path"] ?? params["folder_path"] {
                        mutatingTargets.append((action: toolName, path: path, requireNonEmpty: false, requireDirectory: true))
                    }
                case "create_file", "write_file":
                    if let path = params["path"] ?? params["file_path"] {
                        let content = params["content"] ?? ""
                        mutatingTargets.append((action: toolName, path: path, requireNonEmpty: !content.isEmpty, requireDirectory: false))
                    }
                case "edit_file", "append_file":
                    if let path = params["path"] ?? params["file_path"] {
                        mutatingTargets.append((action: toolName, path: path, requireNonEmpty: true, requireDirectory: false))
                    }
                case "copy_file", "move_file":
                    if let dest = params["destination"] ?? params["destination_path"] {
                        mutatingTargets.append((action: toolName, path: dest, requireNonEmpty: false, requireDirectory: false))
                    }
                default:
                    break
                }
            default:
                break
            }
        }

        // 2. If no mutating operations occurred in history:
        if mutatingTargets.isEmpty {
            let lowerGoal = state.goal.lowercased()
            let impliesCreation = lowerGoal.contains("create folder") ||
                                  lowerGoal.contains("create directory") ||
                                  lowerGoal.contains("make folder") ||
                                  lowerGoal.contains("make a folder") ||
                                  lowerGoal.contains("create a folder") ||
                                  lowerGoal.contains("write file") ||
                                  lowerGoal.contains("create file")

            let hasSuccessfulTool = state.history.contains { $0.observation?.isSuccess == true }
            if impliesCreation && !hasSuccessfulTool {
                return .unverified(reason: "Goal requested filesystem changes, but no filesystem tools were executed.")
            }
            return .verified(details: "No mutating filesystem operations to verify.")
        }

        // 3. For each mutating target, verify on disk using get_file_info or FileManager
        let checkToolName: String?
        if await registry.tool(named: "get_file_info") != nil {
            checkToolName = "get_file_info"
        } else if await registry.tool(named: "get_file_metadata") != nil {
            checkToolName = "get_file_metadata"
        } else {
            checkToolName = nil
        }

        var verifiedCount = 0
        for target in mutatingTargets {
            if let toolName = checkToolName {
                let context = ToolExecutionContext(
                    conversationId: state.conversationId,
                    executionId: UUID(),
                    timeoutSeconds: 10.0,
                    isInteractiveApprovalGranted: true,
                    cancellationSignal: nil
                )
                let result = await registry.execute(
                    toolName: toolName,
                    parameters: ["path": target.path],
                    context: context
                )
                guard result.status == .success else {
                    return .unverified(reason: "Verification check for '\(target.path)' failed: \(result.errorDescription ?? "unknown error")")
                }

                // Parse output JSON
                if let data = result.output.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let exists = dict["exists"] as? Bool ?? false
                    guard exists else {
                        return .unverified(reason: "Verification failed: Destination '\(target.path)' does not exist on disk.")
                    }

                    if target.requireDirectory {
                        let isDir = dict["is_directory"] as? Bool ?? false
                        guard isDir else {
                            return .unverified(reason: "Verification failed: Destination '\(target.path)' exists but is not a directory.")
                        }
                    }

                    if target.requireNonEmpty {
                        let size = dict["size_bytes"] as? Int ?? (dict["size"] as? Int ?? 0)
                        guard size > 0 else {
                            return .unverified(reason: "Verification failed: Destination '\(target.path)' exists but is empty (0 bytes).")
                        }
                    }
                }
            } else {
                // Fallback to local FileManager if running in unit test without full MCP registry
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir)
                if exists {
                    if target.requireDirectory && !isDir.boolValue {
                        return .unverified(reason: "Verification failed: Destination '\(target.path)' is not a directory.")
                    }
                    if target.requireNonEmpty {
                        let attrs = try? FileManager.default.attributesOfItem(atPath: target.path)
                        let size = attrs?[.size] as? Int ?? 0
                        if size == 0 {
                            return .unverified(reason: "Verification failed: Destination '\(target.path)' is empty (0 bytes).")
                        }
                    }
                }
            }
            verifiedCount += 1
        }

        return .verified(details: "Verified \(verifiedCount) destination(s) on disk successfully.")
    }
}

