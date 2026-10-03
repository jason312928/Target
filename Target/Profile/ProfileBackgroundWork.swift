import Foundation

/// Cancellation can prevent a queued operation. Once a disk transaction starts,
/// it completes or rolls back before its result returns to the main actor.
enum ProfileBackgroundWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try work()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct ProfileStoreSnapshot: Sendable {
    let profiles: [Profile]
    let selectedID: UUID?
    let configuration: String?
    let catalogs: [UUID: PolicyCatalog]
}
