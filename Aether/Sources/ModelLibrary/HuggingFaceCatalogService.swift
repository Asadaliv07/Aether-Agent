import Foundation
import os

/// Protocol defining the contract for Hugging Face Hub catalog queries.
public protocol HuggingFaceCatalogServiceProtocol: Sendable {
    func searchModels(
        query: String?,
        architecture: String?,
        sort: HuggingFaceSortOrder,
        limit: Int
    ) async throws -> [HuggingFaceModel]

    func fetchModelDetails(repoId: String) async throws -> HuggingFaceModel

    func fetchRepoFileSizes(
        repoId: String,
        revision: String,
        forceRefresh: Bool
    ) async throws -> [String: Int64]

    func enrichModelWithAccurateFileSizes(
        _ model: HuggingFaceModel,
        forceRefresh: Bool
    ) async throws -> HuggingFaceModel

    func fetchModelCardContent(repoId: String) async throws -> String
}

extension HuggingFaceCatalogServiceProtocol {
    public func fetchRepoFileSizes(
        repoId: String,
        revision: String = "main",
        forceRefresh: Bool = false
    ) async throws -> [String: Int64] {
        try await fetchRepoFileSizes(repoId: repoId, revision: revision, forceRefresh: forceRefresh)
    }

    public func enrichModelWithAccurateFileSizes(
        _ model: HuggingFaceModel,
        forceRefresh: Bool = false
    ) async throws -> HuggingFaceModel {
        try await enrichModelWithAccurateFileSizes(model, forceRefresh: forceRefresh)
    }

    public func fetchModelCardContent(repoId: String) async throws -> String {
        return ""
    }
}

/// Errors occurring during Hugging Face Hub catalog interactions.
public enum HuggingFaceCatalogError: LocalizedError, Equatable {
    case invalidURL
    case rateLimited(retryAfter: Int?)
    case unauthorizedOrGated(repoId: String)
    case repoNotFound(repoId: String)
    case serverError(statusCode: Int)
    case networkFailure(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Hugging Face API request URL."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Hugging Face API rate limit reached. Please wait \(retryAfter) seconds and try again."
            }
            return "Hugging Face API rate limit reached. Please wait a moment and try again."
        case .unauthorizedOrGated(let repo):
            return "Repository '\(repo)' is gated or requires authentication. Please accept the terms on Hugging Face."
        case .repoNotFound(let repo):
            return "Repository '\(repo)' was not found on Hugging Face Hub."
        case .serverError(let code):
            return "Hugging Face server returned an error (HTTP \(code))."
        case .networkFailure(let msg):
            return "Network connection to Hugging Face Hub failed: \(msg)"
        case .decodingError(let msg):
            return "Failed to parse Hugging Face API response: \(msg)"
        }
    }
}

public typealias HuggingFaceError = HuggingFaceCatalogError

/// Actor providing robust, thread-safe access to the Hugging Face Hub REST API.
public actor HuggingFaceCatalogService: HuggingFaceCatalogServiceProtocol {
    private let session: URLSession
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.aether.Aether", category: "HuggingFaceCatalogService")

    private struct CachedRepoMetadata: Sendable {
        let fileSizes: [String: Int64]
        let timestamp: Date
    }

    private var metadataCache: [String: CachedRepoMetadata] = [:]
    private var inFlightTasks: [String: Task<[String: Int64], Error>] = [:]
    private let cacheTTL: TimeInterval = 3600 // 1 hour
    private let maxCacheEntries: Int = 200

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://huggingface.co/api")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    /// Searches the Hugging Face Hub for GGUF model repositories matching the specified criteria.
    public func searchModels(
        query: String? = nil,
        architecture: String? = nil,
        sort: HuggingFaceSortOrder = .downloads,
        limit: Int = 20
    ) async throws -> [HuggingFaceModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: true)

        var filterValue = "gguf"
        if let arch = architecture?.trimmingCharacters(in: .whitespacesAndNewlines), !arch.isEmpty {
            filterValue = "gguf,\(arch)"
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "filter", value: filterValue),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "\(min(max(1, limit), 50))"),
            URLQueryItem(name: "full", value: "true")
        ]

        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            queryItems.append(URLQueryItem(name: "search", value: query))
        }

        components?.queryItems = queryItems

        guard let requestURL = components?.url else {
            throw HuggingFaceCatalogError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15.0

        let (data, response) = try await execute(request: request)
        try validateResponse(response, repoId: query ?? "search")

        return try Self.decodeModels(from: data)
    }

    /// Fetches detailed repository metadata including complete file trees for a specific repository ID.
    public func fetchModelDetails(repoId: String) async throws -> HuggingFaceModel {
        let requestURL = baseURL.appendingPathComponent("models/\(repoId)")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15.0

        let (data, response) = try await execute(request: request)
        try validateResponse(response, repoId: repoId)

        return try Self.decodeSingleModel(from: data, fallbackId: repoId)
    }

    /// Fetches accurate file sizes for all GGUF artifacts in the repository tree.
    public func fetchRepoFileSizes(
        repoId: String,
        revision: String = "main",
        forceRefresh: Bool = false
    ) async throws -> [String: Int64] {
        let cacheKey = "\(repoId)@\(revision)"

        if !forceRefresh {
            if let cached = metadataCache[cacheKey],
               Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                logger.debug("Tree metadata cache hit for \(cacheKey)")
                return cached.fileSizes
            }
        }

        // Deduplicate in-flight requests for the same repository revision
        if let existingTask = inFlightTasks[cacheKey] {
            logger.debug("Coalescing in-flight request for \(cacheKey)")
            return try await existingTask.value
        }

        let task = Task<[String: Int64], Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.fetchTreeFileSizesFromNetwork(repoId: repoId, revision: revision)
        }

        inFlightTasks[cacheKey] = task

        do {
            let sizes = try await task.value
            inFlightTasks.removeValue(forKey: cacheKey)
            pruneCacheIfNeeded()
            metadataCache[cacheKey] = CachedRepoMetadata(fileSizes: sizes, timestamp: Date())
            return sizes
        } catch {
            inFlightTasks.removeValue(forKey: cacheKey)
            throw error
        }
    }

    /// Enriches a discovered model's GGUF files with exact file sizes and re-evaluated compatibility from the repository tree.
    public func enrichModelWithAccurateFileSizes(
        _ model: HuggingFaceModel,
        forceRefresh: Bool = false
    ) async throws -> HuggingFaceModel {
        let sizes = try await fetchRepoFileSizes(repoId: model.id, revision: "main", forceRefresh: forceRefresh)
        let updatedFiles = model.ggufFiles.map { file in
            let matchedSize = sizes[file.filename] ?? sizes[(file.filename as NSString).lastPathComponent]
            if let accurateSize = matchedSize, accurateSize > 0 {
                return file.withUpdatedSize(accurateSize, architecture: model.inferredArchitecture)
            }
            return file
        }
        return model.withUpdatedGGUFFiles(updatedFiles)
    }

    /// Fetches the raw README.md for a model repository to extract authoritative documentation snippets.
    public func fetchModelCardContent(repoId: String) async throws -> String {
        guard let requestURL = URL(string: "https://huggingface.co/\(repoId)/raw/main/README.md") else {
            throw HuggingFaceCatalogError.invalidURL
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return ""
        } catch {
            return ""
        }
    }

    private func fetchTreeFileSizesFromNetwork(repoId: String, revision: String) async throws -> [String: Int64] {
        let baseTreeURL = baseURL.appendingPathComponent("models/\(repoId)/tree/\(revision)")
        var components = URLComponents(url: baseTreeURL, resolvingAgainstBaseURL: true)
        components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]

        guard var nextURL = components?.url else {
            throw HuggingFaceCatalogError.invalidURL
        }

        var allSizes: [String: Int64] = [:]
        var pageCount = 0
        let maxPages = 20

        while pageCount < maxPages {
            pageCount += 1

            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15.0

            let (data, response) = try await execute(request: request)
            try validateResponse(response, repoId: repoId)

            guard let entries = try? JSONDecoder().decode([HuggingFaceTreeEntry].self, from: data) else {
                throw HuggingFaceCatalogError.decodingError("Failed to decode repository tree entries for '\(repoId)'")
            }

            for entry in entries {
                guard entry.path.lowercased().hasSuffix(".gguf") else { continue }
                let size = entry.resolvedSize
                if size > 0 {
                    allSizes[entry.path] = size
                    let name = (entry.path as NSString).lastPathComponent
                    if allSizes[name] == nil {
                        allSizes[name] = size
                    }
                }
            }

            if let httpResponse = response as? HTTPURLResponse,
               let linkHeader = httpResponse.value(forHTTPHeaderField: "Link"),
               let parsedNext = Self.parseNextLink(from: linkHeader) {
                nextURL = parsedNext
            } else {
                break
            }
        }

        return allSizes
    }

    private func pruneCacheIfNeeded() {
        guard metadataCache.count >= maxCacheEntries else { return }
        let now = Date()
        let expiredKeys = metadataCache.filter { now.timeIntervalSince($0.value.timestamp) >= cacheTTL }.map(\.key)
        for key in expiredKeys {
            metadataCache.removeValue(forKey: key)
        }

        if metadataCache.count >= maxCacheEntries {
            let sortedByTime = metadataCache.sorted { $0.value.timestamp < $1.value.timestamp }
            let countToEvict = max(1, metadataCache.count / 5)
            for item in sortedByTime.prefix(countToEvict) {
                metadataCache.removeValue(forKey: item.key)
            }
        }
    }

    public static func parseNextLink(from header: String?) -> URL? {
        guard let header = header, !header.isEmpty else { return nil }
        let links = header.components(separatedBy: ",")
        for link in links {
            let parts = link.components(separatedBy: ";")
            guard parts.count >= 2 else { continue }
            let relPart = parts[1].trimmingCharacters(in: .whitespaces)
            if relPart.contains("rel=\"next\"") || relPart.contains("rel=next") {
                let urlPart = parts[0].trimmingCharacters(in: .whitespaces)
                if urlPart.hasPrefix("<") && urlPart.hasSuffix(">") {
                    let cleaned = String(urlPart.dropFirst().dropLast())
                    return URL(string: cleaned)
                }
            }
        }
        return nil
    }

    #if DEBUG
    public func clearCache() {
        metadataCache.removeAll()
    }

    public func cachedEntryCount() -> Int {
        metadataCache.count
    }
    #endif

    // MARK: - Private Helpers

    private func execute(request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw HuggingFaceCatalogError.networkFailure(error.localizedDescription)
        }
    }

    private func validateResponse(_ response: URLResponse, repoId: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw HuggingFaceCatalogError.unauthorizedOrGated(repoId: repoId)
        case 404:
            throw HuggingFaceCatalogError.repoNotFound(repoId: repoId)
        case 429:
            let retryHeader = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retrySeconds = retryHeader.flatMap { Int($0) }
            throw HuggingFaceCatalogError.rateLimited(retryAfter: retrySeconds)
        case 500...599:
            throw HuggingFaceCatalogError.serverError(statusCode: httpResponse.statusCode)
        default:
            throw HuggingFaceCatalogError.serverError(statusCode: httpResponse.statusCode)
        }
    }

    public static func decodeModels(from data: Data) throws -> [HuggingFaceModel] {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HuggingFaceError.decodingError("Expected JSON array of models from Hugging Face.")
        }

        var models: [HuggingFaceModel] = []
        for dict in jsonArray {
            if let model = parseModel(from: dict) {
                // Only include models that actually have GGUF files available
                if !model.ggufFiles.isEmpty {
                    models.append(model)
                }
            }
        }
        return models
    }

    public static func decodeSingleModel(from data: Data, fallbackId: String) throws -> HuggingFaceModel {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = parseModel(from: dict) else {
            throw HuggingFaceError.decodingError("Invalid model detail payload for \(fallbackId)")
        }
        return model
    }

    public static func parseModel(from dict: [String: Any]) -> HuggingFaceModel? {
        guard let id = dict["id"] as? String ?? dict["modelId"] as? String else {
            return nil
        }

        let parts = id.split(separator: "/", maxSplits: 1)
        let author = dict["author"] as? String ?? (parts.count > 1 ? String(parts[0]) : "community")
        let name = parts.count > 1 ? String(parts[1]) : id

        let downloads = dict["downloads"] as? Int ?? 0
        let likes = dict["likes"] as? Int ?? 0
        let tags = dict["tags"] as? [String] ?? []
        let pipelineTag = dict["pipeline_tag"] as? String
        let isGated: Bool = {
            if let g = dict["gated"] as? Bool { return g }
            if let gStr = dict["gated"] as? String, !gStr.isEmpty, gStr != "false" { return true }
            return false
        }()

        var description: String? = nil
        var license: String? = nil
        var cardDataObj: HuggingFaceCardData? = nil

        if let cardData = dict["cardData"] as? [String: Any] {
            let cardDesc = cardData["description"] as? String
            let cardLic = cardData["license"] as? String
            let baseM: [String]? = {
                if let s = cardData["base_model"] as? String { return [s] }
                if let a = cardData["base_model"] as? [String] { return a }
                return nil
            }()
            let qBy = cardData["quantized_by"] as? String
            cardDataObj = HuggingFaceCardData(license: cardLic, description: cardDesc, baseModel: baseM, quantizedBy: qBy)
            description = cardDesc
            license = cardLic
        }

        if license == nil {
            for tag in tags {
                if tag.hasPrefix("license:") {
                    license = tag.replacingOccurrences(of: "license:", with: "")
                    break
                }
            }
        }

        let lastModified: Date? = {
            guard let dateStr = dict["lastModified"] as? String else { return nil }
            return ISO8601DateFormatter().date(from: dateStr)
        }()

        // Parse siblings
        var siblings: [HuggingFaceSibling] = []
        if let sibArray = dict["siblings"] as? [[String: Any]] {
            for s in sibArray {
                if let rfilename = s["rfilename"] as? String {
                    let size = s["size"] as? Int64
                    var lfsInfo: HuggingFaceLFSInfo? = nil
                    if let lfsDict = s["lfs"] as? [String: Any] {
                        let lfsSize = (lfsDict["size"] as? NSNumber)?.int64Value
                        let sha = lfsDict["sha256"] as? String
                        lfsInfo = HuggingFaceLFSInfo(size: lfsSize, sha256: sha)
                    }
                    siblings.append(HuggingFaceSibling(rfilename: rfilename, size: size, lfs: lfsInfo))
                }
            }
        }

        // Infer architecture
        var architecture: String? = nil
        if let ggufDict = dict["gguf"] as? [String: Any],
           let arch = ggufDict["architecture"] as? String {
            architecture = arch
        }
        if architecture == nil {
            let combined = ([id, name] + tags).joined(separator: " ").lowercased()
            for arch in GGUFMetadataReader.supportedArchitectures {
                if combined.contains(arch.lowercased()) {
                    architecture = arch
                    break
                }
            }
        }

        // Build downloadable GGUF files
        var ggufFiles: [HuggingFaceGGUFFile] = []
        for sibling in siblings where sibling.rfilename.lowercased().hasSuffix(".gguf") {
            let filename = sibling.rfilename
            let size = sibling.resolvedSize
            let quant = HuggingFaceQuantUtils.extractQuantization(from: filename)
            let bitDepth = HuggingFaceQuantUtils.quantBitDepths[quant]
            let isShard = filename.contains("-of-") || filename.contains("-0000")

            let downloadURL = URL(string: "https://huggingface.co/\(id)/resolve/main/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)")!
            let compat = HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: architecture, fileSize: size)

            ggufFiles.append(HuggingFaceGGUFFile(
                repoId: id,
                filename: filename,
                size: size,
                quantization: quant,
                bitDepth: bitDepth,
                isShard: isShard,
                downloadURL: downloadURL,
                compatibility: compat
            ))
        }

        // Sort GGUF files by size ascending (smaller quants first)
        ggufFiles.sort { $0.size < $1.size }

        return HuggingFaceModel(
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
            cardData: cardDataObj
        )
    }
}
