import Foundation
import NetworkExtension
import Observation
import SwiftUI

@MainActor
@Observable
final class TunnelLifecycleModel {
    private static let providerBundleIdentifier = "com.jason312928.Target.PacketTunnel"

    private var manager: NETunnelProviderManager?
    private(set) var state: TunnelLifecycleState = .stopped

    var canToggle: Bool {
        state == .stopped || state == .running || state == .unavailable
    }

    var statusKey: LocalizedStringKey { state.statusKey }
    var detailKey: LocalizedStringKey { state.detailKey }
    var actionKey: LocalizedStringKey { state == .running ? "connection.action.stop" : "connection.action.start" }
    var symbolName: String { state.symbolName }

    func toggle() {
        state == .running ? stop() : start()
    }

    private func start() {
        guard canToggle else { return }
        state = .starting

        Task {
            do {
                let manager = try await configuredManager()
                try manager.connection.startVPNTunnel()
                state = .running
            } catch {
                state = .unavailable
            }
        }
    }

    private func stop() {
        guard state == .running else { return }
        state = .stopping
        manager?.connection.stopVPNTunnel()
        state = .stopped
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let selectedManager = managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleIdentifier
        } ?? NETunnelProviderManager()

        if selectedManager.protocolConfiguration == nil {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = Self.providerBundleIdentifier
            configuration.serverAddress = "Target"
            selectedManager.protocolConfiguration = configuration
            selectedManager.localizedDescription = "Target"
            selectedManager.isEnabled = true
            try await selectedManager.saveToPreferences()
        }

        try await selectedManager.loadFromPreferences()
        manager = selectedManager
        return selectedManager
    }
}

enum TunnelLifecycleState {
    case stopped
    case starting
    case running
    case stopping
    case unavailable

    var statusKey: LocalizedStringKey {
        switch self {
        case .stopped: "connection.status.stopped"
        case .starting: "connection.status.starting"
        case .running: "connection.status.running"
        case .stopping: "connection.status.stopping"
        case .unavailable: "connection.status.unavailable"
        }
    }

    var detailKey: LocalizedStringKey {
        switch self {
        case .stopped: "connection.detail.ready"
        case .starting: "connection.detail.starting"
        case .running: "connection.detail.running"
        case .stopping: "connection.detail.stopping"
        case .unavailable: "connection.detail.unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .stopped, .unavailable: "bolt.slash"
        case .starting, .stopping: "bolt.circle"
        case .running: "bolt.circle.fill"
        }
    }
}
