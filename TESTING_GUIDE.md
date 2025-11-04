# Testing Guide

**Framework**: Swift Testing (native Swift 6.0+ testing framework)
**Date**: 2025-01-04

## Overview

Bleu uses **Swift Testing**, Apple's modern testing framework introduced in Swift 6.0. All tests have been migrated from XCTest to Swift Testing for better async/await support, improved test organization, and modern Swift features.

## Why Swift Testing?

### ✅ Advantages over XCTest

1. **Native async/await support** - No need for expectations or waitForExpectations
2. **Better test organization** - @Suite for logical grouping
3. **Improved assertions** - #expect with clear error messages
4. **Parameterized tests** - Test multiple inputs easily
5. **Tags for filtering** - Run subsets of tests
6. **Better IDE integration** - Cleaner test navigator

### 🚀 Modern Swift Features

- Fully leverages Swift 6.0 concurrency
- Native structured concurrency
- Actor-safe testing patterns
- Clean async test methods

## Test Structure

### Directory Layout

```
Tests/BleuTests/
├── Mocks/                          # Mock implementations
│   ├── MockBLEActorSystem.swift   # Test helper extensions
│   ├── MockPeripheralManager.swift # Mock peripheral
│   ├── MockCentralManager.swift    # Mock central
│   └── MockActorExamples.swift     # Example actors for testing
│
├── Unit/                           # Unit tests
│   ├── RPCTests.swift             # RPC envelope tests
│   ├── TransportLayerTests.swift  # BLE transport tests
│   └── UnitTests.swift            # Core functionality tests
│
├── Integration/                    # Integration tests
│   ├── MockActorSystemTests.swift # Same-process actor tests
│   ├── ErrorHandlingTests.swift   # Error scenarios
│   └── FullWorkflowTests.swift    # End-to-end workflows
│
└── Hardware/                       # Hardware tests (manual)
    └── RealBLETests.swift         # Real BLE hardware tests
```

## Writing Tests with Swift Testing

### Basic Test

```swift
import Testing
import Foundation
@testable import Bleu

@Suite("My Feature Tests")
struct MyFeatureTests {

    @Test("Should do something")
    func testSomething() async throws {
        let system = await BLEActorSystem.mock()

        // Your test code

        #expect(someValue == expectedValue)
    }
}
```

### Test Suites

Group related tests with `@Suite`:

```swift
@Suite("RPC Tests")
struct RPCTests {

    @Test("Invocation Envelope")
    func testInvocationEnvelope() throws {
        // Test envelope creation
    }

    @Test("Response Envelope")
    func testResponseEnvelope() throws {
        // Test response handling
    }
}
```

### Async Tests

Swift Testing has native async support:

```swift
@Test("Async operation")
func testAsyncOperation() async throws {
    let system = await BLEActorSystem.mock()
    let result = try await system.someAsyncMethod()

    #expect(result.isSuccess)
}
```

### Assertions

Use `#expect` instead of XCTAssert:

```swift
// Boolean checks
#expect(value == expected)
#expect(result.isSuccess)

// Optional checks
#expect(optionalValue != nil)

// Throwing checks
#expect(throws: MyError.self) {
    try riskyOperation()
}

// Custom messages
#expect(value == expected, "Value should match expected")
```

### Recording Issues

For complex failure scenarios:

```swift
if someCondition {
    Issue.record("Something went wrong: \(details)")
    return
}
```

### Parameterized Tests

Test multiple inputs easily:

```swift
@Test("Temperature validation", arguments: [
    (-50.0, true),
    (0.0, true),
    (100.0, true),
    (-51.0, false),
    (101.0, false)
])
func testTemperatureValidation(value: Double, isValid: Bool) throws {
    let result = TemperatureSensor.isValid(value)
    #expect(result == isValid)
}
```

### Tags

Filter tests with tags:

```swift
@Suite("Integration Tests")
@Tag(.integration)
struct IntegrationTests {

    @Test("Full workflow", .tags(.slow))
    func testFullWorkflow() async throws {
        // Long-running test
    }
}

// Define custom tags
extension Tag {
    @Tag static var integration: Self
    @Tag static var slow: Self
    @Tag static var hardware: Self
}
```

## Mock Testing Patterns

### Creating Mock System

```swift
@Test("Using mock system")
func testWithMocks() async throws {
    // Simple mock creation
    let system = await BLEActorSystem.mock()

    // Verify system is ready
    #expect(await system.ready)
}
```

### Direct Mock Access

For advanced testing, keep direct references:

```swift
@Test("Custom mock configuration")
func testCustomMocks() async throws {
    // Create mocks with custom config
    let mockPeripheral = MockPeripheralManager(
        configuration: .init(
            shouldFailConnection: true
        )
    )
    let mockCentral = MockCentralManager()

    // Create system with explicit mocks
    let system = BLEActorSystem(
        peripheralManager: mockPeripheral,
        centralManager: mockCentral
    )

    // Use mocks directly
    await mockCentral.simulateDisconnection()

    // Test error handling
    #expect(throws: BleuError.connectionFailed) {
        try await system.connect(to: peripheralID, as: Sensor.self)
    }
}
```

### Testing Distributed Actors

```swift
@Test("Distributed actor RPC")
func testDistributedActor() async throws {
    let system = await BLEActorSystem.mock()

    // Create actor
    let sensor = TemperatureSensor(actorSystem: system)

    // Create proxy (simulates remote actor)
    let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

    // Call distributed method
    let temp = try await proxy.readTemperature()

    #expect(temp == 22.5)
}
```

## Running Tests

### Run All Tests

```bash
swift test
```

### Run Specific Suite

```bash
swift test --filter "RPC Tests"
```

### Run Specific Test

```bash
swift test --filter "testInvocationEnvelope"
```

### Run with Tags

```bash
swift test --filter tag:integration
```

### Parallel Execution

Swift Testing runs tests in parallel by default for better performance.

## Test Categories

### Unit Tests (Fast)

- RPC envelope serialization
- Transport layer fragmentation
- Error conversion
- Service mapping

**Characteristics**:
- No real BLE hardware
- Use mocks exclusively
- Fast execution (< 1s per test)
- Run on CI

### Integration Tests (Medium)

- Same-process actor communication
- Error handling scenarios
- Full RPC workflows with mocks
- Connection lifecycle

**Characteristics**:
- Use mock BLE managers
- Test multiple components together
- Medium execution (1-5s per test)
- Run on CI

### Hardware Tests (Slow)

- Real BLE device communication
- Cross-device RPC
- Connection reliability
- Real-world scenarios

**Characteristics**:
- Require real BLE hardware
- Require TCC permissions
- Slow execution (10s+ per test)
- Manual testing only

## Best Practices

### ✅ DO

- Use `@testable import Bleu` for internal access
- Use `#expect` for assertions
- Write async tests with `async throws`
- Keep direct references to mocks when needed
- Group related tests with `@Suite`
- Use descriptive test names
- Test error paths thoroughly

### ❌ DON'T

- Don't use XCTest (fully migrated to Swift Testing)
- Don't use `XCTAssert*` (use `#expect`)
- Don't use test expectations (use async/await)
- Don't test implementation details
- Don't write slow tests without tags
- Don't require real hardware in CI tests

## Example: Complete Test File

```swift
import Testing
import Foundation
import Distributed
@testable import Bleu

@Suite("Temperature Sensor Tests")
struct TemperatureSensorTests {

    @Test("Read temperature from mock sensor")
    func testReadTemperature() async throws {
        let system = await BLEActorSystem.mock()
        let sensor = TemperatureSensor(actorSystem: system)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        let temp = try await proxy.readTemperature()

        #expect(temp >= 20.0)
        #expect(temp <= 30.0)
    }

    @Test("Set threshold validation", arguments: [
        (25.0, true),
        (-60.0, false),
        (150.0, false)
    ])
    func testSetThreshold(value: Double, shouldSucceed: Bool) async throws {
        let system = await BLEActorSystem.mock()
        let sensor = TemperatureSensor(actorSystem: system)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        if shouldSucceed {
            try await proxy.setThreshold(value)
            // Success
        } else {
            #expect(throws: TemperatureError.invalidThreshold) {
                try await proxy.setThreshold(value)
            }
        }
    }

    @Test("Multiple sensor instances")
    func testMultipleSensors() async throws {
        let system = await BLEActorSystem.mock()

        let sensor1 = TemperatureSensor(actorSystem: system)
        let sensor2 = TemperatureSensor(actorSystem: system)

        let proxy1 = try TemperatureSensor.resolve(id: sensor1.id, using: system)
        let proxy2 = try TemperatureSensor.resolve(id: sensor2.id, using: system)

        let temp1 = try await proxy1.readTemperature()
        let temp2 = try await proxy2.readTemperature()

        // Each sensor has independent state
        #expect(sensor1.id != sensor2.id)
    }
}
```

## CI Configuration

### GitHub Actions Example

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: swift test --parallel
```

## Troubleshooting

### Test Hangs on `await system.ready`

**Problem**: Test waits indefinitely for system to be ready

**Solution**: Mock system should be ready almost instantly. Check:
- Mock managers are initializing correctly
- No real Bluetooth hardware access
- Using `BLEActorSystem.mock()` not `.production()`

### Cannot Access Mock Managers

**Problem**: `system.mockPeripheralManager()` doesn't exist

**Solution**: Keep direct references instead:
```swift
let mock = MockPeripheralManager()
let system = BLEActorSystem(peripheralManager: mock, ...)
```

### Tests Fail with "Actor not found"

**Problem**: Distributed actor calls fail

**Solution**: Ensure both actors are in the same `BLEActorSystem`:
```swift
let system = await BLEActorSystem.mock()
let sensor = TemperatureSensor(actorSystem: system)  // Same system
let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)  // Same system
```

## Resources

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [WWDC 2024: Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/)
- [Swift Evolution Proposal](https://github.com/apple/swift-evolution/blob/main/proposals/0419-swift-testing.md)

## Migration Notes

All tests have been **fully migrated** from XCTest to Swift Testing:

✅ Unit tests
✅ Integration tests
✅ Mock actor system tests
✅ Error handling tests
✅ RPC tests
✅ Transport layer tests

**No XCTest dependencies remain.**
