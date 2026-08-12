import Darwin
import Foundation

actor SingBoxBackend: EngineInstalling, PolicyRuntimeEvidenceProviding, RuntimeControlDescriptorProviding, RuntimePolicyApplying, RuntimeObservationProviding {
    static let applicationSupportDirectoryName = "Target"
    static let engineDirectoryName = "sing-box"

    private var process: Process?
    private var logHandle: FileHandle?
    private let portProbe: any LocalEnginePortProbing
    private let portSelector: any LocalEnginePortSelecting
    private let runtimeOwnership: EngineRuntimeOwnership
    private let profileStore: ProfileStore
    private let runtimeConfigurations: RuntimeConfigurationStore
    private let readinessTimeout: Duration
    private let executableURL: URL
    private let logURL: URL
    private let runtimeControlClient: any RuntimeControlClient

    init(
        portProbe: any LocalEnginePortProbing = LocalTCPPortProbe(),
        portSelector: any LocalEnginePortSelecting = DynamicHighLocalPortSelector(),
        runtimeOwnership: EngineRuntimeOwnership = EngineRuntimeOwnership(),
        profileStore: ProfileStore = ProfileStore(),
        engineDirectory: URL? = nil,
        executableURL: URL? = nil,
        readinessTimeout: Duration = .seconds(3),
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
        self.logURL = resolvedDirectory.appending(path: "logs/sing-box.log")
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
                try? logHandle?.close()
                logHandle = nil
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

    func applyLivePolicySelection(selectorTag: String, outboundTag: String) async -> Bool {
        guard let descriptor = await verifiedRuntimeControlDescriptor() else { return false }
        do {
            try await runtimeControlClient.select(selector: selectorTag, outbound: outboundTag, using: descriptor)
            let selectors = try await runtimeControlClient.selectors(using: descriptor)
            return selectors[selectorTag]?.selected == outboundTag
        } catch {
            return false
        }
    }

    func currentRuntimeConnectionTotals() async -> RuntimeConnectionTotals? {
        guard let descriptor = await verifiedRuntimeControlDescriptor() else { return nil }
        return try? await runtimeControlClient.connectionTotals(using: descriptor)
    }

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
        var handle: FileHandle?
        do {
            try checkConfiguration(at: temporary.url)
            try Task.checkCancellation()
            let openedLogHandle = try openLog()
            handle = openedLogHandle
            let candidate = makeEngineProcess(configurationURL: temporary.url, logHandle: openedLogHandle)
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
                runtimeConfigurationID: temporary.id
            )
            try Task.checkCancellation()
            guard try await waitForPortReadiness(for: candidate) else {
                throw EngineRuntimeReadiness.startupFailure(processStillRunning: candidate.isRunning)
            }
            try Task.checkCancellation()
            process = candidate
            logHandle = openedLogHandle
            return try await queryStatus()
        } catch is CancellationError {
            await cleanupFailedLaunch(process: launched, logHandle: handle, configurationID: temporary.id)
            throw CancellationError()
        } catch let error as BackendError {
            await cleanupFailedLaunch(process: launched, logHandle: handle, configurationID: temporary.id)
            throw error
        } catch {
            await cleanupFailedLaunch(process: launched, logHandle: handle, configurationID: temporary.id)
            throw BackendError.engineLaunchFailed
        }
    }

    func stopEngine() async throws -> BackendStatus {
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
        try? logHandle?.close()
        logHandle = nil
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

    private func makeEngineProcess(configurationURL: URL, logHandle: FileHandle) -> Process {
        let launched = Process()
        launched.executableURL = executableURL
        launched.arguments = ["run", "-c", configurationURL.path]
        let pipe = Pipe()
        launched.standardOutput = pipe
        launched.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak logHandle] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            try? logHandle?.write(contentsOf: EngineLogRedactor.redact(data))
        }
        launched.terminationHandler = { _ in pipe.fileHandleForReading.readabilityHandler = nil }
        return launched
    }

    private func openLog() throws -> FileHandle {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }

    private func cleanupFailedLaunch(process: Process?, logHandle: FileHandle?, configurationID: UUID) async {
        if let process { _ = await stopOwnedProcess(process) }
        runtimeOwnership.clearRecord()
        runtimeConfigurations.remove(id: configurationID)
        try? logHandle?.close()
        self.process = nil
        self.logHandle = nil
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
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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
        try? logHandle?.close()
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

enum EngineRuntimeProfileState {
    static func requiresRestart(record: EngineRuntimeRecord, selected: ProfileConfigurationVersion?) -> Bool {
        guard let selected else { return true }
        return record.profileID != selected.profile.id || record.profileRevision != selected.revision
            || record.sourceConfigurationFingerprint != TargetConfigurationFingerprint.sha256(selected.data)
    }
}

enum EngineLogRedactor {
    private static let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    private static let ipv6 = try! NSRegularExpression(pattern: #"(?i)[0-9a-f:]*:[0-9a-f:]+"#)
    private static let userPath = try! NSRegularExpression(pattern: #"/Users/[^\s]+"#)
    private static let credentialURL = try! NSRegularExpression(pattern: #"://[^\s/@:]+:[^\s/@]+@"#)
    private static let uuid = try! NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#)
    private static let sensitiveJSON = try! NSRegularExpression(pattern: #"(?i)(\"(?:password|uuid|private_key|private-key|token|secret|subscription_url)\"\s*:\s*)\"[^\"]*\""#)
    private static let absolutePath = try! NSRegularExpression(pattern: #"(?<!:)\B/(?:[^\s\"']+/)+[^\s\"']+"#)

    static func redact(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for (expression, replacement) in [(ipv4, "[redacted-ip]"), (ipv6, "[redacted-ip]"), (credentialURL, "://[redacted-credentials]@"), (uuid, "[redacted-uuid]"), (sensitiveJSON, "$1\"[redacted]\""), (userPath, "[redacted-path]"), (absolutePath, "[redacted-path]")] {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return Data(text.utf8)
    }
}
