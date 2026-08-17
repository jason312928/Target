import Foundation
import XCTest

@testable import Target

@MainActor
final class TargetUpdateControllerTests: XCTestCase {
    func testBuildPresentationParsesVersionBuildAndChannels() {
        let preview = TargetUpdatePresentation(infoDictionary: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "TargetBuildChannel": "DevelopmentPreview"
        ])
        XCTAssertEqual(preview.version, "1.2.3")
        XCTAssertEqual(preview.build, "42")
        XCTAssertEqual(preview.channel, .developmentPreview)
        XCTAssertEqual(preview.channel.localizedKey, "settings.software-update.channel.development-preview")

        XCTAssertEqual(TargetBuildChannel(bundleValue: "Stable"), .stable)
        XCTAssertEqual(TargetBuildChannel(bundleValue: "Release"), .stable)
        XCTAssertEqual(TargetBuildChannel(bundleValue: "Local"), .local)
        XCTAssertEqual(TargetBuildChannel(bundleValue: "unexpected"), .local)
    }

    func testOnlyDevelopmentPreviewAllowsDevelopmentChannel() {
        XCTAssertEqual(TargetBuildChannel.developmentPreview.allowedSparkleChannels, ["development"])
        XCTAssertTrue(TargetBuildChannel.stable.allowedSparkleChannels.isEmpty)
        XCTAssertTrue(TargetBuildChannel.local.allowedSparkleChannels.isEmpty)
    }

    func testAutomaticCheckPreferenceUsesUpdaterClientAsSingleSourceOfTruth() {
        let client = FakeUpdateClient(canCheck: true, automaticChecks: true)
        let controller = TargetUpdateController(
            presentation: .init(infoDictionary: [:]),
            updateClient: client
        )
        XCTAssertTrue(controller.automaticallyChecksForUpdates)

        controller.setAutomaticallyChecksForUpdates(false)

        XCTAssertFalse(client.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyChecksForUpdates)
        XCTAssertEqual(client.preferenceWriteCount, 1)
    }

    func testCheckForUpdatesUsesSameClientAndPresentsCheckingState() {
        let client = FakeUpdateClient(canCheck: true, automaticChecks: false)
        let controller = TargetUpdateController(
            presentation: .init(infoDictionary: [:]),
            updateClient: client
        )

        controller.checkForUpdates()

        XCTAssertEqual(client.checkCallCount, 1)
        XCTAssertEqual(controller.status, .checking)
    }

    func testDisabledUpdaterDoesNotStartCheck() {
        let client = FakeUpdateClient(canCheck: false, automaticChecks: true)
        let controller = TargetUpdateController(
            presentation: .init(infoDictionary: [:]),
            updateClient: client
        )

        controller.checkForUpdates()

        XCTAssertEqual(client.checkCallCount, 0)
        XCTAssertEqual(controller.status, .idle)
    }

    func testProductionInfoPlistHasFixedSignedHTTPSFeedAndPrivacyConfiguration() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repositoryRoot.appending(path: "Target/Info.plist")) as? [String: Any])
        XCTAssertEqual(plist["SUFeedURL"] as? String, "https://raw.githubusercontent.com/Jason312928/Target/main/Updates/appcast.xml")
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, "KFYe1MGjoJohjYcERu9Wqf5Jcc3lbxdKZfM+2aHx7JI=")
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUEnableSystemProfiling"] as? Bool, false)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, false)

        let feed = try XCTUnwrap(plist["SUFeedURL"] as? String)
        XCTAssertTrue(feed.hasPrefix("https://"))
        XCTAssertFalse(feed.contains("localhost"))
        XCTAssertFalse(feed.hasPrefix("file://"))
        XCTAssertFalse(feed.contains("?"))
    }

    func testSparkleDependencyIsExactlyPinnedAndLinkedOnlyToAppTarget() throws {
        let project = try String(contentsOf: repositoryRoot.appending(path: "Target.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertTrue(project.contains("repositoryURL = \"https://github.com/sparkle-project/Sparkle\";"))
        XCTAssertTrue(project.contains("kind = exactVersion;\n\t\t\t\tversion = 2.9.4;"))
        XCTAssertEqual(project.components(separatedBy: "Sparkle in Frameworks").count - 1, 2)
        XCTAssertFalse(project.contains("TargetService; packageProductDependencies = (U800"))
    }

    func testHistoricalAppcastIsSignedDevelopmentOnlyHTTPSBaseline() throws {
        let appcastURL = repositoryRoot.appending(path: "Updates/appcast.xml")
        let data = try Data(contentsOf: appcastURL)
        let document = try XMLDocument(data: data)
        let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        XCTAssertEqual(document.rootElement()?.namespaces?.first(where: { $0.name == "sparkle" })?.stringValue, sparkleNamespace)

        let items = try document.nodes(forXPath: "//item")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(
            try document.nodes(forXPath: "//*[name()='sparkle:channel']").compactMap(\.stringValue),
            ["development", "development", "development"]
        )
        XCTAssertEqual(
            try document.nodes(forXPath: "//*[name()='sparkle:version']").compactMap(\.stringValue),
            ["4", "3", "2"]
        )
        XCTAssertEqual(
            try document.nodes(forXPath: "//*[name()='sparkle:shortVersionString']").compactMap(\.stringValue),
            ["1.0.0", "1.0.0", "1.0.0"]
        )

        let enclosures = try document.nodes(forXPath: "//enclosure").compactMap { $0 as? XMLElement }
        XCTAssertEqual(enclosures.count, 3)
        let expectedAssets = [
            ("v1.0.0-dev.4/Target-1.0.0-dev.4-macos-arm64.zip", "3670482"),
            ("v1.0.0-dev.3/Target-1.0.0-dev.3-macos-arm64.zip", "3669747"),
            ("v1.0.0-dev.2/Target-1.0.0-dev.2-macos-arm64.zip", "2577177")
        ]
        for (enclosure, expected) in zip(enclosures, expectedAssets) {
            let url = try XCTUnwrap(enclosure.attribute(forName: "url")?.stringValue)
            XCTAssertEqual(url, "https://github.com/Jason312928/Target/releases/download/\(expected.0)")
            XCTAssertEqual(enclosure.attribute(forName: "length")?.stringValue, expected.1)
            XCTAssertFalse(
                try XCTUnwrap(
                    enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)?.stringValue
                ).isEmpty
            )
        }

        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<!-- sparkle-signatures:"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("private key"))
        XCTAssertFalse(text.contains("Target-Internal"))
        XCTAssertFalse(text.contains("localhost"))
        XCTAssertFalse(text.contains("file://"))
    }

    func testTerminationWaitsForSharedSafeStopAndVetoesOnFailure() async {
        let stopped = BackendStatus(
            serviceInstallation: .enabled,
            engineState: .stopped,
            engineInstallation: .installed,
            hasSelectedValidProfile: true
        )
        let success = TerminationRuntimeOperations(result: .success(.init(engineStatus: stopped, systemProxyStatus: .disabled)))
        let successModel = BackendLifecycleModel(backend: MockBackend(), runtimeOperations: success)
        successModel.applyAutomationEngineStatus(runningStatus)
        let successTermination = await successModel.prepareForApplicationTermination()
        let successStopCount = await success.callCount()
        XCTAssertTrue(successTermination)
        XCTAssertEqual(successStopCount, 1)

        let failure = TerminationRuntimeOperations(result: .failure(BackendError.serviceUnavailable))
        let failureModel = BackendLifecycleModel(backend: MockBackend(), runtimeOperations: failure)
        failureModel.applyAutomationEngineStatus(runningStatus)
        let failureTermination = await failureModel.prepareForApplicationTermination()
        let failureStopCount = await failure.callCount()
        XCTAssertFalse(failureTermination)
        XCTAssertEqual(failureStopCount, 1)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private var runningStatus: BackendStatus {
        .init(
            serviceInstallation: .enabled,
            engineState: .running,
            engineInstallation: .installed,
            hasSelectedValidProfile: true,
            enginePort: 12_345,
            runningProfileID: UUID(),
            runningProfileRevision: 1
        )
    }
}

@MainActor
private final class FakeUpdateClient: TargetUpdateClient {
    let canCheckForUpdates: Bool
    var automaticallyChecksForUpdates: Bool {
        didSet { preferenceWriteCount += 1 }
    }
    private(set) var checkCallCount = 0
    private(set) var preferenceWriteCount = 0

    init(canCheck: Bool, automaticChecks: Bool) {
        canCheckForUpdates = canCheck
        automaticallyChecksForUpdates = automaticChecks
    }

    func checkForUpdates() { checkCallCount += 1 }
}

private actor TerminationRuntimeOperations: TargetRuntimeOperating {
    let result: Result<EngineStopResult, Error>
    private(set) var stopCallCount = 0

    init(result: Result<EngineStopResult, Error>) {
        self.result = result
    }

    func startEngine() async throws -> EngineStartResult {
        throw BackendError.notImplemented
    }

    func stopEngineSafely() async throws -> EngineStopResult {
        stopCallCount += 1
        return try result.get()
    }

    func callCount() -> Int { stopCallCount }
}
