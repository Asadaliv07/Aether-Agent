import Foundation

/// Sort order for Hugging Face model catalog queries.
public enum HuggingFaceSortOrder: String, Sendable, CaseIterable, Identifiable {
    case downloads = "downloads"
    case likes = "likes"
    case lastModified = "lastModified"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .downloads:
            return "Most Downloads"
        case .likes:
            return "Most Liked"
        case .lastModified:
            return "Recently Updated"
        }
    }
}

/// Represents an individual file in a Hugging Face repository.
public struct HuggingFaceSibling: Sendable, Codable, Equatable {
    public let rfilename: String
    public let size: Int64?
    public let lfs: HuggingFaceLFSInfo?

    public init(rfilename: String, size: Int64? = nil, lfs: HuggingFaceLFSInfo? = nil) {
        self.rfilename = rfilename
        self.size = size
        self.lfs = lfs
    }

    public var resolvedSize: Int64 {
        lfs?.size ?? size ?? 0
    }
}

/// LFS metadata block returned by Hugging Face API.
public struct HuggingFaceLFSInfo: Sendable, Codable, Equatable {
    public let size: Int64?
    public let sha256: String?

    public init(size: Int64? = nil, sha256: String? = nil) {
        self.size = size
        self.sha256 = sha256
    }
}

/// Represents a validated, downloadable GGUF file within a Hugging Face repository.
public struct HuggingFaceGGUFFile: Sendable, Identifiable, Equatable {
    public var id: String { "\(repoId)/\(filename)" }
    public let repoId: String
    public let filename: String
    public let size: Int64
    public let quantization: String
    public let bitDepth: Int?
    public let isShard: Bool
    public let downloadURL: URL
    public let compatibility: ModelCompatibility

    public init(
        repoId: String,
        filename: String,
        size: Int64,
        quantization: String,
        bitDepth: Int?,
        isShard: Bool,
        downloadURL: URL,
        compatibility: ModelCompatibility
    ) {
        self.repoId = repoId
        self.filename = filename
        self.size = size
        self.quantization = quantization
        self.bitDepth = bitDepth
        self.isShard = isShard
        self.downloadURL = downloadURL
        self.compatibility = compatibility
    }

    public var formattedSize: String {
        guard size > 0 else { return "Unknown size" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    public var bitDepthLabel: String? {
        guard let bitDepth else { return nil }
        return "\(bitDepth)-bit"
    }

    /// Returns a new instance with an updated file size and re-evaluated compatibility.
    public func withUpdatedSize(_ newSize: Int64, architecture: String?) -> HuggingFaceGGUFFile {
        let newCompat = HuggingFaceQuantUtils.evaluateFileCompatibility(
            architecture: architecture,
            fileSize: newSize
        )
        return HuggingFaceGGUFFile(
            repoId: repoId,
            filename: filename,
            size: newSize,
            quantization: quantization,
            bitDepth: bitDepth,
            isShard: isShard,
            downloadURL: downloadURL,
            compatibility: newCompat
        )
    }
}

/// Model card metadata returned in the `cardData` field.
public struct HuggingFaceCardData: Sendable, Codable, Equatable {
    public let license: String?
    public let description: String?
    public let baseModel: [String]?
    public let quantizedBy: String?

    public init(
        license: String? = nil,
        description: String? = nil,
        baseModel: [String]? = nil,
        quantizedBy: String? = nil
    ) {
        self.license = license
        self.description = description
        self.baseModel = baseModel
        self.quantizedBy = quantizedBy
    }

    enum CodingKeys: String, CodingKey {
        case license
        case description
        case baseModel = "base_model"
        case quantizedBy = "quantized_by"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.license = try? container.decodeIfPresent(String.self, forKey: .license)
        self.description = try? container.decodeIfPresent(String.self, forKey: .description)
        self.quantizedBy = try? container.decodeIfPresent(String.self, forKey: .quantizedBy)

        // base_model can be either a string or an array of strings in HF API
        if let singleModel = try? container.decodeIfPresent(String.self, forKey: .baseModel) {
            self.baseModel = [singleModel]
        } else if let multiModel = try? container.decodeIfPresent([String].self, forKey: .baseModel) {
            self.baseModel = multiModel
        } else {
            self.baseModel = nil
        }
    }
}

// MARK: - Model Categories & Catalog Identity Models

/// Intended capability category for a model.
public enum ModelCategory: String, Sendable, CaseIterable, Identifiable {
    case coding = "Coding"
    case generalAssistant = "General Assistant"
    case reasoning = "Reasoning"
    case math = "Math"
    case base = "Base Model"
    case specialized = "Specialized"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .generalAssistant: return "bubble.left.and.bubble.right"
        case .reasoning: return "brain.head.profile"
        case .math: return "function"
        case .base: return "cube"
        case .specialized: return "gearshape"
        }
    }
}

/// Known instruction or tuning variant of a model.
public enum ModelVariant: String, Sendable, CaseIterable {
    case instruct = "Instruct"
    case chat = "Chat"
    case coder = "Coder"
    case reasoning = "Reasoning"
    case math = "Math"
    case base = "Base"
    case unknown = ""
}

/// Structured, normalized identity separating display title, publisher, quantizer, scale, and category.
public struct NormalizedModelIdentity: Sendable, Equatable {
    public let displayName: String
    public let publisher: String
    public let authorOrOrg: String
    public let quantizer: String?
    public let isCommunityConversion: Bool
    public let parameterScale: String?
    public let category: ModelCategory
    public let variant: ModelVariant
    public let architecture: String?
    public let cleanDescription: String
    public let isOfficialRelease: Bool
    public let originalRepoId: String

    public init(
        displayName: String,
        publisher: String,
        authorOrOrg: String,
        quantizer: String?,
        isCommunityConversion: Bool,
        parameterScale: String?,
        category: ModelCategory,
        variant: ModelVariant,
        architecture: String?,
        cleanDescription: String,
        isOfficialRelease: Bool,
        originalRepoId: String
    ) {
        self.displayName = displayName
        self.publisher = publisher
        self.authorOrOrg = authorOrOrg
        self.quantizer = quantizer
        self.isCommunityConversion = isCommunityConversion
        self.parameterScale = parameterScale
        self.category = category
        self.variant = variant
        self.architecture = architecture
        self.cleanDescription = cleanDescription
        self.isOfficialRelease = isOfficialRelease
        self.originalRepoId = originalRepoId
    }
}

/// Represents a remote model repository discovered from Hugging Face Hub.
public struct HuggingFaceModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let author: String
    public let name: String
    public let downloads: Int
    public let likes: Int
    public let tags: [String]
    public let pipelineTag: String?
    public let description: String?
    public let license: String?
    public let isGated: Bool
    public let lastModified: Date?
    public let siblings: [HuggingFaceSibling]
    public let ggufFiles: [HuggingFaceGGUFFile]
    public let cardData: HuggingFaceCardData?
    public let customDisplayName: String?
    public let customDescription: String?

    public init(
        id: String,
        author: String,
        name: String,
        downloads: Int,
        likes: Int,
        tags: [String],
        pipelineTag: String?,
        description: String?,
        license: String?,
        isGated: Bool,
        lastModified: Date?,
        siblings: [HuggingFaceSibling],
        ggufFiles: [HuggingFaceGGUFFile],
        cardData: HuggingFaceCardData? = nil,
        customDisplayName: String? = nil,
        customDescription: String? = nil
    ) {
        self.id = id
        self.author = author
        self.name = name
        self.downloads = downloads
        self.likes = likes
        self.tags = tags
        self.pipelineTag = pipelineTag
        self.description = description
        self.license = license
        self.isGated = isGated
        self.lastModified = lastModified
        self.siblings = siblings
        self.ggufFiles = ggufFiles
        self.cardData = cardData
        self.customDisplayName = customDisplayName
        self.customDescription = customDescription
    }

    /// Normalized model identity containing cleaned display name, publisher, parameter scale, category, and variant.
    public var normalizedIdentity: NormalizedModelIdentity {
        ModelCatalogNormalizer.normalize(model: self)
    }

    /// Human-readable, clean model title (e.g. "Qwen 2.5 Coder 7B Instruct").
    public var cleanDisplayName: String {
        customDisplayName ?? normalizedIdentity.displayName
    }

    /// Actual model publisher or organization (e.g. "Qwen", "Meta", "Google").
    public var publisher: String {
        normalizedIdentity.publisher
    }

    /// Community quantizer if this is a converted artifact (e.g. "bartowski", "TheBloke").
    public var quantizer: String? {
        normalizedIdentity.quantizer
    }

    /// Whether this artifact is a community conversion rather than an official publisher release.
    public var isCommunityConversion: Bool {
        normalizedIdentity.isCommunityConversion
    }

    /// Verified parameter scale string (e.g. "7B", "3B", "70B").
    public var parameterScale: String? {
        normalizedIdentity.parameterScale
    }

    /// Inferred or declared model capability category.
    public var category: ModelCategory {
        normalizedIdentity.category
    }

    /// Concise, readable, cleaned description with HTML and markdown boilerplate removed.
    public var cleanDescription: String {
        customDescription ?? normalizedIdentity.cleanDescription
    }

    /// Authoritative Hugging Face web repository URL.
    public var authoritativeCardURL: URL {
        URL(string: "https://huggingface.co/\(id)")!
    }

    /// Formatted download count (e.g. "12.4k", "1.2M").
    public var formattedDownloads: String {
        formatMetric(downloads)
    }

    /// Formatted likes count.
    public var formattedLikes: String {
        formatMetric(likes)
    }

    /// Inferred model architecture from tags, id, or description.
    public var inferredArchitecture: String? {
        let textToSearch = ([id, name] + tags).joined(separator: " ").lowercased()
        for arch in GGUFMetadataReader.supportedArchitectures {
            if textToSearch.contains(arch.lowercased()) {
                return arch
            }
        }
        return nil
    }

    private func formatMetric(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }

    /// Returns a new instance with updated GGUF file entries.
    public func withUpdatedGGUFFiles(_ newFiles: [HuggingFaceGGUFFile]) -> HuggingFaceModel {
        HuggingFaceModel(
            id: id,
            author: author,
            name: name,
            downloads: downloads,
            likes: likes,
            tags: tags,
            pipelineTag: pipelineTag,
            description: description,
            license: license,
            isGated: isGated,
            lastModified: lastModified,
            siblings: siblings,
            ggufFiles: newFiles,
            cardData: cardData,
            customDisplayName: customDisplayName,
            customDescription: customDescription
        )
    }

    /// Returns a new instance enriched with updated cardData or custom metadata.
    public func withEnrichedMetadata(
        cardData: HuggingFaceCardData? = nil,
        customDisplayName: String? = nil,
        customDescription: String? = nil
    ) -> HuggingFaceModel {
        HuggingFaceModel(
            id: id,
            author: author,
            name: name,
            downloads: downloads,
            likes: likes,
            tags: tags,
            pipelineTag: pipelineTag,
            description: description,
            license: license,
            isGated: isGated,
            lastModified: lastModified,
            siblings: siblings,
            ggufFiles: ggufFiles,
            cardData: cardData ?? self.cardData,
            customDisplayName: customDisplayName ?? self.customDisplayName,
            customDescription: customDescription ?? self.customDescription
        )
    }
}

// MARK: - Normalization & Title Cleaning Engine

public enum ModelCatalogNormalizer {
    public static let knownPublishers: [(pattern: String, author: String)] = [
        ("qwen", "Qwen"),
        ("llama", "Meta"),
        ("gemma", "Google"),
        ("mistral", "Mistral AI"),
        ("mixtral", "Mistral AI"),
        ("codestral", "Mistral AI"),
        ("ministral", "Mistral AI"),
        ("phi", "Microsoft"),
        ("deepseek", "DeepSeek"),
        ("starcoder", "BigCode"),
        ("smollm", "Hugging Face"),
        ("command-r", "Cohere"),
        ("granite", "IBM"),
        ("hermes", "Nous Research"),
        ("exaone", "LG AI Research"),
        ("bloom", "BigScience"),
        ("falcon", "TII"),
        ("baichuan", "Baichuan"),
        ("olmo", "Allen Institute for AI"),
        ("bitnet", "Microsoft")
    ]

    public static let recognizedCommunityQuantizers: Set<String> = [
        "bartowski",
        "thebloke",
        "mradermacher",
        "unsloth",
        "quantfactory",
        "maziyarpanahi",
        "lonestriker",
        "prunaai",
        "second-state",
        "city96",
        "dranger003",
        "richarderkhov"
    ]

    public static func extractParameterScale(from text: String) -> String? {
        let pattern = #"(?i)(?:^|[-_ \t])([0-9]+(?:\.[0-9]+)?|[0-9]+x[0-9]+)[bB](?:[-_ \t\.]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))
        guard let match = matches.first, match.numberOfRanges > 1 else { return nil }
        let scale = nsString.substring(with: match.range(at: 1))
        return scale.uppercased() + "B"
    }

    public static func extractModelCategory(tags: [String], name: String, pipelineTag: String?) -> ModelCategory {
        let lowerTags = Set(tags.map { $0.lowercased() })
        let lowerName = name.lowercased()

        if lowerTags.contains("code") || lowerName.contains("coder") || lowerName.contains("coding") || lowerName.contains("codestral") || lowerName.contains("starcoder") {
            return .coding
        }
        if lowerTags.contains("reasoning") || lowerName.contains("reasoning") || lowerName.contains("r1") || lowerName.contains("thinking") {
            return .reasoning
        }
        if lowerTags.contains("math") || lowerName.contains("math") {
            return .math
        }
        if lowerTags.contains("conversational") || lowerName.contains("instruct") || lowerName.contains("chat") || lowerName.contains("-it") {
            return .generalAssistant
        }
        if lowerName.contains("base") {
            return .base
        }
        if let pTag = pipelineTag?.lowercased(), pTag == "text-generation" {
            return .generalAssistant
        }
        return .generalAssistant
    }

    public static func extractModelVariant(name: String) -> ModelVariant {
        let lower = name.lowercased()
        if lower.contains("coder") { return .coder }
        if lower.contains("r1") || lower.contains("reasoning") || lower.contains("thinking") { return .reasoning }
        if lower.contains("math") { return .math }
        if lower.contains("chat") { return .chat }
        if lower.contains("instruct") || lower.contains("-it") { return .instruct }
        if lower.contains("base") { return .base }
        return .unknown
    }

    public static func resolvePublisherAndQuantizer(
        repoId: String,
        author: String,
        baseModel: [String]?,
        name: String
    ) -> (publisher: String, quantizer: String?, isCommunityConversion: Bool) {
        let lowerAuthor = author.lowercased()
        let isKnownQuantizer = recognizedCommunityQuantizers.contains(lowerAuthor)
        let hasForeignBase = baseModel != nil && !baseModel!.isEmpty && !baseModel!.first!.lowercased().hasPrefix("\(lowerAuthor)/")

        if isKnownQuantizer || hasForeignBase {
            let quantizer = author
            let isCommunity = true

            var derivedAuthor: String? = nil
            if let firstBase = baseModel?.first {
                let parts = firstBase.split(separator: "/", maxSplits: 1)
                if parts.count > 1 {
                    let baseAuthor = String(parts[0])
                    derivedAuthor = canonicalAuthorName(for: baseAuthor)
                }
            }

            if derivedAuthor == nil {
                let lowerCombined = "\(repoId) \(name)".lowercased()
                for (pat, pub) in knownPublishers {
                    if lowerCombined.contains(pat) {
                        derivedAuthor = pub
                        break
                    }
                }
            }

            let publisher = derivedAuthor ?? author
            return (publisher: publisher, quantizer: quantizer, isCommunityConversion: isCommunity)
        } else {
            let publisher = canonicalAuthorName(for: author)
            return (publisher: publisher, quantizer: nil, isCommunityConversion: false)
        }
    }

    public static func canonicalAuthorName(for rawAuthor: String) -> String {
        let lower = rawAuthor.lowercased()
        switch lower {
        case "meta-llama", "meta": return "Meta"
        case "qwen", "qwenlm": return "Qwen"
        case "google": return "Google"
        case "mistralai": return "Mistral AI"
        case "deepseek-ai", "deepseek": return "DeepSeek"
        case "microsoft": return "Microsoft"
        case "huggingfacetb": return "Hugging Face"
        case "nousresearch": return "Nous Research"
        case "ibm-granite": return "IBM"
        case "cohere": return "Cohere"
        case "bigcode": return "BigCode"
        case "tiiuae": return "TII"
        default: return rawAuthor
        }
    }

    public static func normalizeDisplayTitle(
        rawName: String,
        publisher: String?,
        parameterScale: String?,
        variant: ModelVariant?
    ) -> String {
        var clean = rawName

        // Strip file extension
        if clean.lowercased().hasSuffix(".gguf") {
            clean = String(clean.dropLast(5))
        }

        // Strip GGUF repo suffixes
        let ggufSuffixes = ["-GGUF", "_GGUF", "-gguf", "_gguf"]
        for suf in ggufSuffixes {
            if clean.hasSuffix(suf) {
                clean = String(clean.dropLast(suf.count))
            }
        }

        // Strip quantization tokens
        for q in HuggingFaceQuantUtils.quantBitDepths.keys {
            let patterns = ["-\(q)", ".\(q)", "_\(q)", "-\(q.lowercased())", ".\(q.lowercased())", "_\(q.lowercased())"]
            for pat in patterns {
                clean = clean.replacingOccurrences(of: pat, with: "")
            }
        }

        // Replace -it or -IT with -Instruct
        if clean.lowercased().hasSuffix("-it") {
            clean = String(clean.dropLast(3)) + "-Instruct"
        } else {
            clean = clean.replacingOccurrences(of: "-it-", with: "-Instruct-")
            clean = clean.replacingOccurrences(of: "-IT-", with: "-Instruct-")
        }

        // Clean model family version numbers
        let familyReplacements = [
            ("Meta-Llama-", "Llama "),
            ("meta-llama-", "Llama "),
            ("Meta-Llama", "Llama"),
            ("meta-llama", "Llama"),
            ("Qwen2.5-", "Qwen 2.5 "),
            ("qwen2.5-", "Qwen 2.5 "),
            ("Qwen2-", "Qwen 2 "),
            ("qwen2-", "Qwen 2 "),
            ("Qwen2.5", "Qwen 2.5"),
            ("qwen2.5", "Qwen 2.5"),
            ("Qwen2", "Qwen 2"),
            ("qwen2", "Qwen 2"),
            ("Llama-3.3-", "Llama 3.3 "),
            ("llama-3.3-", "Llama 3.3 "),
            ("Llama-3.2-", "Llama 3.2 "),
            ("llama-3.2-", "Llama 3.2 "),
            ("Llama-3.1-", "Llama 3.1 "),
            ("llama-3.1-", "Llama 3.1 "),
            ("Llama-3-", "Llama 3 "),
            ("llama-3-", "Llama 3 "),
            ("Llama-2-", "Llama 2 "),
            ("llama-2-", "Llama 2 "),
            ("Llama3.3", "Llama 3.3"),
            ("llama3.3", "Llama 3.3"),
            ("Llama3.2", "Llama 3.2"),
            ("llama3.2", "Llama 3.2"),
            ("Llama3.1", "Llama 3.1"),
            ("llama3.1", "Llama 3.1"),
            ("Llama3", "Llama 3"),
            ("llama3", "Llama 3"),
            ("Llama2", "Llama 2"),
            ("llama2", "Llama 2"),
            ("Gemma-3-", "Gemma 3 "),
            ("Gemma-2-", "Gemma 2 "),
            ("gemma-3-", "Gemma 3 "),
            ("gemma-2-", "Gemma 2 "),
            ("Gemma3", "Gemma 3"),
            ("Gemma2", "Gemma 2"),
            ("Mistral-7B-", "Mistral 7B "),
            ("mistral-7b-", "Mistral 7B "),
            ("Phi-3.5-", "Phi 3.5 "),
            ("Phi-3-", "Phi 3 "),
            ("Phi-4-", "Phi 4 "),
            ("DeepSeek-R1-", "DeepSeek R1 "),
            ("DeepSeek-V3-", "DeepSeek V3 "),
            ("SmolLM2-", "SmolLM 2 "),
            ("SmolLM-", "SmolLM ")
        ]

        for (from, to) in familyReplacements {
            clean = clean.replacingOccurrences(of: from, with: to)
        }

        // Replace remaining hyphens and underscores with spaces
        clean = clean.replacingOccurrences(of: "-", with: " ")
        clean = clean.replacingOccurrences(of: "_", with: " ")

        // Format word tokens nicely
        let words = clean.split(separator: " ").map { token -> String in
            let str = String(token)
            let lower = str.lowercased()
            if lower == "qwen" { return "Qwen" }
            if lower == "llama" { return "Llama" }
            if lower == "gemma" { return "Gemma" }
            if lower == "mistral" { return "Mistral" }
            if lower == "instruct" { return "Instruct" }
            if lower == "coder" { return "Coder" }
            if lower == "chat" { return "Chat" }
            if lower == "base" { return "Base" }
            if lower == "distill" { return "Distill" }
            if lower.hasPrefix("qwen") {
                return "Qwen" + str.dropFirst(4)
            }
            if lower.hasPrefix("llama") {
                return "Llama" + str.dropFirst(5)
            }
            if let scale = extractParameterScale(from: str) {
                return scale
            }
            return str
        }

        clean = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        if clean.isEmpty {
            return rawName
        }

        return clean
    }

    public static func stripMarkdownAndHTML(from raw: String) -> String {
        var text = raw

        // Remove YAML frontmatter
        text = text.replacingOccurrences(of: #"(?s)^\s*---[\s\S]*?---\s*"#, with: "", options: .regularExpression)

        // Remove HTML comments
        text = text.replacingOccurrences(of: #"(?s)<!--[\s\S]*?-->"#, with: "", options: .regularExpression)

        // Remove HTML tags
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: "", options: .regularExpression)

        // Remove markdown images and badge links: [![...](...)](...)
        text = text.replacingOccurrences(of: #"\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#, with: "", options: .regularExpression)

        // Convert markdown links to text
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)

        // Remove markdown headings
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s+.*$"#, with: "", options: .regularExpression)

        // Remove markdown bold / italic markers
        text = text.replacingOccurrences(of: #"[*_]{1,3}([^*_]+)[*_]{1,3}"#, with: "$1", options: .regularExpression)

        // Collapse multiple whitespace and newlines
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract first paragraph of substantial text (>30 chars)
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 30 }
        if let firstPara = paragraphs.first {
            if firstPara.count > 240 {
                let prefix = String(firstPara.prefix(240))
                if let lastPeriod = prefix.lastIndex(of: ".") {
                    return String(prefix[...lastPeriod])
                }
                return prefix + "…"
            }
            return firstPara
        }

        return text
    }

    public static func cleanDescription(
        rawText: String?,
        identity: NormalizedModelIdentity
    ) -> String {
        if let raw = rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let stripped = stripMarkdownAndHTML(from: raw)
            if stripped.count > 30 && !stripped.lowercased().hasPrefix("this is gguf") {
                return stripped
            }
        }

        let paramStr = identity.parameterScale.map { "\($0) " } ?? ""
        let catStr = identity.category.rawValue.lowercased()
        let varStr = identity.variant != .unknown ? "\(identity.variant.rawValue) " : ""

        let lowerPub = identity.publisher.lowercased()
        if identity.isCommunityConversion, let quant = identity.quantizer {
            return "\(paramStr)\(varStr)\(catStr) model by \(identity.publisher), converted to GGUF by \(quant)."
        } else if !identity.publisher.isEmpty && lowerPub != "community" && lowerPub != "unknown" {
            return "Official \(paramStr)\(varStr)\(catStr) model by \(identity.publisher)."
        }

        return "No verified model description is available."
    }

    public static func normalize(model: HuggingFaceModel) -> NormalizedModelIdentity {
        let (publisher, quantizer, isCommunity) = resolvePublisherAndQuantizer(
            repoId: model.id,
            author: model.author,
            baseModel: model.cardData?.baseModel,
            name: model.name
        )

        let scale = extractParameterScale(from: "\(model.name) \(model.id)")
        let category = extractModelCategory(tags: model.tags, name: model.name, pipelineTag: model.pipelineTag)
        let variant = extractModelVariant(name: model.name)
        let displayName = normalizeDisplayTitle(
            rawName: model.name,
            publisher: publisher,
            parameterScale: scale,
            variant: variant
        )

        let initialIdentity = NormalizedModelIdentity(
            displayName: displayName,
            publisher: publisher,
            authorOrOrg: model.author,
            quantizer: quantizer,
            isCommunityConversion: isCommunity,
            parameterScale: scale,
            category: category,
            variant: variant,
            architecture: model.inferredArchitecture,
            cleanDescription: "",
            isOfficialRelease: !isCommunity,
            originalRepoId: model.id
        )

        let desc = cleanDescription(rawText: model.description, identity: initialIdentity)

        return NormalizedModelIdentity(
            displayName: displayName,
            publisher: publisher,
            authorOrOrg: model.author,
            quantizer: quantizer,
            isCommunityConversion: isCommunity,
            parameterScale: scale,
            category: category,
            variant: variant,
            architecture: model.inferredArchitecture,
            cleanDescription: desc,
            isOfficialRelease: !isCommunity,
            originalRepoId: model.id
        )
    }

    public static func normalize(installedName: String, filePath: String, architecture: String) -> String {
        let filename = (filePath as NSString).lastPathComponent
        let candidate = installedName.contains(".gguf") ? filename : installedName
        let scale = extractParameterScale(from: "\(installedName) \(filename)")
        let variant = extractModelVariant(name: candidate)

        var publisher = "Local"
        let lower = "\(installedName) \(filename)".lowercased()
        for (pat, pub) in knownPublishers {
            if lower.contains(pat) {
                publisher = pub
                break
            }
        }

        return normalizeDisplayTitle(
            rawName: candidate,
            publisher: publisher,
            parameterScale: scale,
            variant: variant
        )
    }
}

// MARK: - Quantization & GGUF Extraction Utilities

public enum HuggingFaceQuantUtils {
    /// Known quantization bit-depth mapping in bits per weight.
    public static let quantBitDepths: [String: Int] = [
        "BF16": 16, "F16": 16, "FP16": 16,
        "Q8_0": 8, "Q8_1": 8, "Q8_K": 8,
        "Q6_K": 6, "Q6_K_L": 6,
        "Q5_K_M": 5, "Q5_K_S": 5, "Q5_0": 5, "Q5_1": 5,
        "Q4_K_M": 4, "Q4_K_S": 4, "Q4_0": 4, "Q4_1": 4, "IQ4_NL": 4, "IQ4_XS": 4,
        "Q3_K_L": 3, "Q3_K_M": 3, "Q3_K_S": 3, "IQ3_M": 3, "IQ3_S": 3, "IQ3_XS": 3, "IQ3_XXS": 3,
        "Q2_K": 2, "Q2_K_S": 2, "IQ2_M": 2, "IQ2_S": 2, "IQ2_XS": 2, "IQ2_XXS": 2,
        "IQ1_M": 1, "IQ1_S": 1
    ]

    /// Extracts quantization token (e.g. "Q4_K_M", "Q8_0") from a GGUF filename.
    public static func extractQuantization(from filename: String) -> String {
        let clean = (filename as NSString).deletingPathExtension
        let upper = clean.uppercased()

        // Match longest standard patterns first
        let patterns = [
            "Q4_K_M", "Q4_K_S", "Q5_K_M", "Q5_K_S", "Q3_K_L", "Q3_K_M", "Q3_K_S",
            "Q2_K_S", "Q2_K", "Q6_K_L", "Q6_K", "Q8_0", "Q8_1", "Q8_K",
            "Q4_0", "Q4_1", "Q5_0", "Q5_1",
            "IQ4_NL", "IQ4_XS", "IQ3_XXS", "IQ3_XS", "IQ3_S", "IQ3_M",
            "IQ2_XXS", "IQ2_XS", "IQ2_S", "IQ2_M", "IQ1_S", "IQ1_M",
            "BF16", "FP16", "F16"
        ]

        for pat in patterns {
            if upper.contains(pat) {
                return pat
            }
        }

        return "GGUF"
    }

    /// Evaluates compatibility of a remote GGUF file given the inferred architecture, host RAM,
    /// and estimated runtime memory demand.
    public static func evaluateFileCompatibility(
        architecture: String?,
        fileSize: Int64,
        targetContextLength: Int? = nil,
        cacheType: KVCacheDataType = .f16,
        hostRAM: UInt64? = nil
    ) -> ModelCompatibility {
        guard let arch = architecture?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !arch.isEmpty else {
            return .unknown("Architecture is unverified or not declared")
        }

        guard GGUFMetadataReader.supportedArchitectures.contains(arch) else {
            return .unsupportedArchitecture(arch)
        }

        guard fileSize > 0 else {
            return .unknown("File size unknown; memory requirements cannot be evaluated")
        }

        let targetCtx = targetContextLength ?? 2048
        let syntheticMetadata = GGUFMetadata(
            architecture: arch,
            name: arch,
            quantization: extractQuantization(from: "model.gguf"),
            contextLength: targetCtx,
            blockCount: 32,
            parameterCount: nil,
            tensorCount: 0,
            chatTemplate: nil,
            license: nil,
            headCount: 32,
            headCountKV: 8,
            embeddingLength: 4096,
            keyLength: 128
        )

        let estimate = GGUFMetadataReader.estimateRuntimeMemory(
            metadata: syntheticMetadata,
            fileSize: fileSize,
            targetContextLength: targetCtx,
            cacheType: cacheType,
            hostRAM: hostRAM
        )

        if !estimate.isCompatible, let warning = estimate.warningReason {
            return .memoryWarning(warning)
        }

        return .compatible
    }
}

// MARK: - Hugging Face Repository Tree Models

/// Represents a single file or directory item returned by the Hugging Face Hub tree API (`/api/models/{repo}/tree/{revision}`).
public struct HuggingFaceTreeEntry: Sendable, Codable, Equatable {
    public let type: String
    public let path: String
    public let size: Int64?
    public let lfs: HuggingFaceTreeLFS?

    public init(
        type: String,
        path: String,
        size: Int64? = nil,
        lfs: HuggingFaceTreeLFS? = nil
    ) {
        self.type = type
        self.path = path
        self.size = size
        self.lfs = lfs
    }

    /// Resolves the actual byte size of the file, checking LFS metadata first or falling back to raw size.
    public var resolvedSize: Int64 {
        if let lfsSize = lfs?.size, lfsSize > 0 {
            return lfsSize
        }
        if let size = size, size > 0 {
            return size
        }
        return 0
    }
}

/// Represents Git LFS metadata in a Hugging Face tree API entry.
public struct HuggingFaceTreeLFS: Sendable, Codable, Equatable {
    public let size: Int64?
    public let sha256: String?
    public let pointerSize: Int64?

    public init(size: Int64? = nil, sha256: String? = nil, pointerSize: Int64? = nil) {
        self.size = size
        self.sha256 = sha256
        self.pointerSize = pointerSize
    }

    enum CodingKeys: String, CodingKey {
        case size
        case sha256
        case pointerSize = "pointerSize"
    }
}
