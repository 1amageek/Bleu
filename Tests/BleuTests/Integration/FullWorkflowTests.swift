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
        // Create separate systems for peripheral and central
        let peripheralSystem = await BLEActorSystem.mock(
            peripheralConfig: TestHelpers.fastPeripheralConfig()
        )
        let centralSystem = await BLEActorSystem.mock(
            centralConfig: TestHelpers.fastCentralConfig()
        )

        // Create and advertise sensor
        let sensor = SensorActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(sensor)

        // Setup mock central to discover the sensor
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: sensor.id,
            name: "Sensor",
            serviceUUIDs: [serviceUUID]
        )

        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

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
        let peripheralSystem = await BLEActorSystem.mock(
            peripheralConfig: TestHelpers.fastPeripheralConfig()
        )
        let centralSystem = await BLEActorSystem.mock(
            centralConfig: TestHelpers.fastCentralConfig()
        )

        // Create multiple sensors
        let sensor1 = SensorActor(actorSystem: peripheralSystem)
        let sensor2 = SensorActor(actorSystem: peripheralSystem)
        let sensor3 = SensorActor(actorSystem: peripheralSystem)

        try await peripheralSystem.startAdvertising(sensor1)
        try await peripheralSystem.startAdvertising(sensor2)
        try await peripheralSystem.startAdvertising(sensor3)

        // Setup mock central
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)

        // Register all three peripherals
        for sensor in [sensor1, sensor2, sensor3] {
            let discovered = TestHelpers.createDiscoveredPeripheral(
                id: sensor.id,
                name: "Sensor-\(sensor.id)",
                serviceUUIDs: [serviceUUID]
            )
            await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])
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
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        // Create counter actor
        let counter = CounterActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(counter)

        // Setup mock central
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: CounterActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: CounterActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: counter.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

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

        let centralSystem = await BLEActorSystem.mock(centralConfig: config)

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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

        let centralSystem = await BLEActorSystem.mock(centralConfig: config)

        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

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
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        // Create complex data actor
        let dataActor = ComplexDataActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(dataActor)

        // Setup mock central
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: ComplexDataActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: ComplexDataActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: dataActor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

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
        let peripheralSystem = await BLEActorSystem.mock()
        let centralSystem = await BLEActorSystem.mock()

        // Create counter
        let counter = CounterActor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(counter)

        // Setup mock central
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: CounterActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: CounterActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: counter.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

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
