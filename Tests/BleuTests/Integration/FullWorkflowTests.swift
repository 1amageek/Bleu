import Testing
import Foundation
import Distributed
@testable import Bleu

/// Integration tests for complete peripheral-central workflows using mock BLE
@Suite("Full Workflow Integration Tests")
struct FullWorkflowTests {

    // MARK: - Complete Discovery and Connection Flow

    @Test("Complete discovery to RPC flow")
    func testCompleteFlow() async throws {
        // Reset bridge
        await MockBLEBridge.shared.reset()

        // Create separate systems with bridge enabled
        var peripheralConfig = TestHelpers.fastPeripheralConfig()
        peripheralConfig.useBridge = true

        var centralConfig = TestHelpers.fastCentralConfig()
        centralConfig.useBridge = true

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create and advertise sensor
        let sensor = SensorActor(actorSystem: peripheralSystem)

        // Set peripheral ID for bridge routing
        await mockPeripheral1.setPeripheralID(sensor.id)

        try await peripheralSystem.startAdvertising(sensor)

        let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: sensor.id,
            name: "Sensor",
            serviceUUIDs: [serviceUUID]
        )

        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover sensors
        let sensors = try await centralSystem.discover(SensorActor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        // Call distributed methods
        let temp = try await sensors[0].readTemperature()
        #expect(temp == 22.5)

        let humidity = try await sensors[0].readHumidity()
        #expect(humidity == 45.0)

        let reading = try await sensors[0].readAll()
        #expect(reading.temperature == 22.5)
        #expect(reading.humidity == 45.0)
    }

    // MARK: - Multiple Peripherals

    @Test("Discover multiple peripherals")
    func testMultiplePeripherals() async throws {
        // Reset bridge
        await MockBLEBridge.shared.reset()

        // Configure with bridge
        var peripheralConfig = TestHelpers.fastPeripheralConfig()
        peripheralConfig.useBridge = true

        var centralConfig = TestHelpers.fastCentralConfig()
        centralConfig.useBridge = true

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create multiple sensors
        let sensor1 = SensorActor(actorSystem: peripheralSystem)
        let sensor2 = SensorActor(actorSystem: peripheralSystem)
        let sensor3 = SensorActor(actorSystem: peripheralSystem)

        // Set peripheral IDs for bridge routing
        await mockPeripheral1.setPeripheralID(sensor1.id)
        await mockPeripheral1.setPeripheralID(sensor2.id)
        await mockPeripheral1.setPeripheralID(sensor3.id)

        try await peripheralSystem.startAdvertising(sensor1)
        try await peripheralSystem.startAdvertising(sensor2)
        try await peripheralSystem.startAdvertising(sensor3)

        let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)

        // Register all three peripherals
        for sensor in [sensor1, sensor2, sensor3] {
            let discovered = TestHelpers.createDiscoveredPeripheral(
                id: sensor.id,
                name: "Sensor-\(sensor.id)",
                serviceUUIDs: [serviceUUID]
            )
            await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])
        }

        // Discover all sensors
        let sensors = try await centralSystem.discover(SensorActor.self, timeout: 1.0)
        #expect(sensors.count == 3)

        // Verify all sensors work
        for sensor in sensors {
            let temp = try await sensor.readTemperature()
            #expect(temp == 22.5)
        }
    }

    // MARK: - Stateful Interactions

    @Test("Stateful counter interactions")
    func testStatefulCounter() async throws {
        await MockBLEBridge.shared.reset()

        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.useBridge = true

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.useBridge = true

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create counter actor
        let counter = CounterActor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(counter.id)
        try await peripheralSystem.startAdvertising(counter)

        let serviceUUID = UUID.serviceUUID(for: CounterActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: CounterActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: counter.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Connect and interact
        let counters = try await centralSystem.discover(CounterActor.self, timeout: 1.0)
        #expect(counters.count == 1)

        let remoteCounter = counters[0]

        // Test stateful operations
        var count = try await remoteCounter.increment()
        #expect(count == 1)

        count = try await remoteCounter.increment()
        #expect(count == 2)

        count = try await remoteCounter.add(5)
        #expect(count == 7)

        count = try await remoteCounter.decrement()
        #expect(count == 6)

        try await remoteCounter.reset()
        count = try await remoteCounter.getCount()
        #expect(count == 0)
    }

    // MARK: - Error Handling

    @Test("Connection failure handling")
    func testConnectionFailure() async throws {
        var config = TestHelpers.fastCentralConfig()
        config.shouldFailConnection = true

        let mockCentral = MockCentralManager(configuration: config)
        let mockPeripheral = MockPeripheralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Register a peripheral
        let peripheralID = UUID()
        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)
        let serviceMetadata = TestHelpers.createSimpleService()

        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Attempt connection - should fail
        do {
            try await centralSystem.connect(to: peripheralID, as: SimpleValueActor.self)
            Issue.record("Expected connection to fail")
        } catch let error as BleuError {
            if case .connectionFailed = error {
                // Success - error thrown as expected
            } else {
                Issue.record("Expected BleuError.connectionFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected BleuError, got \(error)")
        }
    }

    @Test("Timeout handling")
    func testConnectionTimeout() async throws {
        var config = TestHelpers.fastCentralConfig()
        config.connectionTimeout = true

        let mockCentral = MockCentralManager(configuration: config)
        let mockPeripheral = MockPeripheralManager()
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Register a peripheral
        let peripheralID = UUID()
        let discovered = TestHelpers.createDiscoveredPeripheral(id: peripheralID)
        let serviceMetadata = TestHelpers.createSimpleService()

        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Attempt connection - should timeout
        do {
            try await centralSystem.connect(to: peripheralID, as: SimpleValueActor.self)
            Issue.record("Expected connection to timeout")
        } catch let error as BleuError {
            if case .connectionTimeout = error {
                // Success - timeout as expected
            } else {
                Issue.record("Expected BleuError.connectionTimeout, got \(error)")
            }
        } catch {
            Issue.record("Expected BleuError.connectionTimeout, got \(error)")
        }
    }

    // MARK: - Complex Data Transfer

    @Test("Complex data structures over RPC")
    func testComplexDataTransfer() async throws {
        await MockBLEBridge.shared.reset()

        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.useBridge = true

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.useBridge = true

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create complex data actor
        let dataActor = ComplexDataActor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(dataActor.id)
        try await peripheralSystem.startAdvertising(dataActor)

        let serviceUUID = UUID.serviceUUID(for: ComplexDataActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ComplexDataActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: dataActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover and call
        let actors = try await centralSystem.discover(ComplexDataActor.self, timeout: 1.0)
        #expect(actors.count == 1)

        let complexData = try await actors[0].getComplexData()

        // Verify complex data structure
        #expect(complexData.values == [1, 2, 3, 4, 5])
        #expect(complexData.metadata.version == "1.0.0")
        #expect(complexData.nested.flag == true)
        #expect(complexData.nested.description == "Test data")
    }

    // MARK: - Concurrent Operations

    @Test("Concurrent RPC calls")
    func testConcurrentRPCCalls() async throws {
        await MockBLEBridge.shared.reset()

        var peripheralConfig = MockPeripheralManager.Configuration()
        peripheralConfig.useBridge = true

        var centralConfig = MockCentralManager.Configuration()
        centralConfig.useBridge = true

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager(configuration: centralConfig)
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        let mockPeripheral2 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create counter
        let counter = CounterActor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(counter.id)
        try await peripheralSystem.startAdvertising(counter)

        let serviceUUID = UUID.serviceUUID(for: CounterActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: CounterActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: counter.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Connect
        let counters = try await centralSystem.discover(CounterActor.self, timeout: 1.0)
        #expect(counters.count == 1)

        let remoteCounter = counters[0]

        // Make concurrent calls
        async let count1 = remoteCounter.increment()
        async let count2 = remoteCounter.increment()
        async let count3 = remoteCounter.increment()

        let results = try await [count1, count2, count3]

        // All should succeed (order may vary due to actor isolation)
        #expect(results.count == 3)
        #expect(results.contains(1))
        #expect(results.contains(2))
        #expect(results.contains(3))
    }
}
