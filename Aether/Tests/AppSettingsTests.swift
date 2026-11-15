import XCTest
@testable import Aether

final class AppSettingsTests: XCTestCase {
    var testDefaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.aether.settings.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultValues() {
        let settings = AppSettings(defaults: testDefaults)

        XCTAssertEqual(settings.appTheme, "system")
        XCTAssertEqual(settings.fontSize, 13.0)
        XCTAssertEqual(settings.interfaceDensity, "comfortable")
        XCTAssertNil(settings.defaultModelId)
        XCTAssertEqual(settings.contextLength, 4096)
        XCTAssertEqual(settings.maxTokens, 2048)
        XCTAssertEqual(settings.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(settings.topP, 0.9, accuracy: 0.001)
        XCTAssertEqual(settings.topK, 40)
        XCTAssertEqual(settings.repetitionPenalty, 1.1, accuracy: 0.001)
        XCTAssertTrue(settings.metalGPUAcceleration)
        XCTAssertEqual(settings.metalGPULayers, 99)
        XCTAssertTrue(settings.isStreamingEnabled)
        XCTAssertTrue(settings.isAgentModeEnabled)
        XCTAssertTrue(settings.verifyChecksums)
    }

    @MainActor
    func testPersistenceAcrossInstances() {
        let settingsA = AppSettings(defaults: testDefaults)
        settingsA.appTheme = "dark"
        settingsA.temperature = 0.4
        settingsA.maxTokens = 1024
        settingsA.contextLength = 8192
        settingsA.isStreamingEnabled = false
        settingsA.defaultModelId = "custom-test-uuid"

        // Instantiate second instance with same suite
        let settingsB = AppSettings(defaults: testDefaults)
        XCTAssertEqual(settingsB.appTheme, "dark")
        XCTAssertEqual(settingsB.temperature, 0.4, accuracy: 0.001)
        XCTAssertEqual(settingsB.maxTokens, 1024)
        XCTAssertEqual(settingsB.contextLength, 8192)
        XCTAssertFalse(settingsB.isStreamingEnabled)
        XCTAssertEqual(settingsB.defaultModelId, "custom-test-uuid")
    }

    @MainActor
    func testResetToDefaults() {
        let settings = AppSettings(defaults: testDefaults)
        settings.appTheme = "light"
        settings.temperature = 1.2
        settings.maxTokens = 4096
        settings.resetToDefaults()

        XCTAssertEqual(settings.appTheme, "system")
        XCTAssertEqual(settings.temperature, 0.7, accuracy: 0.001)
        XCTAssertEqual(settings.maxTokens, 2048)
        XCTAssertEqual(settings.contextLength, 4096)
    }

    @MainActor
    func testTemporaryCacheClearing() {
        let settings = AppSettings(defaults: testDefaults)
        let cleared = settings.clearTemporaryCache()
        XCTAssertGreaterThanOrEqual(cleared, 0)
    }

    @MainActor
    func testStorageCalculationSafety() {
        let settings = AppSettings(defaults: testDefaults)
        let (used, count) = settings.computeModelStorageUsage()
        XCTAssertGreaterThanOrEqual(used, 0)
        XCTAssertGreaterThanOrEqual(count, 0)
    }
}
