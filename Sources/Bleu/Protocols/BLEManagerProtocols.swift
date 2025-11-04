import Foundation
import CoreBluetooth

// MARK: - BLE Manager Protocols

/// Protocol abstracting CBPeripheralManager operations for peripheral role
/// Conforming types must be actors for thread-safety
public protocol BLEPeripheralManagerProtocol: Actor {

    // MARK: - Event Stream

    /// Async stream of BLE events from peripheral manager
    nonisolated var events: AsyncStream<BLEEvent> { get }

    // MARK: - State Management

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the peripheral manager
    /// - Note: For CoreBluetooth implementations, creates CBPeripheralManager (triggers TCC)
    ///   For mock implementations, this is typically a no-op
    func initialize() async

    /// Wait until Bluetooth is powered on
    /// - Returns: Final state (should be .poweredOn)
    func waitForPoweredOn() async -> CBManagerState

    // MARK: - Service Management

    /// Add a service to the peripheral
    /// - Parameter service: Service metadata to add
    /// - Throws: BleuError if service cannot be added
    func add(_ service: ServiceMetadata) async throws

    // MARK: - Advertising

    /// Start advertising with given data
    /// - Parameter data: Advertisement data to broadcast
    /// - Throws: BleuError if advertising fails to start
    func startAdvertising(_ data: AdvertisementData) async throws

    /// Stop advertising
    func stopAdvertising() async

    /// Check if currently advertising
    var isAdvertising: Bool { get async }

    // MARK: - Characteristic Updates

    /// Update characteristic value and notify subscribed centrals
    /// - Parameters:
    ///   - data: New value for the characteristic
    ///   - characteristicUUID: UUID of the characteristic
    ///   - centrals: Optional list of specific centrals to notify (nil = all)
    /// - Returns: true if update was sent successfully
    /// - Throws: BleuError if update fails
    func updateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool

    // MARK: - Subscription Management

    /// Get list of centrals subscribed to a characteristic
    /// - Parameter characteristicUUID: UUID of the characteristic
    /// - Returns: Array of subscribed central UUIDs
    func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID]
}

/// Protocol abstracting CBCentralManager operations for central role
/// Conforming types must be actors for thread-safety
public protocol BLECentralManagerProtocol: Actor {

    // MARK: - Event Stream

    /// Async stream of BLE events from central manager
    nonisolated var events: AsyncStream<BLEEvent> { get }

    // MARK: - State Management

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the central manager
    /// - Note: For CoreBluetooth implementations, creates CBCentralManager (triggers TCC)
    ///   For mock implementations, this is typically a no-op
    func initialize() async

    /// Wait until Bluetooth is powered on
    /// - Returns: Final state (should be .poweredOn)
    func waitForPoweredOn() async -> CBManagerState

    // MARK: - Scanning

    /// Scan for peripherals advertising specified services
    /// - Parameters:
    ///   - serviceUUIDs: Services to scan for (empty = all peripherals)
    ///   - timeout: Maximum time to scan
    /// - Returns: AsyncStream of discovered peripherals
    func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral>

    /// Stop scanning for peripherals
    func stopScan() async

    // MARK: - Connection Management

    /// Connect to a peripheral
    /// - Parameters:
    ///   - peripheralID: UUID of the peripheral
    ///   - timeout: Connection timeout
    /// - Throws: BleuError if connection fails or times out
    func connect(
        to peripheralID: UUID,
        timeout: TimeInterval
    ) async throws

    /// Disconnect from a peripheral
    /// - Parameter peripheralID: UUID of the peripheral
    /// - Throws: BleuError if disconnection fails
    func disconnect(from peripheralID: UUID) async throws

    /// Check if a peripheral is connected
    /// - Parameter peripheralID: UUID of the peripheral
    /// - Returns: true if connected
    func isConnected(_ peripheralID: UUID) async -> Bool

    // MARK: - Service & Characteristic Discovery

    /// Discover services on a connected peripheral
    /// - Parameters:
    ///   - peripheralID: UUID of the peripheral
    ///   - serviceUUIDs: Specific services to discover (nil = all)
    /// - Returns: Array of discovered services
    /// - Throws: BleuError if discovery fails
    func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata]

    /// Discover characteristics for a service
    /// - Parameters:
    ///   - serviceUUID: Service UUID
    ///   - peripheralID: Peripheral UUID
    ///   - characteristicUUIDs: Specific characteristics (nil = all)
    /// - Returns: Array of discovered characteristics
    /// - Throws: BleuError if discovery fails
    func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata]

    // MARK: - Characteristic Operations

    /// Read characteristic value
    /// - Parameters:
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    /// - Returns: Characteristic value
    /// - Throws: BleuError if read fails
    func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data

    /// Write characteristic value
    /// - Parameters:
    ///   - data: Data to write
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    ///   - type: Write type (with/without response)
    /// - Throws: BleuError if write fails
    func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws

    /// Enable/disable notifications for characteristic
    /// - Parameters:
    ///   - enabled: true to enable, false to disable
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    /// - Throws: BleuError if operation fails
    func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws

    // MARK: - MTU Management

    /// Get maximum write length for a peripheral
    /// - Parameters:
    ///   - peripheralID: Peripheral UUID
    ///   - type: Write type
    /// - Returns: Maximum write length in bytes (nil if not connected)
    func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int?
}
