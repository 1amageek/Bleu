<div align="center">
  <img src="Bleu.png" alt="Bleu Logo" width="600">
  
  # Bleu 2
  
  **Modern Bluetooth Low Energy Framework with Swift Distributed Actors**
  
  [![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
  [![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20|%20macOS%2015%2B%20|%20watchOS%2011%2B%20|%20tvOS%2018%2B-brightgreen.svg)](https://developer.apple.com/swift/)
  [![Swift Package Manager](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
  [![Test](https://github.com/1amageek/Bleu/actions/workflows/test.yml/badge.svg)](https://github.com/1amageek/Bleu/actions/workflows/test.yml)
  [![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
</div>

---

## Overview

Bleu 2 is a revolutionary Bluetooth Low Energy framework that leverages **Swift's Distributed Actor System** and **`@Resolvable` protocols** to create seamless, type-safe communication between BLE devices.

**Define a protocol, implement it, and call methods over BLE—it's that simple.**

No complex BLE APIs. No manual serialization. No boilerplate code. Just define your distributed actor protocol with `@Resolvable`, and Bleu handles everything else automatically.

## ✨ Key Features

### 🎯 **Protocol-Oriented BLE with @Resolvable**
- **Define a protocol** with distributed methods
- **Implement on peripheral** as a distributed actor
- **Resolve on central** using auto-generated stubs
- **Call methods over BLE** as if they were local
- Zero boilerplate, maximum simplicity

### 🎭 **Distributed Actor Architecture**
- Transparent RPC over BLE using Swift's native distributed actors
- Type-safe remote method invocation
- Automatic serialization and error handling
- Actor isolation for thread safety

### 🚀 **High Performance**
- Binary packet fragmentation with 24-byte headers
- Efficient data transport with checksums
- Adaptive MTU negotiation
- Automatic packet reassembly

### 📱 **Modern Swift Integration**
- Full async/await support
- AsyncStream for real-time data
- Swift 6 concurrency features
- Sendable protocol compliance

### 🔧 **Developer Friendly**
- Simple, intuitive API
- Comprehensive logging system
- Automatic resource management
- Clean error handling

## 🚀 Quick Start

### Installation

Add Bleu to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/Bleu.git", from: "2.0.0")
]
```

### The Simplest Way: Using @Resolvable

```swift
import Bleu
import Distributed

// 1. Define your BLE device API as a protocol
@Resolvable
protocol TemperatureSensor: PeripheralActor {
    distributed func getTemperature() async throws -> Double
    distributed func setUpdateInterval(_ seconds: Int) async throws
}

// 2. Peripheral: Implement the protocol
distributed actor MyThermometer: TemperatureSensor {
    typealias ActorSystem = BLEActorSystem

    distributed func getTemperature() async throws -> Double {
        return 25.5  // Read from actual sensor
    }

    distributed func setUpdateInterval(_ seconds: Int) async throws {
        // Configure update rate
    }
}

// 3. Central: Resolve and call methods over BLE
let actorSystem = BLEActorSystem(
    peripheralManager: CoreBluetoothPeripheralManager(),
    centralManager: CoreBluetoothCentralManager()
)

// Discover the sensor
let sensors = try await actorSystem.discover(MyThermometer.self, timeout: 10.0)

// Resolve using the protocol (works even if you only know the ID!)
let sensor = try $TemperatureSensor.resolve(id: sensors[0].id, using: actorSystem)

// Call methods as if the sensor were local
let temp = try await sensor.getTemperature()  // 🎉 That's it!
```

### Traditional Approach: Concrete Actor Types

You can also define distributed actors directly without protocols:

```swift
import Bleu
import Distributed

// Define a distributed actor that runs on a BLE peripheral
distributed actor TemperatureSensor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func getTemperature() async throws -> Double {
        // Read from actual sensor hardware
        return 25.5
    }

    distributed func setUpdateInterval(_ seconds: Int) async throws {
        // Configure sensor update rate
    }
}
```

#### Peripheral Side

```swift
// Create BLE actor system with CoreBluetooth managers
let peripheralManager = CoreBluetoothPeripheralManager()
let centralManager = CoreBluetoothCentralManager()
let actorSystem = BLEActorSystem(
    peripheralManager: peripheralManager,
    centralManager: centralManager
)

// Create and advertise the sensor
let sensor = TemperatureSensor(actorSystem: actorSystem)

// Start advertising the sensor service
try await actorSystem.startAdvertising(sensor)
```

#### Central Side

```swift
// Create BLE actor system with CoreBluetooth managers
let peripheralManager = CoreBluetoothPeripheralManager()
let centralManager = CoreBluetoothCentralManager()
let actorSystem = BLEActorSystem(
    peripheralManager: peripheralManager,
    centralManager: centralManager
)

// Discover and connect to sensors
let sensors = try await actorSystem.discover(TemperatureSensor.self, timeout: 10.0)

if let remoteSensor = sensors.first {
    // Call methods on the remote sensor as if it were local!
    let temperature = try await remoteSensor.getTemperature()
    print("Current temperature: \(temperature)°C")

    // Configure the remote sensor
    try await remoteSensor.setUpdateInterval(5)
}
```

## 🎯 Advanced Features

### Protocol-Based Actor Resolution with @Resolvable

Bleu 2 leverages Swift's `@Resolvable` macro ([SE-0428](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0428-resolve-distributed-actor-protocols.md)) to enable protocol-oriented distributed actor design. You can define your own protocols with distributed methods and use the compiler-generated stubs to resolve remote actors without knowing their concrete implementations.

#### Why Use @Resolvable?

- **Protocol-First API Design**: Define your BLE device APIs as protocols
- **Implementation Flexibility**: Peripheral implementations remain private
- **Type-Safe Resolution**: Resolve actors by ID using protocol types
- **Module Separation**: Share protocol definitions across app modules
- **Easy Testing**: Mock protocol implementations for unit tests

#### Define Your Own Protocol

**Important**: Add `@Resolvable` to **your custom protocols**, not to the base `PeripheralActor` protocol. The `PeripheralActor` protocol is a marker protocol without distributed methods.

```swift
// Step 1: Define a custom protocol with @Resolvable and distributed methods
@Resolvable
protocol TemperatureSensor: PeripheralActor {
    distributed func getTemperature() async throws -> Double
    distributed func setTemperatureUnit(_ unit: String) async throws
}

// Step 2: Peripheral side - Implement the protocol
distributed actor IndoorSensor: TemperatureSensor {
    typealias ActorSystem = BLEActorSystem

    private var unit = "celsius"

    distributed func getTemperature() async throws -> Double {
        return unit == "celsius" ? 25.5 : 77.9
    }

    distributed func setTemperatureUnit(_ unit: String) async throws {
        self.unit = unit
    }
}

// Step 3: Central side - Work with the protocol, not the concrete type
let actorSystem = BLEActorSystem(
    peripheralManager: CoreBluetoothPeripheralManager(),
    centralManager: CoreBluetoothCentralManager()
)

// Option 1: Discover sensors using concrete type
let sensors = try await actorSystem.discover(IndoorSensor.self, timeout: 10.0)
if let sensor = sensors.first {
    let temp = try await sensor.getTemperature()
}

// Option 2: Resolve by ID using @Resolvable-generated stub
// The @Resolvable macro generates a $TemperatureSensor type automatically
let knownSensorID = UUID(/* saved sensor ID */)
let sensor = try $TemperatureSensor.resolve(id: knownSensorID, using: actorSystem)

// Call methods defined in the protocol
try await sensor.setTemperatureUnit("fahrenheit")
let temp = try await sensor.getTemperature()

// Pass around as protocol type - no concrete type needed!
func monitorTemperature(_ sensor: any TemperatureSensor) async throws {
    let temp = try await sensor.getTemperature()
    print("Current temperature: \(temp)")
}
try await monitorTemperature(sensor)
```

#### Use Cases

```swift
// Example: Multiple sensor types with same protocol
@Resolvable
protocol EnvironmentSensor: PeripheralActor {
    distributed func readValue() async throws -> Double
    distributed func calibrate() async throws
}

distributed actor TemperatureSensor: EnvironmentSensor { /* ... */ }
distributed actor HumiditySensor: EnvironmentSensor { /* ... */ }
distributed actor PressureSensor: EnvironmentSensor { /* ... */ }

// Central can work with all sensors uniformly
func readAllSensors(_ sensors: [any EnvironmentSensor]) async throws -> [Double] {
    try await withThrowingTaskGroup(of: Double.self) { group in
        for sensor in sensors {
            group.addTask { try await sensor.readValue() }
        }

        var values: [Double] = []
        for try await value in group {
            values.append(value)
        }
        return values
    }
}
```

#### Key Benefits

- **Protocol-First Design**: Define your device APIs as protocols with distributed methods
- **Automatic Stub Generation**: Swift compiler generates `$ProtocolName` types for resolution
- **Location Transparency**: Work with protocol types without knowing concrete implementations
- **Module Separation**: Share protocol definitions across modules, keep implementations private
- **Type Safety**: Full compiler verification of distributed method calls
- **Flexible Resolution**: Resolve actors by ID without discovery process

### Custom Service Metadata

```swift
distributed actor SmartLight: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    // Custom service configuration
    static var serviceMetadata: ServiceMetadata {
        ServiceMetadata(
            uuid: UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!,
            characteristics: [
                CharacteristicMetadata(
                    uuid: UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!,
                    properties: [.read, .write, .notify],
                    permissions: [.readable, .writeable]
                )
            ]
        )
    }
    
    distributed func setBrightness(_ level: Int) async throws {
        // Control light brightness
    }
    
    distributed func setColor(_ rgb: (r: Int, g: Int, b: Int)) async throws {
        // Set RGB color
    }
}
```

### Notifications and Subscriptions

```swift
distributed actor HeartRateMonitor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    // Stream heart rate data
    distributed func streamHeartRate() -> AsyncStream<Int> {
        AsyncStream { continuation in
            // Setup sensor monitoring
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let heartRate = Int.random(in: 60...100)
                continuation.yield(heartRate)
            }
        }
    }
}

// Client side - subscribe to updates
let monitor = try await actorSystem.connect(to: deviceID, as: HeartRateMonitor.self)
for await heartRate in await monitor.streamHeartRate() {
    print("Heart rate: \(heartRate) BPM")
}
```

### Error Handling

```swift
do {
    let devices = try await actorSystem.discover(TemperatureSensor.self)
    // ... use devices
} catch BleuError.bluetoothPoweredOff {
    print("Please enable Bluetooth")
} catch BleuError.connectionTimeout {
    print("Connection timed out")
} catch {
    print("Unexpected error: \(error)")
}
```

## 📋 Architecture

### Core Components

- **`BLEActorSystem`**: The distributed actor system managing BLE communication
- **`PeripheralActor`**: Protocol for actors that can be advertised as BLE peripherals
- **`BLETransport`**: Handles packet fragmentation and reassembly
- **`ServiceMapper`**: Maps actor types to BLE service metadata
- **Manager Protocols**: Protocol-oriented design for testability without hardware

### Communication Flow

```
┌─────────────┐                    ┌─────────────┐
│   Central   │                    │ Peripheral  │
└──────┬──────┘                    └──────┬──────┘
       │                                   │
       │  discover(TemperatureSensor)      │
       │────────────────────────────────>  │
       │                                   │
       │  <────────────────────────────    │
       │     [TemperatureSensor actors]    │
       │                                   │
       │  remoteSensor.getTemperature()    │
       │────────────────────────────────>  │
       │                                   │
       │  <────────────────────────────    │
       │            25.5°C                 │
       └───────────────────────────────────┘
```

### Binary Packet Format

Bleu uses an efficient binary packet format for BLE communication:

```
┌──────────────┬─────────────┬──────────────┬──────────┐
│  UUID (16B)  │  Seq (2B)   │  Total (2B)  │ CRC (4B) │ Payload
└──────────────┴─────────────┴──────────────┴──────────┘
        24-byte header
```

## 🧪 Testing

Bleu 2 features a **Protocol-Oriented Testing Architecture** that enables comprehensive testing without requiring real Bluetooth hardware or TCC permissions. This architecture provides in-memory BLE simulation, allowing unit and integration tests to run in CI/CD environments.

### Key Testing Benefits

- ✅ **No Hardware Required**: Mock implementations simulate complete BLE behavior
- ✅ **No TCC Permissions**: Unit and integration tests run without Bluetooth access
- ✅ **Fast Execution**: Tests complete in seconds, not minutes
- ✅ **CI/CD Friendly**: All tests (except hardware validation) run in automated environments
- ✅ **Type-Safe**: Full type safety across mock and production implementations

### Test Directory Structure

```
Tests/BleuTests/
├── Unit/                          # Pure unit tests (no BLE)
│   ├── UnitTests.swift            # Core functionality tests
│   ├── RPCTests.swift             # RPC mechanism tests
│   ├── EventBridgeTests.swift    # Event routing tests
│   └── TransportLayerTests.swift # Message transport tests
│
├── Integration/                   # Mock-based integration tests
│   ├── MockActorSystemTests.swift # Mock manager tests
│   ├── FullWorkflowTests.swift    # Complete workflows
│   └── ErrorHandlingTests.swift   # Error scenarios
│
├── Hardware/                      # Real BLE hardware tests
│   └── RealBLETests.swift         # Requires real hardware
│
└── Mocks/                         # Test utilities
    ├── TestHelpers.swift          # Common test helpers
    └── MockActorExamples.swift    # Example distributed actors
```

### Running Tests

```bash
# Run all tests (unit + integration, skips hardware)
swift test

# Run specific test suite
swift test --filter "Mock Actor System Tests"

# Run with verbose output
swift test --verbose

# Parallel execution
swift test --parallel
```

### Quick Start: Writing Tests

#### Unit Tests (No BLE Dependency)

```swift
import Testing
@testable import Bleu

@Suite("Transport Layer")
struct TransportTests {
    @Test("Packet fragmentation")
    func testFragmentation() async {
        let transport = BLETransport.shared
        let data = Data(repeating: 0xFF, count: 1000)

        let packets = await transport.fragment(data)
        #expect(packets.count > 1)
    }
}
```

#### Integration Tests with Mock BLE

```swift
import Testing
import Distributed
@testable import Bleu

@Suite("BLE System Integration")
struct MockBLESystemTests {
    @Test("Complete discovery to RPC flow")
    func testCompleteFlow() async throws {
        // Create bridge for cross-system communication
        let bridge = MockBLEBridge()

        // Create peripheral system with mock managers
        var peripheralConfig = TestHelpers.fastPeripheralConfig()
        peripheralConfig.bridge = bridge

        let mockPeripheral1 = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral1 = MockCentralManager()
        let peripheralSystem = BLEActorSystem(
            peripheralManager: mockPeripheral1,
            centralManager: mockCentral1
        )

        // Create central system with mock managers
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

        // Define test actor
        distributed actor TestSensor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            distributed func getValue() async -> Int {
                return 42
            }
        }

        // Setup peripheral
        let sensor = TestSensor(actorSystem: peripheralSystem)
        await mockPeripheral1.setPeripheralID(sensor.id)
        try await peripheralSystem.startAdvertising(sensor)

        // Register peripheral for discovery
        let serviceUUID = UUID.serviceUUID(for: TestSensor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: TestSensor.self)

        let discovered = TestHelpers.createDiscoveredPeripheral(
            id: sensor.id,
            name: "TestSensor",
            serviceUUIDs: [serviceUUID]
        )

        await mockCentral2.registerPeripheral(discovered, services: [serviceMetadata])

        // Test discovery and RPC
        let sensors = try await centralSystem.discover(TestSensor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        let value = try await sensors[0].getValue()
        #expect(value == 42)
    }
}
```

#### Using Test Helpers

Bleu provides comprehensive test utilities:

```swift
// Fast mock configurations (10ms delays)
let peripheralConfig = TestHelpers.fastPeripheralConfig()
let centralConfig = TestHelpers.fastCentralConfig()

let mockPeripheral = MockPeripheralManager(configuration: peripheralConfig)
let mockCentral = MockCentralManager(configuration: centralConfig)
let system = BLEActorSystem(
    peripheralManager: mockPeripheral,
    centralManager: mockCentral
)

// Generate test data
let randomData = TestHelpers.randomData(size: 100)
let deterministicData = TestHelpers.deterministicData(size: 100, pattern: 0xAB)

// Create test peripherals
let peripheral = TestHelpers.createDiscoveredPeripheral(
    id: UUID(),
    name: "TestDevice",
    rssi: -50,
    serviceUUIDs: [serviceUUID]
)

// Pre-built test actors
let sensor = SensorActor(actorSystem: system)
let temp = try await sensor.readTemperature() // Returns 22.5
```

#### Mock Actor Examples

Pre-defined distributed actors for common testing scenarios:

```swift
// Simple value actor
let actor = SimpleValueActor(actorSystem: system)
let value = try await actor.getValue() // Returns 42

// Stateful counter actor
let counter = CounterActor(actorSystem: system)
let count = try await counter.increment() // Returns 1

// Error-throwing actor
let errorActor = ErrorThrowingActor(actorSystem: system)
try await errorActor.alwaysThrows() // Throws TestError
```

### Mock System Configuration

Mocks support extensive configuration for testing various scenarios:

```swift
// Configure mock delays
var peripheralConfig = MockPeripheralManager.Configuration()
peripheralConfig.advertisingDelay = 0.01 // Fast for testing
peripheralConfig.writeResponseDelay = 0.01

var centralConfig = MockCentralManager.Configuration()
centralConfig.scanDelay = 0.01
centralConfig.connectionDelay = 0.01

// Configure failure scenarios
peripheralConfig.shouldFailAdvertising = true
centralConfig.shouldFailConnection = true

let mockPeripheral = MockPeripheralManager(configuration: peripheralConfig)
let mockCentral = MockCentralManager(configuration: centralConfig)
let system = BLEActorSystem(
    peripheralManager: mockPeripheral,
    centralManager: mockCentral
)
```

### Hardware Tests

Hardware tests require real BLE hardware and TCC permissions. They are disabled by default:

```swift
@Suite("Real BLE Hardware Tests", .disabled("Requires real BLE hardware"))
struct RealBLETests {
    @Test("Real device communication")
    func testRealDevice() async throws {
        // Create system with real CoreBluetooth managers (requires TCC)
        let peripheralManager = CoreBluetoothPeripheralManager()
        let centralManager = CoreBluetoothCentralManager()
        let system = BLEActorSystem(
            peripheralManager: peripheralManager,
            centralManager: centralManager
        )
        // ... test with real hardware
    }
}
```

To run hardware tests, remove the `.disabled` attribute and ensure your app has proper `Info.plist` with Bluetooth permissions.

### CI/CD Integration

GitHub Actions example:

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: swift test
```

Hardware tests are automatically skipped in CI/CD due to `.disabled` attribute.

### Comprehensive Testing Guide

For complete documentation including:
- Detailed architecture explanation
- Mock system usage patterns
- Simulating BLE events
- Error handling tests
- Best practices
- Troubleshooting guide

See the **[Complete Testing Guide](docs/guides/TESTING.md)**.

## 📱 Platform Requirements

- **iOS 18.0+** / **macOS 15.0+** / **watchOS 11.0+** / **tvOS 18.0+**
- **Swift 6.0+**
- **Xcode 16.0+**

## 📚 Documentation

Comprehensive documentation is available in the `docs/` directory:

- **[Specification](docs/SPECIFICATION.md)** - Complete framework specification and design
- **[Design Documents](docs/design/)** - Architecture and implementation design documents
  - [Discovery Connection Fix](docs/design/DISCOVERY_CONNECTION_FIX.md) - Bug fix design for eager connection pattern

For contributors and maintainers:
- **[Repository Guidelines](docs/internal/REPOSITORY_GUIDELINES.md)** - Project structure, coding standards, and development workflow
- **[Claude Code Guide](docs/internal/CLAUDE.md)** - AI assistant integration guide

## 📄 License

Bleu is available under the MIT license. See the [LICENSE](LICENSE) file for more info.

---

<div align="center">
  Made with ❤️ by <a href="https://x.com/1amageek">@1amageek</a>

  [Documentation](docs/) • [Issues](https://github.com/1amageek/Bleu/issues) • [Discussions](https://github.com/1amageek/Bleu/discussions)
</div>
