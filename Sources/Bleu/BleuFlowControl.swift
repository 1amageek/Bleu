import Foundation
import CoreBluetooth

// MARK: - Data Flow Control and Backpressure Management

/// Flow control configuration
public struct FlowControlConfiguration: Sendable, Codable {
    /// Maximum number of pending operations per device
    public let maxPendingOperations: Int
    
    /// Maximum data rate in bytes per second (0 = unlimited)
    public let maxDataRate: Double
    
    /// Buffer size for incoming data
    public let incomingBufferSize: Int
    
    /// Buffer size for outgoing data
    public let outgoingBufferSize: Int
    
    /// Window size for sliding window protocol
    public let windowSize: Int
    
    /// Timeout for acknowledgments
    public let ackTimeout: TimeInterval
    
    /// Enable adaptive throttling based on connection quality
    public let adaptiveThrottling: Bool
    
    public init(
        maxPendingOperations: Int = 10,
        maxDataRate: Double = 0, // unlimited
        incomingBufferSize: Int = 64 * 1024, // 64KB
        outgoingBufferSize: Int = 64 * 1024, // 64KB
        windowSize: Int = 5,
        ackTimeout: TimeInterval = 5.0,
        adaptiveThrottling: Bool = true
    ) {
        self.maxPendingOperations = maxPendingOperations
        self.maxDataRate = maxDataRate
        self.incomingBufferSize = incomingBufferSize
        self.outgoingBufferSize = outgoingBufferSize
        self.windowSize = windowSize
        self.ackTimeout = ackTimeout
        self.adaptiveThrottling = adaptiveThrottling
    }
    
    /// Conservative configuration for low-quality connections
    public static let conservative = FlowControlConfiguration(
        maxPendingOperations: 3,
        maxDataRate: 1024, // 1KB/s
        windowSize: 2,
        ackTimeout: 10.0
    )
    
    /// Aggressive configuration for high-quality connections
    public static let aggressive = FlowControlConfiguration(
        maxPendingOperations: 20,
        maxDataRate: 0, // unlimited
        windowSize: 10,
        ackTimeout: 2.0
    )
}

/// Data packet for flow control
public struct DataPacket: Sendable, Codable {
    public let id: UUID
    public let sequenceNumber: UInt32
    public let data: Data
    public let timestamp: Date
    public let requiresAck: Bool
    
    public init(
        sequenceNumber: UInt32,
        data: Data,
        requiresAck: Bool = true
    ) {
        self.id = UUID()
        self.sequenceNumber = sequenceNumber
        self.data = data
        self.timestamp = Date()
        self.requiresAck = requiresAck
    }
}

/// Acknowledgment packet
public struct AckPacket: Sendable, Codable {
    public let packetId: UUID
    public let sequenceNumber: UInt32
    public let timestamp: Date
    public let receivedSuccessfully: Bool
    
    public init(packetId: UUID, sequenceNumber: UInt32, receivedSuccessfully: Bool = true) {
        self.packetId = packetId
        self.sequenceNumber = sequenceNumber
        self.timestamp = Date()
        self.receivedSuccessfully = receivedSuccessfully
    }
}

/// Flow control state for a device connection
private actor FlowControlState {
    let deviceId: DeviceIdentifier
    let configuration: FlowControlConfiguration
    
    // Sequence numbers
    private var nextOutgoingSequence: UInt32 = 0
    private var expectedIncomingSequence: UInt32 = 0
    
    // Sliding window
    private var sendWindow: [UInt32: DataPacket] = [:]
    private var sendWindowBase: UInt32 = 0
    
    // Buffers
    private var incomingBuffer: Data = Data()
    private var outgoingQueue: [DataPacket] = []
    
    // Pending operations
    private var pendingOperations: Set<UUID> = []
    
    // Rate limiting
    private var lastSendTime: Date = Date()
    private var bytesTransmittedThisSecond: Int = 0
    private var currentSecond: Int = 0
    
    // Statistics
    private var totalBytesSent: Int = 0
    private var totalBytesReceived: Int = 0
    private var packetsDropped: Int = 0
    private var averageRTT: TimeInterval = 0.0
    private var packetRTTs: [TimeInterval] = []
    
    init(deviceId: DeviceIdentifier, configuration: FlowControlConfiguration) {
        self.deviceId = deviceId
        self.configuration = configuration
    }
    
    // MARK: - Outgoing Data Management
    
    func canSendData(size: Int) -> Bool {
        // Check pending operations limit
        if pendingOperations.count >= configuration.maxPendingOperations {
            return false
        }
        
        // Check outgoing buffer capacity
        let queuedBytes = outgoingQueue.reduce(0) { $0 + $1.data.count }
        if queuedBytes + size > configuration.outgoingBufferSize {
            return false
        }
        
        // Check rate limit
        if configuration.maxDataRate > 0 {
            let currentSecondInt = Int(Date().timeIntervalSince1970)
            if currentSecondInt != currentSecond {
                currentSecond = currentSecondInt
                bytesTransmittedThisSecond = 0
            }
            
            if bytesTransmittedThisSecond + size > Int(configuration.maxDataRate) {
                return false
            }
        }
        
        // Check sliding window
        return sendWindow.count < configuration.windowSize
    }
    
    func queueData(_ data: Data, requiresAck: Bool = true) -> DataPacket? {
        guard canSendData(size: data.count) else { return nil }
        
        let packet = DataPacket(
            sequenceNumber: nextOutgoingSequence,
            data: data,
            requiresAck: requiresAck
        )
        
        nextOutgoingSequence += 1
        outgoingQueue.append(packet)
        
        if requiresAck {
            pendingOperations.insert(packet.id)
        }
        
        return packet
    }
    
    var nextPacketToSend: DataPacket? {
        guard !outgoingQueue.isEmpty else { return nil }
        guard sendWindow.count < configuration.windowSize else { return nil }
        
        let packet = outgoingQueue.removeFirst()
        
        if packet.requiresAck {
            sendWindow[packet.sequenceNumber] = packet
        }
        
        // Update rate limiting
        if configuration.maxDataRate > 0 {
            bytesTransmittedThisSecond += packet.data.count
        }
        
        totalBytesSent += packet.data.count
        lastSendTime = Date()
        
        return packet
    }
    
    func acknowledge(_ ack: AckPacket) {
        guard let packet = sendWindow.removeValue(forKey: ack.sequenceNumber) else { return }
        
        pendingOperations.remove(packet.id)
        
        // Update RTT statistics
        let rtt = Date().timeIntervalSince(packet.timestamp)
        packetRTTs.append(rtt)
        if packetRTTs.count > 10 {
            packetRTTs.removeFirst()
        }
        averageRTT = packetRTTs.reduce(0, +) / Double(packetRTTs.count)
        
        // Slide window base if this was the base packet
        if ack.sequenceNumber == sendWindowBase {
            sendWindowBase += 1
            
            // Find new base (next unacknowledged packet)
            while sendWindow[sendWindowBase] == nil && sendWindowBase < nextOutgoingSequence {
                sendWindowBase += 1
            }
        }
    }
    
    func processTimeout() {
        let now = Date()
        var timedOutPackets: [DataPacket] = []
        
        for packet in sendWindow.values {
            if now.timeIntervalSince(packet.timestamp) > configuration.ackTimeout {
                timedOutPackets.append(packet)
            }
        }
        
        // Retransmit timed out packets
        for packet in timedOutPackets {
            sendWindow.removeValue(forKey: packet.sequenceNumber)
            let retransmitPacket = DataPacket(
                sequenceNumber: packet.sequenceNumber,
                data: packet.data,
                requiresAck: packet.requiresAck
            )
            outgoingQueue.insert(retransmitPacket, at: 0) // Priority retransmission
            packetsDropped += 1
        }
    }
    
    // MARK: - Incoming Data Management
    
    func canReceiveData(size: Int) -> Bool {
        return incomingBuffer.count + size <= configuration.incomingBufferSize
    }
    
    func receivePacket(_ packet: DataPacket) -> (shouldAck: Bool, data: Data?) {
        guard canReceiveData(size: packet.data.count) else {
            packetsDropped += 1
            return (shouldAck: false, data: nil)
        }
        
        totalBytesReceived += packet.data.count
        
        if packet.sequenceNumber == expectedIncomingSequence {
            // Packet is in order
            expectedIncomingSequence += 1
            incomingBuffer.append(packet.data)
            
            return (shouldAck: packet.requiresAck, data: packet.data)
        } else {
            // Out of order packet - for simplicity, we'll drop it
            // In a more sophisticated implementation, we'd buffer it
            packetsDropped += 1
            return (shouldAck: false, data: nil)
        }
    }
    
    func consumeIncomingData(maxBytes: Int) -> Data {
        let bytesToConsume = min(maxBytes, incomingBuffer.count)
        let data = incomingBuffer.prefix(bytesToConsume)
        incomingBuffer.removeFirst(bytesToConsume)
        return Data(data)
    }
    
    // MARK: - Statistics
    
    var statistics: FlowControlStatistics {
        return FlowControlStatistics(
            deviceId: deviceId,
            totalBytesSent: totalBytesSent,
            totalBytesReceived: totalBytesReceived,
            packetsDropped: packetsDropped,
            averageRTT: averageRTT,
            pendingOperations: pendingOperations.count,
            sendWindowSize: sendWindow.count,
            incomingBufferSize: incomingBuffer.count,
            outgoingQueueSize: outgoingQueue.count
        )
    }
    
    func reset() {
        sendWindow.removeAll()
        incomingBuffer.removeAll()
        outgoingQueue.removeAll()
        pendingOperations.removeAll()
        nextOutgoingSequence = 0
        expectedIncomingSequence = 0
        sendWindowBase = 0
        totalBytesSent = 0
        totalBytesReceived = 0
        packetsDropped = 0
        packetRTTs.removeAll()
        averageRTT = 0.0
    }
}

/// Flow control statistics
public struct FlowControlStatistics: Sendable, Codable {
    public let deviceId: DeviceIdentifier
    public let totalBytesSent: Int
    public let totalBytesReceived: Int
    public let packetsDropped: Int
    public let averageRTT: TimeInterval
    public let pendingOperations: Int
    public let sendWindowSize: Int
    public let incomingBufferSize: Int
    public let outgoingQueueSize: Int
    
    public var throughput: Double {
        // Simplified throughput calculation
        if averageRTT > 0 {
            return Double(sendWindowSize) / averageRTT
        }
        return 0
    }
    
    public var packetLossRate: Double {
        let totalPackets = totalBytesSent + totalBytesReceived + packetsDropped
        return totalPackets > 0 ? Double(packetsDropped) / Double(totalPackets) : 0
    }
}

/// Main flow control manager
public actor BleuFlowControlManager {
    public static let shared = BleuFlowControlManager()
    
    private var deviceStates: [DeviceIdentifier: FlowControlState] = [:]
    private var configurations: [DeviceIdentifier: FlowControlConfiguration] = [:]
    private var timeoutTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
    
    private let defaultConfiguration = FlowControlConfiguration()
    
    private init() {}
    
    // MARK: - Configuration Management
    
    public func configure(with config: FlowControlConfiguration, for deviceId: DeviceIdentifier) {
        configurations[deviceId] = config
        
        // Update existing state if present
        if deviceStates[deviceId] != nil {
            deviceStates[deviceId] = FlowControlState(deviceId: deviceId, configuration: config)
            startTimeoutMonitoring(for: deviceId)
        }
    }
    
    public func configuration(for deviceId: DeviceIdentifier) -> FlowControlConfiguration {
        return configurations[deviceId] ?? defaultConfiguration
    }
    
    // MARK: - Flow Control Operations
    
    public func initializeFlowControl(for deviceId: DeviceIdentifier) {
        let config = getConfiguration(for: deviceId)
        deviceStates[deviceId] = FlowControlState(deviceId: deviceId, configuration: config)
        startTimeoutMonitoring(for: deviceId)
    }
    
    public func canSendData(to deviceId: DeviceIdentifier, size: Int) async -> Bool {
        guard let state = deviceStates[deviceId] else { return false }
        return await state.canSendData(size: size)
    }
    
    public func queueData(_ data: Data, for deviceId: DeviceIdentifier, requiresAck: Bool = true) async -> DataPacket? {
        guard let state = deviceStates[deviceId] else { return nil }
        return await state.queueData(data, requiresAck: requiresAck)
    }
    
    public func nextPacketToSend(for deviceId: DeviceIdentifier) async -> DataPacket? {
        guard let state = deviceStates[deviceId] else { return nil }
        return await state.getNextPacketToSend()
    }
    
    public func receivePacket(_ packet: DataPacket, from deviceId: DeviceIdentifier) async -> (shouldAck: Bool, data: Data?) {
        if deviceStates[deviceId] == nil {
            initializeFlowControl(for: deviceId)
        }
        
        guard let state = deviceStates[deviceId] else {
            return (shouldAck: false, data: nil)
        }
        
        return await state.receivePacket(packet)
    }
    
    public func acknowledge(_ ack: AckPacket, from deviceId: DeviceIdentifier) async {
        guard let state = deviceStates[deviceId] else { return }
        await state.handleAcknowledgment(ack)
    }
    
    public func consumeIncomingData(from deviceId: DeviceIdentifier, maxBytes: Int = Int.max) async -> Data? {
        guard let state = deviceStates[deviceId] else { return nil }
        let data = await state.consumeIncomingData(maxBytes: maxBytes)
        return data.isEmpty ? nil : data
    }
    
    // MARK: - Statistics and Monitoring
    
    public func statistics(for deviceId: DeviceIdentifier) async -> FlowControlStatistics? {
        guard let state = deviceStates[deviceId] else { return nil }
        return await state.getStatistics()
    }
    
    public var allStatistics: [FlowControlStatistics] { get async
        var statistics: [FlowControlStatistics] = []
        for state in deviceStates.values {
            let stats = await state.getStatistics()
            statistics.append(stats)
        }
        return statistics
    }
    
    // MARK: - Adaptive Flow Control
    
    public func adaptFlowControl(for deviceId: DeviceIdentifier, connectionQuality: ConnectionQuality) {
        let currentConfig = getConfiguration(for: deviceId)
        guard currentConfig.adaptiveThrottling else { return }
        
        let qualityScore = connectionQuality.qualityScore
        var newConfig = currentConfig
        
        if qualityScore < 0.3 {
            // Poor quality - very conservative
            newConfig = FlowControlConfiguration(
                maxPendingOperations: 2,
                maxDataRate: 512,
                windowSize: 1,
                ackTimeout: currentConfig.ackTimeout * 2,
                adaptiveThrottling: true
            )
        } else if qualityScore < 0.6 {
            // Fair quality - conservative
            newConfig = FlowControlConfiguration.conservative
        } else if qualityScore > 0.8 {
            // Excellent quality - aggressive
            newConfig = FlowControlConfiguration.aggressive
        }
        
        if newConfig.maxDataRate != currentConfig.maxDataRate ||
           newConfig.windowSize != currentConfig.windowSize {
            setConfiguration(newConfig, for: deviceId)
        }
    }
    
    // MARK: - Cleanup
    
    public func resetFlowControl(for deviceId: DeviceIdentifier) async {
        guard let state = deviceStates[deviceId] else { return }
        await state.reset()
        
        timeoutTasks[deviceId]?.cancel()
        timeoutTasks.removeValue(forKey: deviceId)
    }
    
    public func cleanupFlowControl(for deviceId: DeviceIdentifier) {
        deviceStates.removeValue(forKey: deviceId)
        configurations.removeValue(forKey: deviceId)
        timeoutTasks[deviceId]?.cancel()
        timeoutTasks.removeValue(forKey: deviceId)
    }
    
    public func cleanupAll() {
        deviceStates.removeAll()
        configurations.removeAll()
        
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
    }
    
    // MARK: - Private Implementation
    
    private func startTimeoutMonitoring(for deviceId: DeviceIdentifier) {
        timeoutTasks[deviceId]?.cancel()
        
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                
                guard !Task.isCancelled else { break }
                
                if let state = await deviceStates[deviceId] {
                    await state.handleTimeout()
                }
            }
        }
        
        timeoutTasks[deviceId] = task
    }
}

// MARK: - Extensions

extension CentralActor {
    /// Send data with flow control
    public distributed func sendDataWithFlowControl(
        to deviceId: DeviceIdentifier,
        data: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID
    ) async throws -> Data? {
        
        // Check if we can send data
        guard await BleuFlowControlManager.shared.canSendData(to: deviceId, size: data.count) else {
            throw BleuError.queueOverflow
        }
        
        // Queue data for flow control
        guard let packet = await BleuFlowControlManager.shared.queueData(data, for: deviceId) else {
            throw BleuError.queueOverflow
        }
        
        // Send the packet
        let message = BleuMessage(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: try JSONEncoder().encode(packet),
            method: .write
        )
        
        return try await sendRequest(to: deviceId, message: message)
    }
    
    /// Receive data with flow control processing
    public distributed func receiveDataWithFlowControl(
        from deviceId: DeviceIdentifier,
        rawData: Data
    ) async throws -> Data? {
        
        // Decode packet
        guard let packet = try? JSONDecoder().decode(DataPacket.self, from: rawData) else {
            throw BleuError.invalidDataFormat
        }
        
        // Process through flow control
        let result = await BleuFlowControlManager.shared.receivePacket(packet, from: deviceId)
        
        // Send acknowledgment if required
        if result.shouldAck {
            let ack = AckPacket(packetId: packet.id, sequenceNumber: packet.sequenceNumber)
            // In a real implementation, we'd send this ack back to the sender
            // For now, we'll just handle it locally for demonstration
            await BleuFlowControlManager.shared.handleAcknowledgment(ack, from: deviceId)
        }
        
        return result.data
    }
}

extension PeripheralActor {
    /// Handle incoming data with flow control
    public func processIncomingDataWithFlowControl(
        from centralId: DeviceIdentifier,
        data: Data
    ) async throws -> Data? {
        
        // Decode packet
        guard let packet = try? JSONDecoder().decode(DataPacket.self, from: data) else {
            throw BleuError.invalidDataFormat
        }
        
        // Process through flow control
        let result = await BleuFlowControlManager.shared.receivePacket(packet, from: centralId)
        
        if result.shouldAck {
            let ack = AckPacket(packetId: packet.id, sequenceNumber: packet.sequenceNumber)
            // Send acknowledgment back
            let ackData = try JSONEncoder().encode(ack)
            // In a real implementation, we'd send this via BLE notification
            return ackData
        }
        
        return result.data
    }
}