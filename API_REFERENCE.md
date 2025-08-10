# Bleu v2 API Reference

Complete API reference for Bleu v2 framework.

## Table of Contents

- [Core Types](#core-types)
- [Main API](#main-api)
- [Actors](#actors)
- [Managers](#managers)
- [Configuration](#configuration)
- [Security](#security)
- [Error Handling](#error-handling)
- [Performance](#performance)
- [Testing](#testing)

## Core Types

### DeviceIdentifier

Uniquely identifies a BLE device.

```swift
public struct DeviceIdentifier: Sendable, Hashable, Codable {
    public let uuid: UUID
    public let name: String?
    
    public init(uuid: UUID, name: String? = nil)
}
```

### ServiceConfiguration

Configuration for BLE services.

```swift
public struct ServiceConfiguration: Sendable, Codable {
    public let serviceUUID: UUID
    public let characteristicUUIDs: [UUID]
    public let isPrimary: Bool
    
    public init(serviceUUID: UUID, characteristicUUIDs: [UUID], isPrimary: Bool = true)
}
```

### BleuMessage

Message structure for BLE communication.

```swift
public struct BleuMessage: Sendable, Codable {
    public let id: UUID
    public let serviceUUID: UUID
    public let characteristicUUID: UUID
    public let data: Data?
    public let timestamp: Date
    public let method: RequestMethod
    
    public init(serviceUUID: UUID, characteristicUUID: UUID, data: Data? = nil, method: RequestMethod = .read)
}
```

### RequestMethod

BLE operation methods.

```swift
public enum RequestMethod: Sendable, Codable, CaseIterable {
    case read
    case write
    case writeWithoutResponse
    case notify
    case indicate
    
    public var properties: CBCharacteristicProperties { get }
    public var permissions: CBAttributePermissions { get }
}
```

### DeviceInfo

Information about discovered BLE devices.

```swift
public struct DeviceInfo: Sendable, Codable {
    public let identifier: DeviceIdentifier
    public let rssi: Int?
    public let advertisementData: AdvertisementData
    public let isConnectable: Bool
    public let lastSeen: Date
    
    public init(identifier: DeviceIdentifier, rssi: Int? = nil, advertisementData: AdvertisementData, isConnectable: Bool = true, lastSeen: Date = Date())
}
```

### AdvertisementData

BLE advertisement data structure.

```swift
public struct AdvertisementData: Sendable, Codable {
    public let localName: String?
    public let serviceUUIDs: [UUID]
    public let manufacturerData: Data?
    public let serviceData: [UUID: Data]
    public let txPowerLevel: Int?
    
    public init(localName: String? = nil, serviceUUIDs: [UUID] = [], manufacturerData: Data? = nil, serviceData: [UUID: Data] = [:], txPowerLevel: Int? = nil)
}
```

## Main API

### Bleu (Namespace)

Main entry point for quick-start APIs.

```swift
public enum Bleu {
    /// Create a BLE server (peripheral)
    static func server(serviceUUID: UUID, characteristicUUIDs: [UUID], localName: String?) async throws -> BleuServer
    
    /// Create a BLE client (central)
    static func client(serviceUUIDs: [UUID] = []) async throws -> BleuClient
    
    /// Discover nearby BLE devices
    static func discover(serviceUUIDs: [UUID] = [], timeout: TimeInterval = 10.0) async throws -> [DeviceInfo]
    
    /// Monitor Bluetooth state changes
    static func monitorBluetoothState() -> AsyncStream<CBManagerState>
    
    /// Check if Bluetooth is available
    static var isBluetoothAvailable: Bool { get async }
}
```

### BleuServer

High-level server implementation.

```swift
public actor BleuServer {
    public init(serviceUUID: UUID, characteristicUUIDs: [UUID], localName: String? = nil) async throws
    
    /// Handle incoming requests of a specific type
    public func handleRequests<T: RemoteProcedure>(
        ofType type: T.Type,
        handler: @escaping @Sendable (T) async throws -> T.Response
    ) async
    
    /// Broadcast notification to subscribed clients
    public func broadcast<T: Sendable & Codable>(_ notification: T, characteristicUUID: UUID) async throws
    
    /// Shutdown the server
    public func shutdown() async
}
```

### BleuClient

High-level client implementation.

```swift
public actor BleuClient {
    public init(serviceUUIDs: [UUID] = []) async throws
    
    /// Discover nearby devices
    public func discover(timeout: TimeInterval = 10.0) async throws -> [DeviceInfo]
    
    /// Connect to a device
    public func connect(to device: DeviceInfo) async throws -> PeripheralActor
    
    /// Send a type-safe request
    public func sendRequest<T: RemoteProcedure>(_ request: T, to deviceId: DeviceIdentifier) async throws -> T.Response
    
    /// Subscribe to notifications
    public func subscribe<T: Sendable & Codable>(
        to type: T.Type,
        from deviceId: DeviceIdentifier,
        characteristicUUID: UUID
    ) async throws -> AsyncStream<T>
    
    /// Disconnect from device
    public func disconnect(from deviceId: DeviceIdentifier) async throws
    
    /// Shutdown the client
    public func shutdown() async
}
```

## Actors

### BluetoothActor

Global actor managing Bluetooth state and coordination.

```swift
@globalActor
public actor BluetoothActor: GlobalActor {
    public static let shared: BluetoothActor
    
    /// Create a peripheral actor
    public func createPeripheral(
        configuration: ServiceConfiguration,
        advertisementData: AdvertisementData
    ) async throws -> PeripheralActor
    
    /// Create a central actor
    public func createCentral(
        serviceUUIDs: [UUID] = [],
        options: ConnectionOptions = ConnectionOptions()
    ) async throws -> CentralActor
    
    /// Quick peripheral creation
    public func quickPeripheral(
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        localName: String? = nil
    ) async throws -> PeripheralActor
    
    /// Quick central creation
    public func quickCentral(serviceUUIDs: [UUID] = []) async throws -> CentralActor
    
    /// Discover peripherals
    public func discoverPeripherals(
        serviceUUIDs: [UUID] = [],
        timeout: TimeInterval = 10.0
    ) async throws -> [DeviceInfo]
    
    /// Current Bluetooth state
    public var currentBluetoothState: CBManagerState { get async }
    
    /// Check if Bluetooth is available
    public var isBluetoothAvailable: Bool { get async }
    
    /// Add state observer
    public func addStateObserver(_ observer: @escaping (CBManagerState) -> Void) async -> UUID
    
    /// Remove state observer
    public func removeStateObserver(id: UUID) async
}
```

### CentralActor

Distributed actor for BLE client functionality.

```swift
public distributed actor CentralActor {
    public typealias ActorSystem = BLEActorSystem
    
    public init(actorSystem: ActorSystem, serviceUUIDs: [UUID] = [], options: ConnectionOptions = ConnectionOptions())
    
    /// Scan for peripherals
    public distributed func scanForPeripherals(timeout: TimeInterval = 10.0) async throws -> [DeviceInfo]
    
    /// Stop scanning
    public distributed func stopScanning() async
    
    /// Connect to a peripheral
    public distributed func connect(to deviceId: DeviceIdentifier) async throws -> PeripheralActor
    
    /// Connect with reconnection support
    public distributed func connectWithReconnection(
        to deviceId: DeviceIdentifier,
        policy: ReconnectionPolicy = ReconnectionPolicy()
    ) async throws -> PeripheralActor
    
    /// Disconnect from a peripheral
    public distributed func disconnect(from deviceId: DeviceIdentifier) async throws
    
    /// Disconnect with cleanup
    public distributed func disconnectWithCleanup(from deviceId: DeviceIdentifier) async throws
    
    /// Send a request to a connected peripheral
    public distributed func sendRequest(to deviceId: DeviceIdentifier, message: BleuMessage) async throws -> Data?
    
    /// Send data with flow control
    public distributed func sendDataWithFlowControl(
        to deviceId: DeviceIdentifier,
        data: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID
    ) async throws -> Data?
    
    /// Send optimized data
    public distributed func sendOptimizedData(
        to deviceId: DeviceIdentifier,
        data: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID
    ) async throws -> Data?
    
    /// Subscribe to notifications from a characteristic
    public distributed func subscribeToNotifications(
        from deviceId: DeviceIdentifier,
        characteristicUUID: UUID
    ) async throws -> AsyncStream<Data>
    
    /// Connected peripherals
    public distributed var connectedPeripherals: [DeviceIdentifier] { get async }
    
    /// Shutdown
    public distributed func shutdown() async
}
```

### PeripheralActor

Distributed actor for BLE server functionality.

```swift
public distributed actor PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    public init(actorSystem: ActorSystem, configuration: ServiceConfiguration, advertisementData: AdvertisementData)
    
    /// Start advertising
    public distributed func startAdvertising() async throws
    
    /// Start advertising with security requirements
    public distributed func secureStartAdvertising() async throws
    
    /// Stop advertising
    public distributed func stopAdvertising() async throws
    
    /// Advertising status
    public distributed var advertisingStatus: Bool { get async }
    
    /// Connected centrals
    public distributed var connectedCentrals: [DeviceIdentifier] { get async }
    
    /// Send notification to subscribed centrals
    public distributed func sendNotification(
        characteristicUUID: UUID,
        data: Data,
        to centrals: [DeviceIdentifier]? = nil
    ) async throws
    
    /// Set request handler for a characteristic
    public func setRequestHandler(
        characteristicUUID: UUID,
        handler: @escaping @Sendable (BleuMessage) async throws -> Data?
    ) async
    
    /// Remove request handler
    public func removeRequestHandler(characteristicUUID: UUID) async
    
    /// Handle optimized request
    public func handleOptimizedRequest(_ data: Data) async throws -> Data?
    
    /// Shutdown
    public distributed func shutdown() async
}
```

### BLEActorSystem

Distributed actor system for BLE communication.

```swift
public final class BLEActorSystem: DistributedActorSystem {
    public typealias ActorID = UUID
    public typealias InvocationDecoder = BLEInvocationDecoder
    public typealias InvocationEncoder = BLEInvocationEncoder
    public typealias ResultHandler = BLEResultHandler
    public typealias SerializationRequirement = Codable
    
    public init()
    
    /// Setup peripheral manager
    public func setupPeripheralManager(delegate: CBPeripheralManagerDelegate, queue: DispatchQueue? = nil)
    
    /// Setup central manager
    public func setupCentralManager(delegate: CBCentralManagerDelegate, queue: DispatchQueue? = nil)
    
    /// Register peripheral
    public func registerPeripheral(_ peripheral: CBPeripheral, for actorID: ActorID)
    
    /// Register central
    public func registerCentral(_ central: CBCentral, for actorID: ActorID)
    
    /// Handle peripheral value update
    public func handlePeripheralValueUpdate(characteristic: CBCharacteristic, data: Data?, error: Error?)
    
    /// Handle peripheral write completion
    public func handlePeripheralWriteCompletion(characteristic: CBCharacteristic, error: Error?)
}
```

## Managers

### BleuSecurityManager

Manages BLE security, authentication, and encryption.

```swift
public actor BleuSecurityManager {
    public static let shared: BleuSecurityManager
    
    /// Update security configuration
    public func configure(with configuration: SecurityConfiguration)
    
    /// Current security configuration
    public var securityConfiguration: SecurityConfiguration { get }
    
    /// Trust a device
    public func trustDevice(_ deviceId: DeviceIdentifier, level: TrustLevel = .trusted)
    
    /// Remove device from trusted list
    public func untrustDevice(_ deviceId: DeviceIdentifier)
    
    /// Check if device is trusted
    public func isTrusted(_ deviceId: DeviceIdentifier) -> Bool
    
    /// Get trust level for device
    public func trustLevel(for deviceId: DeviceIdentifier) -> TrustLevel
    
    /// Authenticate device
    public func authenticateDevice(_ deviceId: DeviceIdentifier, using method: AuthenticationMethod) async throws -> SecurityCredentials
    
    /// Encrypt data for transmission
    public func encryptData(_ data: Data, for deviceId: DeviceIdentifier) throws -> Data
    
    /// Decrypt received data
    public func decryptData(_ encryptedData: Data, from deviceId: DeviceIdentifier) throws -> Data
    
    /// Validate connection security
    public func validateConnection(_ deviceId: DeviceIdentifier) throws
}
```

### BleuConnectionManager

Manages connection states and automatic reconnection.

```swift
public actor BleuConnectionManager {
    public static let shared: BleuConnectionManager
    
    /// Update connection state
    public func updateConnectionState(
        for deviceId: DeviceIdentifier,
        state: ConnectionState,
        quality: ConnectionQuality? = nil,
        error: BleuError? = nil
    )
    
    /// Get connection info
    public func connectionInfo(for deviceId: DeviceIdentifier) -> ConnectionInfo?
    
    /// All active connections
    public var allConnections: [ConnectionInfo] { get }
    
    /// Get connections by state
    public func connections(in state: ConnectionState) -> [ConnectionInfo]
    
    /// Configure reconnection policy
    public func configure(reconnectionPolicy policy: ReconnectionPolicy, for deviceId: DeviceIdentifier)
    
    /// Get reconnection policy
    public func reconnectionPolicy(for deviceId: DeviceIdentifier) -> ReconnectionPolicy
    
    /// Enable connection quality monitoring
    public func enableQualityMonitoring(for deviceId: DeviceIdentifier, interval: TimeInterval = 5.0)
    
    /// Disable connection quality monitoring
    public func disableQualityMonitoring(for deviceId: DeviceIdentifier)
    
    /// Update connection quality
    public func updateConnectionQuality(for deviceId: DeviceIdentifier, quality: ConnectionQuality? = nil)
    
    /// Add connection observer
    @discardableResult
    public func addConnectionObserver(_ observer: @escaping (DeviceIdentifier, ConnectionState) -> Void) -> UUID
    
    /// Add quality observer
    @discardableResult
    public func addQualityObserver(_ observer: @escaping (DeviceIdentifier, ConnectionQuality) -> Void) -> UUID
    
    /// Remove observer
    public func removeObserver(id: UUID)
    
    /// Connection statistics
    public var connectionStatistics: ConnectionStatistics { get }
    
    /// Cleanup resources for device
    public func cleanup(for deviceId: DeviceIdentifier)
    
    /// Cleanup all resources
    public func cleanupAll()
}
```

### BleuFlowControlManager

Implements data flow control and backpressure management.

```swift
public actor BleuFlowControlManager {
    public static let shared: BleuFlowControlManager
    
    /// Configure flow control
    public func configure(with config: FlowControlConfiguration, for deviceId: DeviceIdentifier)
    
    /// Get flow control configuration
    public func configuration(for deviceId: DeviceIdentifier) -> FlowControlConfiguration
    
    /// Initialize flow control for device
    public func initializeFlowControl(for deviceId: DeviceIdentifier)
    
    /// Check if data can be sent
    public func canSendData(to deviceId: DeviceIdentifier, size: Int) async -> Bool
    
    /// Queue data for transmission
    public func queueData(_ data: Data, for deviceId: DeviceIdentifier, requiresAck: Bool = true) async -> DataPacket?
    
    /// Get next packet to send
    public func nextPacketToSend(for deviceId: DeviceIdentifier) async -> DataPacket?
    
    /// Receive packet from device
    public func receivePacket(_ packet: DataPacket, from deviceId: DeviceIdentifier) async -> (shouldAck: Bool, data: Data?)
    
    /// Process acknowledgment
    public func acknowledge(_ ack: AckPacket, from deviceId: DeviceIdentifier) async
    
    /// Consume incoming data
    public func consumeIncomingData(from deviceId: DeviceIdentifier, maxBytes: Int = Int.max) async -> Data?
    
    /// Get flow control statistics
    public func statistics(for deviceId: DeviceIdentifier) async -> FlowControlStatistics?
    
    /// All statistics
    public var allStatistics: [FlowControlStatistics] { get async }
    
    /// Adapt flow control based on connection quality
    public func adaptFlowControl(for deviceId: DeviceIdentifier, connectionQuality: ConnectionQuality)
    
    /// Reset flow control state
    public func resetFlowControl(for deviceId: DeviceIdentifier) async
    
    /// Cleanup flow control for device
    public func cleanupFlowControl(for deviceId: DeviceIdentifier)
    
    /// Cleanup all flow control
    public func cleanupAll()
}
```

### BleuDataOptimizer

Provides data compression and buffer management.

```swift
public actor BleuDataOptimizer {
    public static let shared: BleuDataOptimizer
    
    /// Configure buffer settings
    public func configure(with config: BufferConfiguration)
    
    /// Current configuration
    public var configuration: BufferConfiguration { get }
    
    /// Optimize data for transmission
    public func optimizeForTransmission(_ data: Data) async throws -> OptimizedBuffer
    
    /// Restore optimized data
    public func restoreOptimizedData(_ buffer: OptimizedBuffer) async throws -> Data
    
    /// Get optimized buffer for data size
    public func optimizedBuffer(for size: Int) async -> Data
    
    /// Release buffer back to pool
    public func releaseBuffer(_ buffer: Data) async
    
    /// Process multiple items in batch
    public func batchProcess<T>(
        items: [T],
        processor: @Sendable (T) async throws -> OptimizedBuffer
    ) async throws -> [OptimizedBuffer]
    
    /// Optimization statistics
    public var optimizationStatistics: OptimizationStatistics { get async }
    
    /// Clear statistics
    public func clearStatistics()
}
```

## Configuration

### BleuConfiguration

Main configuration structure.

```swift
public struct BleuConfiguration: Sendable, Codable {
    public let environment: Environment
    public let enableDebugLogging: Bool
    public let enablePerformanceMonitoring: Bool
    public let enableMetricsCollection: Bool
    public let connectionTimeoutSeconds: TimeInterval
    public let maxConcurrentConnections: Int
    public let defaultScanTimeout: TimeInterval
    public let enableHeartbeat: Bool
    public let heartbeatInterval: TimeInterval
    public let securityConfiguration: SecurityConfiguration
    public let enableEncryptionByDefault: Bool
    public let requireDeviceAuthentication: Bool
    public let certificateValidationEnabled: Bool
    public let bufferConfiguration: BufferConfiguration
    public let flowControlConfiguration: FlowControlConfiguration
    public let enableDataCompression: Bool
    public let compressionThreshold: Int
    public let reconnectionPolicy: ReconnectionPolicy
    public let maxRetryAttempts: Int
    public let enableAutomaticRecovery: Bool
    public let errorRecoveryDelay: TimeInterval
    public let maxMemoryUsageMB: Int
    public let resourceCleanupInterval: TimeInterval
    public let enableResourceMonitoring: Bool
    public let featureFlags: [String: Bool]
    
    /// Preset configurations
    public static let development: BleuConfiguration
    public static let staging: BleuConfiguration
    public static let production: BleuConfiguration
    
    /// Configuration properties
    public var isDevelopment: Bool { get }
    public var isProduction: Bool { get }
}
```

### BleuConfigurationManager

Manages runtime configuration.

```swift
public actor BleuConfigurationManager {
    public static let shared: BleuConfigurationManager
    
    /// Current configuration
    public var configuration: BleuConfiguration { get }
    
    /// Update configuration
    public func update(_ configuration: BleuConfiguration)
    
    /// Update specific values
    public func update(values updates: [String: Any])
    
    /// Configure feature flag
    public func configure(flag: String, enabled: Bool)
    
    /// Check if feature flag is enabled
    public func isEnabled(flag: String) -> Bool
    
    /// Add configuration observer
    @discardableResult
    public func addConfigurationObserver(_ observer: @escaping (BleuConfiguration) -> Void) -> UUID
    
    /// Remove configuration observer
    public func removeConfigurationObserver(_ id: UUID)
    
    /// Validate configuration
    public func validateConfiguration(_ configuration: BleuConfiguration) throws
    
    /// Detect environment
    public static func detectEnvironment() -> Environment
}
```

## Security

### SecurityConfiguration

Security configuration options.

```swift
public struct SecurityConfiguration: Sendable, Codable {
    public let requirePairing: Bool
    public let requireEncryption: Bool
    public let requireAuthentication: Bool
    public let encryptionKeySize: UInt8
    public let bondingType: BondingType
    
    public init(requirePairing: Bool = true, requireEncryption: Bool = true, requireAuthentication: Bool = true, encryptionKeySize: UInt8 = 16, bondingType: BondingType = .mitm)
    
    /// Preset configurations
    public static let secure: SecurityConfiguration
    public static let development: SecurityConfiguration
}
```

### SecurityCredentials

Device security credentials.

```swift
public struct SecurityCredentials: Sendable, Codable {
    public let deviceIdentifier: DeviceIdentifier
    public let trustLevel: TrustLevel
    public let authenticationState: AuthenticationState
    public let encryptionKey: Data?
    public let certificateChain: [Data]?
    public let lastAuthenticated: Date?
    public let expirationDate: Date?
    
    /// Check if credentials are valid
    public var isValid: Bool { get }
}
```

### AuthenticationMethod

Authentication methods.

```swift
public enum AuthenticationMethod: Sendable {
    case presharedKey(Data)
    case certificate(Data)
    case challengeResponse
}
```

### TrustLevel

Device trust levels.

```swift
public enum TrustLevel: Sendable, Codable, CaseIterable {
    case untrusted
    case temporary
    case trusted
    case verified
}
```

### AuthenticationState

Authentication state.

```swift
public enum AuthenticationState: Sendable, Codable {
    case unauthenticated
    case authenticating
    case authenticated(Date)
    case authenticationFailed(BleuError)
    
    public var isAuthenticated: Bool { get }
}
```

## Error Handling

### BleuError

Main error type with recovery information.

```swift
public enum BleuError: Error, Sendable {
    // Connection errors
    case bluetoothUnavailable
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case deviceNotFound
    case connectionFailed(String)
    case connectionLost
    case communicationTimeout
    case scanningFailed(String)
    
    // Data errors
    case serializationFailed
    case deserializationFailed
    case dataCorrupted
    case invalidDataFormat
    case dataTooLarge(Int, Int)
    
    // Security errors
    case authenticationFailed
    case encryptionFailed
    case decryptionFailed
    case certificateInvalid
    case permissionDenied
    case securityViolation(String)
    
    // Actor system errors
    case remoteActorUnavailable
    case actorSystemFailure(String)
    case distributedCallFailed(String)
    
    // Request/Response errors
    case invalidRequest
    case requestFailed(String)
    case responseTimeout
    case unexpectedResponse
    
    // Service/Characteristic errors
    case serviceNotFound(UUID)
    case characteristicNotFound(UUID)
    case serviceDiscoveryFailed(UUID)
    case characteristicDiscoveryFailed(UUID)
    case characteristicNotReadable(UUID)
    case characteristicNotWritable(UUID)
    case characteristicNotNotifiable(UUID)
    
    // Resource errors
    case resourceExhausted(String)
    case memoryPressure
    case queueOverflow
    
    // Platform errors
    case platformNotSupported
    case osVersionNotSupported(String)
    case hardwareNotSupported
    
    /// Error severity level
    public var severity: ErrorSeverity { get }
    
    /// Whether error is recoverable
    public var isRecoverable: Bool { get }
    
    /// Suggested recovery actions
    public var recoveryActions: [RecoveryAction] { get }
}
```

### ErrorSeverity

Error severity levels.

```swift
public enum ErrorSeverity: Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical
}
```

### RecoveryAction

Suggested recovery actions.

```swift
public enum RecoveryAction: Sendable, Codable, CaseIterable {
    case retry
    case reconnect
    case scan
    case enableBluetooth
    case requestPermission
    case reauthenticate
    case checkCredentials
    case releaseResources
    case restartApp
    case increaseTimeout
    case reduceThroughput
    case increaseBufferSize
    case contactSupport
}
```

## Performance

### BleuLogger

Structured logging system.

```swift
public actor BleuLogger {
    public static let shared: BleuLogger
    
    /// Configure minimum log level
    public func configure(minimumLevel level: LogLevel)
    
    /// Configure logging enabled state
    public func configure(enabled: Bool)
    
    /// Add log destination
    public func addDestination(_ destination: LogDestination)
    
    /// Remove all destinations
    public func removeAllDestinations()
    
    /// Configure category filter
    public func configure(categoryFilter categories: Set<LogCategory>)
    
    /// Main logging method
    public func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    )
    
    /// Convenience methods
    public func debug(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line, deviceId: String? = nil, metadata: [String: String] = [:])
    public func info(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line, deviceId: String? = nil, metadata: [String: String] = [:])
    public func warning(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line, deviceId: String? = nil, metadata: [String: String] = [:])
    public func error(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line, deviceId: String? = nil, metadata: [String: String] = [:])
    public func critical(_ message: String, category: LogCategory = .general, file: String = #file, function: String = #function, line: Int = #line, deviceId: String? = nil, metadata: [String: String] = [:])
    
    /// Log statistics
    public var logStatistics: LogStatistics { get }
    
    /// Flush all destinations
    public func flush() async
}
```

### BleuPerformanceMonitor

Performance monitoring and metrics collection.

```swift
public actor BleuPerformanceMonitor {
    public static let shared: BleuPerformanceMonitor
    
    /// Record performance metric
    public func recordMetric(_ metric: PerformanceMetrics)
    
    /// Measure operation performance
    public func measureOperation<T>(
        name: String,
        deviceId: String? = nil,
        metadata: [String: String] = [:],
        operation: () async throws -> T
    ) async rethrows -> T
    
    /// Performance statistics
    public var performanceStatistics: PerformanceStatistics { get }
    
    /// Clear all metrics
    public func clearMetrics()
    
    /// Configure maximum metrics count
    public func configure(maxMetricsCount count: Int)
}
```

## Testing

### Test Utilities

Testing utilities and mock implementations.

```swift
/// Test data generators
enum TestDataGenerator {
    static func generateRandomData(size: Int) -> Data
    static func generateCompressibleData(size: Int) -> Data
    static func generateDeviceInfos(count: Int) -> [DeviceInfo]
}

/// Performance assertions
enum PerformanceAssertions {
    static func assertPerformance<T>(
        _ operation: () async throws -> T,
        completesWithin duration: TimeInterval,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> T
    
    static func assertMemoryUsage(
        staysBelow limit: Int,
        file: StaticString = #file,
        line: UInt = #line
    )
}
```

## Protocols

### RemoteProcedure

Protocol for type-safe remote procedure calls.

```swift
public protocol RemoteProcedure: Sendable, Codable {
    associatedtype Response: Sendable, Codable
    
    var serviceUUID: UUID { get }
    var characteristicUUID: UUID { get }
    var method: RequestMethod { get }
}
```

### LogDestination

Protocol for log destinations.

```swift
public protocol LogDestination: Sendable {
    func write(_ entry: LogEntry) async
    func flush() async
}
```

## Global Functions

### Configuration Access

```swift
/// Get current configuration
public func BleuConfig() async -> BleuConfiguration

/// Check if feature is enabled
public func isFeatureEnabled(_ flag: String) async -> Bool
```

---

This API reference covers all public APIs in Bleu v2. For usage examples and best practices, see the main [README.md](README.md) and [Migration Guide](MIGRATION.md).