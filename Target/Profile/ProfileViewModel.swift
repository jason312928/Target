import Foundation
import Observation

@MainActor
@Observable
final class ProfileViewModel {
    private let store: ProfileStore
    private let policyOperations: any TargetPolicyOperating
    private let smartOperations: (any SmartApplicationOperating)?
    private let policyCatalogLoader: () throws -> PolicyCatalog
    private let usesCustomPolicyCatalogLoader: Bool
    private let configurationLoader: (UUID) throws -> String
    private let usesCustomConfigurationLoader: Bool
    private let subscriptionOperations: TargetSubscriptionOperations
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionGeneration = 0
    private var importGeneration = 0
    private var persistenceTask: Task<Void, Never>?
    private var editorDiagnosticTask: Task<Void, Never>?
    private var editorGeneration = 0
    private var metadataGeneration = 0
    private var cachedCatalogs: [UUID: PolicyCatalog] = [:]
    private var hasLoadedInitialState = false
    private(set) var isPerformingPersistence = false
    private var importTask: Task<Void, Never>?
    private var policyTask: Task<Void, Never>?
    private var queuedPolicySelection: (selectorTag: String, outboundTag: String)?
    private var policyProbeTask: Task<Void, Never>?
    private var policyRefreshGeneration = 0
    private var policyHealthGeneration = 0
    private var smartApplicationGeneration = 0
    private var smartApplicationTask: Task<Void, Never>?

    private(set) var profiles: [Profile] = []
    private(set) var selectedID: UUID?
    var editorText = ""
    private(set) var diagnostic: ConfigurationDiagnostic?
    private(set) var isDirty = false
    private(set) var isConfigurationLoaded = false
    private(set) var messageKey: String?
    private(set) var subscriptionFailureDiagnostic: SubscriptionFailureDiagnostic?
    private(set) var pendingSubscriptionIntake: PendingSubscriptionIntake?
    private(set) var isUpdatingSubscription = false
    private(set) var pendingImportCandidate: ProfileImportCandidate?
    private(set) var isPreparingImport = false
    private(set) var isCommittingImport = false
    private(set) var isShowingExportWarning = false
    private(set) var isExporting = false
    private(set) var pendingOperation: ProfileWorkspaceOperation?
    /// Presentation ownership is separate from the typed pending intent, but
    /// its active state is kept consistent with that intent by decision result.
    private(set) var unsavedChangesPresentation = ProfileUnsavedChangesPresentation()
    /// Changes that affect selected configuration readiness. The view observes
    /// this rather than refreshing lifecycle state for cancelled actions or
    /// subscription-cache metadata updates.
    private(set) var readinessChangeGeneration = 0
    private(set) var policyCatalog: PolicyCatalog?
    private(set) var isPolicyCatalogUnavailable = false
    private(set) var isSelectingPolicy = false
    private(set) var testingPolicySelectorID: Int?
    private(set) var policyHealthBySelector: [Int: [String: RuntimeProxyHealth]] = [:]
    private(set) var isApplyingSmart = false
    private(set) var smartApplicationResult: SmartApplicationResult?

    init(
        store: ProfileStore = ProfileStore(),
        subscriptionFetcher: any ProfileSubscriptionFetching = SecureSubscriptionFetcher(),
        configurationLoader: ((UUID) throws -> String)? = nil,
        policyOperations: (any TargetPolicyOperating)? = nil,
        smartOperations: (any SmartApplicationOperating)? = nil,
        policyCatalogLoader: (() throws -> PolicyCatalog)? = nil,
        loadImmediately: Bool = true
    ) {
        self.store = store
        let resolvedPolicyOperations = policyOperations ?? TargetPolicyOperations(profileStore: store)
        self.policyOperations = resolvedPolicyOperations
        self.smartOperations = smartOperations
        self.policyCatalogLoader = policyCatalogLoader ?? resolvedPolicyOperations.readPersisted
        self.usesCustomPolicyCatalogLoader = policyCatalogLoader != nil
        self.subscriptionOperations = TargetSubscriptionOperations(store: store, fetcher: subscriptionFetcher)
        self.usesCustomConfigurationLoader = configurationLoader != nil
        self.configurationLoader = configurationLoader ?? { try store.configurationText(for: $0) }
        if loadImmediately {
            reloadInitialState()
            hasLoadedInitialState = true
        }
    }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedID } }
    var smartActionsAvailable: Bool { smartOperations != nil && selectedProfile != nil }
    var canEditConfiguration: Bool { selectedProfile != nil && isConfigurationLoaded && !isPerformingPersistence }
    var canExport: Bool { canEditConfiguration && !isDirty && !isExporting && !isPerformingPersistence }
    var defaultExportFileName: String {
        selectedProfile.map { ProfileTransferService.defaultExportFileName(for: $0.name) } ?? "Profile.json"
    }
    var shouldPresentImportConfirmation: Bool { pendingImportCandidate != nil && pendingOperation == nil }
    var pendingSubscriptionUpdate: PendingSubscriptionIntake? { pendingSubscriptionIntake }
    var shouldPresentSubscriptionPreview: Bool { pendingSubscriptionIntake != nil && pendingOperation == nil }

    func requestSelection(_ id: UUID?) {
        guard id != selectedID else { return }
        guard let id else { return }
        request(.select(id))
    }

    func participatingCountryRoutes(profileIDs: Set<UUID>) -> [PolicyCountryRoute] {
        let eligible =
            profiles
            .filter { profileIDs.contains($0.id) && $0.validation.status != .invalid }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.id.uuidString < $1.id.uuidString
            }
        var grouped: [PolicyRouteCountry: [PolicyMemberPresentation]] = [:]
        var seenMembers = Set<String>()

        for profile in eligible {
            guard let catalog = cachedCatalogs[profile.id] else { continue }
            for selector in catalog.selectors where selector.isMutable {
                let health = profile.id == selectedID ? policyHealthBySelector[selector.id] ?? [:] : [:]
                for route in PolicySelectorPresentation(selector, health: health).countryRoutes {
                    let uniqueMembers = route.members.filter { member in
                        seenMembers.insert("\(profile.id.uuidString)|\(member.tag)|\(member.endpoint ?? "")").inserted
                    }
                    grouped[route.country, default: []].append(contentsOf: uniqueMembers)
                }
            }
        }

        return grouped.map { PolicyCountryRoute(country: $0.key, members: $0.value) }
            .sorted { $0.country.englishName < $1.country.englishName }
    }

    func requestCountrySelection(_ countryCode: String, participatingProfileIDs: Set<UUID>) {
        let eligible =
            profiles
            .filter { participatingProfileIDs.contains($0.id) && $0.validation.status != .invalid }
            .sorted {
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.id.uuidString < $1.id.uuidString
            }
        var candidates: [(profile: Profile, selector: PolicyCatalogSelector, member: PolicyCatalogMember, latency: Int?)] = []

        for profile in eligible {
            guard let catalog = cachedCatalogs[profile.id] else { continue }
            for selector in catalog.selectors where selector.isMutable {
                let health = profile.id == selectedID ? policyHealthBySelector[selector.id] ?? [:] : [:]
                for member in selector.members where member.status == .available {
                    guard PolicyRouteCountry.recognize(in: member.tag, endpoint: member.endpoint)?.code == countryCode,
                        selector.tag != nil
                    else { continue }
                    candidates.append((profile, selector, member, health[member.tag]?.latencyMilliseconds))
                }
            }
        }

        let chosen = candidates.min { lhs, rhs in
            switch (lhs.latency, rhs.latency) {
            case (let left?, let right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let leftCurrent = lhs.profile.id == selectedID
                let rightCurrent = rhs.profile.id == selectedID
                if leftCurrent != rightCurrent { return leftCurrent }
                if lhs.profile.name != rhs.profile.name { return lhs.profile.name < rhs.profile.name }
                return lhs.member.tag < rhs.member.tag
            }
        }
        guard let chosen, let selectorTag = chosen.selector.tag else { return }
        request(
            .selectPolicy(
                profileID: chosen.profile.id,
                selectorTag: selectorTag,
                outboundTag: chosen.member.tag
            ))
    }

    func requestCreate(name: String, subscriptionURL: URL? = nil) {
        if let subscriptionURL { prepareSubscription(name: name, url: subscriptionURL) } else { request(.create(name: name)) }
    }

    func prepareSubscription(name: String, url: URL) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            messageKey = "profile.message.invalid-name"
            return
        }
        cancelSubscriptionOperation(clearCandidate: true)
        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        messageKey = nil
        subscriptionFailureDiagnostic = nil
        isUpdatingSubscription = true
        let operations = subscriptionOperations
        subscriptionTask = Task { [weak self] in
            defer {
                if let self, self.subscriptionGeneration == generation {
                    self.subscriptionTask = nil
                    self.isUpdatingSubscription = false
                }
            }
            do {
                let pending = try await operations.prepareNew(name: normalizedName, url: url)
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation else { return }
                self.pendingSubscriptionIntake = pending
            } catch {
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation else { return }
                self.presentSubscriptionError(error)
            }
        }
    }

    func requestDuplicate(_ id: UUID) {
        request(.duplicate(id))
    }

    func requestDelete(_ id: UUID) {
        request(.delete(id))
    }

    func requestRestore(_ id: UUID) {
        request(.restore(id))
    }

    @discardableResult
    func resolveUnsavedChanges(_ decision: ProfileUnsavedChangesDecision) async -> ProfileUnsavedChangesDecisionResult {
        guard !isPerformingPersistence else { return .failedAndStillPending }
        guard let operation = pendingOperation else { return .noPendingOperation }
        switch decision {
        case .cancel:
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.cancelled)
            return .cancelled
        case .discardChanges:
            guard await discardCurrentEditorToPersistedState() else {
                unsavedChangesPresentation.resolve(.failedAndStillPending)
                return .failedAndStillPending
            }
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.resolved)
            await execute(operation)
            return .resolved
        case .saveAndContinue:
            guard await saveCurrentEditor() else {
                unsavedChangesPresentation.resolve(.failedAndStillPending)
                return .failedAndStillPending
            }
            pendingOperation = nil
            unsavedChangesPresentation.resolve(.resolved)
            await execute(operation)
            return .resolved
        }
    }

    func cancelUnsavedChangesConfirmation() {
        Task { _ = await resolveUnsavedChanges(.cancel) }
    }

    func unsavedChangesAlertPresentationDidChange(_ isPresented: Bool) {
        unsavedChangesPresentation.alertPresentationDidChange(isPresented)
    }

    private func reloadInitialState() {
        do {
            profiles = try store.listProfiles()
            cachedCatalogs = try Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, try store.policyCatalog(for: $0.id)) })
            selectedID = try store.selectedProfileID() ?? profiles.first?.id
            loadSelectedText()
            refreshPolicyCatalog()
        } catch {
            profiles = []
            selectedID = nil
            editorText = ""
            isConfigurationLoaded = false
            messageKey = "profile.message.load-failed"
            policyCatalog = nil
            isPolicyCatalogUnavailable = true
        }
    }

    func prepareImport(from url: URL) {
        cancelPreparedImport()
        isPreparingImport = true
        messageKey = nil
        let generation = importGeneration
        let store = store
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.importGeneration == generation {
                    self.importTask = nil
                    self.isPreparingImport = false
                }
            }
            do {
                let candidate = try await ProfileBackgroundWork.run { try store.prepareImportCandidate(from: url) }
                guard !Task.isCancelled, self.importGeneration == generation else { return }
                self.pendingImportCandidate = candidate
            } catch let error as ProfileTransferError {
                guard !Task.isCancelled, self.importGeneration == generation else { return }
                self.messageKey = self.transferMessageKey(for: error)
            } catch {
                guard !Task.isCancelled, self.importGeneration == generation else { return }
                self.messageKey = "profile.import.error.unreadable"
            }
        }
    }

    func commitPreparedImport(name: String) {
        guard let candidate = pendingImportCandidate, !isCommittingImport else { return }
        request(.importCandidate(candidate, name: name))
    }

    func cancelPreparedImport() {
        importGeneration &+= 1
        importTask?.cancel()
        importTask = nil
        isPreparingImport = false
        pendingImportCandidate = nil
    }

    func importPickerCancelled() {
        cancelPreparedImport()
        messageKey = "profile.import.cancelled"
    }

    func requestExport() {
        guard canExport else {
            if isDirty { messageKey = "profile.export.unsaved-changes" }
            return
        }
        isShowingExportWarning = true
    }

    func dismissExportWarning() {
        isShowingExportWarning = false
    }

    func exportSelectedProfile(to destination: URL) {
        guard canExport else { return }
        isShowingExportWarning = false
        isExporting = true
        let store = store
        Task { [weak self] in
            defer { self?.isExporting = false }
            do {
                try await ProfileBackgroundWork.run { try store.exportSelectedProfile(to: destination) }
                self?.messageKey = "profile.export.success"
            } catch let error as ProfileTransferError {
                self?.messageKey = self?.transferMessageKey(for: error)
            } catch { self?.messageKey = "profile.export.error.failed" }
        }
    }

    func exportCancelled() {
        isShowingExportWarning = false
        messageKey = "profile.export.cancelled"
    }

    func rename(_ id: UUID, to name: String) {
        let store = store
        startMetadataMutation { try store.rename(id, to: name) }
    }

    private func startMetadataMutation(_ mutation: @escaping @Sendable () throws -> Void) {
        guard !isPerformingPersistence, persistenceTask == nil else { return }
        isPerformingPersistence = true
        let store = store
        persistenceTask = Task { [weak self] in
            defer {
                self?.isPerformingPersistence = false
                self?.persistenceTask = nil
            }
            do {
                let snapshot = try await ProfileBackgroundWork.run {
                    try mutation()
                    return try store.snapshot()
                }
                self?.profiles = snapshot.profiles
                self?.cachedCatalogs = snapshot.catalogs
                self?.refreshPolicyCatalogFromSnapshot(snapshot)
                self?.markReadinessChanged()
            } catch { self?.messageKey = "profile.message.operation-failed" }
        }
    }

    func selectPolicy(selectorTag: String, outboundTag: String) {
        if isSelectingPolicy {
            queuedPolicySelection = (selectorTag, outboundTag)
            return
        }
        isSelectingPolicy = true
        messageKey = nil
        policyTask = Task { [weak self] in
            guard let self else { return }
            var selection = (selectorTag: selectorTag, outboundTag: outboundTag)
            while true {
                self.messageKey = nil
                do {
                    self.policyCatalog = try await self.policyOperations.select(
                        selectorTag: selection.selectorTag,
                        outboundTag: selection.outboundTag
                    )
                    self.isPolicyCatalogUnavailable = false
                    self.refreshMetadataPreservingEditor()
                    self.markReadinessChanged()
                } catch let error as TargetPolicyOperationError {
                    self.messageKey = self.policyMessageKey(for: error)
                    self.refreshPolicyCatalog()
                } catch {
                    self.messageKey = "policy.catalog.selection.failed"
                    self.refreshPolicyCatalog()
                }

                guard let queued = self.queuedPolicySelection else { break }
                self.queuedPolicySelection = nil
                selection = queued
            }
            self.policyTask = nil
            self.isSelectingPolicy = false
        }
    }

    func resetPolicy() {
        guard !isSelectingPolicy else { return }
        isSelectingPolicy = true
        messageKey = nil
        policyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.policyTask = nil
                self.isSelectingPolicy = false
                if let queued = self.queuedPolicySelection {
                    self.queuedPolicySelection = nil
                    self.selectPolicy(
                        selectorTag: queued.selectorTag,
                        outboundTag: queued.outboundTag
                    )
                }
            }
            do {
                self.policyCatalog = try await self.policyOperations.reset().catalog
                self.isPolicyCatalogUnavailable = false
                self.refreshMetadataPreservingEditor()
                self.markReadinessChanged()
            } catch let error as TargetPolicyOperationError {
                self.messageKey = self.policyMessageKey(for: error)
                self.refreshPolicyCatalog()
            } catch {
                self.messageKey = "policy.catalog.reset.failed"
                self.refreshPolicyCatalog()
            }
        }
    }

    /// Runs one explicit Smart action through the shared application stack.
    /// Completion is accepted only while the same Profile generation remains
    /// selected; runtime changes call `invalidateSmartApplication()` as well.
    func applySmart(_ action: SmartApplicationAction) {
        guard let operations = smartOperations,
              let profile = selectedProfile,
              !isApplyingSmart,
              !isDirty,
              !isPerformingPersistence
        else { return }
        smartApplicationGeneration &+= 1
        let generation = smartApplicationGeneration
        let expectedID = profile.id
        let expectedRevision = profile.validRevision
        isApplyingSmart = true
        smartApplicationResult = nil
        smartApplicationTask = Task { [weak self] in
            let result: SmartApplicationResult
            switch action {
            case .switchAction:
                result = SmartApplicationResult(action: action, result: await operations.applySwitch())
            case .continuityApply:
                result = SmartApplicationResult(action: action, result: await operations.applyContinuity())
            }
            guard let self,
                  !Task.isCancelled,
                  self.smartApplicationGeneration == generation,
                  self.selectedID == expectedID,
                  self.selectedProfile?.validRevision == expectedRevision
            else { return }
            self.smartApplicationResult = result
            self.isApplyingSmart = false
            self.smartApplicationTask = nil
            self.refreshPolicyState()
            self.markReadinessChanged()
        }
    }

    func invalidateSmartApplication() {
        smartApplicationGeneration &+= 1
        smartApplicationTask?.cancel()
        smartApplicationTask = nil
        isApplyingSmart = false
        smartApplicationResult = nil
    }

    func refreshPolicyState() {
        invalidatePolicyHealth()
        refreshPolicyCatalog()
    }

    @discardableResult
    func bindRoute(
        url: URL,
        countryCode: String,
        outboundTag: String,
        participatingProfileIDs: Set<UUID>
    ) async -> Bool {
        guard !isPerformingPersistence, !isDirty,
            let domain = ProfileRouteBinding.domain(from: url),
            let binding = ProfileRouteBinding(domain: domain, outboundTag: outboundTag, countryCode: countryCode)
        else {
            messageKey = isDirty ? "profile.route.error.unsaved" : "profile.route.error.invalid-link"
            return false
        }
        let owner = profiles.filter { participatingProfileIDs.contains($0.id) && $0.validation.status != .invalid }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .first { profile in
                cachedCatalogs[profile.id]?.selectors.flatMap(\.members).contains {
                    $0.tag == outboundTag && $0.status == .available
                        && PolicyRouteCountry.recognize(in: $0.tag, endpoint: $0.endpoint)?.code == countryCode
                } == true
            }
        guard let owner else {
            messageKey = "profile.route.error.save-failed"
            return false
        }
        isPerformingPersistence = true
        defer { isPerformingPersistence = false }
        let store = store
        let previousID = selectedID
        do {
            let snapshot = try await ProfileBackgroundWork.run {
                try store.bindRouteSelectingProfile(binding, profileID: owner.id, expectedRevision: owner.validRevision)
                return try store.snapshot()
            }
            if previousID != snapshot.selectedID {
                applySnapshot(snapshot)
            } else {
                profiles = snapshot.profiles
                cachedCatalogs = snapshot.catalogs
            }
            messageKey = "profile.route.saved"
            markReadinessChanged()
            return true
        } catch {
            messageKey = "profile.route.error.save-failed"
            return false
        }
    }

    func removeRouteBinding(domain: String) {
        guard let profile = selectedProfile else { return }
        let store = store
        startMetadataMutation {
            _ = try store.removeRouteBinding(profileID: profile.id, expectedRevision: profile.validRevision, domain: domain)
        }
    }

    func probePolicyLatency(selectorID: Int, selectorTag: String) {
        guard policyProbeTask == nil,
            let catalog = policyCatalog,
            let profileID = catalog.profileID,
            let profileRevision = catalog.profileRevision,
            let sourceFingerprint = catalog.sourceFingerprint,
            let selector = catalog.selectors.first(where: { $0.id == selectorID && $0.tag == selectorTag })
        else {
            return
        }
        let availableMembers = selector.members.filter { $0.status == .available }
        guard !availableMembers.isEmpty else { return }

        policyHealthGeneration &+= 1
        let generation = policyHealthGeneration
        let selectedProfileID = selectedID
        testingPolicySelectorID = selectorID
        policyHealthBySelector[selectorID] = Dictionary(
            uniqueKeysWithValues: availableMembers.map { ($0.tag, .testing(tag: $0.tag)) }
        )

        policyProbeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == self.policyHealthGeneration {
                    self.policyProbeTask = nil
                    self.testingPolicySelectorID = nil
                }
            }
            do {
                let result = try await self.policyOperations.probeLatency(selectorTag: selectorTag)
                guard !Task.isCancelled,
                    generation == self.policyHealthGeneration,
                    self.selectedID == selectedProfileID,
                    result.profileID == profileID,
                    result.profileRevision == profileRevision,
                    result.sourceFingerprint == sourceFingerprint,
                    result.selector == selectorTag,
                    self.policyCatalog?.profileID == profileID,
                    self.policyCatalog?.profileRevision == profileRevision,
                    self.policyCatalog?.sourceFingerprint == sourceFingerprint
                else { return }
                self.policyHealthBySelector[selectorID] = Dictionary(
                    uniqueKeysWithValues: result.members.map { ($0.tag, $0) }
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.policyHealthGeneration else { return }
                self.policyHealthBySelector[selectorID] = Dictionary(
                    uniqueKeysWithValues: availableMembers.map { ($0.tag, .runtimeUnavailable(tag: $0.tag)) }
                )
            }
        }
    }

    func invalidatePolicyHealth() {
        policyHealthGeneration &+= 1
        policyProbeTask?.cancel()
        policyProbeTask = nil
        testingPolicySelectorID = nil
        policyHealthBySelector = [:]
    }

    func updateEditor(_ text: String) {
        guard canEditConfiguration else { return }
        subscriptionFailureDiagnostic = nil
        editorText = text
        isDirty = true
        editorGeneration &+= 1
        let generation = editorGeneration
        editorDiagnosticTask?.cancel()
        editorDiagnosticTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                let diagnostic = try await ProfileBackgroundWork.run { JSONSyntaxChecker.validate(text) }
                guard !Task.isCancelled, self?.editorGeneration == generation else { return }
                self?.diagnostic = diagnostic
            } catch {}
        }
        messageKey = nil
    }

    func format() {
        guard canEditConfiguration else { return }
        let source = editorText
        let generation = editorGeneration
        Task { [weak self] in
            do {
                let result = try await ProfileBackgroundWork.run { () -> (String?, ConfigurationDiagnostic?) in
                    if let diagnostic = JSONSyntaxChecker.validate(source) { return (nil, diagnostic) }
                    let object = try JSONSerialization.jsonObject(with: Data(source.utf8))
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    return (String(data: data, encoding: .utf8).map { $0 + "\n" }, nil)
                }
                guard let self, self.editorGeneration == generation, self.canEditConfiguration else { return }
                if let text = result.0 { self.updateEditor(text) } else { self.diagnostic = result.1 }
            } catch { self?.messageKey = "profile.message.operation-failed" }
        }
    }

    func save() {
        guard !isPerformingPersistence, persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            defer { self.persistenceTask = nil }
            if self.pendingOperation != nil {
                _ = await self.resolveUnsavedChanges(.saveAndContinue)
            } else {
                _ = await self.saveCurrentEditor()
            }
        }
    }

    @discardableResult
    private func saveCurrentEditor() async -> Bool {
        guard !isPerformingPersistence, let selectedID, isConfigurationLoaded else { return false }
        isPerformingPersistence = true
        defer { isPerformingPersistence = false }
        let text = editorText
        let generation = editorGeneration
        let store = store
        do {
            let snapshot = try await ProfileBackgroundWork.run {
                try store.withSerializedAccess {
                    try store.save(json: text, for: selectedID)
                    return try store.snapshot()
                }
            }
            guard self.selectedID == selectedID else { return false }
            profiles = snapshot.profiles
            cachedCatalogs = snapshot.catalogs
            if editorText == text, editorGeneration == generation {
                diagnostic = nil
                isDirty = false
            }
            messageKey = "profile.message.saved"
            invalidatePolicyHealth()
            refreshPolicyCatalogFromSnapshot(snapshot)
            markReadinessChanged()
            return !isDirty
        } catch let error as ProfileStoreError { present(error) } catch { messageKey = "profile.message.operation-failed" }
        return false
    }

    func loadInitialState() async {
        guard !hasLoadedInitialState else { return }
        hasLoadedInitialState = true
        let store = store
        do { applySnapshot(try await ProfileBackgroundWork.run { try store.snapshot() }) } catch {
            messageKey = "profile.message.load-failed"
            isPolicyCatalogUnavailable = true
        }
    }

    private func refreshPolicyCatalogFromSnapshot(_ snapshot: ProfileStoreSnapshot) {
        if usesCustomPolicyCatalogLoader {
            refreshPolicyCatalog()
            return
        }
        policyCatalog = snapshot.selectedID.flatMap { snapshot.catalogs[$0] }
        isPolicyCatalogUnavailable = snapshot.selectedID != nil && policyCatalog == nil
        refreshPolicyState()
    }

    private func applySnapshot(_ snapshot: ProfileStoreSnapshot) {
        invalidateSmartApplication()
        metadataGeneration &+= 1
        invalidatePolicyHealth()
        profiles = snapshot.profiles
        cachedCatalogs = snapshot.catalogs
        selectedID = snapshot.selectedID
        editorText = snapshot.configuration ?? ""
        isConfigurationLoaded = snapshot.configuration != nil
        if usesCustomConfigurationLoader, let selectedID {
            do { editorText = try configurationLoader(selectedID) } catch {
                editorText = ""
                isConfigurationLoaded = false
                messageKey = "profile.message.configuration-read-failed"
            }
        }
        isDirty = false
        diagnostic = nil
        editorGeneration &+= 1
        editorDiagnosticTask?.cancel()
        refreshPolicyCatalogFromSnapshot(snapshot)
    }

    func updateSubscription() {
        guard let profile = selectedProfile, let subscription = profile.subscription, subscriptionTask == nil else { return }
        _ = subscription
        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        messageKey = nil
        subscriptionFailureDiagnostic = nil
        pendingSubscriptionIntake = nil
        isUpdatingSubscription = true
        let profileID = profile.id
        let store = store
        let operations = subscriptionOperations
        subscriptionTask = Task { [weak self] in
            defer {
                if let self, self.subscriptionGeneration == generation {
                    self.subscriptionTask = nil
                    self.isUpdatingSubscription = false
                }
            }
            do {
                let prepared = try await operations.prepareUpdate(profileID: profileID)
                guard let self, !Task.isCancelled, self.subscriptionGeneration == generation,
                    self.selectedID == profileID
                else { return }
                if prepared.candidate == nil {
                    do {
                        _ = try await ProfileBackgroundWork.run { try operations.commitNotModified(prepared) }
                    } catch {
                        throw SubscriptionPersistenceFailure()
                    }
                }
                self.pendingSubscriptionIntake = prepared.candidate
                self.refreshMetadataPreservingEditor()
                if prepared.candidate == nil { self.messageKey = "profile.subscription.not-modified" }
            } catch {
                guard let self, self.subscriptionGeneration == generation else { return }
                if Task.isCancelled || (error as? SubscriptionUpdateError) == .cancelled {
                    _ = try? await ProfileBackgroundWork.run { try store.recordSubscriptionCancellation(for: profileID) }
                    self.messageKey = SubscriptionUpdateError.cancelled.messageKey
                    self.subscriptionFailureDiagnostic = nil
                } else {
                    let key = self.subscriptionMessageKey(for: error)
                    _ = try? await ProfileBackgroundWork.run { try store.recordSubscriptionFailure(for: profileID, messageKey: key) }
                    self.presentSubscriptionError(error)
                }
                self.refreshMetadataPreservingEditor()
            }
        }
    }

    func cancelSubscriptionUpdate() {
        let profileID = selectedProfile?.id
        cancelSubscriptionOperation(clearCandidate: false)
        if let profileID {
            let store = store
            Task { _ = try? await ProfileBackgroundWork.run { try store.recordSubscriptionCancellation(for: profileID) } }
        }
        subscriptionFailureDiagnostic = nil
        messageKey = SubscriptionUpdateError.cancelled.messageKey
        refreshMetadataPreservingEditor()
    }

    func cancelSubscriptionIntake() {
        cancelSubscriptionOperation(clearCandidate: true)
        messageKey = "profile.subscription.error.cancelled"
        subscriptionFailureDiagnostic = nil
    }

    func confirmSubscriptionUpdate() {
        guard let pending = pendingSubscriptionIntake else { return }
        request(.applySubscription(pending))
    }

    func discardSubscriptionPreview() {
        pendingSubscriptionIntake = nil
        messageKey = "profile.subscription.preview-dismissed"
        subscriptionFailureDiagnostic = nil
    }

    private func cancelSubscriptionOperation(clearCandidate: Bool) {
        subscriptionGeneration &+= 1
        subscriptionTask?.cancel()
        subscriptionTask = nil
        isUpdatingSubscription = false
        if clearCandidate { pendingSubscriptionIntake = nil }
    }

    private func subscriptionMessageKey(for error: Error) -> String {
        if let error = error as? SubscriptionFetchFailure { return error.cause.messageKey }
        if let error = error as? SubscriptionUpdateError { return error.messageKey }
        if let error = error as? SubscriptionIntakeFailure { return error.cause.messageKey }
        if let error = error as? SubscriptionIntakeError { return error.messageKey }
        if error is SubscriptionPersistenceFailure { return "profile.subscription.error.persistence-failed" }
        if let storeError = error as? ProfileStoreError {
            if case .validationFailed = storeError {
                return SubscriptionIntakeError.validationFailed.messageKey
            }
        }
        return "profile.subscription.error.download-failed"
    }

    private func presentSubscriptionError(_ error: Error) {
        messageKey = subscriptionMessageKey(for: error)
        subscriptionFailureDiagnostic = SubscriptionFailureDiagnostic(error: error)
    }

    private func request(_ operation: ProfileWorkspaceOperation) {
        // A recovery decision owns the next replacement action. This also
        // prevents a clean editor from overwriting a recoverable older intent.
        guard pendingOperation == nil, !isPerformingPersistence, !isExporting, persistenceTask == nil else { return }
        invalidateSmartApplication()
        guard !isDirty else {
            pendingOperation = operation
            unsavedChangesPresentation.requestPresentation()
            return
        }
        isPerformingPersistence = true
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            self.isPerformingPersistence = false
            await self.execute(operation)
            self.persistenceTask = nil
        }
    }

    private func execute(_ operation: ProfileWorkspaceOperation) async {
        guard !isPerformingPersistence else { return }
        isPerformingPersistence = true
        defer {
            isPerformingPersistence = false
            isCommittingImport = false
        }
        let store = store
        let operations = subscriptionOperations
        if case .importCandidate = operation { isCommittingImport = true }
        do {
            let snapshot = try await ProfileBackgroundWork.run {
                try store.withSerializedAccess {
                    switch operation {
                    case .select(let id), .selectPolicy(let id, _, _): try store.select(id)
                    case .create(let name):
                        let profile = try store.create(name: name)
                        try store.select(profile.id)
                    case .duplicate(let id):
                        let profile = try store.duplicate(id)
                        try store.select(profile.id)
                    case .delete(let id): try store.delete(id)
                    case .restore(let id):
                        try store.restorePreviousValidVersion(for: id)
                        try store.select(id)
                    case .importCandidate(let candidate, let name): _ = try store.importCandidate(candidate, name: name)
                    case .applySubscription(let pending):
                        let profile = try operations.commit(pending)
                        try store.select(profile.id)
                    }
                    return try store.snapshot()
                }
            }
            cancelSubscriptionOperation(clearCandidate: true)
            subscriptionFailureDiagnostic = nil
            if case .importCandidate = operation { pendingImportCandidate = nil } else { cancelPreparedImport() }
            applySnapshot(snapshot)
            switch operation {
            case .selectPolicy(_, let selectorTag, let outboundTag): selectPolicy(selectorTag: selectorTag, outboundTag: outboundTag)
            case .restore: messageKey = "profile.message.restored"
            case .importCandidate: messageKey = "profile.import.success"
            case .applySubscription(let pending):
                if case .newProfile = pending.destination {
                    messageKey = "profile.subscription.added"
                } else {
                    messageKey = "profile.subscription.applied"
                }
            default: break
            }
            markReadinessChanged()
        } catch let error as ProfileStoreError {
            if case .applySubscription(let pending) = operation {
                if case .validationFailed(let diagnostic) = error {
                    self.diagnostic = diagnostic
                    presentSubscriptionError(SubscriptionIntakeFailure(cause: .validationFailed, response: pending.response.metadata))
                } else {
                    presentSubscriptionError(SubscriptionPersistenceFailure())
                }
            } else {
                present(error)
            }
        } catch { messageKey = "profile.message.operation-failed" }
    }

    /// For remote subscription state and metadata-only actions. Never invokes
    /// loadSelectedText(), so a task completing after the user edits cannot
    /// replace the current editing buffer or clear its dirty state.
    private func refreshMetadataPreservingEditor() {
        metadataGeneration &+= 1
        let generation = metadataGeneration
        let store = store
        let expectedID = selectedID
        Task { [weak self] in
            do {
                let snapshot = try await ProfileBackgroundWork.run { try store.snapshot() }
                guard let self, self.selectedID == expectedID, self.metadataGeneration == generation, !self.isPerformingPersistence else {
                    return
                }
                self.profiles = snapshot.profiles
                self.cachedCatalogs = snapshot.catalogs
            } catch { self?.messageKey = "profile.message.load-failed" }
        }
    }

    /// Restores the currently selected editor from authenticated persistent
    /// storage before any replacement operation may run. This is deliberately
    /// fail-closed: a read failure leaves the user's buffer and dirty state
    /// untouched, and the requested operation remains pending.
    @discardableResult
    private func discardCurrentEditorToPersistedState() async -> Bool {
        isPerformingPersistence = true
        defer { isPerformingPersistence = false }
        guard let selectedID else {
            messageKey = "profile.message.operation-failed"
            return false
        }
        do {
            let store = store
            let persistedText =
                usesCustomConfigurationLoader
                ? try configurationLoader(selectedID)
                : try await ProfileBackgroundWork.run { try store.configurationText(for: selectedID) }
            editorGeneration &+= 1
            editorDiagnosticTask?.cancel()
            editorText = persistedText
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = true
            return true
        } catch is ProfileStoreError {
            messageKey = "profile.message.configuration-read-failed"
            return false
        } catch {
            messageKey = "profile.message.configuration-read-failed"
            return false
        }
    }

    private func loadSelectedText() {
        invalidatePolicyHealth()
        guard let selectedID else {
            editorText = ""
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = false
            subscriptionFailureDiagnostic = nil
            policyCatalog = nil
            isPolicyCatalogUnavailable = false
            return
        }
        do {
            editorText = try configurationLoader(selectedID)
            diagnostic = nil
            isDirty = false
            isConfigurationLoaded = true
            messageKey = nil
        } catch {
            if !isDirty {
                editorText = ""
                diagnostic = nil
            }
            isConfigurationLoaded = false
            messageKey = "profile.message.configuration-read-failed"
        }
        refreshPolicyCatalog()
    }

    private func markReadinessChanged() {
        readinessChangeGeneration &+= 1
    }

    /// Catalog state is fail-closed. A storage read error clears prior data rather
    /// than retaining the previous Profile's catalog in the UI.
    private func refreshPolicyCatalog() {
        policyRefreshGeneration &+= 1
        let generation = policyRefreshGeneration
        do {
            policyCatalog = usesCustomPolicyCatalogLoader ? try policyCatalogLoader() : selectedID.flatMap { cachedCatalogs[$0] }
            isPolicyCatalogUnavailable = false
        } catch {
            policyCatalog = nil
            isPolicyCatalogUnavailable = true
        }
        guard !usesCustomPolicyCatalogLoader else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let reconciled = try await self.policyOperations.read()
                guard generation == self.policyRefreshGeneration else { return }
                self.policyCatalog = reconciled
                self.isPolicyCatalogUnavailable = false
            } catch {
                guard generation == self.policyRefreshGeneration else { return }
                self.policyCatalog = nil
                self.isPolicyCatalogUnavailable = true
            }
        }
    }

    private func policyMessageKey(for error: TargetPolicyOperationError) -> String {
        switch error {
        case .selectorNotFound, .selectorAmbiguous, .selectorUnavailable,
            .outboundNotFound, .outboundUnavailable:
            "policy.catalog.selection.unavailable"
        case .persistenceFailed:
            "policy.catalog.selection.failed"
        }
    }

    private func present(_ error: ProfileStoreError) {
        switch error {
        case .invalidJSON(let diagnostic), .validationFailed(let diagnostic):
            self.diagnostic = diagnostic
            self.messageKey = diagnostic.messageKey
        case .profileInUse:
            self.messageKey = "profile.message.stop-before-delete"
        default:
            self.messageKey = "profile.message.operation-failed"
        }
    }

    private func transferMessageKey(for error: ProfileTransferError) -> String {
        switch error {
        case .unreadableImport: "profile.import.error.unreadable"
        case .importTooLarge: "profile.import.error.too-large"
        case .importInvalidUTF8: "profile.import.error.invalid-utf8"
        case .importInvalidJSON: "profile.import.error.invalid-json"
        case .importValidationFailed: "profile.import.error.validation"
        case .unsafeExportDestination: "profile.export.error.unsafe-destination"
        case .exportFailed, .exportCleanupFailed: "profile.export.error.failed"
        }
    }
}
