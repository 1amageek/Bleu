import Testing
import Foundation
@testable import Bleu

@Suite("Event Bridge Tests")
struct EventBridgeTests {

    @Test("Subscribe and unsubscribe")
    func testEventBridgeIntegration() async throws {
        let bridge = EventBridge.shared
        let actorID = UUID()

        actor EventCollector {
            var eventReceived = false
            var receivedPeripheralID: UUID?

            func recordEvent(peripheralID: UUID) {
                eventReceived = true
                receivedPeripheralID = peripheralID
            }

            var isEventReceived: Bool { eventReceived }
            var getReceivedPeripheralID: UUID? { receivedPeripheralID }
        }

        let collector = EventCollector()

        // Subscribe to events
        await bridge.subscribe(actorID) { event in
            switch event {
            case .peripheralConnected(let peripheralID):
                await collector.recordEvent(peripheralID: peripheralID)
            default:
                break
            }
        }

        // Simulate a connection event
        let testPeripheralID = UUID()
        await bridge.distribute(.peripheralConnected(testPeripheralID))

        // Wait a bit for async processing
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        #expect(await collector.isEventReceived)
        #expect(await collector.getReceivedPeripheralID == testPeripheralID)

        // Clean up
        await bridge.unsubscribe(actorID)
    }

    @Test("RPC characteristic registration")
    func testRPCCharacteristicRegistration() async throws {
        let bridge = EventBridge.shared
        let charUUID = UUID()
        let actorID = UUID()

        // Register RPC characteristic
        await bridge.registerRPCCharacteristic(charUUID, for: actorID)

        // Unregister
        await bridge.unregisterRPCCharacteristic(for: actorID)
    }

    @Test("RPC Call Registration")
    func testRPCCallRegistration() async throws {
        let bridge = EventBridge.shared
        let callID = UUID()
        let peripheralID = UUID()

        // Register RPC call with timeout (now uses String callID)
        let expectation = Task {
            do {
                _ = try await bridge.registerRPCCall(callID.uuidString, peripheralID: peripheralID)
                return false // Should timeout
            } catch {
                return true // Expected timeout
            }
        }

        // Wait for timeout
        let timedOut = await expectation.value
        #expect(timedOut == true)
    }
}
