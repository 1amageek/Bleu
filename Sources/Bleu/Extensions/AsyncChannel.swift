import Foundation

/// A channel for sending values asynchronously between actors
public actor AsyncChannel<Element: Sendable> {
    private var buffer: [Element] = []
    private var continuations: [CheckedContinuation<Element?, Never>] = []
    private var isFinished = false
    
    /// Send an element to the channel
    public func send(_ element: Element) {
        guard !isFinished else { return }
        
        if !continuations.isEmpty {
            let continuation = continuations.removeFirst()
            continuation.resume(returning: element)
        } else {
            buffer.append(element)
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
    }
    
    /// Create an AsyncStream from this channel
    public nonisolated var stream: AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let element = await self.next()
                    if let element = element {
                        continuation.yield(element)
                    } else {
                        continuation.finish()
                        break
                    }
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
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

/// A bounded version of AsyncChannel with maximum capacity
public actor BoundedAsyncChannel<Element: Sendable> {
    private let capacity: Int
    private var buffer: [Element] = []
    private var sendContinuations: [CheckedContinuation<Void, Never>] = []
    private var receiveContinuations: [CheckedContinuation<Element?, Never>] = []
    private var isFinished = false
    
    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be greater than 0")
        self.capacity = capacity
    }
    
    /// Send an element to the channel, waiting if at capacity
    public func send(_ element: Element) async {
        guard !isFinished else { return }
        
        // If there's a waiting receiver, deliver directly
        if !receiveContinuations.isEmpty {
            let continuation = receiveContinuations.removeFirst()
            continuation.resume(returning: element)
            return
        }
        
        // If buffer is at capacity, wait
        while buffer.count >= capacity && !isFinished {
            await withCheckedContinuation { continuation in
                sendContinuations.append(continuation)
            }
        }
        
        guard !isFinished else { return }
        buffer.append(element)
        
        // Wake up a waiting receiver if any
        if !receiveContinuations.isEmpty {
            let continuation = receiveContinuations.removeFirst()
            let element = buffer.removeFirst()
            continuation.resume(returning: element)
            
            // Wake up a waiting sender if any
            if !sendContinuations.isEmpty {
                let sendContinuation = sendContinuations.removeFirst()
                sendContinuation.resume()
            }
        }
    }
    
    /// Try to send an element without waiting
    public func trySend(_ element: Element) -> Bool {
        guard !isFinished else { return false }
        
        if !receiveContinuations.isEmpty {
            let continuation = receiveContinuations.removeFirst()
            continuation.resume(returning: element)
            return true
        }
        
        if buffer.count < capacity {
            buffer.append(element)
            return true
        }
        
        return false
    }
    
    /// Receive an element from the channel
    public func receive() async -> Element? {
        if !buffer.isEmpty {
            let element = buffer.removeFirst()
            
            // Wake up a waiting sender if any
            if !sendContinuations.isEmpty {
                let continuation = sendContinuations.removeFirst()
                continuation.resume()
            }
            
            return element
        }
        
        if isFinished {
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }
    
    /// Finish the channel
    public func finish() {
        guard !isFinished else { return }
        isFinished = true
        
        // Resume all waiting receivers with nil
        for continuation in receiveContinuations {
            continuation.resume(returning: nil)
        }
        receiveContinuations.removeAll()
        
        // Resume all waiting senders
        for continuation in sendContinuations {
            continuation.resume()
        }
        sendContinuations.removeAll()
    }
    
    /// Create an AsyncStream from this channel
    public nonisolated var stream: AsyncStream<Element> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let element = await self.receive()
                    if let element = element {
                        continuation.yield(element)
                    } else {
                        continuation.finish()
                        break
                    }
                }
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}