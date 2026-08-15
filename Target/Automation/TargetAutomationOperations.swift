import Foundation
import TargetCore

actor TargetAutomationOperations {
    private struct SystemProxyStatusRead {
        let status: SystemProxyStatus?
        let isAuthoritative: Bool
    }

    private let profileStore: ProfileStore
    private let subscriptionOperations: TargetSubscriptionOperations
    private let policyOperations: any TargetPolicyOperating
    private let backend: any EngineBackend
    private let serviceClient: any SystemProxyClient
    private let systemProxyOperations: any TargetSystemProxyOperating
    private let runtimeOperations: any TargetRuntimeOperating
    private let runtimeObservationOperations: any TargetRuntimeObserving
    private let hostNetworkSafetyMode: HostNetworkSafetyMode
    private let engineStatusObserver: (@Sendable (BackendStatus) async -> Void)?
    private let systemProxyStatusObserver: (@Sendable (SystemProxyStatus) async -> Void)?

    init(
        profileStore: ProfileStore = ProfileStore(),
        subscriptionFetcher: any ProfileSubscriptionFetching = SecureSubscriptionFetcher(),
        policyOperations: (any TargetPolicyOperating)? = nil,
        backend: any EngineBackend = SingBoxBackend(),
        serviceClient: any SystemProxyClient = TargetServiceXPCClient(),
        systemProxyOperations: (any TargetSystemProxyOperating)? = nil,
        runtimeOperations: (any TargetRuntimeOperating)? = nil,
        runtimeObservationOperations: any TargetRuntimeObserving = UnavailableRuntimeObservationProvider(),
        hostNetworkSafetyMode: HostNetworkSafetyMode = TargetValidationPolicy.hostNetworkSafetyMode,
        engineStatusObserver: (@Sendable (BackendStatus) async -> Void)? = nil,
        systemProxyStatusObserver: (@Sendable (SystemProxyStatus) async -> Void)? = nil
    ) {
        self.profileStore = profileStore
        self.subscriptionOperations = TargetSubscriptionOperations(store: profileStore, fetcher: subscriptionFetcher)
        self.policyOperations = policyOperations ?? TargetPolicyOperations(profileStore: profileStore)
        self.backend = backend
        self.serviceClient = serviceClient
        let resolvedSystemProxyOperations = systemProxyOperations ?? TargetSystemProxyOperations(client: serviceClient)
        self.systemProxyOperations = resolvedSystemProxyOperations
        self.runtimeOperations = runtimeOperations ?? TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: serviceClient,
            systemProxyOperations: resolvedSystemProxyOperations
        )
        self.runtimeObservationOperations = runtimeObservationOperations
        self.hostNetworkSafetyMode = hostNetworkSafetyMode
        self.engineStatusObserver = engineStatusObserver
        self.systemProxyStatusObserver = systemProxyStatusObserver
    }

    func handle(_ request: AutomationRequest) async -> AutomationResponse {
        guard request.protocolVersion == AutomationProtocol.version else {
            return .failure(code: "unsupported_version", message: "The protocol version is not supported.")
        }
        do {
            if Self.argumentFreeActions.contains(request.action), !request.arguments.isEmpty {
                return .failure(code: "invalid_arguments", message: "This action does not accept arguments.")
            }
            switch request.action {
            case "capabilities": return capabilities()
            case "status": return await consolidatedStatus()
            case "runtime.status": return await runtimeStatus()
            case "profile.import": return try profileImport(request.arguments)
            case "profile.subscribe": return try await profileSubscribe(request.arguments)
            case "profile.subscription-update": return try await profileSubscriptionUpdate(request.arguments)
            case "profile.list": return try profileList()
            case "policy.list": return try await policyList()
            case "policy.select": return try await policySelect(request.arguments)
            case "policy.probe": return try await policyProbe(request.arguments)
            case "policy.reset": return try await policyReset()
            case "profile.delete": return try profileDelete(request.arguments)
            case "engine.status": return await engineStatus()
            case "engine.start": return try await engineStart()
            case "engine.stop": return try await engineStop()
            case "service.status": return serviceStatus()
            case "service.install": return try serviceInstall()
            case "service.ping": return await servicePing()
            case "service.remove": return try serviceRemove()
            case "proxy.status": return await proxyStatus()
            case "proxy.enable": return try await proxyAction(systemProxyOperations.enable)
            case "proxy.disable": return try await proxyAction(systemProxyOperations.disable)
            case "proxy.recover": return try await proxyAction(systemProxyOperations.recover)
            default: return .failure(code: "unknown_action", message: "The requested action is not supported.")
            }
        } catch let error as ProfileTransferError {
            return profileTransferFailure(error)
        } catch let error as SubscriptionFetchFailure {
            return subscriptionFailure(error.cause)
        } catch let error as SubscriptionUpdateError {
            return subscriptionFailure(error)
        } catch let error as SubscriptionIntakeFailure {
            return subscriptionIntakeFailure(error.cause)
        } catch let error as SubscriptionIntakeError {
            return subscriptionIntakeFailure(error)
        } catch let error as TargetPolicyOperationError {
            return policyFailure(error)
        } catch let error as ProfileStoreError {
            return profileStoreFailure(error)
        } catch let error as BackendError {
            return backendFailure(error)
        } catch let error as SystemProxyError {
            return serviceFailure(xpcError(error).code)
        } catch let error as TargetSystemProxyOperationError {
            return serviceFailure(xpcError(error.operationError).code)
        } catch let error as NSError where error.domain == "com.jason312928.Target.TargetService" {
            return serviceFailure(error.code)
        } catch {
            return .failure(code: "operation_failed", message: "The operation could not be completed.")
        }
    }

    private func capabilities() -> AutomationResponse {
        .success(.object([
            "commands": .array(Self.commands.map(JSONValue.string)),
            "phase": .string("Local Automation Phase 1"),
            "protocolVersion": .integer(AutomationProtocol.version)
        ]))
    }

    private func consolidatedStatus() async -> AutomationResponse {
        let engine = try? await backend.queryStatus()
        let service = TargetServiceRegistration.status
        let xpcReachable = service == .enabled ? (try? await serviceClient.ping()) != nil : nil
        let proxyRead = await systemProxyStatusRead()
        await observeSystemProxyStatus(proxyRead.status)
        let proxy = proxyRead.status
        let recoveryCapability = proxy?.recoveryCapability(
            hostNetworkSafetyMode: hostNetworkSafetyMode,
            isOperationInProgress: false
        )
        let selectedValid = (try? profileStore.selectedValidVersion()) != nil
        return .success(.object([
            "buildChannel": .string(Bundle.main.object(forInfoDictionaryKey: "TargetBuildChannel") as? String ?? "unknown"),
            "engineState": .string(engine?.engineState.rawValue ?? "unknown"),
            "engineReachable": .boolean(proxy?.engineReachable ?? false),
            "affectedServiceCount": .integer(proxy?.affectedServiceCount ?? 0),
            "hasRecoverySnapshot": .boolean(proxy?.hasRecoverySnapshot ?? false),
            "hostSafety": .string(hostNetworkSafetyMode.automationValue),
            "recoveryRequired": .boolean(proxy?.state == .recoveryRequired),
            "recoveryAvailable": .boolean(recoveryCapability?.isAvailable ?? false),
            "recoveryBlocker": recoveryCapability.map {
                $0.blocker.map { .string($0.rawValue) } ?? .null
            } ?? .string(SystemProxyRecoveryBlocker.statusUnavailable.rawValue),
            "selectedValidProfile": .boolean(selectedValid),
            "serviceState": .string(service.rawValue),
            "sourceSHA": .string(Bundle.main.object(forInfoDictionaryKey: "TargetSourceCommit") as? String ?? "unknown"),
            "statusAuthoritative": .boolean(proxyRead.isAuthoritative),
            "systemProxyState": .string(proxy?.state.rawValue ?? "unavailable"),
            "utmValidation": .boolean(TargetValidationPolicy.isUTMValidation),
            "xpcState": .string(ServiceConnectionAssessment.xpcState(registration: service, xpcReachable: xpcReachable).rawValue)
        ]))
    }

    private func profileImport(_ arguments: [String: String]) throws -> AutomationResponse {
        guard Set(arguments.keys) == ["file", "name"],
              let path = arguments["file"], let name = arguments["name"] else {
            return .failure(code: "invalid_arguments", message: "Profile import requires file and name arguments.")
        }
        let candidate = try profileStore.prepareImportCandidate(from: URL(fileURLWithPath: path))
        let profile = try profileStore.importCandidate(candidate, name: name)
        return .success(.object([
            "id": .string(profile.id.uuidString.lowercased()),
            "name": .string(profile.name),
            "revision": .integer(profile.validRevision),
            "selected": .boolean((try profileStore.selectedProfileID()) == profile.id),
            "valid": .boolean(profile.validation.status == .valid)
        ]))
    }

    private func profileSubscribe(_ arguments: [String: String]) async throws -> AutomationResponse {
        guard Set(arguments.keys) == ["name", "url", "confirm"],
              arguments["confirm"] == "true", let name = arguments["name"],
              let rawURL = arguments["url"], let url = URL(string: rawURL) else {
            return .failure(code: "subscription_confirmation_required", message: "Subscription creation requires an explicit confirmation and a valid URL.")
        }
        let pending = try await subscriptionOperations.prepareNew(name: name, url: url)
        let profile = try subscriptionOperations.commit(pending)
        return try subscriptionResult(profile: profile, pending: pending)
    }

    private func profileSubscriptionUpdate(_ arguments: [String: String]) async throws -> AutomationResponse {
        guard Set(arguments.keys) == ["id", "confirm"], let idText = arguments["id"],
              arguments["confirm"] == idText, let id = UUID(uuidString: idText) else {
            return .failure(code: "subscription_confirmation_required", message: "Subscription update requires confirmation with the Profile ID.")
        }
        let prepared = try await subscriptionOperations.prepareUpdate(profileID: id)
        guard let pending = prepared.candidate else {
            let profile = try subscriptionOperations.commitNotModified(prepared)
            return .success(.object([
                "formatVersion": .integer(1), "profileID": .string(profile.id.uuidString.lowercased()),
                "name": .string(profile.name), "revision": .integer(profile.validRevision),
                "notModified": .boolean(true), "selected": .boolean((try profileStore.selectedProfileID()) == profile.id),
                "valid": .boolean(profile.validation.status == .valid)
            ]))
        }
        let profile = try subscriptionOperations.commit(pending)
        return try subscriptionResult(profile: profile, pending: pending)
    }

    private func subscriptionResult(profile: Profile, pending: PendingSubscriptionIntake) throws -> AutomationResponse {
        let summary = pending.normalization.summary
        return .success(.object([
            "formatVersion": .integer(1),
            "profileID": .string(profile.id.uuidString.lowercased()),
            "name": .string(profile.name),
            "revision": .integer(profile.validRevision),
            "detectedFormat": .string(summary.format.rawValue),
            "nodeCount": .integer(summary.nodeCount),
            "totalNodeCount": .integer(summary.totalNodeCount),
            "skippedNodeCount": .integer(summary.skippedNodeCount),
            "skippedTLSVerificationNodeCount": .integer(summary.skippedTLSVerificationNodeCount),
            "skippedProtocols": .array(summary.skippedProtocols.map { .string($0.rawValue) }),
            "protocols": .array(summary.protocols.map { .string($0.rawValue) }),
            "compatibilityWarnings": .array(summary.warnings.map { .string($0.rawValue) }),
            "selected": .boolean((try profileStore.selectedProfileID()) == profile.id),
            "valid": .boolean(profile.validation.status == .valid)
        ]))
    }

    private func profileList() throws -> AutomationResponse {
        let selected = try profileStore.selectedProfileID()
        let profiles = try profileStore.listProfiles().map { profile in
            JSONValue.object([
                "id": .string(profile.id.uuidString.lowercased()),
                "name": .string(profile.name),
                "revision": .integer(profile.validRevision),
                "selected": .boolean(profile.id == selected),
                "valid": .boolean(profile.validation.status == .valid)
            ])
        }
        return .success(.object(["profiles": .array(profiles)]))
    }

    private func policyList() async throws -> AutomationResponse {
        .success(try await policyOperations.read().automationJSON())
    }

    private func policySelect(_ arguments: [String: String]) async throws -> AutomationResponse {
        guard Set(arguments.keys) == ["selector", "outbound"],
              let selectorTag = arguments["selector"], !selectorTag.isEmpty,
              let outboundTag = arguments["outbound"], !outboundTag.isEmpty else {
            return .failure(
                code: "invalid_arguments",
                message: "Policy selection requires selector and outbound arguments."
            )
        }
        let catalog = try await policyOperations.select(
            selectorTag: selectorTag,
            outboundTag: outboundTag
        )
        guard let selector = catalog.selectors.first(where: { $0.tag == selectorTag }) else {
            return .failure(code: "operation_failed", message: "The operation could not be completed.")
        }
        return .success(.object([
            "desiredSelection": selector.effectiveDesired.map(JSONValue.string) ?? .null,
            "formatVersion": .integer(1),
            "profileID": catalog.profileID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "profileRevision": catalog.profileRevision.map(JSONValue.integer) ?? .null,
            "restartRequired": .boolean(selector.restartRequired),
            "runningSelection": selector.runningSelection.map(JSONValue.string) ?? .null,
            "runtimeConvergence": .string(selector.runtimeConvergence.rawValue),
            "selector": .string(selectorTag)
        ]))
    }

    private func policyReset() async throws -> AutomationResponse {
        let result = try await policyOperations.reset()
        let catalog = result.catalog
        return .success(.object([
            "catalog": catalog.automationJSON(),
            "clearedOverrideCount": .integer(result.clearedOverrideCount),
            "formatVersion": .integer(1),
            "profileID": catalog.profileID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "profileRevision": catalog.profileRevision.map(JSONValue.integer) ?? .null,
            "restartRequired": .boolean(catalog.selectors.contains(where: \.restartRequired))
        ]))
    }

    private func policyProbe(_ arguments: [String: String]) async throws -> AutomationResponse {
        guard Set(arguments.keys) == ["selector"],
              let selectorTag = arguments["selector"], !selectorTag.isEmpty else {
            return .failure(
                code: "invalid_arguments",
                message: "Policy latency probing requires a selector argument."
            )
        }
        return .success(try await policyOperations.probeLatency(selectorTag: selectorTag).automationJSON())
    }

    private func profileDelete(_ arguments: [String: String]) throws -> AutomationResponse {
        guard Set(arguments.keys) == ["id", "confirm"],
              let idText = arguments["id"], arguments["confirm"] == idText,
              let id = UUID(uuidString: idText) else {
            return .failure(code: "confirmation_required", message: "Profile deletion requires an exact identifier confirmation.")
        }
        try profileStore.delete(id)
        return .success(.object(["deleted": .boolean(true), "id": .string(id.uuidString.lowercased())]))
    }

    private func engineStatus() async -> AutomationResponse {
        do { return engineResult(try await backend.queryStatus()) }
        catch let error as BackendError { return backendFailure(error) }
        catch { return .failure(code: "engine_unavailable", message: "Engine status is unavailable.") }
    }

    private func runtimeStatus() async -> AutomationResponse {
        let observation = await runtimeObservationOperations.read()
        return .success(observation.automationJSON())
    }

    private func engineStart() async throws -> AutomationResponse {
        let result = try await runtimeOperations.startEngine()
        await engineStatusObserver?(result.engineStatus)
        await observeSystemProxyStatus(result.systemProxyStatus)
        return engineResult(result.engineStatus)
    }

    private func engineStop() async throws -> AutomationResponse {
        let result = try await runtimeOperations.stopEngineSafely()
        await engineStatusObserver?(result.engineStatus)
        await observeSystemProxyStatus(result.systemProxyStatus)
        return engineResult(result.engineStatus)
    }

    private func engineResult(_ status: BackendStatus) -> AutomationResponse {
        .success(.object([
            "engineInstallation": .string(status.engineInstallation.rawValue),
            "engineState": .string(status.engineState.rawValue),
            "restartRequired": .boolean(status.restartRequired),
            "selectedValidProfile": .boolean(status.hasSelectedValidProfile)
        ]))
    }

    private func serviceStatus() -> AutomationResponse {
        .success(.object(["serviceState": .string(TargetServiceRegistration.status.rawValue)]))
    }

    private func serviceInstall() throws -> AutomationResponse {
        try TargetServiceRegistration.register()
        return serviceStatus()
    }

    private func servicePing() async -> AutomationResponse {
        do {
            _ = try await serviceClient.ping()
            return .success(.object(["xpcState": .string("connected")]))
        } catch {
            return .failure(code: "xpc_unavailable", message: "The privileged service is unavailable.")
        }
    }

    private func serviceRemove() throws -> AutomationResponse {
        try TargetServiceRegistration.unregister()
        return serviceStatus()
    }

    private func proxyStatus() async -> AutomationResponse {
        let read = await systemProxyStatusRead()
        await observeSystemProxyStatus(read.status)
        return proxyResult(read)
    }

    private func proxyAction(_ operation: () async throws -> SystemProxyStatus) async throws -> AutomationResponse {
        do {
            let status = try await operation()
            await observeSystemProxyStatus(status)
            return proxyResult(SystemProxyStatusRead(status: status, isAuthoritative: true))
        } catch let error as TargetSystemProxyOperationError {
            await observeSystemProxyStatus(error.reconciledStatus)
            throw error
        }
    }

    private func observeSystemProxyStatus(_ status: SystemProxyStatus?) async {
        if let status { await systemProxyStatusObserver?(status) }
    }

    private func systemProxyStatusRead() async -> SystemProxyStatusRead {
        do {
            return SystemProxyStatusRead(
                status: try await systemProxyOperations.queryStatus(),
                isAuthoritative: true
            )
        } catch let error as TargetSystemProxyOperationError {
            return SystemProxyStatusRead(status: error.reconciledStatus, isAuthoritative: false)
        } catch {
            return SystemProxyStatusRead(status: nil, isAuthoritative: false)
        }
    }

    private func proxyResult(_ read: SystemProxyStatusRead) -> AutomationResponse {
        let capability = read.status?.recoveryCapability(
            hostNetworkSafetyMode: hostNetworkSafetyMode,
            isOperationInProgress: false
        )
        return .success(.object([
            "affectedServiceCount": .integer(read.status?.affectedServiceCount ?? 0),
            "engineReachable": .boolean(read.status?.engineReachable ?? false),
            "hasRecoverySnapshot": .boolean(read.status?.hasRecoverySnapshot ?? false),
            "recoveryAvailable": .boolean(capability?.isAvailable ?? false),
            "recoveryBlocker": capability.map {
                $0.blocker.map { .string($0.rawValue) } ?? .null
            } ?? .string(SystemProxyRecoveryBlocker.statusUnavailable.rawValue),
            "recoveryRequired": .boolean(read.status?.state == .recoveryRequired),
            "statusAuthoritative": .boolean(read.isAuthoritative),
            "systemProxyState": .string(read.status?.state.rawValue ?? "unavailable")
        ]))
    }

    func serviceFailure(_ code: Int) -> AutomationResponse {
        let stableCode: String
        switch code {
        case 100: stableCode = "proxy_safe_mode_blocked"
        case 101: stableCode = "proxy_conflict"
        case 102: stableCode = "proxy_no_active_service"
        case 103: stableCode = "proxy_engine_unavailable"
        case 104: stableCode = "proxy_snapshot_failed"
        case 105: stableCode = "proxy_snapshot_owner_invalid"
        case 106: stableCode = "proxy_external_change_conflict"
        case 107: stableCode = "proxy_apply_failed"
        case 108: stableCode = "proxy_verification_failed"
        case 109: stableCode = "proxy_recovery_failed"
        case 110: stableCode = "proxy_status_unavailable"
        default: stableCode = "service_operation_failed"
        }
        return .failure(code: stableCode, message: "The privileged service operation failed safely.")
    }

    private func profileTransferFailure(_ error: ProfileTransferError) -> AutomationResponse {
        switch error {
        case .unreadableImport: .failure(code: "profile_file_unreadable", message: "The Profile file cannot be read safely.")
        case .importTooLarge: .failure(code: "profile_file_too_large", message: "The Profile file exceeds the size limit.")
        case .importInvalidUTF8: .failure(code: "profile_invalid_utf8", message: "The Profile file is not valid UTF-8.")
        case .importInvalidJSON: .failure(code: "profile_invalid_json", message: "The Profile file is not valid JSON.")
        case .importValidationFailed: .failure(code: "profile_validation_failed", message: "The Profile failed sing-box validation.")
        case .unsafeExportDestination, .exportFailed, .exportCleanupFailed:
            .failure(code: "operation_failed", message: "The operation could not be completed.")
        }
    }

    private func subscriptionFailure(_ error: SubscriptionUpdateError) -> AutomationResponse {
        switch error {
        case .noSubscription:
            .failure(code: "subscription_not_configured", message: "The Profile has no subscription source.")
        case .unsafeURL, .unsafeRedirect:
            .failure(code: "invalid_subscription_url", message: "Only public HTTPS subscription URLs are allowed.")
        case .responseTooLarge:
            .failure(code: "subscription_payload_invalid", message: "The subscription response exceeds the safe limit.")
        case .cancelled:
            .failure(code: "subscription_fetch_failed", message: "The subscription request was cancelled.")
        case .timedOut, .invalidResponse, .httpStatus, .transportFailure, .transport:
            .failure(code: "subscription_fetch_failed", message: "The subscription could not be downloaded safely.")
        }
    }

    private func subscriptionIntakeFailure(_ error: SubscriptionIntakeError) -> AutomationResponse {
        switch error {
        case .formatUnsupported:
            .failure(code: "subscription_format_unsupported", message: "The subscription format is not supported.")
        case .webPageReturned:
            .failure(code: "subscription_web_page_returned", message: "The server returned a web page instead of a subscription.")
        case .protocolUnsupported:
            .failure(code: "subscription_protocol_unsupported", message: "The subscription contains an unsupported protocol.")
        case .variantUnsupported:
            .failure(code: "subscription_variant_unsupported", message: "The subscription contains an unsupported protocol variant.")
        case .validationFailed:
            .failure(code: "subscription_validation_failed", message: "The normalized Profile failed sing-box validation.")
        case .emptyPayload, .invalidUTF8, .payloadInvalid, .complexityLimitExceeded:
            .failure(code: "subscription_payload_invalid", message: "The subscription payload is invalid or exceeds safe limits.")
        }
    }

    private func policyFailure(_ error: TargetPolicyOperationError) -> AutomationResponse {
        switch error {
        case .selectorNotFound:
            .failure(code: "policy_selector_not_found", message: "The Policy selector was not found.")
        case .selectorAmbiguous:
            .failure(code: "policy_selector_ambiguous", message: "The Policy selector tag is ambiguous.")
        case .selectorUnavailable:
            .failure(code: "policy_selector_unavailable", message: "The Policy selector is structurally unavailable.")
        case .outboundNotFound:
            .failure(code: "policy_outbound_not_found", message: "The Policy outbound was not found.")
        case .outboundUnavailable:
            .failure(code: "policy_outbound_unavailable", message: "The Policy outbound is unavailable.")
        case .persistenceFailed:
            .failure(code: "policy_persistence_failed", message: "The Policy change could not be persisted.")
        }
    }

    func profileStoreFailure(_ error: ProfileStoreError) -> AutomationResponse {
        switch error {
        case .profileNotFound: .failure(code: "profile_not_found", message: "The Profile was not found.")
        case .profileInUse: .failure(code: "profile_in_use", message: "Stop the engine before deleting this Profile.")
        case .invalidName: .failure(code: "invalid_profile_name", message: "A valid Profile name is required.")
        case .noSelectedProfile: .failure(code: "profile_not_selected", message: "No valid Profile is selected.")
        case .noValidVersion: .failure(code: "profile_no_valid_version", message: "The selected Profile has no valid revision.")
        case .keychainReadFailed: .failure(code: "profile_keychain_unavailable", message: "The Profile encryption key is unavailable.")
        case .encryptedStoreKeyMissing: .failure(code: "profile_keychain_key_missing", message: "The Profile encryption key is missing.")
        case .invalidEncryptionKey, .invalidEncryptedEnvelope, .unsupportedStorageVersion,
             .encryptedStorageAuthenticationFailed, .encryptedStorageAADMismatch:
            .failure(code: "profile_store_authentication_failed", message: "Profile storage authentication failed.")
        case .invalidStoredMetadata, .invalidStoredSelection, .mixedOrDowngradedStorage, .missingEncryptedRecord:
            .failure(code: "profile_store_invalid", message: "Profile storage is structurally invalid.")
        default: .failure(code: "profile_store_unavailable", message: "Profile storage could not be loaded safely.")
        }
    }

    func backendFailure(_ error: BackendError) -> AutomationResponse {
        switch error {
        case .serviceNotInstalled: .failure(code: "service_not_installed", message: "The privileged service is not installed.")
        case .serviceRegistrationFailed: .failure(code: "service_registration_failed", message: "The privileged service registration failed.")
        case .serviceUnavailable: .failure(code: "service_unavailable", message: "The backend service is unavailable.")
        case .engineNotInstalled: .failure(code: "engine_not_installed", message: "The Target engine is not installed.")
        case .engineInstallationFailed: .failure(code: "engine_installation_failed", message: "The Target engine installation failed.")
        case .configurationCheckFailed: .failure(code: "configuration_check_failed", message: "The selected Profile failed the installed engine check.")
        case .engineLaunchFailed: .failure(code: "engine_launch_failed", message: "The Target engine could not be launched.")
        case .enginePortUnavailable: .failure(code: "engine_port_unavailable", message: "A dynamic local engine port is unavailable.")
        case .profileNotSelected: .failure(code: "profile_not_selected", message: "No valid Profile is selected.")
        case .profileNoValidVersion: .failure(code: "profile_no_valid_version", message: "The selected Profile has no valid revision.")
        case .profileConfigurationUnsafe: .failure(code: "profile_configuration_unsafe", message: "The selected Profile is outside the user-mode safety boundary.")
        case .profileConfigurationInvalid: .failure(code: "profile_configuration_invalid", message: "The selected Profile cannot be prepared for the engine.")
        case .invalidLifecycleTransition: .failure(code: "invalid_engine_state", message: "The engine cannot perform that transition.")
        case .operationCancelled: .failure(code: "operation_cancelled", message: "The operation was cancelled.")
        case .invalidConfiguration, .notImplemented:
            .failure(code: "backend_operation_failed", message: "The backend operation failed.")
        }
    }

    private static let commands = [
        "capabilities", "status", "runtime.status", "profile.import", "profile.subscribe", "profile.subscription-update", "profile.list", "profile.delete", "policy.list", "policy.select", "policy.probe", "policy.reset",
        "engine.status", "engine.start", "engine.stop", "service.status", "service.install",
        "service.ping", "service.remove", "proxy.status", "proxy.enable", "proxy.disable", "proxy.recover"
    ]
    private static let argumentFreeActions = Set(commands).subtracting([
        "profile.import", "profile.subscribe", "profile.subscription-update", "profile.delete", "policy.select", "policy.probe"
    ])
}
