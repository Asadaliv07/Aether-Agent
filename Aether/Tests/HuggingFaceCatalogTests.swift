import XCTest
@testable import Aether

final class HuggingFaceCatalogTests: XCTestCase {

    // MARK: - Model Decoding & Quant Parsing Tests

    func testModelDecodingFromValidJSON() throws {
        let json = """
        [
            {
                "_id": "65e234",
                "id": "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
                "author": "Qwen",
                "description": "Qwen2.5-Coder is the latest series of Code-Specific Qwen large language models.",
                "downloads": 125000,
                "likes": 342,
                "pipeline_tag": "text-generation",
                "gated": false,
                "tags": ["text-generation", "gguf", "llama", "code"],
                "siblings": [
                    { "rfilename": "README.md", "size": 1250 },
                    { "rfilename": "qwen2.5-coder-7b-instruct-q4_k_m.gguf", "size": 4680000000 },
                    { "rfilename": "qwen2.5-coder-7b-instruct-q8_0.gguf", "size": 8100000000 },
                    { "rfilename": ".gitattributes", "size": 340 }
                ]
            }
        ]
        """.data(using: .utf8)!

        let models = try HuggingFaceCatalogService.decodeModels(from: json)

        XCTAssertEqual(models.count, 1)
        let model = models[0]
        XCTAssertEqual(model.id, "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF")
        XCTAssertEqual(model.name, "Qwen2.5-Coder-7B-Instruct-GGUF")
        XCTAssertEqual(model.author, "Qwen")
        XCTAssertEqual(model.downloads, 125000)
        XCTAssertEqual(model.likes, 342)
        XCTAssertEqual(model.pipelineTag, "text-generation")
        XCTAssertFalse(model.isGated)

        // Only GGUF files should be extracted
        XCTAssertEqual(model.ggufFiles.count, 2)
        XCTAssertEqual(model.ggufFiles[0].filename, "qwen2.5-coder-7b-instruct-q4_k_m.gguf")
        XCTAssertEqual(model.ggufFiles[0].quantization, "Q4_K_M")
        XCTAssertEqual(model.ggufFiles[0].size, 4680000000)

        XCTAssertEqual(model.ggufFiles[1].filename, "qwen2.5-coder-7b-instruct-q8_0.gguf")
        XCTAssertEqual(model.ggufFiles[1].quantization, "Q8_0")
        XCTAssertEqual(model.ggufFiles[1].size, 8100000000)
    }

    func testQuantTokenExtraction() {
        XCTAssertEqual(HuggingFaceQuantUtils.extractQuantization(from: "llama-3-8b-instruct.Q4_K_M.gguf"), "Q4_K_M")
        XCTAssertEqual(HuggingFaceQuantUtils.extractQuantization(from: "model-q8_0.gguf"), "Q8_0")
        XCTAssertEqual(HuggingFaceQuantUtils.extractQuantization(from: "mistral-7b-v0.1.q5_k_s.gguf"), "Q5_K_S")
        XCTAssertEqual(HuggingFaceQuantUtils.extractQuantization(from: "gemma-2b-f16.gguf"), "F16")
        XCTAssertEqual(HuggingFaceQuantUtils.extractQuantization(from: "custom-model.gguf"), "GGUF")
    }

    override func tearDown() {
        MockURLProtocol.testHandler = nil
        super.tearDown()
    }

    func testMemoryCompatibilityClassification() {
        let smallSize: Int64 = 3_000_000_000 // 3 GB

        let compSmall = HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: "llama", fileSize: smallSize)
        XCTAssertTrue(compSmall.isUsable)

        let compUnsupported = HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: "unknown_weird_arch", fileSize: smallSize)
        XCTAssertFalse(compUnsupported.isUsable)
        if case .unsupportedArchitecture(let arch) = compUnsupported {
            XCTAssertEqual(arch, "unknown_weird_arch")
        } else {
            XCTFail("Expected unsupportedArchitecture")
        }

        let compNoArch = HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: nil, fileSize: smallSize)
        XCTAssertFalse(compNoArch.isUsable)
        if case .unknown(let reason) = compNoArch {
            XCTAssertTrue(reason.contains("Architecture is unverified"))
        } else {
            XCTFail("Expected unknown for nil architecture")
        }

        let compZeroSize = HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: "llama", fileSize: 0)
        XCTAssertFalse(compZeroSize.isUsable)
        if case .unknown(let reason) = compZeroSize {
            XCTAssertTrue(reason.contains("File size unknown"))
        } else {
            XCTFail("Expected unknown for 0 file size")
        }
    }

    // MARK: - Mock URLProtocol for Service Tests

    final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var testHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        override class func canInit(with request: URLRequest) -> Bool {
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            return request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.testHandler else {
                XCTFail("MockURLProtocol handler not set")
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testCatalogServiceSearchModels() async throws {
        let mockJSON = """
        [
            {
                "id": "meta-llama/Meta-Llama-3-8B-Instruct-GGUF",
                "author": "meta-llama",
                "downloads": 500000,
                "likes": 1200,
                "pipeline_tag": "text-generation",
                "gated": false,
                "siblings": [
                    { "rfilename": "meta-llama-3-8b-instruct-q4_k_m.gguf", "size": 4920000000 }
                ]
            }
        ]
        """.data(using: .utf8)!

        MockURLProtocol.testHandler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("filter=gguf") == true)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, mockJSON)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())
        let models = try await service.searchModels(query: "llama", architecture: "llama", sort: .downloads, limit: 10)

        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].author, "meta-llama")
        XCTAssertEqual(models[0].ggufFiles.count, 1)
    }

    func testCatalogServiceHandles429RateLimit() async {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "60"]
            )!
            return (response, Data())
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        do {
            _ = try await service.searchModels(query: "qwen", architecture: nil, sort: .downloads, limit: 10)
            XCTFail("Expected rate limit error")
        } catch let error as HuggingFaceCatalogError {
            if case .rateLimited(let retryAfter) = error {
                XCTAssertEqual(retryAfter, 60)
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-catalog error: \(error)")
        }
    }

    func testCatalogServiceHandles403GatedRepository() async {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        do {
            _ = try await service.fetchModelDetails(repoId: "meta-llama/Meta-Llama-3-70B")
            XCTFail("Expected gated/unauthorized error")
        } catch let error as HuggingFaceCatalogError {
            if case .unauthorizedOrGated(let repo) = error {
                XCTAssertEqual(repo, "meta-llama/Meta-Llama-3-70B")
            } else {
                XCTFail("Unexpected error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-catalog error: \(error)")
        }
    }

    // MARK: - Tree API, Pagination & Caching Tests

    func testTreeEntryDecodingAndResolvedSize() throws {
        let json = """
        [
            {
                "type": "file",
                "path": "model-q4_k_m.gguf",
                "size": 4200000000,
                "lfs": {
                    "size": 4200000000,
                    "sha256": "abc123def456",
                    "pointerSize": 134
                }
            },
            {
                "type": "file",
                "path": "small_config.json",
                "size": 1500,
                "lfs": null
            },
            {
                "type": "file",
                "path": "empty_file.gguf",
                "size": null,
                "lfs": null
            }
        ]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([HuggingFaceTreeEntry].self, from: json)
        XCTAssertEqual(entries.count, 3)

        XCTAssertEqual(entries[0].path, "model-q4_k_m.gguf")
        XCTAssertEqual(entries[0].resolvedSize, 4200000000)

        XCTAssertEqual(entries[1].path, "small_config.json")
        XCTAssertEqual(entries[1].resolvedSize, 1500)

        XCTAssertEqual(entries[2].path, "empty_file.gguf")
        XCTAssertEqual(entries[2].resolvedSize, 0)
    }

    func testParseNextLinkFromRFC5988Header() {
        let singleHeader = "<https://huggingface.co/api/models/org/repo/tree/main?cursor=xyz&recursive=true>; rel=\"next\""
        let parsedSingle = HuggingFaceCatalogService.parseNextLink(from: singleHeader)
        XCTAssertEqual(parsedSingle?.absoluteString, "https://huggingface.co/api/models/org/repo/tree/main?cursor=xyz&recursive=true")

        let multiHeader = "<https://huggingface.co/first>; rel=\"prev\", <https://huggingface.co/page2?cursor=abc>; rel=\"next\""
        let parsedMulti = HuggingFaceCatalogService.parseNextLink(from: multiHeader)
        XCTAssertEqual(parsedMulti?.absoluteString, "https://huggingface.co/page2?cursor=abc")

        let noNextHeader = "<https://huggingface.co/prev>; rel=\"prev\""
        XCTAssertNil(HuggingFaceCatalogService.parseNextLink(from: noNextHeader))

        XCTAssertNil(HuggingFaceCatalogService.parseNextLink(from: nil))
        XCTAssertNil(HuggingFaceCatalogService.parseNextLink(from: ""))
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int = 0

        init(_ initial: Int = 0) {
            _value = initial
        }

        var value: Int {
            lock.withLock { _value }
        }

        @discardableResult
        func increment() -> Int {
            lock.withLock {
                _value += 1
                return _value
            }
        }
    }

    func testTreePaginationFollowsLinkHeader() async throws {
        let pageCount = AtomicCounter(0)
        MockURLProtocol.testHandler = { request in
            let count = pageCount.increment()
            if count == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Link": "<https://huggingface.co/api/models/test-org/paged-model/tree/main?cursor=p2&recursive=true>; rel=\"next\""
                    ]
                )!
                let data = """
                [{"type": "file", "path": "shard-01.gguf", "size": 4000000000}]
                """.data(using: .utf8)!
                return (response, data)
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = """
                [{"type": "file", "path": "shard-02.gguf", "size": 4100000000}]
                """.data(using: .utf8)!
                return (response, data)
            }
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())
        let sizes = try await service.fetchRepoFileSizes(repoId: "test-org/paged-model")

        XCTAssertEqual(pageCount.value, 2)
        XCTAssertEqual(sizes["shard-01.gguf"], 4000000000)
        XCTAssertEqual(sizes["shard-02.gguf"], 4100000000)
    }

    func testTreeFilteringNonGGUFFiles() async throws {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            [
                {"type": "file", "path": "README.md", "size": 2500},
                {"type": "file", "path": "tokenizer.json", "size": 950000},
                {"type": "file", "path": "model.safetensors", "size": 15000000000},
                {"type": "file", "path": "model-q4_k_m.gguf", "size": 4500000000}
            ]
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())
        let sizes = try await service.fetchRepoFileSizes(repoId: "test-org/mixed-files")

        // Only .gguf files should be retained in the sizes dictionary
        XCTAssertNil(sizes["README.md"])
        XCTAssertNil(sizes["tokenizer.json"])
        XCTAssertNil(sizes["model.safetensors"])
        XCTAssertEqual(sizes["model-q4_k_m.gguf"], 4500000000)
    }

    func testTreeMetadataCachingAndExplicitRefresh() async throws {
        let networkHits = AtomicCounter(0)
        MockURLProtocol.testHandler = { request in
            networkHits.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            [{"type": "file", "path": "model-q4_k_m.gguf", "size": 4300000000}]
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        // Initial request hits network
        let sizes1 = try await service.fetchRepoFileSizes(repoId: "test-org/cache-test")
        XCTAssertEqual(networkHits.value, 1)
        XCTAssertEqual(sizes1["model-q4_k_m.gguf"], 4300000000)

        // Repeat request without forceRefresh hits cache
        let sizes2 = try await service.fetchRepoFileSizes(repoId: "test-org/cache-test")
        XCTAssertEqual(networkHits.value, 1)
        XCTAssertEqual(sizes2["model-q4_k_m.gguf"], 4300000000)

        // Request with forceRefresh: true bypasses cache
        let sizes3 = try await service.fetchRepoFileSizes(repoId: "test-org/cache-test", forceRefresh: true)
        XCTAssertEqual(networkHits.value, 2)
        XCTAssertEqual(sizes3["model-q4_k_m.gguf"], 4300000000)
    }

    func testTreeConcurrentRequestsDeduplication() async throws {
        let networkHits = AtomicCounter(0)
        MockURLProtocol.testHandler = { request in
            networkHits.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            [{"type": "file", "path": "model-q4_k_m.gguf", "size": 4500000000}]
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        // Launch 4 concurrent requests for the same repo
        async let r1 = service.fetchRepoFileSizes(repoId: "test-org/coalesce-repo")
        async let r2 = service.fetchRepoFileSizes(repoId: "test-org/coalesce-repo")
        async let r3 = service.fetchRepoFileSizes(repoId: "test-org/coalesce-repo")
        async let r4 = service.fetchRepoFileSizes(repoId: "test-org/coalesce-repo")

        let (res1, res2, res3, res4) = try await (r1, r2, r3, r4)

        XCTAssertEqual(res1, res2)
        XCTAssertEqual(res2, res3)
        XCTAssertEqual(res3, res4)
        XCTAssertEqual(networkHits.value, 1, "Concurrent requests for the same repository revision must be coalesced into 1 network call")
    }

    func testTreeEndpoint429RateLimit() async {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "45"]
            )!
            return (response, Data())
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        do {
            _ = try await service.fetchRepoFileSizes(repoId: "test-org/rate-limited-tree")
            XCTFail("Expected rateLimited error")
        } catch let error as HuggingFaceCatalogError {
            if case .rateLimited(let retryAfter) = error {
                XCTAssertEqual(retryAfter, 45)
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-catalog error: \(error)")
        }
    }

    func testTreeEndpoint401Or403GatedRepository() async {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        do {
            _ = try await service.fetchRepoFileSizes(repoId: "meta-llama/Llama-3-Gated")
            XCTFail("Expected unauthorizedOrGated error")
        } catch let error as HuggingFaceCatalogError {
            if case .unauthorizedOrGated(let repo) = error {
                XCTAssertEqual(repo, "meta-llama/Llama-3-Gated")
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected non-catalog error: \(error)")
        }
    }

    func testModelEnrichmentReEvaluatesCompatibilityFromUnknown() async throws {
        // Initial model discovered via summary where file size is 0
        let initialFile = HuggingFaceGGUFFile(
            repoId: "test-org/tiny-model",
            filename: "tiny-model-q4_k_m.gguf",
            size: 0,
            quantization: "Q4_K_M",
            bitDepth: 4,
            isShard: false,
            downloadURL: URL(string: "https://huggingface.co/test-org/tiny-model/resolve/main/tiny-model-q4_k_m.gguf")!,
            compatibility: HuggingFaceQuantUtils.evaluateFileCompatibility(architecture: "llama", fileSize: 0)
        )

        XCTAssertEqual(initialFile.formattedSize, "Unknown size")
        if case .unknown(let reason) = initialFile.compatibility {
            XCTAssertTrue(reason.contains("File size unknown"))
        } else {
            XCTFail("Initial compatibility should be .unknown for size 0")
        }

        let initialModel = HuggingFaceModel(
            id: "test-org/tiny-model",
            author: "test-org",
            name: "tiny-model",
            downloads: 1000,
            likes: 50,
            tags: ["llama"],
            pipelineTag: "text-generation",
            description: "A small test model",
            license: "apache-2.0",
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: [initialFile]
        )

        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            [{"type": "file", "path": "tiny-model-q4_k_m.gguf", "size": 2500000000}]
            """.data(using: .utf8)!
            return (response, data)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())
        let enriched = try await service.enrichModelWithAccurateFileSizes(initialModel)

        XCTAssertEqual(enriched.ggufFiles.count, 1)
        let enrichedFile = enriched.ggufFiles[0]
        XCTAssertEqual(enrichedFile.size, 2500000000)
        XCTAssertNotEqual(enrichedFile.formattedSize, "Unknown size")
        XCTAssertTrue(enrichedFile.compatibility.isUsable)
        XCTAssertEqual(enrichedFile.compatibility, .compatible)
    }

    func testCorruptTreePayloadThrowsDecodingErrorWithoutCaching() async {
        MockURLProtocol.testHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let corruptData = "<html><body>Not JSON</body></html>".data(using: .utf8)!
            return (response, corruptData)
        }

        let service = HuggingFaceCatalogService(session: makeMockSession())

        do {
            _ = try await service.fetchRepoFileSizes(repoId: "test-org/corrupt-tree")
            XCTFail("Expected decodingError")
        } catch let error as HuggingFaceCatalogError {
            if case .decodingError = error {
                // Expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let cacheCount = await service.cachedEntryCount()
        XCTAssertEqual(cacheCount, 0, "Failed tree fetches must not be cached")
    }

    func testGGUFFileWithUpdatedSizeReEvaluatesCompatibility() {
        let fileZero = HuggingFaceGGUFFile(
            repoId: "test/repo",
            filename: "model.Q4_K_M.gguf",
            size: 0,
            quantization: "Q4_K_M",
            bitDepth: 4,
            isShard: false,
            downloadURL: URL(string: "https://example.com/model.gguf")!,
            compatibility: .unknown("Waiting for metadata")
        )

        let fileEnriched = fileZero.withUpdatedSize(3_500_000_000, architecture: "llama")
        XCTAssertEqual(fileEnriched.size, 3_500_000_000)
        XCTAssertEqual(fileEnriched.compatibility, .compatible)
        XCTAssertTrue(fileEnriched.compatibility.isUsable)

        let fileUnsupportedArch = fileZero.withUpdatedSize(3_500_000_000, architecture: "unsupported_xyz")
        XCTAssertFalse(fileUnsupportedArch.compatibility.isUsable)
        if case .unsupportedArchitecture(let arch) = fileUnsupportedArch.compatibility {
            XCTAssertEqual(arch, "unsupported_xyz")
        } else {
            XCTFail("Expected unsupportedArchitecture")
        }
    }

    // MARK: - Phase 3.10: Normalization & Identity Tests

    func testOfficialRepositoryNamingAndIdentity() {
        let model = HuggingFaceModel(
            id: "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
            author: "Qwen",
            name: "Qwen2.5-Coder-7B-Instruct-GGUF",
            downloads: 150000,
            likes: 620,
            tags: ["code", "gguf", "llama", "conversational"],
            pipelineTag: "text-generation",
            description: "Qwen2.5-Coder is the latest code-specific model from Qwen.",
            license: "apache-2.0",
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: []
        )

        let identity = model.normalizedIdentity
        XCTAssertEqual(identity.displayName, "Qwen 2.5 Coder 7B Instruct")
        XCTAssertEqual(identity.publisher, "Qwen")
        XCTAssertNil(identity.quantizer)
        XCTAssertFalse(identity.isCommunityConversion)
        XCTAssertTrue(identity.isOfficialRelease)
        XCTAssertEqual(identity.parameterScale, "7B")
        XCTAssertEqual(identity.category, .coding)
        XCTAssertEqual(identity.variant, .coder)
    }

    func testCommunityConversionAttributionSeparation() {
        let model = HuggingFaceModel(
            id: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            author: "bartowski",
            name: "Llama-3.2-3B-Instruct-GGUF",
            downloads: 85000,
            likes: 310,
            tags: ["llama", "text-generation", "conversational"],
            pipelineTag: "text-generation",
            description: nil,
            license: "llama3.2",
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: [],
            cardData: HuggingFaceCardData(
                license: "llama3.2",
                description: nil,
                baseModel: ["meta-llama/Llama-3.2-3B-Instruct"],
                quantizedBy: "bartowski"
            )
        )

        let identity = model.normalizedIdentity
        XCTAssertEqual(identity.displayName, "Llama 3.2 3B Instruct")
        XCTAssertEqual(identity.publisher, "Meta", "Base model author meta-llama should resolve to Meta")
        XCTAssertEqual(identity.quantizer, "bartowski")
        XCTAssertTrue(identity.isCommunityConversion)
        XCTAssertFalse(identity.isOfficialRelease)
        XCTAssertEqual(identity.parameterScale, "3B")
        XCTAssertEqual(identity.category, .generalAssistant)
        XCTAssertEqual(identity.variant, .instruct)
    }

    func testParameterScaleExtractionCases() {
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "Qwen2.5-Coder-7B-Instruct"), "7B")
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "Llama-3.2-1B-Instruct"), "1B")
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "Qwen2.5-0.5B"), "0.5B")
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "Qwen2.5-1.5B-Instruct"), "1.5B")
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "Mixtral-8x7B-Instruct"), "8X7B")
        XCTAssertEqual(ModelCatalogNormalizer.extractParameterScale(from: "DeepSeek-V3-671B"), "671B")
        XCTAssertNil(ModelCatalogNormalizer.extractParameterScale(from: "bert-base-uncased"))
    }

    func testDescriptionCleanupAndHTMLStripping() {
        let dirtyDescription = """
        ---
        license: apache-2.0
        tags:
        - code
        ---
        <!-- comment here -->
        # Model Summary
        [![Hugging Face](https://img.shields.io/badge/hf-repo-yellow.svg)](https://huggingface.co)
        <div class="header">Notice: This is important</div>
        **Qwen2.5-Coder-7B** is designed specifically for code generation, bug fixing, and repository understanding.
        It supports over 92 programming languages with a large context window.
        """

        let cleaned = ModelCatalogNormalizer.stripMarkdownAndHTML(from: dirtyDescription)
        XCTAssertFalse(cleaned.contains("---"), "Frontmatter must be stripped")
        XCTAssertFalse(cleaned.contains("<!--"), "HTML comments must be stripped")
        XCTAssertFalse(cleaned.contains("<div"), "HTML tags must be stripped")
        XCTAssertFalse(cleaned.contains("# Model Summary"), "Headings must be stripped")
        XCTAssertFalse(cleaned.contains("[!["), "Badges must be stripped")
        XCTAssertTrue(cleaned.contains("Qwen2.5-Coder-7B is designed specifically for code generation"))
    }

    func testNeutralFallbackDescriptionNeverHallucinates() {
        let communityModel = HuggingFaceModel(
            id: "bartowski/Qwen2.5-Coder-7B-Instruct-GGUF",
            author: "bartowski",
            name: "Qwen2.5-Coder-7B-Instruct-GGUF",
            downloads: 1000,
            likes: 10,
            tags: ["code"],
            pipelineTag: nil,
            description: nil,
            license: nil,
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: []
        )

        let cleanDesc = communityModel.cleanDescription
        XCTAssertTrue(cleanDesc.contains("7B"))
        XCTAssertTrue(cleanDesc.contains("Qwen"))
        XCTAssertTrue(cleanDesc.contains("bartowski"))
        XCTAssertFalse(cleanDesc.contains("state of the art"), "Never invent marketing or benchmark claims")
        XCTAssertFalse(cleanDesc.contains("99% accuracy"), "Never invent metrics")

        let unknownModel = HuggingFaceModel(
            id: "unknown/mystery-repo",
            author: "unknown",
            name: "mystery-repo",
            downloads: 0,
            likes: 0,
            tags: [],
            pipelineTag: nil,
            description: nil,
            license: nil,
            isGated: false,
            lastModified: nil,
            siblings: [],
            ggufFiles: []
        )
        XCTAssertEqual(unknownModel.cleanDescription, "No verified model description is available.")
    }

    func testInstalledModelNormalizationPreservesIdentity() {
        let normalized = ModelCatalogNormalizer.normalize(
            installedName: "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            filePath: "/Users/test/Models/qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            architecture: "qwen2"
        )
        XCTAssertEqual(normalized, "Qwen 2.5 Coder 7B Instruct")

        let normalizedLlama = ModelCatalogNormalizer.normalize(
            installedName: "Meta-Llama-3.1-8B-Instruct-Q8_0.gguf",
            filePath: "/Users/test/Models/Meta-Llama-3.1-8B-Instruct-Q8_0.gguf",
            architecture: "llama"
        )
        XCTAssertEqual(normalizedLlama, "Llama 3.1 8B Instruct")
    }

    func testModelRecordComputedPropertiesWithoutSchemaMigration() {
        let record = ModelRecord(
            name: "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            filePath: "/path/to/qwen2.5-coder-7b-instruct-q4_k_m.gguf",
            fileSize: 4_680_000_000,
            architecture: "qwen2",
            quantization: "Q4_K_M",
            contextLength: 32768,
            parameterCount: 7_000_000_000
        )

        XCTAssertEqual(record.displayName, "Qwen 2.5 Coder 7B Instruct")
        XCTAssertEqual(record.parameterScale, "7.0B")
        XCTAssertEqual(record.category, .coding)
    }

    func testCategoryExtractionRules() {
        let codeCat = ModelCatalogNormalizer.extractModelCategory(tags: ["code"], name: "qwen", pipelineTag: nil)
        XCTAssertEqual(codeCat, .coding)

        let reasoningCat = ModelCatalogNormalizer.extractModelCategory(tags: [], name: "DeepSeek-R1-Distill-Qwen-7B", pipelineTag: nil)
        XCTAssertEqual(reasoningCat, .reasoning)

        let mathCat = ModelCatalogNormalizer.extractModelCategory(tags: ["math"], name: "Qwen2.5-Math-7B", pipelineTag: nil)
        XCTAssertEqual(mathCat, .math)

        let generalCat = ModelCatalogNormalizer.extractModelCategory(tags: ["text-generation"], name: "Llama-3.2-3B-Instruct", pipelineTag: "text-generation")
        XCTAssertEqual(generalCat, .generalAssistant)
    }

    func testAdversarialAndMalformedMetadata() throws {
        // Payload with base_model as string instead of array, null fields, and numeric strings
        let json = """
        [
            {
                "id": "unsloth/gemma-2-2b-it-GGUF",
                "author": "unsloth",
                "cardData": {
                    "base_model": "google/gemma-2-2b-it",
                    "description": "<script>alert('xss')</script>A high performance lightweight model.",
                    "license": "gemma"
                },
                "tags": ["gemma", "conversational"],
                "siblings": [
                    { "rfilename": "gemma-2-2b-it-Q4_K_M.gguf", "size": 1700000000 }
                ]
            }
        ]
        """.data(using: .utf8)!

        let models = try HuggingFaceCatalogService.decodeModels(from: json)
        XCTAssertEqual(models.count, 1)
        let model = models[0]

        XCTAssertEqual(model.publisher, "Google", "Unsloth converted Google model should attribute Google as publisher")
        XCTAssertEqual(model.quantizer, "unsloth")
        XCTAssertTrue(model.isCommunityConversion)
        XCTAssertEqual(model.cleanDisplayName, "Gemma 2 2B Instruct")
        XCTAssertFalse(model.cleanDescription.contains("<script>"), "Scripts must be stripped from description")
    }
}
