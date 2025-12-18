import Foundation
import CoreBluetooth
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
    ///   - timeout: Maximum time to wait for system to be ready (default: 10s)
    /// - Returns: BLEActorSystem with mock implementations, guaranteed to be ready
    /// - Throws: BleuError if Bluetooth state prevents initialization
    /// - Note: No Bluetooth permissions required, no hardware needed
    /// - Important: This async version waits for the system to be ready before returning
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init(),
        timeout: TimeInterval = 10.0
    ) async throws -> BLEActorSystem {
        let mockPeripheral = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral = MockCentralManager(configuration: centralConfig)

        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Wait for system to be ready with proper error handling
        try await waitForReady(
            system: system,
            peripheralManager: mockPeripheral,
            centralManager: mockCentral,
            timeout: timeout
        )

        return system
    }

    /// Legacy non-throwing mock() for backward compatibility
    /// - Note: This method does not check Bluetooth state errors
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) async -> BLEActorSystem {
        let mockPeripheral = MockPeripheralManager(configuration: peripheralConfig)
        let mockCentral = MockCentralManager(configuration: centralConfig)

        let system = BLEActorSystem(
            peripheralManager: mockPeripheral,
            centralManager: mockCentral
        )

        // Wait for system to be ready (best effort, no error checking)
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

    /// Wait for BLEActorSystem to be ready with proper error handling
    /// - Parameters:
    ///   - system: The BLEActorSystem to wait for
    ///   - peripheralManager: Peripheral manager to check state
    ///   - centralManager: Central manager to check state
    ///   - timeout: Maximum time to wait
    /// - Throws: BleuError if Bluetooth state prevents initialization
    internal static func waitForReady(
        system: BLEActorSystem,
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let checkInterval: UInt64 = 50_000_000  // 50ms

        while true {
            // Check if ready
            if await system.ready {
                return
            }

            // Get current states
            let peripheralState = await peripheralManager.state
            let centralState = await centralManager.state

            // Check for unrecoverable states (fail fast)
            if peripheralState == .unsupported || centralState == .unsupported {
                throw BleuError.bluetoothUnavailable
            }

            if peripheralState == .unauthorized || centralState == .unauthorized {
                throw BleuError.bluetoothUnauthorized
            }

            // Check timeout
            if Date() > deadline {
                if peripheralState == .poweredOff || centralState == .poweredOff {
                    throw BleuError.bluetoothPoweredOff
                }
                throw BleuError.connectionTimeout
            }

            try? await Task.sleep(nanoseconds: checkInterval)
        }
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
