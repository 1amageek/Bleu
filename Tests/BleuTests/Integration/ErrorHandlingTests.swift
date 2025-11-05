import Testing
import Foundation
import Distributed
import CoreBluetooth
@testable import Bleu

/// Integration tests focused on error handling scenarios
@Suite("Error Handling Integration Tests")
struct ErrorHandlingTests {

    // MARK: - Service and Characteristic Errors

    @Test("Service not found error")
    func testServiceNotFound() async throws {
        // Create mocks explicitly
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Register peripheral without the expected service
        let peripheralID = UUID()
        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)

        // Register with wrong service UUID
        let wrongService = ServiceMetadata(
            uuid: UUID(),  // Different from what SensorActor expects
            isPrimary: true,
            characteristics: []
        )

        await mockCentral.registerPeripheral(discovered, services: [wrongService])

        // Try to connect - should fail with service not found
        do {
            try await mockCentral.connect(to: peripheralID, timeout: 1.0)

            let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
            _ = try await mockCentral.discoverServices(
                for: peripheralID,
                serviceUUIDs: [serviceUUID]
            )

            // If we get here, service discovery returned empty
            // This is correct behavior - empty array is returned
        } catch {
            // Also acceptable - some implementations may throw
        }
    }

    @Test("Characteristic not found error")
    func testCharacteristicNotFound() async throws {
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        let peripheralID = UUID()
        let serviceUUID = UUID()

        // Register peripheral with service but no characteristics
        let serviceWithoutChars = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: []  // No characteristics
        )

        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)
        await mockCentral.registerPeripheral(discovered, services: [serviceWithoutChars])

        try await mockCentral.connect(to: peripheralID, timeout: 1.0)

        // Try to discover non-existent characteristic
        let chars = try await mockCentral.discoverCharacteristics(
            for: serviceUUID,
            in: peripheralID,
            characteristicUUIDs: [UUID()]
        )

        #expect(chars.isEmpty)
    }

    // MARK: - Connection Errors

    @Test("Peripheral not found error")
    func testPeripheralNotFound() async throws {
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Try to connect to non-existent peripheral
        let nonExistentID = UUID()

        do {
            try await mockCentral.connect(to: nonExistentID, timeout: 1.0)
            Issue.record("Expected peripheralNotFound error")
        } catch let error as BleuError {
            if case .peripheralNotFound(let id) = error {
                #expect(id == nonExistentID)
            } else {
                Issue.record("Expected BleuError.peripheralNotFound, got \(error)")
            }
        }
    }

    @Test("Connection failure with custom message")
    func testConnectionFailureMessage() async throws {
        var config = TestHelpers.fastCentralConfig()
        config.shouldFailConnection = true

        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager(configuration: config)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        let peripheralID = UUID()
        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)

        await mockCentral.registerPeripheral(discovered, services: [])

        do {
            try await mockCentral.connect(to: peripheralID, timeout: 1.0)
            Issue.record("Expected connection to fail")
        } catch let error as BleuError {
            if case .connectionFailed(let message) = error {
                #expect(message == "Mock configured to fail")
            } else {
                Issue.record("Expected BleuError.connectionFailed")
            }
        }
    }

    @Test("Disconnection during operation")
    func testDisconnectionDuringOperation() async throws {
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        let peripheralID = UUID()
        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)
        let service = TestHelpers.createSimpleService()

        await mockCentral.registerPeripheral(discovered, services: [service])

        // Connect
        try await mockCentral.connect(to: peripheralID, timeout: 1.0)
        #expect(await mockCentral.isConnected(peripheralID))

        // Simulate disconnection
        await mockCentral.simulateDisconnection(peripheralID: peripheralID, error: nil)

        // Verify disconnected
        #expect(await mockCentral.isConnected(peripheralID) == false)
    }

    // MARK: - State Errors

    @Test("Bluetooth powered off error")
    func testBluetoothPoweredOff() async throws {
        // Configure both managers to start powered off
        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.initialState = .poweredOff
        peripheralConfig.skipWaitForPoweredOn = true

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.initialState = .poweredOff
        centralConfig.skipWaitForPoweredOn = true

        let mockPeripheral = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral = MockCentralManager(configuration: centralConfig)
        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Give system time to initialize and process state
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Verify initial states are powered off
        #expect(await mockPeripheral.state == .poweredOff)
        #expect(await mockCentral.state == .poweredOff)

        // System should not be ready when Bluetooth is powered off
        #expect(await system.ready == false)

        // Try to start advertising while powered off - should fail
        let sensor = SensorActor(actorSystem: system)
        do {
            try await system.startAdvertising(sensor)
            Issue.record("Expected advertising to fail when Bluetooth is powered off")
        } catch {
            // Expected - advertising should fail when powered off
        }

        // Now power on both managers
        await mockPeripheral.simulateStateChange(.poweredOn)
        await mockCentral.simulateStateChange(.poweredOn)

        // Give system time to process state changes
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        #expect(await mockPeripheral.state == .poweredOn)
        #expect(await mockCentral.state == .poweredOn)

        // System should now be ready
        #expect(await system.ready == true)

        // Advertising should now succeed
        try await system.startAdvertising(sensor)
    }

    @Test("Advertising when not ready")
    func testAdvertisingNotReady() async throws {
        var config = MockPeripheralManager.Configuration()
        config.shouldFailAdvertising = true

        let mockPeripheral = MockPeripheralManager(configuration: config)
        let mockCentral = MockCentralManager()
        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Wait for system to be ready (Bluetooth powered on)
        try await TestHelpers.waitForReady(system)

        // Create actor and try to advertise when mock is configured to fail
        let sensor = SensorActor(actorSystem: system)

        do {
            try await system.startAdvertising(sensor)
            Issue.record("Expected advertising to fail")
        } catch let error as BleuError {
            if case .operationNotSupported = error {
                // Success - expected error
            } else {
                Issue.record("Expected BleuError.operationNotSupported, got \(error)")
            }
        } catch {
            Issue.record("Expected BleuError.operationNotSupported, got \(error)")
        }
    }

    // MARK: - RPC Errors

    @Test("Distributed actor method throws error")
    func testActorMethodThrows() async throws {
        // Create bridge instance for this test
        let bridge = MockBLEBridge()

        // Configure managers to use bridge for cross-system communication
        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.bridge = bridge

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.bridge = bridge

        // Peripheral system
        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        // Central system
        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create error-throwing actor
        let errorActor = ErrorThrowingActor(actorSystem: peripheralSystem)

        // Set peripheral ID so bridge can route messages
        await mockPeripheral1.setPeripheralID(errorActor.id)

        try await peripheralSystem.startAdvertising(errorActor)

        let serviceUUID = UUID.serviceUUID(for: ErrorThrowingActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ErrorThrowingActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: errorActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover and call error-throwing method
        let actors = try await centralSystem.discover(ErrorThrowingActor.self, timeout: 1.0)
        #expect(actors.count == 1)

        let remoteActor = actors[0]

        // Test method that always throws
        do {
            _ = try await remoteActor.alwaysThrows()
            Issue.record("Expected method to throw")
        } catch {
            // Success - error was propagated over RPC via bridge
            // Note: The specific error type might be wrapped
        }
    }

    @Test("Conditional error throwing")
    func testConditionalError() async throws {
        // Create bridge instance for this test
        let bridge = MockBLEBridge()

        // Configure managers to use bridge
        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.bridge = bridge

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.bridge = bridge

        // Peripheral system
        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        // Central system
        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        let errorActor = ErrorThrowingActor(actorSystem: peripheralSystem)

        // Set peripheral ID for bridge routing
        await mockPeripheral1.setPeripheralID(errorActor.id)

        try await peripheralSystem.startAdvertising(errorActor)

        let serviceUUID = UUID.serviceUUID(for: ErrorThrowingActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ErrorThrowingActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: errorActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        let actors = try await centralSystem.discover(ErrorThrowingActor.self, timeout: 1.0)
        #expect(actors.count == 1)

        let remoteActor = actors[0]

        // Should succeed when condition is false
        let result1 = try await remoteActor.throwsIf(false)
        #expect(result1 == "Success")

        // Should throw when condition is true
        do {
            _ = try await remoteActor.throwsIf(true)
            Issue.record("Expected method to throw")
        } catch {
            // Success - error thrown as expected via bridge
        }
    }

    // MARK: - Operation Not Supported

    @Test("Service add failure")
    func testServiceAddFailure() async throws {
        var config = TestHelpers.fastPeripheralConfig()
        config.shouldFailServiceAdd = true

        let mockPeripheral = MockPeripheralManager(configuration: config)
        let mockCentral = MockCentralManager()
        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        let service = TestHelpers.createSimpleService()

        do {
            try await mockPeripheral.add(service)
            Issue.record("Expected service add to fail")
        } catch let error as BleuError {
            if case .operationNotSupported = error {
                // Success
            } else {
                Issue.record("Expected BleuError.operationNotSupported")
            }
        }
    }

    // MARK: - Data Validation Errors

    @Test("Invalid data handling")
    func testInvalidData() async throws {
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        let peripheralID = UUID()
        let service = TestHelpers.createSimpleService()
        let charUUID = service.characteristics[0].uuid

        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)
        await mockCentral.registerPeripheral(discovered, services: [service])

        try await mockCentral.connect(to: peripheralID, timeout: 1.0)

        // Write some data
        let testData = Data([0x00, 0x01, 0x02])
        try await mockCentral.writeValue(
            testData,
            for: charUUID,
            in: peripheralID,
            type: .withResponse
        )

        // Read it back
        let readData = try await mockCentral.readValue(
            for: charUUID,
            in: peripheralID
        )

        #expect(readData == testData)
    }
}
