# Bleu 2 Testing Guide

Complete guide to testing with Bleu 2's Protocol-Oriented Testing Architecture.

## Table of Contents

1. [Overview](#overview)
2. [Test Architecture](#test-architecture)
3. [Quick Start](#quick-start)
4. [Writing Tests](#writing-tests)
5. [Mock System Usage](#mock-system-usage)
6. [Test Helpers](#test-helpers)
7. [Running Tests](#running-tests)
8. [Best Practices](#best-practices)
9. [Troubleshooting](#troubleshooting)

---

## Overview

Bleu 2 uses a Protocol-Oriented Testing Architecture that enables comprehensive testing without requiring real Bluetooth hardware or TCC permissions. This architecture provides:

- **Mock BLE Implementations**: In-memory simulation of BLE peripherals and centrals
- **No TCC Required**: Unit and integration tests run without Bluetooth permissions
- **Fast Execution**: Tests complete in seconds, not minutes
- **CI/CD Friendly**: All tests (except hardware tests) can run in CI/CD environments
- **Type-Safe**: Full type safety across mock and production implementations

### Test Coverage

- ✅ **Unit Tests**: 100% coverage of core functionality
- ✅ **Integration Tests**: Full workflow testing with mocks
- ✅ **Hardware Tests**: Real BLE validation (manual execution)

---

## Test Architecture

### Directory Structure

```
Tests/BleuTests/
├── Unit/                          # Pure unit tests
│   ├── UnitTests.swift            # BLE Transport, UUID, etc.
│   ├── RPCTests.swift             # RPC functionality
│   ├── BleuV2SwiftTests.swift    # Core type tests
│   ├── EventBridgeTests.swift    # Event routing
│   └── TransportLayerTests.swift # Message transport
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
    ├── TestHelpers.swift          # Common helpers
    └── MockActorExamples.swift    # Example actors
```

### Test Categories

**Unit Tests** (`Tests/BleuTests/Unit/`)
- No BLE hardware required
- No TCC permissions required
- Fast execution (milliseconds)
- Test individual components in isolation
- Examples: UUID generation, data serialization, event routing

**Integration Tests** (`Tests/BleuTests/Integration/`)
- Use mock BLE implementations
- No TCC permissions required
- Fast execution (seconds)
- Test complete workflows
- Examples: Discovery, connection, RPC execution

**Hardware Tests** (`Tests/BleuTests/Hardware/`)
- Require real BLE hardware
- Require TCC permissions (Info.plist)
- Slower execution (minutes)
- Manual execution only
- Final validation before release

---

## Quick Start

### Running All Tests

```bash
# Run all tests (unit + integration, skips hardware)
swift test

# Run specific test suite
swift test --filter "Mock Actor System Tests"

# Run with verbose output
swift test --verbose
```

### Running Hardware Tests

Hardware tests are disabled by default. To run them:

```swift
// Remove .disabled attribute from suite
@Suite("Real BLE Hardware Tests") // Remove: .disabled(...)
struct RealBLETests {
    // ...
}
```

Then ensure your app has proper Info.plist with Bluetooth permissions.

---

## Writing Tests

### Creating a Unit Test

```swift
import Testing
import Foundation
@testable import Bleu

@Suite("My Feature Tests")
struct MyFeatureTests {

    @Test("Feature works correctly")
    func testFeature() async throws {
        // Arrange
        let input = "test"

        // Act
        let result = processInput(input)

        // Assert
        #expect(result == "expected")
    }
}
```

### Creating an Integration Test with Mocks

```swift
import Testing
import Foundation
import Distributed
@testable import Bleu

@Suite("My Integration Tests")
struct MyIntegrationTests {

    @Test("Complete workflow")
    func testWorkflow() async throws {
        // Create mock systems
        let peripheralSystem = BLEActorSystem.mock()
        let centralSystem = BLEActorSystem.mock()

        // Define test actor
        distributed actor TestSensor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            distributed func getValue() async -> Int {
                return 42
            }
        }

        // Setup peripheral
        let sensor = TestSensor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(sensor)

        // Setup central to discover peripheral
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central")
            return
        }

        let serviceUUID = UUID.serviceUUID(for: TestSensor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: TestSensor.self)

        let discovered = DiscoveredPeripheral(
            id: sensor.id,
            name: "TestSensor",
            rssi: -50,
            advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID])
        )

        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Test discovery and RPC
        let sensors = try await centralSystem.discover(TestSensor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        let value = try await sensors[0].getValue()
        #expect(value == 42)
    }
}
```

---

## Mock System Usage

### Creating Mock Systems

```swift
// Basic mock system
let system = BLEActorSystem.mock()

// Mock with custom configuration
let peripheralConfig = MockPeripheralManager.Configuration()
peripheralConfig.advertisingDelay = 0.01 // Fast for testing

let centralConfig = MockCentralManager.Configuration()
centralConfig.scanDelay = 0.01

let system = BLEActorSystem.mock(
    peripheralConfig: peripheralConfig,
    centralConfig: centralConfig
)
```

### Accessing Mock Managers

```swift
let system = BLEActorSystem.mock()

// Access mock peripheral manager
if let mockPeripheral = await system.mockPeripheralManager() {
    // Use mock-specific methods
    await mockPeripheral.simulateStateChange(.poweredOn)
}

// Access mock central manager
if let mockCentral = await system.mockCentralManager() {
    // Register peripherals for discovery
    await mockCentral.registerPeripheral(peripheral, services: services)
}
```

### Mock Configuration Options

**MockPeripheralManager.Configuration**
```swift
var config = MockPeripheralManager.Configuration()
config.initialState = .poweredOn           // Initial Bluetooth state
config.advertisingDelay = 0.1              // Delay before advertising starts
config.shouldFailAdvertising = false       // Simulate advertising failure
config.shouldFailServiceAdd = false        // Simulate service add failure
config.writeResponseDelay = 0              // Delay before write responses
```

**MockCentralManager.Configuration**
```swift
var config = MockCentralManager.Configuration()
config.initialState = .poweredOn           // Initial Bluetooth state
config.scanDelay = 0.1                     // Delay between discoveries
config.connectionDelay = 0.1               // Delay before connection
config.discoveryDelay = 0.05               // Service/char discovery delay
config.shouldFailConnection = false        // Simulate connection failure
config.connectionTimeout = false           // Simulate connection timeout
```

### Simulating BLE Events

```swift
// Simulate subscription
await mockPeripheral.simulateSubscription(
    central: centralID,
    to: characteristicUUID
)

// Simulate write request
await mockPeripheral.simulateWriteRequest(
    from: centralID,
    to: characteristicUUID,
    value: testData
)

// Simulate state change
await mockPeripheral.simulateStateChange(.poweredOff)

// Simulate disconnection
await mockCentral.simulateDisconnection(
    peripheralID: peripheralID,
    error: someError
)

// Simulate value update (notification)
await mockCentral.simulateValueUpdate(
    for: characteristicUUID,
    in: peripheralID,
    value: newData
)
```

---

## Test Helpers

### Using TestHelpers

The `TestHelpers` enum provides common utilities:

```swift
// Generate test data
let randomData = TestHelpers.randomData(size: 100)
let deterministicData = TestHelpers.deterministicData(size: 100, pattern: 0xAB)

// Create services
let simpleService = TestHelpers.createSimpleService()
let rpcService = TestHelpers.createRPCService()
let complexService = TestHelpers.createComplexService()

// Create advertisement data
let adData = TestHelpers.createAdvertisementData(
    name: "MyDevice",
    serviceUUIDs: [serviceUUID]
)

// Create discovered peripheral
let peripheral = TestHelpers.createDiscoveredPeripheral(
    id: UUID(),
    name: "TestDevice",
    rssi: -50,
    serviceUUIDs: [serviceUUID]
)

// Fast mock configurations
let fastPeripheralConfig = TestHelpers.fastPeripheralConfig()
let fastCentralConfig = TestHelpers.fastCentralConfig()

// Failing mock configurations
let failingPeripheralConfig = TestHelpers.failingPeripheralConfig()
let failingCentralConfig = TestHelpers.failingCentralConfig()
```

### Using Mock Actor Examples

Pre-defined actors for testing:

```swift
// Simple value actor
let actor = SimpleValueActor(actorSystem: system)
let value = try await actor.getValue() // Returns 42

// Echo actor
let echo = EchoActor(actorSystem: system)
let result = try await echo.echo("hello") // Returns "hello"

// Sensor actor
let sensor = SensorActor(actorSystem: system)
let temp = try await sensor.readTemperature() // Returns 22.5

// Counter actor (stateful)
let counter = CounterActor(actorSystem: system)
let count = try await counter.increment() // Returns 1

// Error-throwing actor
let errorActor = ErrorThrowingActor(actorSystem: system)
try await errorActor.alwaysThrows() // Throws TestError

// Complex data actor
let dataActor = ComplexDataActor(actorSystem: system)
let complexData = try await dataActor.getComplexData()
```

---

## Running Tests

### Command Line

```bash
# Run all tests
swift test

# Run specific suite
swift test --filter "Mock Actor System Tests"

# Run specific test
swift test --filter "testMockSystemInit"

# Parallel execution
swift test --parallel

# Verbose output
swift test --verbose

# Generate test report
swift test 2>&1 | tee test-results.txt
```

### Xcode

1. Open Package.swift in Xcode
2. Select the test target
3. Press Cmd+U to run all tests
4. Click individual test diamonds to run specific tests

### CI/CD

**GitHub Actions Example:**

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: swift test
```

Hardware tests are automatically skipped in CI/CD due to `.disabled` attribute.

---

## Best Practices

### 1. Use Mock Systems for Most Tests

```swift
// ✅ Good - Fast, no TCC required
let system = BLEActorSystem.mock()

// ❌ Avoid in tests - Slow, requires TCC
let system = BLEActorSystem.shared
```

### 2. Use Fast Configurations

```swift
// ✅ Good - Fast test execution
let system = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.fastPeripheralConfig(),
    centralConfig: TestHelpers.fastCentralConfig()
)

// ❌ Slow - Default delays
let system = BLEActorSystem.mock()
```

### 3. Test One Thing Per Test

```swift
// ✅ Good - Focused test
@Test("Counter increments correctly")
func testCounterIncrement() async throws {
    let counter = CounterActor(actorSystem: system)
    let count = try await counter.increment()
    #expect(count == 1)
}

// ❌ Bad - Tests multiple things
@Test("Counter works")
func testCounter() async throws {
    // Tests increment, decrement, reset, add...
}
```

### 4. Use Descriptive Test Names

```swift
// ✅ Good
@Test("Connection fails when peripheral not found")

// ❌ Bad
@Test("Test 1")
```

### 5. Clean Up After Tests

```swift
@Test("Test with cleanup")
func testWithCleanup() async throws {
    let system = BLEActorSystem.mock()
    let sensor = SensorActor(actorSystem: system)

    try await system.startAdvertising(sensor)

    // Test logic...

    // Cleanup
    await system.stopAdvertising()
}
```

### 6. Test Error Cases

```swift
@Test("Handles connection failure gracefully")
func testConnectionFailure() async throws {
    var config = TestHelpers.fastCentralConfig()
    config.shouldFailConnection = true

    let system = BLEActorSystem.mock(centralConfig: config)

    do {
        try await system.connect(to: UUID(), as: SensorActor.self)
        Issue.record("Expected connection to fail")
    } catch {
        // Success - error was thrown
    }
}
```

### 7. Use Guard Statements for Optional Unwrapping

```swift
// ✅ Good - Clear error message
guard let mockCentral = await system.mockCentralManager() else {
    Issue.record("Expected mock central manager")
    return
}

// ❌ Bad - Force unwrap
let mockCentral = await system.mockCentralManager()!
```

---

## Troubleshooting

### Tests Fail with "bluetoothUnavailable"

**Problem**: Tests fail with `BleuError.bluetoothUnavailable`

**Solution**: System not ready. Wait for initialization:

```swift
let system = BLEActorSystem.mock()

// Wait for system to be ready
var retries = 10
while !await system.ready && retries > 0 {
    try await Task.sleep(nanoseconds: 100_000_000) // 100ms
    retries -= 1
}

guard await system.ready else {
    Issue.record("System not ready")
    return
}
```

### Tests Are Slow

**Problem**: Tests take too long to execute

**Solution**: Use fast configurations:

```swift
let system = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.fastPeripheralConfig(),
    centralConfig: TestHelpers.fastCentralConfig()
)
```

### "Cannot find type X in scope"

**Problem**: Compiler can't find test helpers or mock actors

**Solution**: Ensure proper imports:

```swift
import Testing
import Foundation
import Distributed
@testable import Bleu
```

### TCC Crash in Tests

**Problem**: Test crashes with TCC privacy violation

**Solution**: Use mock system, not production:

```swift
// ✅ Correct - No TCC required
let system = BLEActorSystem.mock()

// ❌ Wrong - Triggers TCC
let system = BLEActorSystem.shared
let system = BLEActorSystem.production()
let system = BLEActorSystem()
```

### Hardware Tests Not Running

**Problem**: Hardware tests are skipped

**Solution**: This is intentional. Remove `.disabled` attribute:

```swift
// Before (skipped in CI/CD)
@Suite("Real BLE Hardware Tests", .disabled("Requires real BLE hardware"))

// After (runs everywhere)
@Suite("Real BLE Hardware Tests")
```

**Warning**: Only run hardware tests manually with proper Info.plist setup.

### Mock Central Not Discovering Peripherals

**Problem**: `discover()` returns empty array

**Solution**: Register peripheral in mock central:

```swift
guard let mockCentral = await centralSystem.mockCentralManager() else {
    Issue.record("Expected mock central")
    return
}

// Must register peripheral before discovery
let serviceMetadata = ServiceMapper.createServiceMetadata(from: SensorActor.self)
let discovered = DiscoveredPeripheral(
    id: sensor.id,
    name: "Sensor",
    rssi: -50,
    advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID])
)

await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

// Now discovery will work
let sensors = try await centralSystem.discover(SensorActor.self, timeout: 1.0)
```

---

## Advanced Topics

### Testing Custom Distributed Actors

```swift
distributed actor MyCustomActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func customMethod() async -> String {
        return "custom"
    }
}

@Test("Custom actor works")
func testCustomActor() async throws {
    let peripheralSystem = BLEActorSystem.mock()
    let centralSystem = BLEActorSystem.mock()

    let actor = MyCustomActor(actorSystem: peripheralSystem)
    try await peripheralSystem.startAdvertising(actor)

    guard let mockCentral = await centralSystem.mockCentralManager() else {
        Issue.record("Expected mock central")
        return
    }

    let serviceUUID = UUID.serviceUUID(for: MyCustomActor.self)
    let serviceMetadata = ServiceMapper.createServiceMetadata(from: MyCustomActor.self)

    let discovered = DiscoveredPeripheral(
        id: actor.id,
        name: "MyActor",
        rssi: -50,
        advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID])
    )

    await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

    let actors = try await centralSystem.discover(MyCustomActor.self, timeout: 1.0)
    let result = try await actors[0].customMethod()
    #expect(result == "custom")
}
```

### Testing Error Propagation

```swift
distributed actor ErrorTestActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    enum MyError: Error, Codable {
        case customError
    }

    distributed func throwsError() async throws -> Int {
        throw MyError.customError
    }
}

@Test("Errors propagate over BLE RPC")
func testErrorPropagation() async throws {
    // Setup peripheral and central...

    do {
        _ = try await remoteActor.throwsError()
        Issue.record("Expected error to be thrown")
    } catch {
        // Success - error propagated correctly
    }
}
```

---

## Summary

Bleu 2's Protocol-Oriented Testing Architecture enables:

- ✅ Fast, comprehensive testing without real hardware
- ✅ No TCC permissions required for most tests
- ✅ CI/CD friendly test execution
- ✅ Type-safe mocking with full protocol conformance
- ✅ Easy simulation of error conditions and edge cases

For questions or issues, see the main [README](../../README.md) or file an issue on GitHub.
