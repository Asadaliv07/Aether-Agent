import Foundation
import Observation

/// Application state tracking foundational environment, persistence, inference, and chat coordinators.
///
/// Uses Swift 6 Observation framework (`@Observable`) with strict MainActor isolation.
@Observable
@MainActor
public final class AppState {
    public let appName: String = "Aether"
    public let appVersion: String = "0.1.0"
    public let buildPhase: String = "Phase 3.6 — Local Model Library, Multi-Model Selection & Catalog Management"
    public let launchDate: Date = Date()

    public var operatingSystemVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64) — Non-target architecture"
        #else
        return "Unknown Architecture"
        #endif
    }

    /// Configured App Sandbox policy for the application target.
    public let sandboxPolicy: String = "App Sandbox entitlement configured"

    /// Supporting detail documenting the configured sandbox boundary.
    public let sandboxPolicyDetail: String = "The app target is configured with com.apple.security.app-sandbox = true. SQLite database resides in the application container."

    public let database: ConversationDatabase
    public let inferenceService: InferenceService
    public let modelLibraryService: ModelLibraryService
    public let chatViewModel: ChatViewModel

    public init() {
        let db: ConversationDatabase
        do {
            db = try ConversationDatabase()
        } catch {
            fatalError("Failed to initialize SQLite database: \(error.localizedDescription)")
        }
        let inf = InferenceService()
        let lib = ModelLibraryService(database: db)
        self.database = db
        self.inferenceService = inf
        self.modelLibraryService = lib
        self.chatViewModel = ChatViewModel(inferenceService: inf, database: db, modelLibraryService: lib)
    }

    /// Alternate initializer for testing with injected components.
    public init(database: ConversationDatabase, inferenceService: InferenceService, modelLibraryService: ModelLibraryService? = nil) {
        let lib = modelLibraryService ?? ModelLibraryService(database: database)
        self.database = database
        self.inferenceService = inferenceService
        self.modelLibraryService = lib
        self.chatViewModel = ChatViewModel(inferenceService: inferenceService, database: database, modelLibraryService: lib)
    }
}
