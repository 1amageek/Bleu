import Foundation
import CoreBluetooth

/// Simulates the BLE radio, allowing mock peripherals and centrals
/// in different actor systems to communicate with each other.
///
/// This bridge acts as a communication channel that routes characteristic
/// writes from centrals to peripherals and notifications from peripherals to centrals.
///
/// Usage:
/// ```swift
/// // Create a shared bridge instance for the test
/// let bridge = MockBLEBridge()
///
/// // Peripheral system
/// var peripheralConfig = MockPeripheralManager.Configuration()
/// peripheralConfig.bridge = bridge
/// let peripheralSystem = BLEActorSystem(peripheralManager: MockPeripheralManager(configuration: peripheralConfig), ...)
///
/// // Central system (sharing the same bridge)
/// var centralConfig = MockCentralManager.Configuration()
/// centralConfig.bridge = bridge
/// let centralSystem = BLEActorSystem(centralManager: MockCentralManager(configuration: centralConfig), ...)
///
/// // The bridge routes communication between them
/// ```
public actor MockBLEBridge {

    /// Public initializer for creating bridge instances
    public init() {}

    // MARK: - Types

    /// Handler for characteristic writes (peripheral side)
    public typealias WriteHandler = @Sendable (UUID, Data) async -> Void

    /// Handler for characteristic notifications (central side)
    public typealias NotificationHandler = @Sendable (UUID, Data) async -> Void

    // MARK: - State

    /// Registered peripherals: peripheralID -> (serviceUUID -> (charUUID -> writeHandler))
    private var peripherals: [UUID: [UUID: [UUID: WriteHandler]]] = [:]

    /// Registered centrals: centralID -> peripheralID -> (charUUID -> notificationHandler)
    private var centrals: [UUID: [UUID: [UUID: NotificationHandler]]] = [:]

    /// Characteristic values: peripheralID -> (charUUID -> value)
    private var characteristicValues: [UUID: [UUID: Data]] = [:]

    // MARK: - Peripheral Registration

    /// Register a peripheral's characteristic for receiving writes
    public func registerPeripheral(
        _ peripheralID: UUID,
        serviceUUID: UUID,
        characteristicUUID: UUID,
        writeHandler: @escaping WriteHandler
    ) {
        if peripherals[peripheralID] == nil {
            peripherals[peripheralID] = [:]
        }
        if peripherals[peripheralID]?[serviceUUID] == nil {
            peripherals[peripheralID]?[serviceUUID] = [:]
        }
        peripherals[peripheralID]?[serviceUUID]?[characteristicUUID] = writeHandler
    }

    /// Unregister a peripheral
    public func unregisterPeripheral(_ peripheralID: UUID) {
        peripherals.removeValue(forKey: peripheralID)
        characteristicValues.removeValue(forKey: peripheralID)
    }

    // MARK: - Central Registration

    /// Register a central's notification handler for a peripheral's characteristic
    public func registerCentral(
        _ centralID: UUID,
        for peripheralID: UUID,
        characteristicUUID: UUID,
        notificationHandler: @escaping NotificationHandler
    ) {
        if centrals[centralID] == nil {
            centrals[centralID] = [:]
        }
        if centrals[centralID]?[peripheralID] == nil {
            centrals[centralID]?[peripheralID] = [:]
        }
        centrals[centralID]?[peripheralID]?[characteristicUUID] = notificationHandler
    }

    /// Unregister a central
    public func unregisterCentral(_ centralID: UUID) {
        centrals.removeValue(forKey: centralID)
    }

    /// Unregister a central from a specific peripheral
    public func unregisterCentral(_ centralID: UUID, from peripheralID: UUID) {
        centrals[centralID]?.removeValue(forKey: peripheralID)
    }

    // MARK: - Communication

    /// Central writes to a peripheral's characteristic
    /// This routes the write to the peripheral's write handler
    public func centralWrite(
        from centralID: UUID,
        to peripheralID: UUID,
        characteristicUUID: UUID,
        value: Data
    ) async throws {
        // Store the value
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = value

        // Find the peripheral's write handler
        // We don't know the service UUID, so search all services
        for (_, characteristics) in peripherals[peripheralID] ?? [:] {
            if let handler = characteristics[characteristicUUID] {
                await handler(characteristicUUID, value)
                return
            }
        }

        // No handler found - this is OK for mock testing
        // The peripheral might not be actively listening
    }

    /// Central reads from a peripheral's characteristic
    public func centralRead(
        from centralID: UUID,
        to peripheralID: UUID,
        characteristicUUID: UUID
    ) async -> Data? {
        return characteristicValues[peripheralID]?[characteristicUUID]
    }

    /// Peripheral sends notification/indication to subscribed centrals
    public func peripheralNotify(
        from peripheralID: UUID,
        characteristicUUID: UUID,
        value: Data
    ) async {
        // Store the value
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = value

        // Notify all subscribed centrals
        for (_, peripherals) in centrals {
            if let handler = peripherals[peripheralID]?[characteristicUUID] {
                await handler(characteristicUUID, value)
            }
        }
    }

    /// Clear all registrations (for testing)
    public func reset() {
        peripherals.removeAll()
        centrals.removeAll()
        characteristicValues.removeAll()
    }
}
