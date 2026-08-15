import Foundation
import Observation
import Sparkle

enum TargetBuildChannel: Equatable {
    case local
    case developmentPreview
    case stable

    init(bundleValue: String?) {
        switch bundleValue?.lowercased() {
        case "developmentpreview", "development-preview": self = .developmentPreview
        case "stable", "release": self = .stable
        default: self = .local
        }
    }

    var localizedKey: String {
        switch self {
        case .local: "settings.software-update.channel.local"
        case .developmentPreview: "settings.software-update.channel.development-preview"
        case .stable: "settings.software-update.channel.stable"
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .developmentPreview: ["development"]
        case .local, .stable: []
        }
    }
}

struct TargetUpdatePresentation: Equatable {
    let version: String
    let build: String
    let channel: TargetBuildChannel

    init(infoDictionary: [String: Any]) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "-"
        build = infoDictionary["CFBundleVersion"] as? String ?? "-"
        channel = TargetBuildChannel(bundleValue: infoDictionary["TargetBuildChannel"] as? String)
    }
}

enum TargetUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case failed

    var localizedKey: String? {
        switch self {
        case .idle: nil
        case .checking: "settings.software-update.status.checking"
        case .upToDate: "settings.software-update.status.up-to-date"
        case .updateAvailable: "settings.software-update.status.available"
        case .failed: "settings.software-update.status.failed"
        }
    }
}

@MainActor
protocol TargetUpdateClient: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
}

@MainActor
private final class SparkleUpdateClient: TargetUpdateClient {
    private let controller: SPUStandardUpdaterController

    init(controller: SPUStandardUpdaterController) {
        self.controller = controller
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
@Observable
final class TargetUpdateController: NSObject, SPUUpdaterDelegate {
    let presentation: TargetUpdatePresentation
    private(set) var status: TargetUpdateStatus = .idle
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true

    @ObservationIgnored private var updateClient: any TargetUpdateClient
    @ObservationIgnored private var standardUpdaterController: SPUStandardUpdaterController?

    override convenience init() {
        self.init(bundle: .main)
    }

    init(bundle: Bundle) {
        presentation = TargetUpdatePresentation(infoDictionary: bundle.infoDictionary ?? [:])
        let placeholder = DeferredTargetUpdateClient()
        updateClient = placeholder
        super.init()

        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let controller = SPUStandardUpdaterController(
            startingUpdater: !isRunningTests,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        standardUpdaterController = controller
        let client = SparkleUpdateClient(controller: controller)
        updateClient = client
        placeholder.client = client
        refreshPreferences()
    }

    init(presentation: TargetUpdatePresentation, updateClient: any TargetUpdateClient) {
        self.presentation = presentation
        self.updateClient = updateClient
        super.init()
        refreshPreferences()
    }

    func refreshPreferences() {
        canCheckForUpdates = updateClient.canCheckForUpdates
        automaticallyChecksForUpdates = updateClient.automaticallyChecksForUpdates
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updateClient.automaticallyChecksForUpdates = enabled
        refreshPreferences()
    }

    func checkForUpdates() {
        refreshPreferences()
        guard canCheckForUpdates else { return }
        status = .checking
        updateClient.checkForUpdates()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        presentation.channel.allowedSparkleChannels
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = .updateAvailable
        refreshPreferences()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        status = .upToDate
        refreshPreferences()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = .failed
        refreshPreferences()
    }
}

@MainActor
private final class DeferredTargetUpdateClient: TargetUpdateClient {
    weak var client: (any TargetUpdateClient)?

    var canCheckForUpdates: Bool { client?.canCheckForUpdates ?? false }
    var automaticallyChecksForUpdates: Bool {
        get { client?.automaticallyChecksForUpdates ?? true }
        set { client?.automaticallyChecksForUpdates = newValue }
    }
    func checkForUpdates() { client?.checkForUpdates() }
}
