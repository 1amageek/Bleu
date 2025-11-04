import Foundation
import CoreBluetooth
@testable import Bleu

/// Common test utilities and helpers for Bleu tests
enum TestHelpers {

    // MARK: - Test Data Generation

    /// Generate random test data of specified size
    static func randomData(size: Int) -> Data {
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        return data
    }

    /// Generate deterministic test data for reproducible tests
    static func deterministicData(size: Int, pattern: UInt8 = 0xAB) -> Data {
        return Data(repeating: pattern, count: size)
    }

    // MARK: - Service Metadata Helpers

    /// Create a simple test service with one read/write characteristic
    static func createSimpleService() -> ServiceMetadata {
        let serviceUUID = UUID()
        let characteristicUUID = UUID()

        return ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: characteristicUUID,
                    properties: [.read, .write],
                    permissions: [.readable, .writeable]
                )
            ]
        )
    }

    /// Create a service with RPC characteristics (notify + write)
    static func createRPCService() -> ServiceMetadata {
        let serviceUUID = UUID()
        let rpcCharUUID = UUID()

        return ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: rpcCharUUID,
                    properties: [.notify, .write],
                    permissions: [.readable, .writeable]
                )
            ]
        )
    }

    /// Create a service with multiple characteristics
    static func createComplexService() -> ServiceMetadata {
        let serviceUUID = UUID()

        return ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: UUID(),
                    properties: [.read],
                    permissions: [.readable]
                ),
                CharacteristicMetadata(
                    uuid: UUID(),
                    properties: [.write],
                    permissions: [.writeable]
                ),
                CharacteristicMetadata(
                    uuid: UUID(),
                    properties: [.notify],
                    permissions: [.readable]
                ),
                CharacteristicMetadata(
                    uuid: UUID(),
                    properties: [.read, .write, .notify],
                    permissions: [.readable, .writeable]
                )
            ]
        )
    }

    // MARK: - Advertisement Data Helpers

    /// Create simple advertisement data
    static func createAdvertisementData(
        name: String = "TestDevice",
        serviceUUIDs: [UUID] = []
    ) -> AdvertisementData {
        return AdvertisementData(
            localName: name,
            serviceUUIDs: serviceUUIDs
        )
    }

    // MARK: - Discovered Peripheral Helpers

    /// Create a discovered peripheral for testing
    static func createDiscoveredPeripheral(
        id: UUID = UUID(),
        name: String = "TestPeripheral",
        rssi: Int = -50,
        serviceUUIDs: [UUID] = []
    ) -> DiscoveredPeripheral {
        return DiscoveredPeripheral(
            id: id,
            name: name,
            rssi: rssi,
            advertisementData: createAdvertisementData(name: name, serviceUUIDs: serviceUUIDs)
        )
    }

    // MARK: - Mock Configuration Helpers

    /// Create mock peripheral configuration for fast tests
    static func fastPeripheralConfig() -> MockPeripheralManager.Configuration {
        var config = MockPeripheralManager.Configuration()
        config.advertisingDelay = 0.01  // 10ms
        config.writeResponseDelay = 0.01
        return config
    }

    /// Create mock central configuration for fast tests
    static func fastCentralConfig() -> MockCentralManager.Configuration {
        var config = MockCentralManager.Configuration()
        config.scanDelay = 0.01  // 10ms
        config.connectionDelay = 0.01
        config.discoveryDelay = 0.01
        return config
    }

    /// Create mock peripheral configuration that simulates failures
    static func failingPeripheralConfig() -> MockPeripheralManager.Configuration {
        var config = MockPeripheralManager.Configuration()
        config.shouldFailAdvertising = true
        config.shouldFailServiceAdd = true
        return config
    }

    /// Create mock central configuration that simulates failures
    static func failingCentralConfig() -> MockCentralManager.Configuration {
        var config = MockCentralManager.Configuration()
        config.shouldFailConnection = true
        return config
    }

    /// Create mock central configuration that simulates timeouts
    static func timeoutCentralConfig() -> MockCentralManager.Configuration {
        var config = MockCentralManager.Configuration()
        config.connectionTimeout = true
        return config
    }

    // MARK: - Async Test Helpers

    // Note: waitFor and withTimeout helpers removed due to Swift 6 concurrency restrictions
    // Tests can use simple Task.sleep with timeouts directly

    /// Wait for BLEActorSystem to be ready
    /// - Parameter system: The system to wait for
    /// - Parameter timeout: Maximum time to wait in seconds (default: 1.0)
    /// - Throws: TestTimeoutError if system doesn't become ready in time
    static func waitForReady(_ system: BLEActorSystem, timeout: TimeInterval = 1.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await system.ready {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000) // 1ms
        }
        throw TestTimeoutError()
    }
}

// MARK: - Test Errors

struct TestTimeoutError: Error, CustomStringConvertible {
    var description: String { "Test operation timed out" }
}

struct TestSetupError: Error, CustomStringConvertible {
    let message: String
    var description: String { "Test setup failed: \(message)" }
}
