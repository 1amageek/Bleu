import Testing
import Foundation
import Distributed
@testable import Bleu

// Define a custom @Resolvable protocol for testing
@Resolvable
protocol CustomTemperatureSensor: PeripheralActor {
    distributed func readTemperature() async throws -> Double
    distributed func setUnit(_ unit: String) async throws
}

// Concrete implementation of the custom protocol
distributed actor TestTemperatureSensor: CustomTemperatureSensor {
    typealias ActorSystem = BLEActorSystem

    private var unit: String = "celsius"
    private let baseTemp: Double = 25.5

    distributed func readTemperature() async throws -> Double {
        return unit == "celsius" ? baseTemp : (baseTemp * 9/5) + 32
    }

    distributed func setUnit(_ unit: String) async throws {
        self.unit = unit
    }
}

/// Tests for @Resolvable protocol usage
@Suite("Resolvable Protocol Tests")
struct ResolvableTests {

    @Test("Discover and call methods on concrete type")
    func testDiscoverAndCallMethods() async throws {
        // Create bridge for cross-system communication
        let bridge = MockBLEBridge()

        // Create peripheral system
        var peripheralConfig = TestHelpers.fastPeripheralConfig()
        peripheralConfig.bridge = bridge

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager()
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        // Create central system
        var centralConfig = TestHelpers.fastCentralConfig()
        centralConfig.bridge = bridge

        let mockPeripheral2 = MockPeripheralManager()
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Create sensor on peripheral system
        let sensor = SensorActor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(sensor.id)
        try await peripheralSystem.startAdvertising(sensor)

        let serviceUUID = UUID.serviceUUID(for: SensorActor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: sensor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover sensors using traditional approach
        let sensors = try await centralSystem.discover(SensorActor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        // The discovered sensor conforms to PeripheralActor protocol
        let peripheralActor: any PeripheralActor = sensors[0]
        #expect(peripheralActor.id == sensor.id)

        // Call distributed methods on the concrete type
        let temp = try await sensors[0].readTemperature()
        #expect(temp == 22.5)
    }

    @Test("Custom protocol with @Resolvable")
    func testCustomProtocolResolvable() async throws {
        // Create bridge for cross-system communication
        let bridge = MockBLEBridge()

        // Create peripheral system
        var peripheralConfig = TestHelpers.fastPeripheralConfig()
        peripheralConfig.bridge = bridge

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager()
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        // Create central system
        var centralConfig = TestHelpers.fastCentralConfig()
        centralConfig.bridge = bridge

        let mockPeripheral2 = MockPeripheralManager()
        let mockCentral2 = MockCentralManager(configuration: centralConfig)
        let centralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral2,
            centralManager: mockCentral2
        )

        // Wait for systems to be ready
        try await TestHelpers.waitForReady(peripheralSystem)
        try await TestHelpers.waitForReady(centralSystem)

        // Peripheral side: Create a custom temperature sensor
        let sensor = TestTemperatureSensor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(sensor.id)
        try await peripheralSystem.startAdvertising(sensor)

        let serviceUUID = UUID.serviceUUID(for: TestTemperatureSensor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: TestTemperatureSensor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: sensor.id,
            serviceUUIDs: [serviceUUID]
        )
        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Central side: First discover to establish connection
        let sensors = try await centralSystem.discover(TestTemperatureSensor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        // Now use @Resolvable to resolve the same sensor using custom protocol
        // The $CustomTemperatureSensor type is generated by @Resolvable macro
        let resolvedSensor = try $CustomTemperatureSensor.resolve(id: sensor.id, using: centralSystem)

        // Verify resolution
        #expect(resolvedSensor.id == sensor.id)

        // Call distributed methods defined in custom protocol
        let tempCelsius = try await resolvedSensor.readTemperature()
        #expect(tempCelsius == 25.5)

        // Change unit to fahrenheit
        try await resolvedSensor.setUnit("fahrenheit")

        // Read temperature again - should be in fahrenheit now
        let tempFahrenheit = try await resolvedSensor.readTemperature()
        #expect(tempFahrenheit == 77.9)  // (25.5 * 9/5) + 32

        // This demonstrates that users can define their own @Resolvable protocols
        // with custom distributed methods and use the generated stubs for resolution
    }
}
