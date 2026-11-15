import Foundation
import os

/// Locates and validates the Python runtime and sidecar scripts across production bundle,
/// Application Support, environment overrides, and development fallbacks.
public enum SidecarRuntimeLocator {
    private static let logger = Logger(subsystem: "com.aether.Aether", category: "SidecarRuntimeLocator")

    public struct ResolvedRuntime: Sendable {
        public let pythonPath: String
        public let scriptPath: String
        public let checkpointDirectory: String
        public let runtimeTier: String

        public init(
            pythonPath: String,
            scriptPath: String,
            checkpointDirectory: String,
            runtimeTier: String
        ) {
            self.pythonPath = pythonPath
            self.scriptPath = scriptPath
            self.checkpointDirectory = checkpointDirectory
            self.runtimeTier = runtimeTier
        }
    }

    /// Resolves the sidecar execution environment adhering to macOS App Sandbox boundaries.
    public static func resolve(customPython: String? = nil, customScript: String? = nil) throws -> ResolvedRuntime {
        let fm = FileManager.default

        // 1. Resolve Sandboxed Application Support Checkpoint Directory
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let checkpointDir = appSupport.appendingPathComponent("Aether/Checkpoints", isDirectory: true)
        try fm.createDirectory(at: checkpointDir, withIntermediateDirectories: true)

        // 2. Custom overrides if explicitly provided
        if let py = customPython, let sc = customScript {
            if fm.fileExists(atPath: py) && fm.fileExists(atPath: sc) {
                return ResolvedRuntime(
                    pythonPath: py,
                    scriptPath: sc,
                    checkpointDirectory: checkpointDir.path,
                    runtimeTier: "CustomOverride"
                )
            }
        }

        // 3. Environment Variable Overrides
        let env = ProcessInfo.processInfo.environment
        if let envPy = env["AETHER_PYTHON_PATH"], let envSc = env["AETHER_SIDECAR_SCRIPT_PATH"] {
            if fm.fileExists(atPath: envPy) && fm.fileExists(atPath: envSc) {
                return ResolvedRuntime(
                    pythonPath: envPy,
                    scriptPath: envSc,
                    checkpointDirectory: checkpointDir.path,
                    runtimeTier: "EnvironmentVariable"
                )
            }
        }

        // 4. Tier 1: Application Bundle Embedded Runtime (Production Distributed App)
        if let resourceURL = Bundle.main.resourceURL {
            let bundleSidecar = resourceURL.appendingPathComponent("Sidecars/MultiAgent", isDirectory: true)
            let candidatePythons = [
                bundleSidecar.appendingPathComponent("runtime/bin/python3").path,
                bundleSidecar.appendingPathComponent("python/bin/python3").path,
                bundleSidecar.appendingPathComponent(".venv/bin/python3").path,
                bundleSidecar.appendingPathComponent(".venv/bin/python").path
            ]
            let candidateScript = bundleSidecar.appendingPathComponent("server.py").path

            if fm.fileExists(atPath: candidateScript) {
                for py in candidatePythons {
                    if fm.isExecutableFile(atPath: py) {
                        logger.info("[SidecarRuntimeLocator] Located Tier 1 Bundle Runtime at: \(py)")
                        return ResolvedRuntime(
                            pythonPath: py,
                            scriptPath: candidateScript,
                            checkpointDirectory: checkpointDir.path,
                            runtimeTier: "ApplicationBundle"
                        )
                    }
                }
            }
        }

        // 5. Tier 2: Sandboxed Application Support Runtime (User-installed standalone runtime)
        let appSupportSidecar = appSupport.appendingPathComponent("Aether/Sidecars/MultiAgent", isDirectory: true)
        let appSupportPythons = [
            appSupportSidecar.appendingPathComponent("runtime/bin/python3").path,
            appSupportSidecar.appendingPathComponent(".venv/bin/python3").path,
            appSupportSidecar.appendingPathComponent(".venv/bin/python").path
        ]
        let appSupportScript = appSupportSidecar.appendingPathComponent("server.py").path

        if fm.fileExists(atPath: appSupportScript) {
            for py in appSupportPythons {
                if fm.isExecutableFile(atPath: py) {
                    logger.info("[SidecarRuntimeLocator] Located Tier 2 Application Support Runtime at: \(py)")
                    return ResolvedRuntime(
                        pythonPath: py,
                        scriptPath: appSupportScript,
                        checkpointDirectory: checkpointDir.path,
                        runtimeTier: "ApplicationSupport"
                    )
                }
            }
        }

        // 6. Tier 3: Development Workspace Fallback (Source Repository Execution)
        let sourceAnchor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MultiAgent
            .deletingLastPathComponent() // Agent
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // Aether
            .appendingPathComponent("Resources/Sidecars/MultiAgent").path

        let devWorkspaces = [
            sourceAnchor,
            fm.currentDirectoryPath + "/Aether/Resources/Sidecars/MultiAgent",
            fm.currentDirectoryPath + "/Resources/Sidecars/MultiAgent",
            Bundle.main.bundlePath + "/../../../../Aether/Resources/Sidecars/MultiAgent"
        ]

        for ws in devWorkspaces {
            let devScript = ws + "/server.py"
            let devPythons = [
                ws + "/.venv/bin/python3",
                ws + "/.venv/bin/python"
            ]
            if fm.fileExists(atPath: devScript) {
                for py in devPythons {
                    if fm.isExecutableFile(atPath: py) {
                        logger.info("[SidecarRuntimeLocator] Located Tier 3 Dev Workspace Runtime at: \(py)")
                        return ResolvedRuntime(
                            pythonPath: py,
                            scriptPath: devScript,
                            checkpointDirectory: checkpointDir.path,
                            runtimeTier: "DevWorkspace"
                        )
                    }
                }
            }
        }

        logger.error("[SidecarRuntimeLocator] Failed to locate a valid Python sidecar runtime across all tiers.")
        throw NSError(
            domain: "SidecarRuntimeLocator",
            code: 404,
            userInfo: [
                NSLocalizedDescriptionKey: "No compatible Microsoft Agent Framework Python runtime found. Ensure the application bundle contains the embedded sidecar or AETHER_PYTHON_PATH is configured."
            ]
        )
    }
}
