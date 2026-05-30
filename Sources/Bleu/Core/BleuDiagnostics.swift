import Foundation

/// Stores and streams structured diagnostics for a BLEActorSystem instance.
public actor BleuDiagnostics {
    private let eventChannel = AsyncChannel<BleuDiagnosticEvent>()
    private let maxStoredEvents: Int
    private var storedEvents: [BleuDiagnosticEvent] = []
    private var metrics = BleuDiagnosticMetrics()
    private var isFinished = false

    public init(maxStoredEvents: Int = 1_024) {
        self.maxStoredEvents = maxStoredEvents
    }

    public nonisolated var events: AsyncStream<BleuDiagnosticEvent> {
        eventChannel.stream
    }

    public func record(_ event: BleuDiagnosticEvent) async {
        guard !isFinished else {
            return
        }

        storedEvents.append(event)
        if storedEvents.count > maxStoredEvents {
            storedEvents.removeFirst(storedEvents.count - maxStoredEvents)
        }

        metrics.record(event)
        await eventChannel.send(event)
    }

    public func snapshot() -> [BleuDiagnosticEvent] {
        storedEvents
    }

    public func currentMetrics() -> BleuDiagnosticMetrics {
        metrics
    }

    public func finish() async {
        guard !isFinished else {
            return
        }

        isFinished = true
        await eventChannel.finish()
    }
}
