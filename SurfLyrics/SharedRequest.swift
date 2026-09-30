import Foundation

/// Shares one operation until it completes or its last caller cancels.
@MainActor
final class SharedRequest<Value: Sendable> {
    private var task: Task<Value?, Never>?
    private var generation: UInt64 = 0
    private var waiters: Set<UUID> = []

    var isRunning: Bool { task != nil }

    func value(loader: @escaping @MainActor () async -> Value?) async -> Value? {
        guard !Task.isCancelled else { return nil }
        if task == nil {
            generation &+= 1
            task = Task { await loader() }
        }
        guard let task else { return nil }
        let requestedGeneration = generation
        let waiter = UUID()
        waiters.insert(waiter)

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(waiter, generation: requestedGeneration)
            }
        }
        release(waiter, generation: requestedGeneration)
        return Task.isCancelled ? nil : result
    }

    private func release(_ waiter: UUID, generation requestedGeneration: UInt64) {
        guard generation == requestedGeneration, waiters.remove(waiter) != nil else { return }
        if waiters.isEmpty {
            task?.cancel()
            task = nil
        }
    }
}
