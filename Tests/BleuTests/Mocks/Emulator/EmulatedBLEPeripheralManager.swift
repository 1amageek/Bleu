import Foundation
import CoreBluetooth
import CoreBluetoothEmulator
@testable import Bleu

/// Adapter that wraps CoreBluetoothEmulator's EmulatedCBPeripheralManager
/// to conform to Bleu's BLEPeripheralManagerProtocol
///
/// This adapter bridges the delegate-based EmulatedCBPeripheralManager API
/// to Bleu's actor-based AsyncStream API, enabling full-fidelity BLE
/// emulation in tests without requiring actual BLE hardware.
public actor EmulatedBLEPeripheralManager: BLEPeripheralManagerProtocol {

    // MARK: - Internal State

    /// The underlying EmulatedCBPeripheralManager from CoreBluetoothEmulator
    private var peripheralManager: EmulatedCBPeripheralManager!

    /// Delegate bridge that converts callbacks to events
    private var delegateBridge: DelegateBridge!

    /// Event channel for AsyncStream
    private let eventChannel = AsyncChannel<BLEEvent>()

    /// Current Bluetooth state
    private var _state: CBManagerState = .unknown

    /// Track if currently advertising
    private var _isAdvertising: Bool = false

    /// Track added services (UUID -> EmulatedCBMutableService)
    private var addedServices: [UUID: EmulatedCBMutableService] = [:]

    /// Track characteristic to service mapping
    private var characteristicToService: [UUID: UUID] = [:]

    /// Track subscribed centrals per characteristic (charUUID -> Set<centralUUID>)
    private var subscribedCentrals: [UUID: Set<UUID>] = [:]

    /// Dispatch queue for delegate callbacks (defaults to main queue)
    private let delegateQueue: DispatchQueue?

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Initial Bluetooth state
        public var initialState: CBManagerState = .poweredOn

        /// Emulator configuration preset
        public var emulatorPreset: EmulatorPreset = .instant

        /// Custom emulator configuration (overrides preset if set)
        public var customEmulatorConfig: EmulatorConfiguration?

        /// Queue for delegate callbacks (nil = main queue)
        public var delegateQueue: DispatchQueue? = nil

        public enum EmulatorPreset: Sendable {
            case instant  // No delays, fast unit testing
            case `default`  // Realistic timing for development
            case slow  // Poor connection simulation
            case unreliable  // Error and failure simulation

            var configuration: EmulatorConfiguration {
                switch self {
                case .instant: return .instant
                case .default: return .default
                case .slow: return .slow
                case .unreliable: return .unreliable
                }
            }
        }

        public init() {}
    }

    private let config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
        self.delegateQueue = configuration.delegateQueue
    }

    // MARK: - BLEPeripheralManagerProtocol Implementation

    public nonisolated var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        get async {
            return _state
        }
    }

    public func initialize() async {
        // EmulatorBus should be configured once by the test, not by each manager
        // Multiple configure() calls can interfere with event routing

        // Create delegate bridge
        let bridge = DelegateBridge(eventChannel: eventChannel, manager: self)
        self.delegateBridge = bridge

        // Create EmulatedCBPeripheralManager
        // This will automatically register with the already-configured EmulatorBus
        let manager = EmulatedCBPeripheralManager(
            delegate: bridge,
            queue: delegateQueue,
            options: nil
        )
        self.peripheralManager = manager
    }

    public func waitForPoweredOn() async -> CBManagerState {
        // Check if already powered on
        if _state == .poweredOn {
            return .poweredOn
        }

        // Wait for state to become powered on
        for await event in eventChannel.stream {
            if case .stateChanged(let newState) = event {
                _state = newState
                if newState == .poweredOn {
                    return .poweredOn
                }
            }
        }
        return _state
    }

    public func add(_ service: ServiceMetadata) async throws {
        // Convert ServiceMetadata to EmulatedCBMutableService
        let cbServiceUUID = CBUUID(nsuuid: service.uuid)
        let cbService = EmulatedCBMutableService(type: cbServiceUUID, primary: service.isPrimary)

        // Convert characteristics
        var cbCharacteristics: [EmulatedCBMutableCharacteristic] = []
        for char in service.characteristics {
            let cbCharUUID = CBUUID(nsuuid: char.uuid)
            let cbChar = EmulatedCBMutableCharacteristic(
                type: cbCharUUID,
                properties: char.properties.cbProperties,
                value: nil,  // Value is set via updateValue
                permissions: char.permissions.cbPermissions
            )
            cbCharacteristics.append(cbChar)

            // Track characteristic to service mapping
            characteristicToService[char.uuid] = service.uuid
        }

        cbService.characteristics = cbCharacteristics

        // Add service to peripheral manager
        peripheralManager.add(cbService)

        // Store service
        addedServices[service.uuid] = cbService

        // The emulator handles service addition synchronously
        // No need to wait for confirmation event
    }

    public func startAdvertising(_ data: AdvertisementData) async throws {
        // Convert AdvertisementData to dictionary
        var advertisementData: [String: Any] = [:]

        if let localName = data.localName {
            advertisementData[CBAdvertisementDataLocalNameKey] = localName
        }

        if !data.serviceUUIDs.isEmpty {
            let cbUUIDs = data.serviceUUIDs.map { CBUUID(nsuuid: $0) }
            advertisementData[CBAdvertisementDataServiceUUIDsKey] = cbUUIDs
        }

        // Start advertising
        peripheralManager.startAdvertising(advertisementData)

        // Wait for peripheralManagerDidStartAdvertising callback
        for await event in eventChannel.stream {
            if case .advertisingStarted(let error) = event {
                if let error = error {
                    throw error
                }
                return
            }
        }
    }

    public func stopAdvertising() async {
        peripheralManager.stopAdvertising()
        _isAdvertising = false
    }

    public var isAdvertising: Bool {
        get async {
            return _isAdvertising
        }
    }

    public func updateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool {
        // Find the characteristic
        guard let serviceUUID = characteristicToService[characteristicUUID],
              let service = addedServices[serviceUUID],
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid.uuidString == characteristicUUID.uuidString
              }) as? EmulatedCBMutableCharacteristic else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        // Note: In the emulator, we don't have direct access to EmulatedCBCentral objects
        // The emulator will handle routing based on subscriptions
        // For now, we'll pass nil and let the emulator route to all subscribed centrals
        let emulatedCentrals: [EmulatedCBCentral]? = nil
        _ = centrals  // Acknowledge parameter (not used in emulator)

        // Update the value
        let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: emulatedCentrals)

        return success
    }

    public func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID] {
        return Array(subscribedCentrals[characteristicUUID] ?? [])
    }

    // MARK: - Internal Helpers

    /// Update state
    internal func updateState(_ newState: CBManagerState) {
        _state = newState
    }

    /// Mark advertising as started
    internal func setAdvertising(_ isAdvertising: Bool) {
        _isAdvertising = isAdvertising
    }

    /// Add subscribed central
    internal func addSubscription(central: UUID, characteristic: UUID) {
        if subscribedCentrals[characteristic] == nil {
            subscribedCentrals[characteristic] = []
        }
        subscribedCentrals[characteristic]?.insert(central)
    }

    /// Remove subscribed central
    internal func removeSubscription(central: UUID, characteristic: UUID) {
        subscribedCentrals[characteristic]?.remove(central)
    }
}

// MARK: - Delegate Bridge

/// Bridge that converts EmulatedCBPeripheralManagerDelegate callbacks to BLEEvent stream
private class DelegateBridge: NSObject, EmulatedCBPeripheralManagerDelegate, @unchecked Sendable {

    private let eventChannel: AsyncChannel<BLEEvent>
    private weak var manager: EmulatedBLEPeripheralManager?

    init(eventChannel: AsyncChannel<BLEEvent>, manager: EmulatedBLEPeripheralManager) {
        self.eventChannel = eventChannel
        self.manager = manager
    }

    // MARK: - EmulatedCBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: EmulatedCBPeripheralManager) {
        Task {
            await manager?.updateState(peripheral.state)
            await eventChannel.send(.stateChanged(peripheral.state))
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: EmulatedCBPeripheralManager, error: Error?) {
        Task {
            if error == nil {
                await manager?.setAdvertising(true)
            }
            await eventChannel.send(.advertisingStarted(error))
        }
    }

    func peripheralManager(_ peripheral: EmulatedCBPeripheralManager, didAdd service: EmulatedCBService, error: Error?) {
        // Service added - we could send an event here if needed
        // For now, the add() method will handle this
    }

    func peripheralManager(
        _ peripheral: EmulatedCBPeripheralManager,
        central: EmulatedCBCentral,
        didSubscribeTo characteristic: EmulatedCBCharacteristic
    ) {
        Task {
            let centralUUID = central.identifier
            let charUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            await manager?.addSubscription(central: centralUUID, characteristic: charUUID)
            await eventChannel.send(.centralSubscribed(centralUUID, serviceUUID, charUUID))
        }
    }

    func peripheralManager(
        _ peripheral: EmulatedCBPeripheralManager,
        central: EmulatedCBCentral,
        didUnsubscribeFrom characteristic: EmulatedCBCharacteristic
    ) {
        Task {
            let centralUUID = central.identifier
            let charUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            await manager?.removeSubscription(central: centralUUID, characteristic: charUUID)
            await eventChannel.send(.centralUnsubscribed(centralUUID, serviceUUID, charUUID))
        }
    }

    func peripheralManager(_ peripheral: EmulatedCBPeripheralManager, didReceiveRead request: EmulatedCBATTRequest) {
        Task {
            let centralUUID = request.central.identifier
            let charUUID = UUID(uuidString: request.characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: request.characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            await eventChannel.send(.readRequestReceived(centralUUID, serviceUUID, charUUID))

            // Respond to the read request
            // In the emulator, the value is typically already set in the characteristic
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(_ peripheral: EmulatedCBPeripheralManager, didReceiveWrite requests: [EmulatedCBATTRequest]) {
        Task {
            for request in requests {
                let centralUUID = request.central.identifier
                let charUUID = UUID(uuidString: request.characteristic.uuid.uuidString) ?? UUID()
                let serviceUUID = UUID(uuidString: request.characteristic.service?.uuid.uuidString ?? "") ?? UUID()
                let data = request.value ?? Data()

                await eventChannel.send(.writeRequestReceived(centralUUID, serviceUUID, charUUID, data))
            }

            // Respond to all write requests
            peripheral.respond(to: requests.first!, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: EmulatedCBPeripheralManager) {
        // The peripheral manager's queue is ready for more notifications
        // This is useful when backpressure is enabled
        // We could send a specific event here if needed
    }
}
