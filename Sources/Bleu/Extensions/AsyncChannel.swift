import Foundation

/// A channel for sending values asynchronously between actors
public actor AsyncChannel<Element: Sendable> {
    private var buffer: [Element] = []
    private var continuations: [CheckedContinuation<Element?, Never>] = []
    private var streamContinuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var terminatedStreamIDs: Set<UUID> = []
    private let maxReplayBufferCount = 1_024
    private var isFinished = false
    
    /// Send an element to the channel
    public func send(_ element: Element) {
        guard !isFinished else { return }
        
        if !streamContinuations.isEmpty {
            buffer.removeAll()

            for continuation in streamContinuations.values {
                continuation.yield(element)
            }
        } else if !continuations.isEmpty {
            let continuation = continuations.removeFirst()
            continuation.resume(returning: element)
        } else {
            appendToReplayBuffer(element)
        }
    }

    private func appendToReplayBuffer(_ element: Element) {
        buffer.append(element)

        if buffer.count > maxReplayBufferCount {
            buffer.removeFirst(buffer.count - maxReplayBufferCount)
        }
    }
    
    /// Send multiple elements to the channel
    public func send<S: Sequence>(contentsOf elements: S) where S.Element == Element {
        for element in elements {
            send(element)
        }
    }
    
    /// Finish the channel, preventing further sends
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        
        // Resume all waiting continuations with nil
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
        continuations.removeAll()

        for continuation in streamContinuations.values {
            continuation.finish()
        }
        streamContinuations.removeAll()
    }
    
    /// Create an AsyncStream from this channel
    public nonisolated var stream: AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.registerStream(id: id, continuation: continuation)
            }

            continuation.onTermination = { _ in
                Task {
                    await self.unregisterStream(id: id)
                }
            }
        }
    }

    private func registerStream(id: UUID, continuation: AsyncStream<Element>.Continuation) {
        if terminatedStreamIDs.remove(id) != nil {
            continuation.finish()
            return
        }

        guard !isFinished else {
            continuation.finish()
            return
        }

        streamContinuations[id] = continuation

        if !buffer.isEmpty {
            for element in buffer {
                continuation.yield(element)
            }
        }
    }

    private func unregisterStream(id: UUID) {
        if streamContinuations.removeValue(forKey: id) == nil {
            terminatedStreamIDs.insert(id)
        }
    }
    
    /// Get the next element from the channel
    private func next() async -> Element? {
        if !buffer.isEmpty {
            return buffer.removeFirst()
        }
        
        if isFinished {
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
    
    /// Check if the channel has buffered elements
    public var hasBufferedElements: Bool {
        !buffer.isEmpty
    }
    
    /// Get the number of buffered elements
    public var bufferCount: Int {
        buffer.count
    }
    
    /// Check if the channel is finished
    public var finished: Bool {
        isFinished
    }
}
