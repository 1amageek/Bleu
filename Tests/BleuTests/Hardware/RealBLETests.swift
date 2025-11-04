import Testing
import Foundation
@testable import Bleu

/// Hardware tests that require real Bluetooth hardware and TCC permissions
/// These tests use BLEActorSystem.shared (production implementation)
///
/// IMPORTANT: These tests are skipped in CI/CD environments
/// Run manually with: swift test --filter Hardware
@Suite("Real BLE Hardware Tests", .disabled("Requires real BLE hardware and TCC permissions"))
struct RealBLETests {

    // MARK: - BLE Actor System Integration Tests

    @Test("BLE Actor System Initialization")
    func testBLEActorSystemInit() async throws {
        // Test that BLE Actor System can be initialized with real hardware
        let actorSystem = BLEActorSystem.shared

        // Wait for system to be ready (with timeout)
        var isReady = false
        for _ in 0..<100 {
            isReady = await actorSystem.ready
            if isReady {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        #expect(isReady == true)
    }

    // MARK: - Future Hardware Tests

    // TODO: Add tests for:
    // - Real peripheral advertising
    // - Real central scanning and discovery
    // - Actual BLE connection establishment
    // - Real characteristic read/write
    // - Real notification handling
    // - Performance benchmarks with real hardware
    // - MTU negotiation
    // - Connection interval adjustments
}
