import Foundation

actor SingBoxBackend: EngineInstalling {
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

    init(
        portProbe: any LocalEnginePortProbing = LocalTCPPortProbe(),
        portSelector: any LocalEnginePortSelecting = DynamicHighLocalPortSelector(),
        runtimeOwnership: EngineRuntimeOwnership = EngineRuntimeOwnership(),
        profileStore: ProfileStore = ProfileStore(),
        engineDirectory: URL? = nil,
        executableURL: URL? = nil,
        readinessTimeout: Duration = .seconds(3)
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
    }

    func queryStatus() async throws -> BackendStatus {
        let installation = installationStatus()
        let version = installation == .installed ? try? versionString() : nil
        let ownedRecord = await runtimeOwnership.ownedRecord()
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
        let restartRequired = verifiedRecord.map { EngineRuntimeProfileState.requiresRestart(record: $0, selected: selected) } ?? false
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
        guard await runtimeOwnership.ownedRecord() == nil else { throw BackendError.invalidLifecycleTransition }
        guard installationStatus() == .installed else { throw BackendError.engineNotInstalled }
        runtimeOwnership.clearRecord()
        runtimeConfigurations.removeAll()

        let prepared = try prepareSelectedConfiguration()
        let temporary = try runtimeConfigurations.write(prepared.data)
        var launched: Process?
        var handle: FileHandle?
        do {
            try checkConfiguration(at: temporary.url)
            let openedLogHandle = try openLog()
            handle = openedLogHandle
            let candidate = makeEngineProcess(configurationURL: temporary.url, logHandle: openedLogHandle)
            try candidate.run()
            launched = candidate
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
            guard await waitForPortReadiness(for: candidate) else {
                throw EngineRuntimeReadiness.startupFailure(processStillRunning: candidate.isRunning)
            }
            process = candidate
            logHandle = openedLogHandle
            return try await queryStatus()
        } catch let error as BackendError {
            cleanupFailedLaunch(process: launched, logHandle: handle, configurationID: temporary.id)
            throw error
        } catch {
            cleanupFailedLaunch(process: launched, logHandle: handle, configurationID: temporary.id)
            throw BackendError.engineLaunchFailed
        }
    }

    func stopEngine() async throws -> BackendStatus {
        guard let record = runtimeOwnership.currentRecord(), runtimeOwnership.ownsProcess(record) else {
            runtimeOwnership.clearRecord()
            throw BackendError.invalidLifecycleTransition
        }
        if let process, process.processIdentifier == record.pid, process.isRunning {
            stopOwnedProcess(process)
        } else {
            kill(pid_t(record.pid), SIGTERM)
        }
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
            case .invalidJSON, .noLoopbackMixedInbound, .invalidPort: throw BackendError.profileConfigurationInvalid
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

    private func cleanupFailedLaunch(process: Process?, logHandle: FileHandle?, configurationID: UUID) {
        if let process { stopOwnedProcess(process) }
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

    private func waitForPortReadiness(for process: Process) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + readinessTimeout
        while process.isRunning && clock.now < deadline {
            guard let record = await runtimeOwnership.ownedRecord() else { return false }
            if await portProbe.isListening(on: record.endpoint.port) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let record = await runtimeOwnership.ownedRecord() else { return false }
        return process.isRunning ? await portProbe.isListening(on: record.endpoint.port) : false
    }

    private func stopOwnedProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
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
