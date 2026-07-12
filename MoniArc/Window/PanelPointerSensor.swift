import Foundation

@MainActor
final class PanelPointerSensor: PointerSensor {
    private var continuation: AsyncStream<Bool>.Continuation?
    private var latestValue = false
    private var isStarted = false

    func hoverEvents() async -> AsyncStream<Bool> {
        continuation?.finish()
        let pair = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(2))
        continuation = pair.continuation
        pair.continuation.yield(latestValue)
        return pair.stream
    }

    func start() async {
        isStarted = true
        continuation?.yield(latestValue)
    }

    func stop() async {
        isStarted = false
    }

    func emit(_ isInside: Bool) {
        guard isInside != latestValue else { return }
        latestValue = isInside
        if isStarted {
            continuation?.yield(isInside)
        }
    }
}
