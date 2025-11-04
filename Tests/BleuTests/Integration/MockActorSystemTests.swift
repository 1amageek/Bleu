import Testing
import Foundation
import Distributed
import CoreBluetooth
@testable import Bleu

// MARK: - Mock BLE Actor System Tests

@Suite("Mock Actor System Tests")
struct MockActorSystemTests {

    // MARK: - Basic Mock Tests

    @Test("Mock system initializes without TCC")
    func testMockSystemInit() async throws {
        // Create mock system - no TCC check should occur
        let system = await BLEActorSystem.mock()

        // System should become ready quickly
        var isReady = false
        for _ in 0..<10 {
            isReady = await system.ready
            if isReady {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        #expect(isReady == true)
    }

    @Test("Mock peripheral manager starts advertising")
    func testMockPeripheralAdvertising() async throws {
        let system = await BLEActorSystem.mock()

        // Access mock peripheral manager
        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        // Initially not advertising
        #expect(await mockPeripheral.isAdvertising == false)

        // Create test service
        let service = ServiceMetadata(
            uuid: UUID(),
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: UUID(),
                    properties: [.read, .write],
                    permissions: [.readable, .writeable]
                )
            ]
        )

        // Add service
        try await mockPeripheral.add(service)

        // Start advertising
        let advertisementData = AdvertisementData(
            localName: "TestPeripheral",
            serviceUUIDs: [service.uuid]
        )
        try await mockPeripheral.startAdvertising(advertisementData)

        // Should be advertising now
        #expect(await mockPeripheral.isAdvertising == true)

        // Stop advertising
        await mockPeripheral.stopAdvertising()
        #expect(await mockPeripheral.isAdvertising == false)
    }

    @Test("Mock central manager scans and connects")
    func testMockCentralScanAndConnect() async throws {
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        guard let mockPeripheral = await peripheralSystem.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        // Setup peripheral
        let serviceUUID = UUID()
        let service = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: []
        )

        try await mockPeripheral.add(service)

        let advertisementData = AdvertisementData(
            localName: "TestDevice",
            serviceUUIDs: [serviceUUID]
        )
        try await mockPeripheral.startAdvertising(advertisementData)

        // Register peripheral in central
        let peripheralID = UUID()
        let discoveredPeripheral = DiscoveredPeripheral(
            id: peripheralID,
            name: "TestDevice",
            rssi: -50,
            advertisementData: advertisementData
        )

        await mockCentral.registerPeripheral(discoveredPeripheral, services: [service])

        // Scan for peripherals
        var foundPeripherals: [DiscoveredPeripheral] = []
        for await peripheral in await mockCentral.scanForPeripherals(
            withServices: [serviceUUID],
            timeout: 1.0
        ) {
            foundPeripherals.append(peripheral)
        }

        #expect(foundPeripherals.count == 1)
        #expect(foundPeripherals.first?.name == "TestDevice")

        // Connect to peripheral
        try await mockCentral.connect(to: peripheralID, timeout: 1.0)
        #expect(await mockCentral.isConnected(peripheralID) == true)

        // Disconnect
        try await mockCentral.disconnect(from: peripheralID)
        #expect(await mockCentral.isConnected(peripheralID) == false)
    }

    @Test("Mock peripheral handles characteristic updates")
    func testMockCharacteristicUpdates() async throws {
        let system = await BLEActorSystem.mock()

        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        // Create service with characteristic
        let charUUID = UUID()
        let service = ServiceMetadata(
            uuid: UUID(),
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: charUUID,
                    properties: [.read, .notify],
                    permissions: [.readable]
                )
            ]
        )

        try await mockPeripheral.add(service)

        // Simulate subscription
        let centralID = UUID()
        await mockPeripheral.simulateSubscription(central: centralID, to: charUUID)

        // Update characteristic value
        let testData = Data([0x01, 0x02, 0x03])
        let success = try await mockPeripheral.updateValue(
            testData,
            for: charUUID,
            to: nil
        )

        #expect(success == true)

        // Verify value was stored
        if let storedValue = await mockPeripheral.getCharacteristicValue(charUUID) {
            #expect(storedValue == testData)
        } else {
            Issue.record("Characteristic value not stored")
        }
    }

    @Test("Mock central discovers services and characteristics")
    func testMockServiceDiscovery() async throws {
        let system = await BLEActorSystem.mock()

        guard let mockCentral = await system.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        // Setup peripheral with services
        let peripheralID = UUID()
        let serviceUUID = UUID()
        let charUUID = UUID()

        let service = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: charUUID,
                    properties: [.read, .write],
                    permissions: [.readable, .writeable]
                )
            ]
        )

        let peripheral = DiscoveredPeripheral(
            id: peripheralID,
            name: "Test",
            rssi: -50,
            advertisementData: AdvertisementData(
                localName: "Test",
                serviceUUIDs: [serviceUUID]
            )
        )

        await mockCentral.registerPeripheral(peripheral, services: [service])

        // Connect
        try await mockCentral.connect(to: peripheralID, timeout: 1.0)

        // Discover services
        let discoveredServices = try await mockCentral.discoverServices(
            for: peripheralID,
            serviceUUIDs: [serviceUUID]
        )

        #expect(discoveredServices.count == 1)
        #expect(discoveredServices.first?.uuid == serviceUUID)

        // Discover characteristics
        let discoveredChars = try await mockCentral.discoverCharacteristics(
            for: serviceUUID,
            in: peripheralID,
            characteristicUUIDs: [charUUID]
        )

        #expect(discoveredChars.count == 1)
        #expect(discoveredChars.first?.uuid == charUUID)
    }

    @Test("Mock handles read and write operations")
    func testMockReadWrite() async throws {
        let system = await BLEActorSystem.mock()

        guard let mockCentral = await system.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        // Setup peripheral
        let peripheralID = UUID()
        let serviceUUID = UUID()
        let charUUID = UUID()

        let service = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: charUUID,
                    properties: [.read, .write],
                    permissions: [.readable, .writeable]
                )
            ]
        )

        let peripheral = DiscoveredPeripheral(
            id: peripheralID,
            name: "Test",
            rssi: -50,
            advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID])
        )

        await mockCentral.registerPeripheral(peripheral, services: [service])
        try await mockCentral.connect(to: peripheralID, timeout: 1.0)

        // Write value
        let testData = Data([0xAA, 0xBB, 0xCC])
        try await mockCentral.writeValue(
            testData,
            for: charUUID,
            in: peripheralID,
            type: .withResponse
        )

        // Read value
        let readData = try await mockCentral.readValue(
            for: charUUID,
            in: peripheralID
        )

        #expect(readData == testData)
    }

    @Test("Mock simulates connection failures")
    func testMockConnectionFailure() async throws {
        var config = MockCentralManager.Configuration()
        config.shouldFailConnection = true

        let system = await BLEActorSystem.mock(centralConfig: config)

        guard let mockCentral = await system.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        // Register a peripheral
        let peripheralID = UUID()
        let peripheral = DiscoveredPeripheral(
            id: peripheralID,
            name: "Test",
            rssi: -50,
            advertisementData: AdvertisementData()
        )

        await mockCentral.registerPeripheral(peripheral, services: [])

        // Attempt connection - should fail
        do {
            try await mockCentral.connect(to: peripheralID, timeout: 1.0)
            Issue.record("Expected connection to fail")
        } catch let error as BleuError {
            // Verify it's a connection failure
            if case .connectionFailed = error {
                // Success - error thrown as expected
            } else {
                Issue.record("Expected BleuError.connectionFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected BleuError, got \(error)")
        }
    }

    @Test("Mock simulates state changes")
    func testMockStateChanges() async throws {
        var config = MockPeripheralManager.Configuration()
        config.initialState = .poweredOff

        let system = await BLEActorSystem.mock(peripheralConfig: config)

        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        // Initial state should be powered off
        #expect(await mockPeripheral.state == .poweredOff)

        // Simulate state change to powered on
        await mockPeripheral.simulateStateChange(.poweredOn)

        // State should now be powered on
        #expect(await mockPeripheral.state == .poweredOn)
    }
}
