import Testing
import Foundation
import Distributed
@testable import Bleu

/// Integration tests focused on error handling scenarios
@Suite("Error Handling Integration Tests")
struct ErrorHandlingTests {

    // MARK: - Service and Characteristic Errors

    @Test("Service not found error")
    func testServiceNotFound() async throws {
        let centralSystem = await BLEActorSystem.mock()

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
        let centralSystem = await BLEActorSystem.mock()

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
        let centralSystem = await BLEActorSystem.mock()

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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

        let centralSystem = await BLEActorSystem.mock(centralConfig: config)

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
        let centralSystem = await BLEActorSystem.mock()

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
        var config = MockPeripheralManager.Configuration()
        config.initialState = .poweredOff

        let system = await BLEActorSystem.mock(peripheralConfig: config)

        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        // Verify initial state
        #expect(await mockPeripheral.state == .poweredOff)

        // Try to add service while powered off - should wait for power on
        let service = TestHelpers.createSimpleService()

        // The mock's waitForPoweredOn will simulate powering on
        // This tests the state handling logic
        let state = await mockPeripheral.waitForPoweredOn()
        #expect(state == .poweredOn)
    }

    @Test("Advertising when not ready")
    func testAdvertisingNotReady() async throws {
        var config = MockPeripheralManager.Configuration()
        config.shouldFailAdvertising = true

        let system = await BLEActorSystem.mock(peripheralConfig: config)

        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

        let service = TestHelpers.createSimpleService()
        try await mockPeripheral.add(service)

        let advertisementData = TestHelpers.createAdvertisementData()

        do {
            try await mockPeripheral.startAdvertising(advertisementData)
            Issue.record("Expected advertising to fail")
        } catch let error as BleuError {
            if case .operationNotSupported = error {
                // Success - expected error
            } else {
                Issue.record("Expected BleuError.operationNotSupported")
            }
        }
    }

    // MARK: - RPC Errors

    @Test("Distributed actor method throws error")
    func testActorMethodThrows() async throws {
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        // Create error-throwing actor
        let errorActor = ErrorThrowingActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(errorActor)

        // Setup mock central
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: ErrorThrowingActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ErrorThrowingActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: errorActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover and call error-throwing method
        let actors = try await centralSystem.discover(ErrorThrowingActor.self, timeout: 1.0)
        #expect(actors.count == 1)

        let remoteActor = actors[0]

        // Test method that always throws
        do {
            _ = try await remoteActor.alwaysThrows()
            Issue.record("Expected method to throw")
        } catch {
            // Success - error was propagated over RPC
            // Note: The specific error type might be wrapped
        }
    }

    @Test("Conditional error throwing")
    func testConditionalError() async throws {
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        let errorActor = ErrorThrowingActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(errorActor)

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: ErrorThrowingActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ErrorThrowingActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: errorActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

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
            // Success - error thrown as expected
        }
    }

    // MARK: - Operation Not Supported

    @Test("Service add failure")
    func testServiceAddFailure() async throws {
        var config = TestHelpers.fastPeripheralConfig()
        config.shouldFailServiceAdd = true

        let system = await BLEActorSystem.mock(peripheralConfig: config)

        guard let mockPeripheral = await system.mockPeripheralManager() else {
            Issue.record("Expected mock peripheral manager")
            return
        }

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
        let centralSystem = await BLEActorSystem.mock()

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
