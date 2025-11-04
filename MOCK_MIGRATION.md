# Mock Implementation Migration

**Date**: 2025-01-04
**Status**: Complete

## Summary

Mock implementations have been moved from production code (`Sources/Bleu/Mocks`) to test code (`Tests/BleuTests/Mocks`). This is a cleaner separation of concerns - production code should not contain test utilities.

## Changes Made

### 1. Files Moved

**From**: `Sources/Bleu/Mocks/`
- `MockPeripheralManager.swift`
- `MockCentralManager.swift`

**To**: `Tests/BleuTests/Mocks/`
- `MockPeripheralManager.swift` ✅
- `MockCentralManager.swift` ✅

### 2. Factory Methods Removed from Production

**Removed from `BLEActorSystem`**:
```swift
// ❌ Removed
public static func mock(...) async -> BLEActorSystem
public static func mockSync(...) -> BLEActorSystem
public func mockPeripheralManager() async -> MockPeripheralManager?
public func mockCentralManager() async -> MockCentralManager?
```

### 3. New Test Helper Created

**File**: `Tests/BleuTests/Mocks/MockBLEActorSystem.swift` ✅

Provides extension methods for tests:
```swift
extension BLEActorSystem {
    public static func mock(...) async -> BLEActorSystem
    public static func mockSync(...) -> BLEActorSystem
}
```

## Migration Guide for Tests

### Before (Old Approach)

```swift
import Bleu

class MyTests: XCTestCase {
    func testSomething() async throws {
        // Factory method was in production code
        let system = await BLEActorSystem.mock()

        // Could access mocks via helper methods
        let mockPeripheral = await system.mockPeripheralManager()
    }
}
```

### After (New Approach)

```swift
@testable import Bleu

class MyTests: XCTestCase {
    func testSomething() async throws {
        // Factory method now in test helper
        let system = await BLEActorSystem.mock()

        // Keep direct references to mocks if needed
        let mockPeripheral = MockPeripheralManager()
        let mockCentral = MockCentralManager()
        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Use mockPeripheral and mockCentral directly
        await mockPeripheral.simulateConnection()
    }
}
```

## Key Changes

### 1. Import Statement Required

Tests must now use `@testable import`:
```swift
@testable import Bleu  // Required for test helpers
```

### 2. Mock Access Pattern

**Old**: Access via helper methods
```swift
let mock = await system.mockPeripheralManager()
```

**New**: Keep direct references
```swift
let mock = MockPeripheralManager()
let system = BLEActorSystem(peripheralManager: mock, ...)
// Use `mock` directly
```

### 3. Factory Method Location

**Old**: `BLEActorSystem.mock()` in production code
**New**: `BLEActorSystem.mock()` in test extension (requires `@testable import`)

## Benefits

### ✅ Clean Separation of Concerns
- Production code doesn't reference test utilities
- Mock implementations only visible in tests
- Smaller production binary (no mock code)

### ✅ Explicit Dependencies
- Tests explicitly create and manage mocks
- No hidden test code in production
- Clearer test setup code

### ✅ Better Encapsulation
- Mock types not exposed in public API
- Test helpers clearly marked as test-only
- No confusion about when to use mocks

## Breaking Changes

### For Tests

⚠️ **Tests will need to be updated**:

1. Add `@testable import Bleu` if not already present
2. Update mock access patterns (see migration guide above)
3. Keep direct references to mock instances

### For Production Code

✅ **No changes needed** - production code never used mocks

## Files Updated

### Production Code
- `Sources/Bleu/Core/BLEActorSystem.swift`
  - Removed `mock()` factory methods
  - Removed `mockPeripheralManager()` helper
  - Removed `mockCentralManager()` helper

### Test Code
- `Tests/BleuTests/Mocks/MockPeripheralManager.swift` (moved)
- `Tests/BleuTests/Mocks/MockCentralManager.swift` (moved)
- `Tests/BleuTests/Mocks/MockBLEActorSystem.swift` (new)

### Documentation
- `ARCHITECTURE.md` - Will be updated
- `IMPLEMENTATION_COMPLETE.md` - Will be updated
- `MOCK_MIGRATION.md` - This file ✅

## Testing Checklist

- [ ] All tests updated to use `@testable import`
- [ ] Mock access patterns updated
- [ ] Tests pass with new structure
- [ ] No references to old mock paths
- [ ] Documentation updated

## Example Test Update

### Before (Old XCTest - Deprecated)
```swift
import XCTest
import Bleu

class SensorTests: XCTestCase {
    func testReadTemperature() async throws {
        let system = await BLEActorSystem.mock()
        let sensor = TemperatureSensor(actorSystem: system)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        let temp = try await proxy.readTemperature()
        XCTAssertEqual(temp, 22.5)
    }
}
```

### After (Swift Testing - Current)
```swift
import Testing
@testable import Bleu

@Suite("Sensor Tests")
struct SensorTests {
    @Test("Read temperature")
    func testReadTemperature() async throws {
        // Mock factory still works (now from test helper)
        let system = await BLEActorSystem.mock()
        let sensor = TemperatureSensor(actorSystem: system)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        let temp = try await proxy.readTemperature()
        #expect(temp == 22.5)
    }
}
```

**Note**: All tests now use **Swift Testing** (not XCTest). See `TESTING_GUIDE.md` for details.

## Advanced: Direct Mock Control

If you need direct access to mocks for advanced testing:

```swift
@testable import Bleu

class AdvancedTests: XCTestCase {
    func testConnectionFailure() async throws {
        // Create mocks with custom configuration
        let mockPeripheral = MockPeripheralManager(
            configuration: .init(shouldFailConnection: true)
        )
        let mockCentral = MockCentralManager()

        // Create system with explicit mocks
        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Simulate failure scenarios
        await mockCentral.simulateDisconnection()

        // Test error handling
        do {
            try await system.connect(to: peripheralID, as: Sensor.self)
            XCTFail("Should throw error")
        } catch BleuError.connectionFailed {
            // Expected
        }
    }
}
```

## FAQ

### Q: Why move mocks to tests?

A: Mock implementations are test utilities and should not be shipped in production code. This reduces binary size and makes the API surface cleaner.

### Q: Do I need to update all my tests?

A: Most tests only need `@testable import Bleu` added. The `.mock()` factory still works.

### Q: Can I still use the `.mock()` factory method?

A: Yes! It's now in `Tests/BleuTests/Mocks/MockBLEActorSystem.swift` and works the same way.

### Q: What if I was using `mockPeripheralManager()`?

A: Keep a direct reference instead:
```swift
let mock = MockPeripheralManager()
let system = BLEActorSystem(peripheralManager: mock, ...)
```

### Q: Will production code still compile?

A: Yes! Production code never used mocks, so no changes needed.

## Conclusion

This migration improves code organization by separating test utilities from production code. The changes are minimal for most tests - just add `@testable import`.

✅ **Migration Complete**: Mock implementations now properly located in test code.
