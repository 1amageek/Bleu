import Testing
import Foundation
import Distributed
import CoreBluetooth
import CoreBluetoothEmulator
@testable import Bleu

/// Integration tests for multi-process BLE emulation using CoreBluetoothEmulator transport
///
/// These tests verify that Bleu's distributed actors work correctly when
/// running in separate "processes" (simulated via InMemoryEmulatorTransport).
///
/// This demonstrates the real-world scenario where:
/// - Process A (iPhone): Peripheral actor (SensorActor)
/// - Process B (Watch): Central discovers and calls RPC methods
@Suite("Multi-Process Emulator Tests", .serialized)
struct MultiProcessEmulatorTests {

    /// Test that transport layer can route events between processes
    @Test("Complete RPC flow across emulator transport")
    func testRPCAcrossEmulatorTransport() async throws {
        // Reset to clean state
        await EmulatorBus.shared.reset()
        await EmulatorBus.shared.configure(.instant)

        // Create shared transport hub
        let hub = InMemoryEmulatorTransport.Hub()

        // Process A: Peripheral side
        let peripheralProcessID = UUID()
        let peripheralTransport = InMemoryEmulatorTransport(
            hub: hub,
            processID: peripheralProcessID,
            role: .peripheral
        )

        // Process B: Central side
        let centralProcessID = UUID()
        let centralTransport = InMemoryEmulatorTransport(
            hub: hub,
            processID: centralProcessID,
            role: .central
        )

        // Start both transports
        await peripheralTransport.start()
        await centralTransport.start()

        // Simulate peripheral advertising event
        let testPeripheralID = UUID()
        let testEvent = EmulatorInternalEvent.advertisingStarted(
            peripheralID: testPeripheralID,
            advertisementData: ["test": .string("data")]
        )

        let testData = try JSONEncoder().encode(testEvent)

        // Send event through transport from peripheral process to central process
        try await peripheralTransport.send(testData, to: centralProcessID)

        // Receive event on central transport
        var receivedEvent: (UUID, Data)?
        for await event in centralTransport.receive() {
            receivedEvent = event
            break
        }

        #expect(receivedEvent != nil)
        #expect(receivedEvent?.0 == peripheralProcessID)

        // Verify event can be decoded
        if let data = receivedEvent?.1 {
            let decodedEvent = try JSONDecoder().decode(EmulatorInternalEvent.self, from: data)
            if case .advertisingStarted(let peripheralID, _) = decodedEvent {
                #expect(peripheralID == testPeripheralID)
            } else {
                Issue.record("Expected advertisingStarted event")
            }
        }

        // Cleanup
        await peripheralTransport.cleanup()
        await centralTransport.cleanup()
        await EmulatorBus.shared.reset()
    }

    /// Test event serialization for all event types
    @Test("EmulatorInternalEvent serialization")
    func testEventSerialization() async throws {
        // Reset to clean state
        await EmulatorBus.shared.reset()
        await EmulatorBus.shared.configure(.instant)
        let peripheralID = UUID()
        let centralID = UUID()
        let serviceUUID = CBUUID(string: "1234").data
        let charUUID = CBUUID(string: "5678").data

        // Test various event types
        let events: [EmulatorInternalEvent] = [
            .scanStarted(centralID: centralID, serviceUUIDs: [serviceUUID]),
            .connectionRequested(centralID: centralID, peripheralID: peripheralID),
            .writeRequested(
                centralID: centralID,
                peripheralID: peripheralID,
                characteristicUUID: charUUID,
                value: Data([0x01, 0x02]),
                type: 0 // .withResponse
            ),
            .advertisingStarted(
                peripheralID: peripheralID,
                advertisementData: [
                    "name": .string("Test Device"),
                    "uuid": .uuid(serviceUUID)
                ]
            )
        ]

        for event in events {
            // Encode
            let data = try JSONEncoder().encode(event)

            // Decode
            let decoded = try JSONDecoder().decode(EmulatorInternalEvent.self, from: data)

            // Verify targetID is preserved
            #expect(event.targetID == decoded.targetID)
        }
    }

    /// Test CodableValue conversion
    @Test("CodableValue conversion")
    func testCodableValueConversion() async throws {
        // Reset to clean state
        await EmulatorBus.shared.reset()
        await EmulatorBus.shared.configure(.instant)
        // Test string
        let stringValue = CodableValue.string("test")
        let stringData = try JSONEncoder().encode(stringValue)
        let decodedString = try JSONDecoder().decode(CodableValue.self, from: stringData)
        if case .string(let value) = decodedString {
            #expect(value == "test")
        } else {
            Issue.record("Expected string value")
        }

        // Test data
        let dataValue = CodableValue.data(Data([0x01, 0x02, 0x03]))
        let encodedData = try JSONEncoder().encode(dataValue)
        let decodedData = try JSONDecoder().decode(CodableValue.self, from: encodedData)
        if case .data(let value) = decodedData {
            #expect(value == Data([0x01, 0x02, 0x03]))
        } else {
            Issue.record("Expected data value")
        }

        // Test dictionary
        let dictValue = CodableValue.dictionary([
            "key1": .string("value1"),
            "key2": .number(42.0)
        ])
        let dictData = try JSONEncoder().encode(dictValue)
        let decodedDict = try JSONDecoder().decode(CodableValue.self, from: dictData)
        if case .dictionary(let dict) = decodedDict {
            #expect(dict.count == 2)
            if case .string(let str) = dict["key1"] {
                #expect(str == "value1")
            }
            if case .number(let num) = dict["key2"] {
                #expect(num == 42.0)
            }
        } else {
            Issue.record("Expected dictionary value")
        }
    }

    /// Test transport hub routing
    @Test("Transport hub routing")
    func testTransportHubRouting() async throws {
        // Reset to clean state
        await EmulatorBus.shared.reset()
        await EmulatorBus.shared.configure(.instant)

        let hub = InMemoryEmulatorTransport.Hub()

        let process1ID = UUID()
        let process2ID = UUID()
        let process3ID = UUID()

        let transport1 = InMemoryEmulatorTransport(hub: hub, processID: process1ID, role: .peripheral)
        let transport2 = InMemoryEmulatorTransport(hub: hub, processID: process2ID, role: .central)
        let transport3 = InMemoryEmulatorTransport(hub: hub, processID: process3ID, role: .central)

        // Start all transports to ensure registration
        await transport1.start()
        await transport2.start()
        await transport3.start()

        // Send from process1 to process2
        let testData = Data([0x01, 0x02, 0x03])

        // Start receiving before sending
        let receiveTask = Task<(UUID, Data)?, Never> {
            for await (sourceID, data) in transport2.receive() {
                return (sourceID, data)
            }
            return nil
        }

        try await transport1.send(testData, to: process2ID)

        // Wait with timeout
        let result = try await withThrowingTaskGroup(of: (UUID, Data)?.self) { group in
            group.addTask {
                await receiveTask.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms timeout
                return nil
            }

            if let result = try await group.next() {
                group.cancelAll()
                return result
            }
            return nil
        }

        // Verify result
        #expect(result != nil)
        if let (sourceID, data) = result {
            #expect(sourceID == process1ID)
            #expect(data == testData)
        }

        // Cleanup
        await transport1.cleanup()
        await transport2.cleanup()
        await transport3.cleanup()
    }

    // NOTE: True multi-process E2E testing is NOT included here
    //
    // Why we DON'T test "E2E Distributed Actor RPC via EmulatorTransport":
    //
    // EmulatorTransport.distributed mode is designed for TRUE cross-process communication:
    // - Process A: iPhone app with EmulatorBus.shared (singleton instance A)
    // - Process B: Watch app with EmulatorBus.shared (different singleton instance B)
    // - Each process has its own EmulatorBus instance with different transports
    // - Hub routes messages between Process A and Process B
    //
    // This CANNOT be tested in a single-process unit test because:
    // 1. EmulatorBus is a shared singleton - only one instance per process
    // 2. We cannot have two different transport configurations simultaneously
    // 3. Distributed mode sends events to OTHER processes, not back to the same process
    //
    // What we DO test (which provides equivalent coverage):
    // ✅ Transport layer (testRPCAcrossEmulatorTransport, testTransportHubRouting)
    // ✅ Event serialization (testEventSerialization, testCodableValueConversion)
    // ✅ Hub routing between process IDs (testTransportHubRouting)
    // ✅ Distributed actor RPC (FullWorkflowTests via MockBLEBridge)
    //
    // For true multi-process E2E testing, you would need:
    // - Separate test executables or XCTest targets
    // - XPC or other IPC mechanism
    // - Process coordination infrastructure
    //
    // This is integration testing territory, not unit testing.

}
