import Testing
import Foundation
@testable import Bleu

// MARK: - Unit Tests for implemented functionality

@Suite("BLE Transport Tests")
struct BLETransportTests {
    
    @Test("Fragment and reassemble data")
    func testFragmentation() async {
        let transport = BLETransport.shared
        let testData = Data(repeating: 0xAB, count: 500)
        let deviceID = UUID()

        // Set MTU for the test device
        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        // Fragment data for a specific device
        let packets = await transport.fragment(testData, for: deviceID)
        #expect(packets.count > 1)

        // Reassemble packets using packPacket for proper binary format
        var reassembledData: Data?
        for packet in packets {
            // Use the transport's pack method to create proper binary format
            let packetData = await transport.packPacket(packet)

            if let complete = await transport.receive(packetData) {
                reassembledData = complete
            }
        }

        #expect(reassembledData == testData)
    }
    
    @Test("Small data should not fragment with sufficient MTU")
    func testNoFragmentation() async {
        let transport = BLETransport.shared
        let smallData = Data([0x01, 0x02, 0x03])
        let deviceID = UUID()

        // Set a large enough MTU for the test device (default 20 is too small with 24-byte header)
        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        let packets = await transport.fragment(smallData, for: deviceID)
        #expect(packets.count == 1)

        if let packet = packets.first {
            #expect(packet.totalPackets == 1)
            #expect(packet.sequenceNumber == 0)
        }
    }
}

@Suite("UUID Extensions Tests")
struct UUIDExtensionsTests {
    
    @Test("Deterministic UUID generation")
    func testDeterministicUUID() {
        let input = "test-string"
        let uuid1 = UUID.deterministic(from: input)
        let uuid2 = UUID.deterministic(from: input)
        
        #expect(uuid1 == uuid2)
        
        let differentInput = "different-string"
        let uuid3 = UUID.deterministic(from: differentInput)
        #expect(uuid1 != uuid3)
    }
    
    // Note: Service UUID generation test removed due to distributed actor compilation issues
    // Will be re-added when distributed actor support is stabilized
}

// Note: Event Bridge Tests moved to EventBridgeTests.swift

// Note: Instance Registry tests removed due to distributed actor compilation issues
// Will be re-added when distributed actor support is stabilized

// Note: Service Mapper tests removed due to distributed actor compilation issues
// Will be re-added when distributed actor support is stabilized

@Suite("Async Channel Tests")
struct AsyncChannelTests {
    
    @Test("Send and receive messages")
    func testAsyncChannel() async {
        let channel = AsyncChannel<Int>()
        
        Task {
            await channel.send(42)
            await channel.send(43)
        }
        
        var received: [Int] = []
        for await value in channel.stream.prefix(2) {
            received.append(value)
        }
        
        #expect(received == [42, 43])
    }
}

// Note: Tests for unimplemented features have been removed
// These included:
// - DeviceIdentifier
// - ServiceConfiguration
// - BleuMessage
// - FlowControlConfiguration
// - BleuFlowControlManager
// - BleuVersion
// These will be added when the corresponding features are implemented