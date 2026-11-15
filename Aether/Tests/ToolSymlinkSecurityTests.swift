import XCTest
@testable import Aether

final class ToolSymlinkSecurityTests: XCTestCase {
    var tempDirectory: URL!
    var authorizedManager: AuthorizedDirectoryManager!
    var securityGuard: ToolSecurityGuard!
    var outsideDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        tempDirectory = fm.temporaryDirectory.appendingPathComponent("AetherSymlinkTest_\(UUID().uuidString)")
        try fm.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        outsideDirectory = fm.temporaryDirectory.appendingPathComponent("AetherOutside_\(UUID().uuidString)")
        try fm.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)

        authorizedManager = AuthorizedDirectoryManager(restorePersistedBookmarks: false)
        try await authorizedManager.authorizeDirectory(url: tempDirectory)

        securityGuard = ToolSecurityGuard(directoryManager: authorizedManager)
    }

    override func tearDown() async throws {
        let fm = FileManager.default
        if let temp = tempDirectory {
            try? fm.removeItem(at: temp)
        }
        if let outside = outsideDirectory {
            try? fm.removeItem(at: outside)
        }
        try await super.tearDown()
    }

    func testSymlinkPointingOutsideSandboxDenied() async throws {
        let fm = FileManager.default
        let outsideSecretFile = outsideDirectory.appendingPathComponent("secret.txt")
        try "super_sensitive_outside_data".write(to: outsideSecretFile, atomically: true, encoding: .utf8)

        // Create symlink inside authorized directory pointing to the outside directory
        let symlinkURL = tempDirectory.appendingPathComponent("symlink_to_outside")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDirectory)

        let targetPath = symlinkURL.appendingPathComponent("secret.txt").path

        do {
            _ = try await authorizedManager.validateAndResolve(path: targetPath)
            XCTFail("Should have thrown protectedSystemPath error for symlink escape")
        } catch let error as SecurityValidationError {
            switch error {
            case .protectedSystemPath:
                break // Expected
            default:
                XCTFail("Expected .protectedSystemPath, got: \(error)")
            }
        }
    }

    func testNonexistentFileUnderSymlinkOutsideDenied() async throws {
        let fm = FileManager.default
        let symlinkURL = tempDirectory.appendingPathComponent("escape_link")
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDirectory)

        let nonExistentPath = symlinkURL.appendingPathComponent("uncreated_file.txt").path

        do {
            _ = try await authorizedManager.validateAndResolve(path: nonExistentPath)
            XCTFail("Should have thrown error for non-existent file under escaping symlink")
        } catch let error as SecurityValidationError {
            switch error {
            case .protectedSystemPath:
                break // Expected
            default:
                XCTFail("Expected .protectedSystemPath, got: \(error)")
            }
        }
    }

    func testSymlinkInsideSandboxAllowed() async throws {
        let fm = FileManager.default
        let internalFolder = tempDirectory.appendingPathComponent("internal_folder")
        try fm.createDirectory(at: internalFolder, withIntermediateDirectories: true)

        let internalFile = internalFolder.appendingPathComponent("test.txt")
        try "internal_content".write(to: internalFile, atomically: true, encoding: .utf8)

        let internalSymlink = tempDirectory.appendingPathComponent("internal_link")
        try fm.createSymbolicLink(at: internalSymlink, withDestinationURL: internalFolder)

        let readPath = internalSymlink.appendingPathComponent("test.txt").path
        let (canonicalURL, rootURL) = try await authorizedManager.validateAndResolve(path: readPath)

        XCTAssertTrue(canonicalURL.path.hasPrefix(rootURL.path))
        XCTAssertEqual(canonicalURL.standardized.path, internalFile.resolvingSymlinksInPath().standardized.path)
    }

    func testSymlinkTraversalViaDotDotPathDenied() async throws {
        let fm = FileManager.default
        let internalFolder = tempDirectory.appendingPathComponent("sub")
        try fm.createDirectory(at: internalFolder, withIntermediateDirectories: true)

        let traversalPath = "\(internalFolder.path)/../../../../../../etc/passwd"

        do {
            _ = try await authorizedManager.validateAndResolve(path: traversalPath)
            XCTFail("Path with .. component must be denied")
        } catch let error as SecurityValidationError {
            switch error {
            case .pathTraversalAttempt:
                break // Expected
            default:
                XCTFail("Expected .pathTraversalAttempt, got: \(error)")
            }
        }
    }

    func testPostCreationVerificationDetectsSymlinkEscape() async throws {
        let server = MCPFilesystemServer(directoryManager: authorizedManager)
        let fm = FileManager.default

        // Create symlink pointing outside
        let linkToOutside = tempDirectory.appendingPathComponent("escape_dir")
        try fm.createSymbolicLink(at: linkToOutside, withDestinationURL: outsideDirectory)

        let createArgs: [String: AnyCodableSendable] = [
            "path": AnyCodableSendable(linkToOutside.appendingPathComponent("escaped_file.txt").path),
            "content": AnyCodableSendable("malicious")
        ]

        let result = await server.executeTool(name: "create_file", arguments: createArgs)
        XCTAssertEqual(result.isError, true)
        // File must not exist in outside directory
        XCTAssertFalse(fm.fileExists(atPath: outsideDirectory.appendingPathComponent("escaped_file.txt").path))
    }
}
