import Darwin
import Foundation

actor SingBoxBackend: EngineInstalling, PolicyRuntimeEvidenceProviding, RuntimeControlDescriptorProviding, RuntimePolicyApplying, RuntimePolicyHealthProbing, RuntimeSnapshotProviding, RuntimeConnectionProviding, RuntimeLogProviding, SmartShadowRuntimeReading, SmartContinuityRuntimeReading, SmartContinuityRuntimeClosing {
    static let applicationSupportDirectoryName = "Target"
    static let engineDirectoryName = "sing-box"

    private var process: Process?
    private let runtimeLogBuffer = RuntimeLogBuffer()
    private let portProbe: any LocalEnginePortProbing
    private let portSelector: any LocalEnginePortSelecting
    private let runtimeOwnership: EngineRuntimeOwnership
    private let profileStore: ProfileStore
    private let runtimeConfigurations: RuntimeConfigurationStore
    private let readinessTimeout: Duration
    private let executableURL: URL
    private let runtimeControlClient: any RuntimeControlClient
    private var policyMutationInProgress = false

    init(
        portProbe: any LocalEnginePortProbing = LocalTCPPortProbe(),
        portSelector: any LocalEnginePortSelecting = DynamicHighLocalPortSelector(),
        runtimeOwnership: EngineRuntimeOwnership = EngineRuntimeOwnership(),
        profileStore: ProfileStore = ProfileStore(),
        engineDirectory: URL? = nil,
        executableURL: URL? = nil,
        readinessTimeout: Duration = .seconds(10),
        runtimeControlClient: any RuntimeControlClient = SingBoxRuntimeControlClient()
    ) {
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Self.applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: Self.engineDirectoryName, directoryHint: .isDirectory)
        let resolvedDirectory = (engineDirectory ?? defaultDirectory).standardizedFileURL
        self.portProbe = portProbe
        self.portSelector = portSelector
        self.runtimeOwnership = runtimeOwnership
        self.profileStore = profileStore
        self.runtimeConfigurations = RuntimeConfigurationStore(directory: resolvedDirectory.appending(path: "runtime", directoryHint: .isDirectory))
        self.readinessTimeout = readinessTimeout
        self.executableURL = executableURL ?? resolvedDirectory.appending(path: "bin/sing-box")
        self.runtimeControlClient = runtimeControlClient
    }

    func queryStatus() async throws -> BackendStatus {
        let installation = installationStatus()
        let version = installation == .installed ? try? versionString() : nil
        let disposition: EngineRuntimeRecordDisposition?
        if let record = runtimeOwnership.currentRecord(), retainedProcessHasExited(for: record) {
            disposition = .processExited(record)
        } else {
            disposition = try? await runtimeOwnership.recordDisposition()
        }
        if case let .processExited(expiredRecord)? = disposition,
           runtimeOwnership.discardExitedRecord(expiredRecord) {
            runtimeConfigurations.remove(id: expiredRecord.runtimeConfigurationID)
            if process?.processIdentifier == expiredRecord.pid {
                process = nil
                runtimeLogBuffer.clear()
            }
        }
        let ownedRecord: EngineRuntimeRecord?
        if case let .ownedRunning(record)? = disposition {
            ownedRecord = record
        } else {
            ownedRecord = nil
        }
        let verifiedRecord: EngineRuntimeRecord?
        if let record = ownedRecord,
           runtimeConfigurations.exists(id: record.runtimeConfigurationID),
           let version = try? profileStore.validVersion(for: record.profileID, revision: record.profileRevision),
           TargetConfigurationFingerprint.sha256(version.data) == record.sourceConfigurationFingerprint {
            verifiedRecord = record
        } else {
            verifiedRecord = nil
        }
        let selected = try? profileStore.selectedValidVersion()
        let restartRequired: Bool
        if let verifiedRecord, let selected {
            let profileRequiresRestart = EngineRuntimeProfileState.requiresRestart(record: verifiedRecord, selected: selected)
            if profileRequiresRestart { restartRequired = true }
            else {
                let desired = PolicyCatalogParser.parse(
                    selected.data,
                    profileID: selected.profile.id,
                    profileRevision: selected.revision,
                    overrides: selected.profile.policyOverrides
                )
                if desired.selectors.contains(where: \.isMutable) {
                    let evidence = await currentPolicyRuntimeEvidence()
                    restartRequired = PolicyCatalogReconciler.reconcile(
                        desired,
                        evidence: evidence
                    ).selectors.contains(where: \.restartRequired)
                } else {
                    restartRequired = false
                }
            }
        } else {
            restartRequired = false
        }
        return BackendStatus(
            serviceInstallation: .notRegistered,
            engineState: verifiedRecord == nil ? .stopped : .running,
            engineInstallation: installation,
            hasSelectedValidProfile: selected != nil,
            engineVersion: version,
            enginePort: verifiedRecord.map { Int($0.endpoint.port) },
            runningProfileID: verifiedRecord?.profileID,
            runningProfileRevision: verifiedRecord?.profileRevision,
            restartRequired: restartRequired
        )
    }

    func currentPolicyRuntimeEvidence() async -> PolicyRuntimeEvidence {
        guard let verified = await verifiedRuntimeControlMaterial() else {
            let disposition = try? await runtimeOwnership.recordDisposition()
            if case .noRecord? = disposition { return .stopped }
            if case .processExited? = disposition { return .stopped }
            return .unavailable
        }
        let selectors = try? await runtimeControlClient.selectors(using: verified.descriptor)
        return .running(
            profileID: verified.record.profileID,
            profileRevision: verified.record.profileRevision,
            sourceFingerprint: verified.record.sourceConfigurationFingerprint,
            configuration: verified.configuration,
            liveSelections: selectors?.mapValues(\.selected)
        )
    }

    func verifiedRuntimeControlDescriptor() async -> RuntimeControlDescriptor? {
        await verifiedRuntimeControlMaterial()?.descriptor
    }

    func applyLivePolicySelection(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        selectorTag: String,
        outboundTag: String
    ) async -> Bool {
        // A later manual choice waits for an already dispatched Smart write and
        // then wins. New Smart requests never queue behind another mutation.
        let deadline = ContinuousClock.now + .seconds(30)
        while policyMutationInProgress {
            guard ContinuousClock.now < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        guard let verified = await verifiedRuntimeControlMaterial(),
              verified.record.profileID == expectedRuntime.profileID,
              verified.record.profileRevision == expectedRuntime.profileRevision,
              verified.record.sourceConfigurationFingerprint == expectedRuntime.sourceFingerprint else {
            return false
        }
        do {
            try Task.checkCancellation()
            return try await performLivePolicySelection(selectorTag: selectorTag, outboundTag: outboundTag, descriptor: verified.descriptor)
        } catch {
            return false
        }
    }

    func applyLivePolicySelectionIfUnchanged(evidence: PolicySelectionEvidence, outboundTag: String,
                                             authorize: @escaping @Sendable () throws -> Void) async throws -> PolicySelectionApplyResult {
        guard !policyMutationInProgress else { return .refused(.mutationInProgress) }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        try Task.checkCancellation()
        guard let before = await verifiedRuntimeControlMaterial(),
              before.record.runtimeConfigurationID == evidence.sessionID,
              before.record.profileID == evidence.catalog.profileID,
              before.record.profileRevision == evidence.catalog.profileRevision,
              before.record.sourceConfigurationFingerprint == evidence.catalog.sourceFingerprint else { return .refused(.identityChanged) }
        let matches = evidence.catalog.selectors.filter { $0.tag == evidence.selector }
        guard matches.count == 1, matches[0].isMutable,
              matches[0].members.contains(where: { $0.tag == outboundTag && $0.status == .available }),
              outboundTag != evidence.currentOutbound else { return .refused(.invalidRecommendation) }
        let live: RuntimeSelectorState
        do {
            guard let value = try await runtimeControlClient.selectors(using: before.descriptor)[evidence.selector] else { return .refused(.runtimeUnavailable) }
            live = value
        } catch is CancellationError { throw CancellationError() }
        catch { return .refused(.runtimeUnavailable) }
        guard live.selected == evidence.currentOutbound,
              Set(live.members) == Set(matches[0].members.map(\.tag)) else { return .refused(.liveSelectionChanged) }
        guard let current = await verifiedRuntimeControlMaterial(), current.record == before.record,
              current.descriptor == before.descriptor else { return .refused(.identityChanged) }
        let age = Date().timeIntervalSince(evidence.observedAt)
        guard age.isFinite, (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(age) else { return .refused(.staleEvidence) }
        try Task.checkCancellation()
        // No suspension between the shared Profile/generation compare-and-commit
        // and dispatch. All Target selector writes share this mutation lease.
        do { try authorize() }
        catch PolicySelectionApplyRefusal.selectionChanged { return .refused(.selectionChanged) }
        catch PolicySelectionApplyRefusal.profileChanged { return .refused(.profileChanged) }
        do {
            let converged = try await performLivePolicySelection(selectorTag: evidence.selector, outboundTag: outboundTag, descriptor: before.descriptor)
            guard converged, let after = await verifiedRuntimeControlMaterial(),
                  after.record == before.record, after.descriptor == before.descriptor else { return .refused(.mutationUnconfirmed) }
            return .init(applied: true, after: outboundTag, reason: .applied, runtimeIdentity: before.record)
        } catch {
            // A dispatched request can have taken effect even when its reply is
            // unavailable. Never retry or claim convergence in that situation.
            return .refused(.mutationUnconfirmed)
        }
    }

    private func performLivePolicySelection(selectorTag: String, outboundTag: String, descriptor: RuntimeControlDescriptor) async throws -> Bool {
        try await runtimeControlClient.select(selector: selectorTag, outbound: outboundTag, using: descriptor)
        return try await runtimeControlClient.selectors(using: descriptor)[selectorTag]?.selected == outboundTag
    }

    func probePolicyMemberLatency(
        expectedRuntime: ExpectedPolicyRuntimeIdentity,
        outboundTags: [String]
    ) async throws -> RuntimePolicyHealthProbeOutcome {
        guard !outboundTags.isEmpty,
              let verified = await verifiedRuntimeControlMaterial(),
              verified.record.profileID == expectedRuntime.profileID,
              verified.record.profileRevision == expectedRuntime.profileRevision,
              verified.record.sourceConfigurationFingerprint == expectedRuntime.sourceFingerprint else {
            return .runtimeUnavailable
        }

        let client = runtimeControlClient
        let descriptor = verified.descriptor
        let maximumConcurrentProbes = 4
        let indexedTags = Array(outboundTags.enumerated())
        var indexedResults: [(Int, RuntimeProxyHealth)] = []
        var controllerUnavailable = false
        var requiresLivenessReconciliation = false

        try await withThrowingTaskGroup(of: (Int, RuntimeProxyHealth, Bool, Bool).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < indexedTags.count else { return }
                let (index, tag) = indexedTags[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let latency = try await client.probeLatency(outbound: tag, using: descriptor)
                        guard let health = RuntimeProxyHealth.reachable(
                            tag: tag,
                            latencyMilliseconds: latency,
                            observedAt: Date()
                        ) else {
                            return (index, .unreachable(tag: tag, observedAt: Date(), isConclusiveFailure: false), false, false)
                        }
                        return (index, health, false, false)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as RuntimeControlError {
                        switch error {
                        case .unavailable, .invalidDescriptor, .redirectRefused, .selectionRejected:
                            return (index, .runtimeUnavailable(tag: tag), true, false)
                        case .probeTransportFailure:
                            return (index, .unreachable(tag: tag, observedAt: Date(), isConclusiveFailure: false), false, true)
                        case .probeFailed:
                            return (index, .unreachable(tag: tag, observedAt: Date()), false, false)
                        case .malformedResponse:
                            return (index, .unreachable(tag: tag, observedAt: Date(), isConclusiveFailure: false), false, false)
                        }
                    } catch {
                        return (index, .unreachable(tag: tag, observedAt: Date(), isConclusiveFailure: false), false, false)
                    }
                }
            }

            for _ in 0..<min(maximumConcurrentProbes, indexedTags.count) { addNext() }
            while let (index, result, unavailable, requiresReconciliation) = try await group.next() {
                indexedResults.append((index, result))
                controllerUnavailable = controllerUnavailable || unavailable
                requiresLivenessReconciliation = requiresLivenessReconciliation || requiresReconciliation
                addNext()
            }
        }
        try Task.checkCancellation()

        guard !controllerUnavailable else {
            return .runtimeUnavailable
        }
        if requiresLivenessReconciliation {
            do {
                _ = try await runtimeControlClient.selectors(using: descriptor)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return .runtimeUnavailable
            }
        }
        guard let current = await verifiedRuntimeControlMaterial(),
              current.record.runtimeConfigurationID == verified.record.runtimeConfigurationID,
              current.record.profileID == verified.record.profileID,
              current.record.profileRevision == verified.record.profileRevision,
              current.record.sourceConfigurationFingerprint == verified.record.sourceConfigurationFingerprint,
              current.record.configurationFingerprint == verified.record.configurationFingerprint,
              current.descriptor == verified.descriptor else {
            return .runtimeUnavailable
        }
        return .results(indexedResults.sorted { $0.0 < $1.0 }.map(\.1))
    }

    func collectShadowEvidence(expectedRuntime: ExpectedPolicyRuntimeIdentity, selector: String, candidates: [String]) async throws -> SmartShadowRuntimeResult {
        guard !candidates.isEmpty, candidates.count <= SmartPolicyShadowOperations.maximumCandidates,
              Set(candidates).count == candidates.count,
              candidates.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            return .unavailable("runtimeUnavailable")
        }
        guard let before = await verifiedRuntimeControlMaterial() else {
            let disposition = try? await runtimeOwnership.recordDisposition()
            if case .noRecord? = disposition { return .stopped }
            if case .processExited? = disposition { return .stopped }
            return .unavailable("ownershipUnavailable")
        }
        guard before.record.profileID == expectedRuntime.profileID,
              before.record.profileRevision == expectedRuntime.profileRevision,
              before.record.sourceConfigurationFingerprint == expectedRuntime.sourceFingerprint else {
            return .unavailable("identityMismatch")
        }
        let live: RuntimeSelectorState
        do {
            guard let value = try await runtimeControlClient.selectors(using: before.descriptor)[selector] else {
                return .unavailable("selectorMissing")
            }
            live = value
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable("controllerUnavailable") }
        guard Set(live.members) == Set(candidates), candidates.contains(live.selected) else {
            return .unavailable("selectorStale")
        }
        let probes = try await probePolicyMemberLatency(expectedRuntime: expectedRuntime, outboundTags: candidates)
        guard case .results = probes else { return .unavailable("runtimeUnavailable") }
        // Exactly one bounded connection snapshot. It never closes connections.
        let snapshot = await currentRuntimeSnapshot()
        guard let after = await verifiedRuntimeControlMaterial(),
              after.record == before.record, after.descriptor == before.descriptor else {
            return .unavailable("identityChanged")
        }
        let final: RuntimeSelectorState
        do {
            guard let value = try await runtimeControlClient.selectors(using: after.descriptor)[selector] else {
                return .unavailable("selectorMissing")
            }
            final = value
        } catch is CancellationError { throw CancellationError() }
        catch { return .unavailable("controllerUnavailable") }
        guard final == live,
              let confirmed = await verifiedRuntimeControlMaterial(),
              confirmed.record == before.record, confirmed.descriptor == before.descriptor else {
            return .unavailable("runtimeChanged")
        }
        return .available(.init(sessionID: before.record.runtimeConfigurationID,
                                currentOutbound: live.selected, probes: probes, connections: snapshot))
    }

    func currentRuntimeConnectionTotals() async -> RuntimeConnectionTotals? {
        await currentRuntimeSnapshot()?.totals
    }

    func currentRuntimeConnections() async -> [RuntimeConnection]? {
        await currentRuntimeSnapshot()?.connections
    }

    func currentRuntimeSnapshot() async -> RuntimeConnectionsSnapshot? {
        guard let verified = await verifiedRuntimeControlMaterial(),
              let snapshot = try? await runtimeControlClient.connections(using: verified.descriptor),
              let current = await verifiedRuntimeControlMaterial(),
              current.record == verified.record, current.descriptor == verified.descriptor else { return nil }
        return snapshot
    }

    func collectContinuityEvidence() async throws -> SmartContinuityRuntimeResult {
        try Task.checkCancellation()
        guard let before = await verifiedRuntimeControlMaterial() else {
            let disposition = try? await runtimeOwnership.recordDisposition()
            if case .noRecord? = disposition { return .stopped }
            if case .processExited? = disposition { return .stopped }
            return .unavailable
        }
        // Reuse the existing authenticated, bounded Connections read and its
        // ownership checks; associate it with identity only after revalidation.
        guard let snapshot = await currentRuntimeSnapshot(),
              let after = await verifiedRuntimeControlMaterial(),
              before.record == after.record, before.descriptor == after.descriptor else { return .unavailable }
        try Task.checkCancellation()
        return .available(.init(identity: before.record, snapshot: snapshot, observedAt: .now))
    }

    func closeContinuityConnection(_ request: SmartContinuityCloseRequest,
                                   authorize: @escaping @Sendable (_ dispatch: @Sendable () -> Void) throws -> Void) async throws -> SmartContinuityCloseOutcome {
        guard !policyMutationInProgress else { return .preserved("mutationInProgress") }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        let receipt = request.receipt
        let dispatchState = ContinuityCloseDispatchState()
        guard receipt.oldOutbound != receipt.newOutbound,
              receipt.identity == request.plan.evidence.identity,
              request.plan.classifications[request.connection.id] == .replaceable,
              SmartContinuityPlan.isRelevantOldConnection(request.connection, receipt: receipt) else {
            return .preserved("unrelatedConnection")
        }
        do {
            try Task.checkCancellation()
            guard let before = await verifiedRuntimeControlMaterial(), before.record == receipt.identity else {
                return .preserved("identityChanged")
            }
            // Validate the UUID before any destructive call. The client has no
            // endpoint, path, method, close-all or caller-selected URL surface.
            _ = try SingBoxRuntimeControlClient.makeConnectionCloseRequest(id: request.connection.id, descriptor: before.descriptor)
            let expectedMembers = receipt.catalog.selectors.filter { $0.tag == receipt.selector }
            guard expectedMembers.count == 1, expectedMembers[0].isMutable,
                  let live = try await runtimeControlClient.selectors(using: before.descriptor)[receipt.selector],
                  live.selected == receipt.newOutbound,
                  Set(live.members) == Set(expectedMembers[0].members.map(\.tag)) else {
                return .preserved("liveSelectionChanged")
            }
            guard let current = await verifiedRuntimeControlMaterial(), current.record == before.record,
                  current.descriptor == before.descriptor else { return .preserved("identityChanged") }
            guard try await runtimeControlClient.selectors(using: before.descriptor)[receipt.selector] == live,
                  let confirmed = await verifiedRuntimeControlMaterial(), confirmed.record == before.record,
                  confirmed.descriptor == before.descriptor else { return .preserved("liveSelectionChanged") }
            // Connections is the last controller read before dispatch. Selector
            // and asynchronous ownership reconciliation must not add another
            // round trip after the candidate's final activity observation.
            let snapshot = try await runtimeControlClient.connections(using: before.descriptor)
            let observedAt = Date()
            guard !snapshot.isTruncated,
                  let connection = snapshot.connections.first(where: { $0.id == request.connection.id }),
                  snapshot.connections.filter({ $0.id == request.connection.id }).count == 1 else {
                return .preserved(snapshot.isTruncated ? "snapshotTruncated" : "connectionDisappeared")
            }
            let fresh = SmartContinuityEvidence(identity: before.record, snapshot: snapshot, observedAt: observedAt)
            guard request.plan.permitsClose(connection, with: fresh, now: .now),
                  SmartContinuityPlan.isRelevantOldConnection(connection, receipt: receipt) else {
                return .preserved("connectionChanged")
            }
            try Task.checkCancellation()
            let ownership = runtimeOwnership
            let record = before.record
            try await runtimeControlClient.closeConnection(id: connection.id, using: before.descriptor) { dispatch in
                // This executes inside the client's final synchronous dispatch
                // callback; lifecycle writes remain excluded by the backend lease.
                guard ownership.currentRecord() == record, ownership.ownsProcess(record) else {
                    throw ContinuityDispatchRefusal.identityChanged
                }
                let age = Date().timeIntervalSince(observedAt)
                let planAge = Date().timeIntervalSince(request.plan.evidence.observedAt)
                guard age.isFinite, planAge.isFinite,
                      (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(age),
                      (0...SmartPolicyApplyOperations.maximumEvidenceAge).contains(planAge) else {
                    throw ContinuityDispatchRefusal.staleEvidence
                }
                try Task.checkCancellation()
                try authorize {
                    dispatchState.markDispatched()
                    dispatch()
                }
            }
            // sing-box returns 204 even when an ID was already absent. Confirm
            // disappearance through the same verified runtime, never infer it
            // from the status code or retry a possibly dispatched close.
            guard let after = await verifiedRuntimeControlMaterial(), after.record == before.record,
                  after.descriptor == before.descriptor,
                  let remaining = await currentRuntimeSnapshot(), !remaining.isTruncated,
                  !remaining.connections.contains(where: { $0.id == connection.id }),
                  let final = await verifiedRuntimeControlMaterial(), final.record == before.record,
                  final.descriptor == before.descriptor else { return .failed }
            return .closed
        } catch is CancellationError {
            // Cancellation after dispatch cannot prove preservation: the peer
            // may already have closed the connection before cancellation won.
            return dispatchState.wasDispatched ? .failed : .cancelled
        } catch ContinuityDispatchRefusal.identityChanged {
            return .preserved("identityChanged")
        } catch ContinuityDispatchRefusal.staleEvidence {
            return .preserved("staleEvidence")
        } catch PolicySelectionApplyRefusal.selectionChanged {
            return dispatchState.wasDispatched ? .failed : .preserved("selectionChanged")
        } catch PolicySelectionApplyRefusal.profileChanged {
            return dispatchState.wasDispatched ? .failed : .preserved("profileChanged")
        } catch RuntimeControlError.invalidDescriptor {
            return dispatchState.wasDispatched ? .failed : .preserved("invalidConnectionID")
        } catch {
            return .failed
        }
    }

    func runtimeConnectionAvailability() async -> RuntimeObservationState {
        await runtimeObservationAvailability()
    }

    func runtimeLogAvailability() async -> RuntimeObservationState {
        guard let material = await verifiedRuntimeControlMaterial(),
              runtimeConfigurations.exists(id: material.record.runtimeConfigurationID) else {
            let disposition = try? await runtimeOwnership.recordDisposition()
            if case .noRecord? = disposition { return .stopped }
            if case .processExited? = disposition { return .stopped }
            return .unavailable
        }
        return .available
    }

    func runtimeLogs() async -> [RuntimeLogEntry] { runtimeLogBuffer.snapshot() }

    func clearRuntimeLogs() async { runtimeLogBuffer.clear() }

    func runtimeObservationAvailability() async -> RuntimeObservationState {
        if await verifiedRuntimeControlDescriptor() != nil { return .loading }
        let disposition = try? await runtimeOwnership.recordDisposition()
        if case .noRecord? = disposition { return .stopped }
        if case .processExited? = disposition { return .stopped }
        return .unavailable
    }

    private func verifiedRuntimeControlMaterial() async -> (record: EngineRuntimeRecord, configuration: Data, descriptor: RuntimeControlDescriptor)? {
        guard case let .ownedRunning(record) = try? await runtimeOwnership.recordDisposition(),
              let version = try? profileStore.validVersion(for: record.profileID, revision: record.profileRevision),
              TargetConfigurationFingerprint.sha256(version.data) == record.sourceConfigurationFingerprint,
              let configuration = runtimeConfigurations.readVerified(
                id: record.runtimeConfigurationID,
                fingerprint: record.configurationFingerprint
              ),
              let descriptor = RuntimeControlDescriptorParser.parse(configuration) else { return nil }
        return (record, configuration, descriptor)
    }

    func installEngine() async throws -> BackendStatus {
        guard !policyMutationInProgress else { throw BackendError.invalidLifecycleTransition }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        guard let installerURL = Bundle.main.url(forResource: "install_sing_box", withExtension: "sh") else {
            throw BackendError.engineInstallationFailed
        }
        let installer = Process()
        installer.executableURL = installerURL
        let result = try run(installer)
        guard result.status == 0 else { throw BackendError.engineInstallationFailed }
        return try await queryStatus()
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {
        _ = try request.validated()
        guard installationStatus() == .installed else { throw BackendError.engineNotInstalled }
        let prepared = try prepareSelectedConfiguration()
        let temporary = try runtimeConfigurations.write(prepared.data)
        defer { runtimeConfigurations.remove(id: temporary.id) }
        try checkConfiguration(at: temporary.url)
    }

    func startEngine() async throws -> BackendStatus {
        guard !policyMutationInProgress else { throw BackendError.invalidLifecycleTransition }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        try Task.checkCancellation()
        let disposition: EngineRuntimeRecordDisposition
        do {
            disposition = try await runtimeOwnership.recordDisposition()
        } catch {
            throw BackendError.invalidLifecycleTransition
        }
        switch disposition {
        case .noRecord:
            // A Target-owned runtime directory with no record contains only
            // unassociated artifacts from a previous interrupted launch.
            runtimeConfigurations.removeAll()
        case .processExited(let record):
            guard runtimeOwnership.discardExitedRecord(record) else {
                throw BackendError.invalidLifecycleTransition
            }
            runtimeConfigurations.remove(id: record.runtimeConfigurationID)
        case .ownedRunning, .liveUnproven:
            throw BackendError.invalidLifecycleTransition
        }
        guard installationStatus() == .installed else { throw BackendError.engineNotInstalled }

        let prepared = try prepareSelectedConfiguration()
        try Task.checkCancellation()
        let temporary = try runtimeConfigurations.write(prepared.data)
        var launched: Process?
        do {
            try checkConfiguration(at: temporary.url)
            try Task.checkCancellation()
            runtimeLogBuffer.clear()
            let candidate = makeEngineProcess(configurationURL: temporary.url, logBuffer: runtimeLogBuffer)
            try candidate.run()
            launched = candidate
            try Task.checkCancellation()
            try runtimeOwnership.recordLaunchedProcess(
                pid: candidate.processIdentifier,
                executableURL: executableURL,
                port: prepared.primaryPort,
                profileID: prepared.profileID,
                profileRevision: prepared.profileRevision,
                sourceConfigurationFingerprint: prepared.sourceFingerprint,
                configurationFingerprint: prepared.configurationFingerprint,
                runtimeConfigurationID: temporary.id,
                routeBindingsFingerprint: prepared.routeBindingsFingerprint
            )
            try Task.checkCancellation()
            guard try await waitForPortReadiness(for: candidate) else {
                throw EngineRuntimeReadiness.startupFailure(processStillRunning: candidate.isRunning)
            }
            try Task.checkCancellation()
            process = candidate
            return try await queryStatus()
        } catch is CancellationError {
            await cleanupFailedLaunch(process: launched, configurationID: temporary.id)
            throw CancellationError()
        } catch let error as BackendError {
            await cleanupFailedLaunch(process: launched, configurationID: temporary.id)
            throw error
        } catch {
            await cleanupFailedLaunch(process: launched, configurationID: temporary.id)
            throw BackendError.engineLaunchFailed
        }
    }

    func stopEngine() async throws -> BackendStatus {
        guard !policyMutationInProgress else { throw BackendError.invalidLifecycleTransition }
        policyMutationInProgress = true
        defer { policyMutationInProgress = false }
        guard let record = runtimeOwnership.currentRecord(), runtimeOwnership.ownsProcess(record) else {
            throw BackendError.invalidLifecycleTransition
        }
        try Task.checkCancellation()
        let terminated: Bool
        if let process, process.processIdentifier == record.pid, process.isRunning {
            terminated = await stopOwnedProcess(process)
        } else {
            terminated = await stopOwnedRecord(record)
        }
        guard terminated else { throw BackendError.engineLaunchFailed }
        self.process = nil
        runtimeOwnership.clearRecord()
        runtimeConfigurations.remove(id: record.runtimeConfigurationID)
        runtimeLogBuffer.clear()
        return try await queryStatus()
    }

    private func prepareSelectedConfiguration() throws -> PreparedProfileConfiguration {
        do {
            return try ProfileRuntimeConfigurationPreparer(portSelector: portSelector).prepare(profileStore.selectedValidVersion())
        } catch let error as ProfileStoreError {
            switch error {
            case .noSelectedProfile: throw BackendError.profileNotSelected
            case .noValidVersion: throw BackendError.profileNoValidVersion
            case .unsafePath: throw BackendError.profileConfigurationUnsafe
            default: throw BackendError.profileConfigurationInvalid
            }
        } catch let error as ProfileRuntimeConfigurationError {
            switch error {
            case .unsafeConfiguration: throw BackendError.profileConfigurationUnsafe
            case .invalidJSON, .noLoopbackMixedInbound, .invalidPort,
                 .secretGenerationFailed, .controllerPortUnavailable:
                throw BackendError.profileConfigurationInvalid
            }
        } catch {
            throw BackendError.profileConfigurationInvalid
        }
    }

    private func checkConfiguration(at url: URL) throws {
        let checker = Process()
        checker.executableURL = executableURL
        checker.arguments = ["check", "-c", url.path]
        let result = try run(checker)
        guard result.status == 0 else { throw BackendError.configurationCheckFailed }
    }

    private func makeEngineProcess(configurationURL: URL, logBuffer: RuntimeLogBuffer) -> Process {
        let launched = Process()
        launched.executableURL = executableURL
        launched.arguments = ["run", "-c", configurationURL.path]
        let pipe = Pipe()
        launched.standardOutput = pipe
        launched.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak logBuffer] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logBuffer?.append(data)
        }
        launched.terminationHandler = { _ in pipe.fileHandleForReading.readabilityHandler = nil }
        return launched
    }

    private func cleanupFailedLaunch(process: Process?, configurationID: UUID) async {
        if let process { _ = await stopOwnedProcess(process) }
        runtimeOwnership.clearRecord()
        runtimeConfigurations.remove(id: configurationID)
        self.process = nil
        runtimeLogBuffer.clear()
    }

    private func installationStatus() -> EngineInstallationState {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return .notInstalled }
        return (try? versionString()) == nil ? .invalid : .installed
    }

    private func versionString() throws -> String {
        let version = Process()
        version.executableURL = executableURL
        version.arguments = ["version"]
        let result = try run(version)
        guard result.status == 0, let firstLine = result.output.split(separator: "\n").first,
              firstLine.hasPrefix("sing-box version ") else { throw BackendError.engineNotInstalled }
        return String(firstLine).replacingOccurrences(of: "sing-box version ", with: "")
    }

    private func run(_ process: Process) throws -> (status: Int32, output: String) {
        let result = try BoundedProcessRunner.run(process)
        return (result.status, result.output)
    }

    private func waitForPortReadiness(for process: Process) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + readinessTimeout
        while process.isRunning && clock.now < deadline {
            try Task.checkCancellation()
            guard let record = await runtimeOwnership.ownedRecord() else { return false }
            if await portProbe.isListening(on: record.endpoint.port) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard let record = await runtimeOwnership.ownedRecord() else { return false }
        return process.isRunning ? await portProbe.isListening(on: record.endpoint.port) : false
    }

    private func retainedProcessHasExited(for record: EngineRuntimeRecord) -> Bool {
        guard let process, process.processIdentifier == record.pid else { return false }
        return !process.isRunning
    }

    private func stopOwnedProcess(_ process: Process) async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForProcessExit(process) { return true }
        _ = kill(pid_t(process.processIdentifier), SIGKILL)
        return await waitForProcessExit(process)
    }

    private func stopOwnedRecord(_ record: EngineRuntimeRecord) async -> Bool {
        guard runtimeOwnership.ownsProcess(record) else { return false }
        if kill(pid_t(record.pid), SIGTERM) != 0, errno == ESRCH { return true }
        if await waitForOwnedRecordToExit(record) { return true }
        guard runtimeOwnership.ownsProcess(record) else { return true }
        _ = kill(pid_t(record.pid), SIGKILL)
        return await waitForOwnedRecordToExit(record)
    }

    private func waitForProcessExit(_ process: Process, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while process.isRunning && clock.now < deadline {
            // Cleanup must finish even when its caller was cancelled.
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !process.isRunning
    }

    private func waitForOwnedRecordToExit(_ record: EngineRuntimeRecord, timeout: Duration = .seconds(1)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while runtimeOwnership.ownsProcess(record) && clock.now < deadline {
            // A stop already signalled a verified Target-owned process.
            try? await Task.sleep(for: .milliseconds(25))
        }
        return !runtimeOwnership.ownsProcess(record)
    }

    deinit {
        if process?.isRunning == true { process?.terminate() }
    }
}

enum EngineRuntimeReadiness {
    static func visibleState(processIsOwned: Bool, portIsListening: Bool) -> EngineState {
        processIsOwned && portIsListening ? .running : .stopped
    }

    static func startupFailure(processStillRunning: Bool) -> BackendError {
        processStillRunning ? .enginePortUnavailable : .engineLaunchFailed
    }
}

private enum ContinuityDispatchRefusal: Error { case identityChanged, staleEvidence }

private final class ContinuityCloseDispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = false
    var wasDispatched: Bool { lock.lock(); defer { lock.unlock() }; return dispatched }
    func markDispatched() { lock.lock(); dispatched = true; lock.unlock() }
}

enum EngineRuntimeProfileState {
    static func requiresRestart(record: EngineRuntimeRecord, selected: ProfileConfigurationVersion?) -> Bool {
        guard let selected else { return true }
        return record.profileID != selected.profile.id || record.profileRevision != selected.revision
            || record.sourceConfigurationFingerprint != TargetConfigurationFingerprint.sha256(selected.data)
            || (record.routeBindingsFingerprint ?? ProfileRouteBinding.fingerprint([]))
                != ProfileRouteBinding.fingerprint(selected.profile.routeBindings)
    }
}

enum EngineLogRedactor {
    private static let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    private static let ipv6 = try! NSRegularExpression(pattern: #"(?i)[0-9a-f:]*:[0-9a-f:]+"#)
    private static let userPath = try! NSRegularExpression(pattern: #"/Users/[^\s]+"#)
    private static let credentialURL = try! NSRegularExpression(pattern: #"://[^\s/@:]+:[^\s/@]+@"#)
    private static let uuid = try! NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    private static let sensitiveJSON = try! NSRegularExpression(pattern: #"(?i)(\"(?:password|uuid|private_key|private-key|token|secret|subscription_url)\"\s*:\s*)\"[^\"]*\""#)
    private static let bearerAuthorization = try! NSRegularExpression(pattern: #"(?i)(authorization:\s*bearer\s+)\S+"#)
    private static let inlineSecret = try! NSRegularExpression(pattern: #"(?i)\b(secret|token|password)\s*=\s*[^\s]+"#)
    private static let absolutePath = try! NSRegularExpression(pattern: #"(?<!:)\B/(?:[^\s\"']+/)+[^\s\"']+"#)

    static func redact(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for (expression, replacement) in [(ipv4, "[redacted-ip]"), (ipv6, "[redacted-ip]"), (credentialURL, "://[redacted-credentials]@"), (uuid, "[redacted-uuid]"), (sensitiveJSON, "$1\"[redacted]\""), (bearerAuthorization, "$1[redacted]"), (inlineSecret, "$1=[redacted]"), (userPath, "[redacted-path]"), (absolutePath, "[redacted-path]")] {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return Data(text.utf8)
    }
}
