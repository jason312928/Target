import Foundation

enum PresentationScenario: String, CaseIterable {
    case saveFailureThenSuccess = "save-failure-then-success"
    case persistedReadDiscardFailure = "persisted-read-discard-failure"
    case successfulDiscard = "successful-discard"
    case importCandidateReturn = "import-candidate-return"
    case subscriptionCandidateReturn = "subscription-candidate-return"
    case emptyWorkspace = "empty-workspace"
    case localProfile = "local-profile"
    case remoteProfile = "remote-profile"
    case dirtyEditor = "dirty-editor"
    case invalidDiagnostic = "invalid-diagnostic"
    case subscriptionBusy = "subscription-busy"
    case policyCatalogPopulated = "policy-catalog-populated"
    case policyCatalogEmpty = "policy-catalog-empty"
    case policyCatalogUnavailable = "policy-catalog-unavailable"
    case policyCatalogWarnings = "policy-catalog-warnings"
    case policyCatalogSecrets = "policy-catalog-secrets"

    static func fromLaunchArguments() -> Self {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--presentation-scenario"),
              arguments.indices.contains(index + 1),
              let scenario = Self(rawValue: arguments[index + 1]) else {
            return .saveFailureThenSuccess
        }
        return scenario
    }
}

@MainActor
final class PresentationFixture {
    let scenario: PresentationScenario
    let root: URL
    let store: ProfileStore
    let model: ProfileViewModel
    let lifecycle = BackendLifecycleModel()
    let first: Profile
    let second: Profile
    private let importURL: URL
    private var hasStarted = false
    private var hasCleanedUp = false

    init(scenario: PresentationScenario) throws {
        self.scenario = scenario
        root = FileManager.default.temporaryDirectory
            .appending(path: "TargetPresentationFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let profileRoot = root.appending(path: "Profiles", directoryHint: .isDirectory)
        importURL = root.appending(path: "FixtureImport.json")
        let checker = PresentationFixtureChecker(results: [.success(())])
        let fetcher = PresentationFixtureFetcher(remainsBusy: scenario == .subscriptionBusy)
        store = ProfileStore(
            rootDirectory: profileRoot,
            checker: checker,
            runtimeUsage: PresentationFixtureRuntimeUsage(),
            keyProvider: PresentationFixtureKeyProvider()
        )
        if scenario == .emptyWorkspace {
            // Keep the model's initial list empty while retaining harmless
            // fixture records for the existing state probe contract.
            model = ProfileViewModel(store: store, subscriptionFetcher: fetcher)
            first = try store.create(name: "First Profile")
            second = try store.create(name: "Second Profile")
            return
        }

        let firstSubscription = scenario == .subscriptionCandidateReturn || scenario == .remoteProfile || scenario == .subscriptionBusy
            ? URL(string: "https://fixture.invalid/subscription.json")
            : nil
        first = try store.create(name: "First Profile", subscriptionURL: firstSubscription)
        second = try store.create(name: "Second Profile")
        try store.save(json: Self.persistedConfiguration, for: second.id)
        if [
            .localProfile, .remoteProfile, .subscriptionBusy,
            .policyCatalogPopulated, .policyCatalogEmpty, .policyCatalogUnavailable,
            .policyCatalogWarnings, .policyCatalogSecrets
        ].contains(scenario) {
            try store.save(json: Self.configuration(for: scenario), for: first.id)
        }
        checker.replaceResults(Self.checkerResults(for: scenario))
        try store.select(first.id)
        model = ProfileViewModel(
            store: store,
            subscriptionFetcher: fetcher,
            policyCatalogLoader: scenario == .policyCatalogUnavailable ? { throw PresentationFixtureError.persistedReadFailed } : nil
        )

        switch scenario {
        case .saveFailureThenSuccess, .successfulDiscard:
            model.updateEditor(Self.dirtyConfiguration)
        case .persistedReadDiscardFailure:
            model.updateEditor(Self.dirtyConfiguration)
            try FileManager.default.removeItem(at: store.safeManagedURL("\(first.id.uuidString)/config.json"))
        case .importCandidateReturn:
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(Self.importConfiguration.utf8).write(to: importURL, options: .atomic)
            model.updateEditor(Self.dirtyConfiguration)
        case .subscriptionCandidateReturn:
            model.updateEditor(Self.dirtyConfiguration)
        case .localProfile, .remoteProfile, .subscriptionBusy,
             .policyCatalogPopulated, .policyCatalogEmpty, .policyCatalogUnavailable,
             .policyCatalogWarnings, .policyCatalogSecrets:
            break
        case .dirtyEditor:
            model.updateEditor(Self.dirtyConfiguration)
        case .invalidDiagnostic:
            model.updateEditor("{\"inbounds\":[")
        case .emptyWorkspace:
            break
        }
    }

    func startScenario() {
        guard !hasStarted else { return }
        hasStarted = true
        switch scenario {
        case .importCandidateReturn:
            model.prepareImport(from: importURL)
        case .subscriptionCandidateReturn:
            model.updateSubscription()
        case .subscriptionBusy:
            model.updateSubscription()
        default:
            break
        }
    }

    func cleanUp() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        try? FileManager.default.removeItem(at: root)
    }

    private static let persistedConfiguration = """
    {
      "inbounds": [],
      "outbounds": [],
      "route": {}
    }
    """ + "\n"
    private static let dirtyConfiguration = """
    {
      "inbounds": [],
      "outbounds": [],
      "route": {},
      "fixtureDirty": true
    }
    """ + "\n"
    private static let importConfiguration = """
    {
      "inbounds": [],
      "outbounds": [],
      "route": {},
      "fixtureImport": true
    }
    """ + "\n"

    private static func configuration(for scenario: PresentationScenario) -> String {
        switch scenario {
        case .policyCatalogPopulated:
            #"{"inbounds":[],"outbounds":[{"type":"selector","tag":"group","outbounds":["first","second"],"default":"second"},{"type":"vmess","tag":"first"},{"type":"direct","tag":"second"}],"route":{}}"#
        case .policyCatalogEmpty:
            #"{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{}}"#
        case .policyCatalogWarnings:
            #"{"inbounds":[],"outbounds":[{"type":"selector","tag":"warnings","outbounds":["missing","duplicate","duplicate","unavailable"]},{"type":"direct","tag":"duplicate"},{"type":"block","tag":"duplicate"},{"tag":"unavailable"},{"type":"selector","tag":"","outbounds":[]},{"type":"selector","tag":"also-invalid","outbounds":"bad"}],"route":{}}"#
        case .policyCatalogSecrets:
            #"{"inbounds":[],"outbounds":[{"type":"selector","tag":"safe-group","outbounds":["safe-member"],"default":"safe-member"},{"type":"vmess","tag":"safe-member","server":"POLICY-PRESENTATION-SECRET","address":"POLICY-PRESENTATION-SECRET","username":"POLICY-PRESENTATION-SECRET","password":"POLICY-PRESENTATION-SECRET","uuid":"POLICY-PRESENTATION-SECRET","token":"POLICY-PRESENTATION-SECRET","private_key":"POLICY-PRESENTATION-SECRET","certificate":"POLICY-PRESENTATION-SECRET","tls":{"server_name":"POLICY-PRESENTATION-SECRET"},"transport":{"path":"POLICY-PRESENTATION-SECRET"},"arbitrary":{"nested":"POLICY-PRESENTATION-SECRET"}}],"route":{}}"#
        default:
            persistedConfiguration
        }
    }

    private static func checkerResults(for scenario: PresentationScenario) -> [Result<Void, ConfigurationDiagnostic>] {
        let failed: Result<Void, ConfigurationDiagnostic> = .failure(
            ConfigurationDiagnostic(messageKey: "profile.validation.check-failed", line: nil, column: nil)
        )
        switch scenario {
        case .saveFailureThenSuccess: return [failed, .success(())]
        case .importCandidateReturn, .subscriptionCandidateReturn: return [.success(()), failed]
        case .persistedReadDiscardFailure, .successfulDiscard, .emptyWorkspace,
             .localProfile, .remoteProfile, .dirtyEditor, .invalidDiagnostic,
             .subscriptionBusy, .policyCatalogPopulated, .policyCatalogEmpty,
             .policyCatalogUnavailable, .policyCatalogWarnings, .policyCatalogSecrets:
            return [.success(())]
        }
    }
}

private enum PresentationFixtureError: Error { case persistedReadFailed }

private final class PresentationFixtureChecker: SingBoxConfigurationChecking, @unchecked Sendable {
    private var results: [Result<Void, ConfigurationDiagnostic>]

    init(results: [Result<Void, ConfigurationDiagnostic>]) { self.results = results }

    func replaceResults(_ results: [Result<Void, ConfigurationDiagnostic>]) {
        self.results = results
    }

    func check(configurationURL: URL) -> Result<Void, ConfigurationDiagnostic> {
        results.isEmpty ? .success(()) : results.removeFirst()
    }
}

private struct PresentationFixtureFetcher: ProfileSubscriptionFetching {
    let remainsBusy: Bool

    func fetch(subscription: RemoteSubscription) async throws -> SubscriptionResponse {
        if remainsBusy {
            try await Task.sleep(for: .seconds(30))
            throw SubscriptionUpdateError.cancelled
        }
        return SubscriptionResponse(
            data: Data(("""
            {
              "inbounds": [],
              "outbounds": [],
              "route": {},
              "fixtureSubscription": true
            }
            """ + "\n").utf8),
            cacheStatus: .updated,
            etag: "fixture-v2",
            lastModified: nil
        )
    }
}

private struct PresentationFixtureRuntimeUsage: ProfileRuntimeUsageChecking {
    func isProfileInUse(_ id: UUID) -> Bool { false }
}

private final class PresentationFixtureKeyProvider: ProfileEncryptionKeyProviding {
    private let key = Data(repeating: 42, count: 32)

    func loadMasterKey() throws -> Data? { key }
    func createMasterKey() throws -> Data { key }
}
