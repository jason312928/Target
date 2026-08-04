import Foundation

actor SingBoxBackend: EngineInstalling {
    static let applicationSupportDirectoryName = "Target"
    static let engineDirectoryName = "sing-box"

    private var process: Process?
    private var logHandle: FileHandle?
    private let portProbe: any LocalProxyProbing
    private let readinessTimeout: Duration

    init(portProbe: any LocalProxyProbing = TCPPort2080Probe(), readinessTimeout: Duration = .seconds(3)) {
        self.portProbe = portProbe
        self.readinessTimeout = readinessTimeout
    }

    private var engineDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Self.applicationSupportDirectoryName, directoryHint: .isDirectory)
            .appending(path: Self.engineDirectoryName, directoryHint: .isDirectory)
    }

    private var executableURL: URL { engineDirectory.appending(path: "bin/sing-box") }
    private var configurationURL: URL { engineDirectory.appending(path: "config.json") }
    private var logURL: URL { engineDirectory.appending(path: "logs/sing-box.log") }

    func queryStatus() async throws -> BackendStatus {
        let installation = installationStatus()
        let version = installation == .installed ? try? versionString() : nil
        let processIsRunning = process?.isRunning == true
        let portIsReady = await portProbe.isAvailable()
        let state = EngineRuntimeReadiness.visibleState(processIsRunning: processIsRunning, portIsListening: portIsReady)
        return BackendStatus(
            serviceInstallation: .notRegistered,
            engineState: state,
            engineInstallation: installation,
            engineVersion: version
        )
    }

    func installEngine() async throws -> BackendStatus {
        guard let installerURL = Bundle.main.url(forResource: "install_sing_box", withExtension: "sh") else {
            throw BackendError.engineInstallationFailed
        }
        let installer = Process()
        installer.executableURL = installerURL
        installer.arguments = []
        let result = try run(installer)
        guard result.status == 0 else { throw BackendError.engineInstallationFailed }
        return try await queryStatus()
    }

    func validateConfiguration(_ request: XPCConfigurationRequest) async throws {
        _ = try request.validated()
        guard installationStatus() == .installed else { throw BackendError.engineNotInstalled }
        try createManagedConfiguration()
        let checker = Process()
        checker.executableURL = executableURL
        checker.arguments = ["check", "-c", configurationURL.path]
        let result = try run(checker)
        guard result.status == 0 else { throw BackendError.configurationCheckFailed }
    }

    func startEngine() async throws -> BackendStatus {
        guard process?.isRunning != true else { throw BackendError.invalidLifecycleTransition }
        try await validateConfiguration(XPCConfigurationRequest(profileName: "Local Direct"))

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()

        let launched = Process()
        launched.executableURL = executableURL
        launched.arguments = ["run", "-c", configurationURL.path]
        let pipe = Pipe()
        launched.standardOutput = pipe
        launched.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak logHandle] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let safe = EngineLogRedactor.redact(data)
            try? logHandle?.write(contentsOf: safe)
        }
        launched.terminationHandler = { _ in
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try launched.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle.close()
            throw BackendError.engineLaunchFailed
        }
        process = launched
        self.logHandle = logHandle
        guard await waitForPortReadiness(for: launched) else {
            stopOwnedProcess(launched)
            try? logHandle.close()
            self.logHandle = nil
            process = nil
            throw EngineRuntimeReadiness.startupFailure(processStillRunning: launched.isRunning)
        }
        return try await queryStatus()
    }

    func stopEngine() async throws -> BackendStatus {
        guard let process, process.isRunning else { throw BackendError.invalidLifecycleTransition }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        try? logHandle?.close()
        logHandle = nil
        return try await queryStatus()
    }

    private func installationStatus() -> EngineInstallationState {
        let executable = executableURL.path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return .notInstalled }
        return (try? versionString()) == nil ? .invalid : .installed
    }

    private func versionString() throws -> String {
        let version = Process()
        version.executableURL = executableURL
        version.arguments = ["version"]
        let result = try run(version)
        guard result.status == 0,
              let firstLine = result.output.split(separator: "\n").first,
              firstLine.hasPrefix("sing-box version ") else {
            throw BackendError.engineNotInstalled
        }
        return String(firstLine).replacingOccurrences(of: "sing-box version ", with: "")
    }

    private func createManagedConfiguration() throws {
        try FileManager.default.createDirectory(at: engineDirectory, withIntermediateDirectories: true)
        let configuration: [String: Any] = [
            "log": ["level": "error", "timestamp": true],
            "inbounds": [["type": "mixed", "tag": "local-mixed", "listen": "127.0.0.1", "listen_port": 2080]],
            "outbounds": [["type": "direct", "tag": "direct"]],
            "route": ["final": "direct"]
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configurationURL, options: .atomic)
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
            if await portProbe.isAvailable() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return process.isRunning ? await portProbe.isAvailable() : false
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
    static func visibleState(processIsRunning: Bool, portIsListening: Bool) -> EngineState {
        processIsRunning && portIsListening ? .running : .stopped
    }

    static func startupFailure(processStillRunning: Bool) -> BackendError {
        processStillRunning ? .enginePortUnavailable : .engineLaunchFailed
    }
}

enum EngineLogRedactor {
    private static let ipv4 = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    private static let ipv6 = try! NSRegularExpression(pattern: #"(?i)[0-9a-f:]*:[0-9a-f:]+"#)
    private static let userPath = try! NSRegularExpression(pattern: #"/Users/[^\s]+"#)

    static func redact(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        for (expression, replacement) in [(ipv4, "[redacted-ip]"), (ipv6, "[redacted-ip]"), (userPath, "[redacted-path]")] {
            let range = NSRange(text.startIndex..., in: text)
            text = expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        return Data(text.utf8)
    }
}
