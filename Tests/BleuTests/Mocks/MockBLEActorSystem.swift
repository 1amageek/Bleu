import Foundation
@testable import Bleu

/// Test helper to create BLEActorSystem with mock implementations
///
/// This file provides factory methods for testing that were previously
/// in the production BLEActorSystem class. Mock implementations should
/// only be used in tests, not in production code.
extension BLEActorSystem {

    /// Create mock instance for testing (async version - recommended)
    /// - Parameters:
    ///   - peripheralConfig: Configuration for mock peripheral manager
    ///   - centralConfig: Configuration for mock central manager
    /// - Returns: BLEActorSystem with mock implementations, guaranteed to be ready
    /// - Note: No Bluetooth permissions required, no hardware needed
    /// - Important: This async version waits for the system to be ready before returning
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) async -> BLEActorSystem {
        let mockPeripheral: BLEPeripheralManagerProtocol = MockPeripheralManager(
            configuration: peripheralConfig
        )
        let mockCentral: BLECentralManagerProtocol = MockCentralManager(
            configuration: centralConfig
        )

        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Wait for system to be ready (should be almost instant with mocks)
        var retries = 1000  // 10 seconds max
        while retries > 0 {
            if await system.ready {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            retries -= 1
        }

        return system
    }

    /// Create mock instance for testing (synchronous version - legacy)
    /// - Parameters:
    ///   - peripheralConfig: Configuration for mock peripheral manager
    ///   - centralConfig: Configuration for mock central manager
    /// - Returns: BLEActorSystem with mock implementations
    /// - Note: No Bluetooth permissions required, no hardware needed
    /// - Warning: System may not be immediately ready. Consider using async version instead.
    /// - Important: Deprecated in favor of async mock() method
    @available(*, deprecated, message: "Use async mock() method for guaranteed readiness")
    public static func mockSync(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) -> BLEActorSystem {
        let mockPeripheral: BLEPeripheralManagerProtocol = MockPeripheralManager(
            configuration: peripheralConfig
        )
        let mockCentral: BLECentralManagerProtocol = MockCentralManager(
            configuration: centralConfig
        )

        return BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )
    }
}

// MARK: - Testing Support

// Note: Access to mock managers is done through direct references kept in tests
// since peripheralManager and centralManager are private in BLEActorSystem.
// Tests should keep references to the mocks when creating the system:
//
// Example:
//   let mockPeripheral = MockPeripheralManager()
//   let mockCentral = MockCentralManager()
//   let system = BLEActorSystem(peripheralManager: mockPeripheral, centralManager: mockCentral)
//   // Use mockPeripheral and mockCentral directly in tests
