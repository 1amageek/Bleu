import Testing
import Foundation
@testable import Bleu

@Suite("Transport Layer Tests")
struct TransportLayerTests {

    @Test("Transport Layer Integration")
    func testTransportIntegration() async throws {
        let transport = BLETransport.shared

        // Test fragmentation and reassembly with various sizes
        let testCases: [(String, Int)] = [
            ("Small", 10),
            ("Medium", 100),
            ("Large", 1000),
            ("Very Large", 5000)
        ]

        for (name, size) in testCases {
            let testData = Data(repeating: 0xFF, count: size)
            let deviceID = UUID()

            // Set MTU for the test device
            await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

            // Fragment for a specific device
            let packets = await transport.fragment(testData, for: deviceID)

            // Reassemble using proper binary format
            var reassembled: Data?
            for packet in packets {
                // Use the transport's pack method to create proper binary format
                let packetData = await transport.packPacket(packet)

                if let complete = await transport.receive(packetData) {
                    reassembled = complete
                }
            }

            #expect(reassembled == testData, "Failed for \(name) data")
        }
    }

    // MARK: - Problem 5: Magic Byte Tests

    @Test("Raw data backward compatibility")
    func testRawDataBackwardCompatibility() async throws {
        let transport = BLETransport.shared

        // Raw data without magic bytes should be returned as-is (backward compatibility)
        let rawData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let result = await transport.receive(rawData)

        #expect(result == rawData, "Raw data should be returned unchanged for backward compatibility")
    }

    @Test("Corrupted packet with valid magic bytes is rejected")
    func testCorruptedPacketRejection() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        // Create a valid packet first
        let testData = Data([0xAA, 0xBB, 0xCC])
        let packets = await transport.fragment(testData, for: deviceID)
        #expect(packets.count == 1)

        var packedData = await transport.packPacket(packets[0])

        // Header structure: Magic(2) + Version(1) + UUID(16) + Seq(2) + Total(2) + Checksum(4) = 27 bytes
        // Checksum is at offset 23-26 (before payload)
        #expect(packedData.count >= 27, "Packed data should have at least 27 byte header")

        // Corrupt the checksum
        packedData[23] ^= 0xFF
        packedData[24] ^= 0xFF

        // Corrupted packet with magic bytes should return nil (not be treated as raw data)
        let result = await transport.receive(packedData)

        #expect(result == nil, "Corrupted packet with magic bytes should be rejected, not returned as raw data")
    }

    @Test("Valid BLETransport packet is processed correctly")
    func testValidPacketProcessing() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let packets = await transport.fragment(testData, for: deviceID)

        #expect(packets.count == 1, "Small data should fit in one packet")

        let packedData = await transport.packPacket(packets[0])
        let result = await transport.receive(packedData)

        #expect(result == testData, "Valid packet should be reassembled correctly")
    }

    @Test("Packet header structure validation")
    func testPacketHeaderStructure() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packets = await transport.fragment(testData, for: deviceID)

        #expect(packets.count == 1)

        let packedData = await transport.packPacket(packets[0])

        // Header: Magic(2) + Version(1) + UUID(16) + Seq(2) + Total(2) + Checksum(4) = 27 bytes + payload
        let expectedSize = 27 + testData.count
        #expect(packedData.count == expectedSize, "Packed data should be exactly \(expectedSize) bytes (27 header + \(testData.count) payload)")

        // Verify magic bytes
        #expect(packedData[0] == 0x42, "First magic byte should be 'B' (0x42)")
        #expect(packedData[1] == 0x54, "Second magic byte should be 'T' (0x54)")

        // Verify version
        #expect(packedData[2] == 0x01, "Version should be 0x01")
    }

    @Test("Magic bytes distinguish BLETransport packets from raw data")
    func testMagicBytesDistinguish() async throws {
        let transport = BLETransport.shared

        // Data that happens to start with magic bytes but is not a valid packet
        // (too short to be a valid packet)
        let fakePacketData = Data([0x42, 0x54, 0x01, 0x00, 0x00])  // Magic + version + garbage

        let result = await transport.receive(fakePacketData)

        // Should be rejected as corrupted packet (has magic bytes but invalid format)
        #expect(result == nil, "Invalid packet with magic bytes should be rejected")
    }
}
