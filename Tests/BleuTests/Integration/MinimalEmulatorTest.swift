import Testing
import Foundation
import CoreBluetooth
import CoreBluetoothEmulator
@testable import Bleu

/// Parent suite for all EmulatorBus tests - ensures serial execution
@Suite("EmulatorBus Tests", .serialized)
enum EmulatorBusTests {}

extension EmulatorBusTests {
    /// Minimal test to debug emulator initialization
    @Suite("Minimal Emulator Test")
    struct MinimalEmulatorTest {

    @Test("Just initialize peripheral manager")
    func testPeripheralInitialization() async throws {
        print("Test started")

        await EmulatorBus.shared.reset()
        print("Bus reset complete")

        await EmulatorBus.shared.configure(.instant)
        print("Bus configured")

        var config = EmulatedBLEPeripheralManager.Configuration()
        config.emulatorPreset = .instant
        let peripheral = EmulatedBLEPeripheralManager(configuration: config)
        print("Peripheral manager created")

        await peripheral.initialize()
        print("Peripheral manager initialized")

        let state = await peripheral.state
        print("Peripheral state: \(state.rawValue)")

        print("Calling waitForPoweredOn...")
        let finalState = await peripheral.waitForPoweredOn()
        print("waitForPoweredOn returned: \(finalState.rawValue)")

        #expect(finalState == .poweredOn)
        print("Test complete")
    }

    @Test("Full connection flow")
    func testFullConnection() async throws {
        print("=== Test started ===")

        // Setup - use unique UUIDs to avoid interference with other tests
        let serviceUUID = UUID()
        let charUUID = UUID()
        let peripheralName = "TestPeripheral-\(UUID().uuidString.prefix(8))"

        // Configure bus (don't reset to avoid interfering with parallel tests)
        await EmulatorBus.shared.configure(.instant)
        print("Bus configured")

        // Create peripheral
        print("--- Creating peripheral ---")
        var peripheralConfig = EmulatedBLEPeripheralManager.Configuration()
        peripheralConfig.emulatorPreset = .instant
        let peripheral = EmulatedBLEPeripheralManager(configuration: peripheralConfig)
        print("Peripheral created")

        await peripheral.initialize()
        print("Peripheral initialized")

        _ = await peripheral.waitForPoweredOn()
        print("Peripheral powered on")

        // Add service
        print("--- Adding service ---")
        let service = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: charUUID,
                    properties: [.read, .notify],
                    permissions: [.readable]
                )
            ]
        )
        try await peripheral.add(service)
        print("Service added")

        // Start advertising
        print("--- Starting advertising ---")
        let advData = AdvertisementData(
            localName: peripheralName,
            serviceUUIDs: [serviceUUID]
        )
        try await peripheral.startAdvertising(advData)
        print("Advertising started with name: \(peripheralName)")

        // Create central
        print("--- Creating central ---")
        var centralConfig = EmulatedBLECentralManager.Configuration()
        centralConfig.emulatorPreset = .instant
        let central = EmulatedBLECentralManager(configuration: centralConfig)
        print("Central created")

        await central.initialize()
        print("Central initialized")

        _ = await central.waitForPoweredOn()
        print("Central powered on")

        // Scan for peripheral
        print("--- Scanning for peripheral ---")
        var discoveredID: UUID?
        for await discovered in central.scanForPeripherals(
            withServices: [serviceUUID],
            timeout: 3.0
        ) {
            print("Discovered: \(discovered.name ?? "unknown") with ID: \(discovered.id)")
            if discovered.name == peripheralName {
                discoveredID = discovered.id
                break
            }
        }
        print("Scan complete")

        guard let peripheralID = discoveredID else {
            print("ERROR: Failed to discover peripheral")
            throw BleuError.peripheralNotFound(serviceUUID)
        }
        print("Peripheral discovered: \(peripheralID)")

        // Connect
        print("--- Connecting ---")
        try await central.connect(to: peripheralID, timeout: 2.0)
        print("Connected successfully")

        print("=== Test complete ===")
    }
}
}
