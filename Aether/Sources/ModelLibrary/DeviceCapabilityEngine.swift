import Foundation
import Darwin

// MARK: - Device Hardware & Capability Assessment

/// Hardware recommendation level for a specific model on the current host Mac.
public enum ModelHardwareSuitability: Sendable, Equatable {
    case optimal(String)
    case suitable(String)
    case highMemoryPressure(String)
    case requiresMoreRAM(neededGB: Int, currentGB: Int)
    case requiresSpecializedEngine(String)

    public var badgeText: String {
        switch self {
        case .optimal:
            return "Optimal for this Mac"
        case .suitable:
            return "Runs Smoothly"
        case .highMemoryPressure:
            return "High RAM Demand"
        case .requiresMoreRAM(let needed, _):
            return "Requires \(needed)GB RAM"
        case .requiresSpecializedEngine(let engine):
            return "Requires \(engine)"
        }
    }

    public var isSmoothlyPlayable: Bool {
        switch self {
        case .optimal, .suitable:
            return true
        case .highMemoryPressure, .requiresMoreRAM, .requiresSpecializedEngine:
            return false
        }
    }
}

/// Unified memory tier on Apple Silicon Macs.
public enum AppleSiliconMemoryTier: String, Sendable, CaseIterable {
    case base8GB = "8 GB"
    case standard16GB = "16 GB"
    case enthusiast24to36GB = "24–36 GB"
    case pro48to64GB = "48–64 GB"
    case ultra128GBPlus = "128+ GB"
}

/// Host machine capability profile for intelligent model recommendations.
public struct DeviceCapabilityProfile: Sendable, Equatable {
    public let physicalRAMBytes: UInt64
    public let physicalRAMGigabytes: Int
    public let chipIdentifier: String
    public let isAppleSilicon: Bool
    public let memoryTier: AppleSiliconMemoryTier

    public init(
        physicalRAMBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        chipIdentifier: String = DeviceCapabilityEngine.queryChipIdentifier()
    ) {
        self.physicalRAMBytes = physicalRAMBytes
        let gb = Int(round(Double(physicalRAMBytes) / (1024.0 * 1024.0 * 1024.0)))
        self.physicalRAMGigabytes = gb
        self.chipIdentifier = chipIdentifier

        #if arch(arm64)
        self.isAppleSilicon = true
        #else
        self.isAppleSilicon = false
        #endif

        if gb <= 8 {
            self.memoryTier = .base8GB
        } else if gb <= 18 {
            self.memoryTier = .standard16GB
        } else if gb <= 36 {
            self.memoryTier = .enthusiast24to36GB
        } else if gb <= 64 {
            self.memoryTier = .pro48to64GB
        } else {
            self.memoryTier = .ultra128GBPlus
        }
    }

    public var summaryDescription: String {
        "\(chipIdentifier) • \(physicalRAMGigabytes) GB Unified Memory"
    }
}

/// Engine that performs hardware-aware capability profiling and model recommendations.
public enum DeviceCapabilityEngine {
    public static let currentProfile = DeviceCapabilityProfile()

    public static func getProfile() -> DeviceCapabilityProfile {
        currentProfile
    }

    /// Queries the machine processor/chip identifier via `sysctl`.
    public static func queryChipIdentifier() -> String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        let raw = String(cString: machine).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "Apple Silicon" : raw
    }

    /// Dynamically samples available system memory (free + inactive pages) using Darwin host_statistics64.
    public static func sampleAvailableSystemMemoryBytes() -> UInt64? {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(getpagesize())
        let freeBytes = UInt64(vmStats.free_count) * pageSize
        let inactiveBytes = UInt64(vmStats.inactive_count) * pageSize
        return freeBytes + inactiveBytes
    }

    /// Evaluates suitability of a model metadata entry against host Mac memory and architecture.
    public static func evaluateSuitability(
        model: ComprehensiveModelMetadata,
        profile: DeviceCapabilityProfile = currentProfile,
        availableMemoryBytes: UInt64? = nil
    ) -> ModelHardwareSuitability {
        // If the model requires an external specialized engine, inform user
        if let primaryEngine = model.supportedInferenceEngines.first, !primaryEngine.isLocallyNative {
            return .requiresSpecializedEngine(primaryEngine.badgeLabel)
        }

        let minRAMBytes = model.hardwareRequirements.minimumRAMBytes
        let recRAMBytes = model.hardwareRequirements.recommendedRAMBytes
        let hostRAM = profile.physicalRAMBytes

        // Host has less than the absolute minimum required RAM
        if hostRAM < minRAMBytes {
            let neededGB = Int(ceil(Double(minRAMBytes) / (1024.0 * 1024.0 * 1024.0)))
            return .requiresMoreRAM(neededGB: neededGB, currentGB: profile.physicalRAMGigabytes)
        }

        // Host meets minimum but is below recommended
        if hostRAM < recRAMBytes {
            return .highMemoryPressure("Runs with potential memory pressure (\(profile.physicalRAMGigabytes)GB host RAM vs \(model.hardwareRequirements.recommendedRAMFormatted) recommended)")
        }

        // MAJ-02: Check dynamic memory pressure: if live free/inactive RAM is below minimum requirement,
        // flag active system memory pressure
        if let availableRAM = availableMemoryBytes, availableRAM < minRAMBytes {
            let availGB = Double(availableRAM) / (1024.0 * 1024.0 * 1024.0)
            return .highMemoryPressure("Active system memory pressure (~\(String(format: "%.1f", availGB))GB available; background apps may throttle)")
        }

        // Check if host has ample headroom (e.g. host RAM is at least 1.3x recommended)
        if Double(hostRAM) >= Double(recRAMBytes) * 1.25 {
            return .optimal("Optimal performance with Metal GPU acceleration on \(profile.chipIdentifier)")
        }

        return .suitable("Comfortably fits in unified memory on this Mac (\(profile.physicalRAMGigabytes)GB)")
    }
}
