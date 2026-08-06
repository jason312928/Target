import Foundation

/// ProfileStore's default is not used by the fixture, which explicitly injects
/// PresentationFixtureRuntimeUsage. This target-local compatibility symbol keeps
/// the real storage source free of engine, service, and host-network dependencies.
protocol ProfileRuntimeUsageChecking: Sendable {
    func isProfileInUse(_ id: UUID) -> Bool
}

struct EngineRuntimeOwnership: ProfileRuntimeUsageChecking {
    func isProfileInUse(_ id: UUID) -> Bool { false }
}
