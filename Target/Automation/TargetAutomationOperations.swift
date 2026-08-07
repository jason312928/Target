import Foundation

actor TargetAutomationOperations {
    private let profileStore: ProfileStore
    private let backend: any EngineBackend
    private let serviceClient: any SystemProxyClient
    private let runtimeOperations: any TargetRuntimeOperating
    private let engineStatusObserver: (@Sendable (BackendStatus) async -> Void)?

    init(
        profileStore: ProfileStore = ProfileStore(),
        backend: any EngineBackend = SingBoxBackend(),
        serviceClient: any SystemProxyClient = TargetServiceXPCClient(),
        runtimeOperations: (any TargetRuntimeOperating)? = nil,
        engineStatusObserver: (@Sendable (BackendStatus) async -> Void)? = nil
    ) {
        self.profileStore = profileStore
        self.backend = backend
        self.serviceClient = serviceClient
        self.runtimeOperations = runtimeOperations ?? TargetRuntimeOperations(
            backend: backend,
            systemProxyClient: serviceClient
        )
        self.engineStatusObserver = engineStatusObserver
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
            case "profile.import": return try profileImport(request.arguments)
            case "profile.list": return try profileList()
            case "profile.delete": return try profileDelete(request.arguments)
            case "engine.status": return await engineStatus()
            case "engine.start": return try await engineStart()
            case "engine.stop": return try await engineStop()
            case "service.status": return serviceStatus()
            case "service.install": return try serviceInstall()
            case "service.ping": return await servicePing()
            case "service.remove": return try serviceRemove()
            case "proxy.status": return await proxyStatus()
            case "proxy.enable": return try await proxyAction(serviceClient.enableSystemProxy)
            case "proxy.disable": return try await proxyAction(serviceClient.disableSystemProxy)
            case "proxy.recover": return try await proxyAction(serviceClient.recoverSystemProxy)
            default: return .failure(code: "unknown_action", message: "The requested action is not supported.")
            }
        } catch let error as ProfileTransferError {
            return profileTransferFailure(error)
        } catch let error as ProfileStoreError {
            return profileStoreFailure(error)
        } catch let error as BackendError {
            return backendFailure(error)
        } catch let error as SystemProxyError {
            return serviceFailure(xpcError(error).code)
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
        let proxy = service == .enabled ? try? await serviceClient.querySystemProxyStatus() : nil
        let selectedValid = (try? profileStore.selectedValidVersion()) != nil
        return .success(.object([
            "buildChannel": .string(Bundle.main.object(forInfoDictionaryKey: "TargetBuildChannel") as? String ?? "unknown"),
            "engineState": .string(engine?.engineState.rawValue ?? "unknown"),
            "hostSafety": .string(TargetValidationPolicy.isHostSafeMode ? "safe" : "authorizedValidation"),
            "recoveryRequired": .boolean(proxy?.state == .recoveryRequired),
            "selectedValidProfile": .boolean(selectedValid),
            "serviceState": .string(service.rawValue),
            "sourceSHA": .string(Bundle.main.object(forInfoDictionaryKey: "TargetSourceCommit") as? String ?? "unknown"),
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

    private func engineStart() async throws -> AutomationResponse {
        let status = try await backend.startEngine()
        await engineStatusObserver?(status)
        return engineResult(status)
    }

    private func engineStop() async throws -> AutomationResponse {
        let result = try await runtimeOperations.stopEngineSafely()
        await engineStatusObserver?(result.engineStatus)
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
        do { return proxyResult(try await serviceClient.querySystemProxyStatus()) }
        catch { return .failure(code: "xpc_unavailable", message: "System proxy status is unavailable.") }
    }

    private func proxyAction(_ operation: () async throws -> SystemProxyStatus) async throws -> AutomationResponse {
        proxyResult(try await operation())
    }

    private func proxyResult(_ status: SystemProxyStatus) -> AutomationResponse {
        .success(.object([
            "affectedServiceCount": .integer(status.affectedServiceCount),
            "engineReachable": .boolean(status.engineReachable),
            "recoveryRequired": .boolean(status.state == .recoveryRequired),
            "systemProxyState": .string(status.state.rawValue)
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
        "capabilities", "status", "profile.import", "profile.list", "profile.delete",
        "engine.status", "engine.start", "engine.stop", "service.status", "service.install",
        "service.ping", "service.remove", "proxy.status", "proxy.enable", "proxy.disable", "proxy.recover"
    ]
    private static let argumentFreeActions = Set(commands.filter { !$0.hasPrefix("profile.") })
}
