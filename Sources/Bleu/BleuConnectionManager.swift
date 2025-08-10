import Foundation
import CoreBluetooth

// MARK: - Connection State Management and Reconnection

/// Connection state for a BLE device
public enum ConnectionState: Sendable, Codable, CaseIterable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed
    
    public var description: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .reconnecting:
            return "Reconnecting"
        case .failed:
            return "Failed"
        }
    }
    
    public var isConnected: Bool {
        return self == .connected
    }
    
    public var isConnecting: Bool {
        return self == .connecting || self == .reconnecting
    }
}

/// Connection quality metrics
public struct ConnectionQuality: Sendable, Codable {
    public let rssi: Int
    public let packetLoss: Double // 0.0 to 1.0
    public let latency: TimeInterval
    public let throughput: Double // bytes per second
    public let lastUpdated: Date
    
    public init(
        rssi: Int,
        packetLoss: Double = 0.0,
        latency: TimeInterval = 0.0,
        throughput: Double = 0.0
    ) {
        self.rssi = rssi
        self.packetLoss = packetLoss
        self.latency = latency
        self.throughput = throughput
        self.lastUpdated = Date()
    }
    
    /// Overall quality score (0.0 to 1.0)
    public var qualityScore: Double {
        let rssiScore = max(0.0, min(1.0, Double(rssi + 100) / 70.0)) // -100 to -30 dBm
        let packetLossScore = 1.0 - packetLoss
        let latencyScore = latency > 0 ? max(0.0, min(1.0, 1.0 - (latency - 0.01) / 0.5)) : 1.0
        
        return (rssiScore + packetLossScore + latencyScore) / 3.0
    }
    
    public var qualityLevel: QualityLevel {
        let score = qualityScore
        if score >= 0.8 {
            return .excellent
        } else if score >= 0.6 {
            return .good
        } else if score >= 0.4 {
            return .fair
        } else {
            return .poor
        }
    }
}

/// Connection quality levels
public enum QualityLevel: Sendable, Codable, CaseIterable {
    case excellent
    case good
    case fair
    case poor
    
    public var description: String {
        switch self {
        case .excellent:
            return "Excellent"
        case .good:
            return "Good"
        case .fair:
            return "Fair"
        case .poor:
            return "Poor"
        }
    }
}

/// Reconnection policy configuration
public struct ReconnectionPolicy: Sendable, Codable {
    public let enabled: Bool
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let backoffMultiplier: Double
    public let jitterFactor: Double
    
    public init(
        enabled: Bool = true,
        maxAttempts: Int = 5,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        backoffMultiplier: Double = 2.0,
        jitterFactor: Double = 0.1
    ) {
        self.enabled = enabled
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitterFactor = jitterFactor
    }
    
    /// Default aggressive reconnection policy
    public static let aggressive = ReconnectionPolicy(
        maxAttempts: 10,
        initialDelay: 0.5,
        backoffMultiplier: 1.5
    )
    
    /// Default conservative reconnection policy
    public static let conservative = ReconnectionPolicy(
        maxAttempts: 3,
        initialDelay: 2.0,
        maxDelay: 60.0,
        backoffMultiplier: 3.0
    )
    
    /// Calculate delay for a given attempt
    public func delayForAttempt(_ attempt: Int) -> TimeInterval {
        let baseDelay = initialDelay * pow(backoffMultiplier, Double(attempt))
        let cappedDelay = min(baseDelay, maxDelay)
        
        // Add jitter
        let jitter = cappedDelay * jitterFactor * (Double.random(in: -1.0...1.0))
        return max(0.1, cappedDelay + jitter)
    }
}

/// Connection information tracking
public struct ConnectionInfo: Sendable, Codable {
    public let deviceId: DeviceIdentifier
    public let state: ConnectionState
    public let quality: ConnectionQuality?
    public let connectedAt: Date?
    public let lastSeen: Date
    public let reconnectAttempts: Int
    public let totalReconnects: Int
    public let errors: [BleuError]
    
    public init(
        deviceId: DeviceIdentifier,
        state: ConnectionState = .disconnected,
        quality: ConnectionQuality? = nil,
        connectedAt: Date? = nil,
        lastSeen: Date = Date(),
        reconnectAttempts: Int = 0,
        totalReconnects: Int = 0,
        errors: [BleuError] = []
    ) {
        self.deviceId = deviceId
        self.state = state
        self.quality = quality
        self.connectedAt = connectedAt
        self.lastSeen = lastSeen
        self.reconnectAttempts = reconnectAttempts
        self.totalReconnects = totalReconnects
        self.errors = errors
    }
    
    /// Connection uptime
    public var uptime: TimeInterval? {
        guard let connectedAt = connectedAt, state.isConnected else { return nil }
        return Date().timeIntervalSince(connectedAt)
    }
    
    /// Time since last seen
    public var timeSinceLastSeen: TimeInterval {
        return Date().timeIntervalSince(lastSeen)
    }
}

/// Connection manager for handling device connections and reconnections
public actor BleuConnectionManager {
    public static let shared = BleuConnectionManager()
    
    private var connections: [DeviceIdentifier: ConnectionInfo] = [:]
    private var reconnectionPolicies: [DeviceIdentifier: ReconnectionPolicy] = [:]
    private var reconnectionTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
    private var qualityMonitoringTasks: [DeviceIdentifier: Task<Void, Never>] = [:]
    
    // Connection event observers
    private var connectionObservers: [UUID: (DeviceIdentifier, ConnectionState) -> Void] = [:]
    private var qualityObservers: [UUID: (DeviceIdentifier, ConnectionQuality) -> Void] = [:]
    
    private let defaultPolicy = ReconnectionPolicy()
    
    private init() {}
    
    // MARK: - Connection State Management
    
    /// Update connection state for a device
    public func updateConnectionState(
        for deviceId: DeviceIdentifier,
        state: ConnectionState,
        quality: ConnectionQuality? = nil,
        error: BleuError? = nil
    ) {
        var info = connections[deviceId] ?? ConnectionInfo(deviceId: deviceId)
        
        let previousState = info.state
        
        // Update connection info
        var errors = info.errors
        if let error = error {
            errors.append(error)
            // Keep only the last 10 errors
            if errors.count > 10 {
                errors = Array(errors.suffix(10))
            }
        }
        
        info = ConnectionInfo(
            deviceId: deviceId,
            state: state,
            quality: quality ?? info.quality,
            connectedAt: state == .connected && previousState != .connected ? Date() : info.connectedAt,
            lastSeen: state.isConnected ? Date() : info.lastSeen,
            reconnectAttempts: state == .reconnecting ? info.reconnectAttempts : 0,
            totalReconnects: state == .connected && previousState == .reconnecting ? info.totalReconnects + 1 : info.totalReconnects,
            errors: errors
        )
        
        connections[deviceId] = info
        
        // Notify observers
        notifyConnectionObservers(deviceId: deviceId, state: state)
        
        // Handle state transitions
        handleStateTransition(deviceId: deviceId, from: previousState, to: state, error: error)
    }
    
    /// Get connection info for a device
    public func connectionInfo(for deviceId: DeviceIdentifier) -> ConnectionInfo? {
        return connections[deviceId]
    }
    
    /// Get all active connections
    public var allConnections: [ConnectionInfo] {
        return Array(connections.values)
    }
    
    /// Get connections by state
    public func connections(in state: ConnectionState) -> [ConnectionInfo] {
        return connections.values.filter { $0.state == state }
    }
    
    // MARK: - Reconnection Policy Management
    
    /// Set reconnection policy for a device
    public func configure(reconnectionPolicy policy: ReconnectionPolicy, for deviceId: DeviceIdentifier) {
        reconnectionPolicies[deviceId] = policy
    }
    
    /// Get reconnection policy for a device
    public func reconnectionPolicy(for deviceId: DeviceIdentifier) -> ReconnectionPolicy {
        return reconnectionPolicies[deviceId] ?? defaultPolicy
    }
    
    // MARK: - Connection Quality Monitoring
    
    /// Start monitoring connection quality for a device
    public func enableQualityMonitoring(for deviceId: DeviceIdentifier, interval: TimeInterval = 5.0) {
        // Cancel existing monitoring
        qualityMonitoringTasks[deviceId]?.cancel()
        
        let task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                await updateConnectionQuality(for: deviceId)
            }
        }
        
        qualityMonitoringTasks[deviceId] = task
    }
    
    /// Stop monitoring connection quality for a device
    public func disableQualityMonitoring(for deviceId: DeviceIdentifier) {
        qualityMonitoringTasks[deviceId]?.cancel()
        qualityMonitoringTasks.removeValue(forKey: deviceId)
    }
    
    /// Update connection quality manually
    public func updateConnectionQuality(for deviceId: DeviceIdentifier, quality: ConnectionQuality? = nil) {
        var info = connections[deviceId] ?? ConnectionInfo(deviceId: deviceId)
        
        let updatedQuality: ConnectionQuality?
        if let providedQuality = quality {
            updatedQuality = providedQuality
        } else {
            // In a real implementation, this would query the actual connection metrics
            updatedQuality = info.quality // Keep existing quality for now
        }
        
        if let quality = updatedQuality {
            info = ConnectionInfo(
                deviceId: info.deviceId,
                state: info.state,
                quality: quality,
                connectedAt: info.connectedAt,
                lastSeen: info.state.isConnected ? Date() : info.lastSeen,
                reconnectAttempts: info.reconnectAttempts,
                totalReconnects: info.totalReconnects,
                errors: info.errors
            )
            
            connections[deviceId] = info
            notifyQualityObservers(deviceId: deviceId, quality: quality)
        }
    }
    
    // MARK: - Observers
    
    /// Add connection state observer
    @discardableResult
    public func addConnectionObserver(
        _ observer: @escaping (DeviceIdentifier, ConnectionState) -> Void
    ) -> UUID {
        let id = UUID()
        connectionObservers[id] = observer
        return id
    }
    
    /// Add quality observer
    @discardableResult
    public func addQualityObserver(
        _ observer: @escaping (DeviceIdentifier, ConnectionQuality) -> Void
    ) -> UUID {
        let id = UUID()
        qualityObservers[id] = observer
        return id
    }
    
    /// Remove observer
    public func removeObserver(id: UUID) {
        connectionObservers.removeValue(forKey: id)
        qualityObservers.removeValue(forKey: id)
    }
    
    // MARK: - Cleanup
    
    /// Clean up resources for a device
    public func cleanup(for deviceId: DeviceIdentifier) {
        connections.removeValue(forKey: deviceId)
        reconnectionPolicies.removeValue(forKey: deviceId)
        reconnectionTasks[deviceId]?.cancel()
        reconnectionTasks.removeValue(forKey: deviceId)
        qualityMonitoringTasks[deviceId]?.cancel()
        qualityMonitoringTasks.removeValue(forKey: deviceId)
    }
    
    /// Clean up all resources
    public func cleanupAll() {
        connections.removeAll()
        reconnectionPolicies.removeAll()
        
        for task in reconnectionTasks.values {
            task.cancel()
        }
        reconnectionTasks.removeAll()
        
        for task in qualityMonitoringTasks.values {
            task.cancel()
        }
        qualityMonitoringTasks.removeAll()
        
        connectionObservers.removeAll()
        qualityObservers.removeAll()
    }
    
    // MARK: - Private Implementation
    
    private func handleStateTransition(
        deviceId: DeviceIdentifier,
        from: ConnectionState,
        to: ConnectionState,
        error: BleuError?
    ) {
        switch (from, to) {
        case (_, .disconnected):
            handleDisconnection(deviceId: deviceId, error: error)
        case (.disconnected, .connected):
            handleSuccessfulConnection(deviceId: deviceId)
        case (.reconnecting, .connected):
            handleSuccessfulReconnection(deviceId: deviceId)
        case (_, .failed):
            handleConnectionFailure(deviceId: deviceId, error: error)
        default:
            break
        }
    }
    
    private func handleDisconnection(deviceId: DeviceIdentifier, error: BleuError?) {
        stopQualityMonitoring(for: deviceId)
        
        let policy = getReconnectionPolicy(for: deviceId)
        if policy.enabled && error != nil {
            startReconnection(for: deviceId)
        }
    }
    
    private func handleSuccessfulConnection(deviceId: DeviceIdentifier) {
        // Cancel any ongoing reconnection
        reconnectionTasks[deviceId]?.cancel()
        reconnectionTasks.removeValue(forKey: deviceId)
        
        // Start quality monitoring
        startQualityMonitoring(for: deviceId)
    }
    
    private func handleSuccessfulReconnection(deviceId: DeviceIdentifier) {
        handleSuccessfulConnection(deviceId: deviceId)
    }
    
    private func handleConnectionFailure(deviceId: DeviceIdentifier, error: BleuError?) {
        stopQualityMonitoring(for: deviceId)
        
        let policy = getReconnectionPolicy(for: deviceId)
        if policy.enabled {
            startReconnection(for: deviceId)
        }
    }
    
    private func startReconnection(for deviceId: DeviceIdentifier) {
        // Cancel existing reconnection task
        reconnectionTasks[deviceId]?.cancel()
        
        let policy = getReconnectionPolicy(for: deviceId)
        guard policy.enabled else { return }
        
        let task = Task {
            var attempt = 0
            
            while attempt < policy.maxAttempts && !Task.isCancelled {
                attempt += 1
                
                // Update state to reconnecting
                await updateConnectionState(for: deviceId, state: .reconnecting)
                
                // Calculate delay
                let delay = policy.delayForAttempt(attempt - 1)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                
                guard !Task.isCancelled else { break }
                
                // Attempt reconnection
                do {
                    try await performReconnection(for: deviceId)
                    // If successful, the state will be updated by the connection process
                    break
                } catch {
                    if attempt >= policy.maxAttempts {
                        await updateConnectionState(
                            for: deviceId,
                            state: .failed,
                            error: BleuError.connectionFailed("Max reconnection attempts reached")
                        )
                    }
                    // Continue to next attempt
                }
            }
        }
        
        reconnectionTasks[deviceId] = task
    }
    
    private func performReconnection(for deviceId: DeviceIdentifier) async throws {
        // This would integrate with the actual BLE connection logic
        // For now, we'll simulate the reconnection attempt
        
        // In a real implementation, this would:
        // 1. Get the CentralActor for the device
        // 2. Attempt to connect to the device
        // 3. Update connection state based on result
        
        throw BleuError.connectionFailed("Simulated reconnection failure")
    }
    
    private func notifyConnectionObservers(deviceId: DeviceIdentifier, state: ConnectionState) {
        for observer in connectionObservers.values {
            observer(deviceId, state)
        }
    }
    
    private func notifyQualityObservers(deviceId: DeviceIdentifier, quality: ConnectionQuality) {
        for observer in qualityObservers.values {
            observer(deviceId, quality)
        }
    }
}

// MARK: - Extensions

extension CentralActor {
    /// Connect with automatic reconnection support
    public distributed func connectWithReconnection(
        to deviceId: DeviceIdentifier,
        policy: ReconnectionPolicy = ReconnectionPolicy()
    ) async throws -> PeripheralActor {
        
        // Set reconnection policy
        await BleuConnectionManager.shared.configure(reconnectionPolicy: policy, for: deviceId)
        
        // Update connection state
        await BleuConnectionManager.shared.updateConnectionState(for: deviceId, state: .connecting)
        
        do {
            let peripheralActor = try await connect(to: deviceId)
            
            // Update state on successful connection
            await BleuConnectionManager.shared.updateConnectionState(for: deviceId, state: .connected)
            
            return peripheralActor
            
        } catch {
            // Update state on connection failure
            let bleuError = error as? BleuError ?? BleuError.connectionFailed(error.localizedDescription)
            await BleuConnectionManager.shared.updateConnectionState(
                for: deviceId,
                state: .failed,
                error: bleuError
            )
            throw error
        }
    }
    
    /// Disconnect with proper cleanup
    public distributed func disconnectWithCleanup(from deviceId: DeviceIdentifier) async throws {
        // Update connection state
        await BleuConnectionManager.shared.updateConnectionState(for: deviceId, state: .disconnected)
        
        // Perform actual disconnection
        try await disconnect(from: deviceId)
        
        // Stop monitoring
        await BleuConnectionManager.shared.stopQualityMonitoring(for: deviceId)
    }
}

extension BleuConnectionManager {
    /// Get connection statistics
    public var connectionStatistics: ConnectionStatistics {
        let allConnections = Array(connections.values)
        
        return ConnectionStatistics(
            totalConnections: allConnections.count,
            connectedDevices: allConnections.filter { $0.state.isConnected }.count,
            reconnectingDevices: allConnections.filter { $0.state == .reconnecting }.count,
            failedConnections: allConnections.filter { $0.state == .failed }.count,
            averageQuality: calculateAverageQuality(from: allConnections),
            totalReconnects: allConnections.reduce(0) { $0 + $1.totalReconnects }
        )
    }
    
    private func calculateAverageQuality(from connections: [ConnectionInfo]) -> Double {
        let qualityScores = connections.compactMap { $0.quality?.qualityScore }
        guard !qualityScores.isEmpty else { return 0.0 }
        return qualityScores.reduce(0, +) / Double(qualityScores.count)
    }
}

/// Connection statistics
public struct ConnectionStatistics: Sendable, Codable {
    public let totalConnections: Int
    public let connectedDevices: Int
    public let reconnectingDevices: Int
    public let failedConnections: Int
    public let averageQuality: Double
    public let totalReconnects: Int
    
    public init(
        totalConnections: Int,
        connectedDevices: Int,
        reconnectingDevices: Int,
        failedConnections: Int,
        averageQuality: Double,
        totalReconnects: Int
    ) {
        self.totalConnections = totalConnections
        self.connectedDevices = connectedDevices
        self.reconnectingDevices = reconnectingDevices
        self.failedConnections = failedConnections
        self.averageQuality = averageQuality
        self.totalReconnects = totalReconnects
    }
}