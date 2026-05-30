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
            let packets = try await transport.fragment(testData, for: deviceID)

            // Reassemble using proper binary format
            var reassembled: Data?
            for packet in packets {
                // Use the transport's pack method to create proper binary format
                let packetData = await transport.packPacket(packet)

                if case .complete(let complete) = await transport.receive(packetData) {
                    reassembled = complete
                }
            }

            #expect(reassembled == testData, "Failed for \(name) data")
        }
    }

    // MARK: - Problem 5: Magic Byte Tests

    @Test("Raw data is rejected")
    func testRawDataRejection() async throws {
        let transport = BLETransport.shared

        let rawData = Data([0x01, 0x02, 0x03, 0x04, 0x05])

        let result = await transport.receive(rawData)

        #expect(result == .rejected(.notTransportPacket))
    }

    @Test("Corrupted packet with valid magic bytes is rejected")
    func testCorruptedPacketRejection() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        // Create a valid packet first
        let testData = Data([0xAA, 0xBB, 0xCC])
        let packets = try await transport.fragment(testData, for: deviceID)
        #expect(packets.count == 1)

        var packedData = await transport.packPacket(packets[0])

        // Header structure: Magic(2) + Version(1) + UUID(16) + Seq(2) + Total(2) + Checksum(4) = 27 bytes
        // Checksum is at offset 23-26 (before payload)
        #expect(packedData.count >= 27, "Packed data should have at least 27 byte header")

        // Corrupt the checksum
        packedData[23] ^= 0xFF
        packedData[24] ^= 0xFF

        let result = await transport.receive(packedData)

        #expect(result == .rejected(.checksumMismatch))
    }

    @Test("Valid BLETransport packet is processed correctly")
    func testValidPacketProcessing() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        let testData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let packets = try await transport.fragment(testData, for: deviceID)

        #expect(packets.count == 1, "Small data should fit in one packet")

        let packedData = await transport.packPacket(packets[0])
        let result = await transport.receive(packedData)

        #expect(result == .complete(testData), "Valid packet should be reassembled correctly")
    }

    @Test("Packet header structure validation")
    func testPacketHeaderStructure() async throws {
        let transport = BLETransport.shared
        let deviceID = UUID()

        await transport.updateMaxPayloadSize(for: deviceID, maxWriteLength: 512)

        let testData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let packets = try await transport.fragment(testData, for: deviceID)

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

        #expect(result == .rejected(.truncatedHeader))
    }

    // MARK: - Legacy Packet Detection Tests

    @Test("Legacy packet format is detected and rejected")
    func testLegacyPacketDetectionAndRejection() async throws {
        let transport = BLETransport.shared

        // Create a legacy format packet (no magic bytes)
        // Legacy format: UUID(16B) + Seq(2B) + Total(2B) + Checksum(4B) + Payload
        let legacyUUID = UUID()
        let payload = Data([0xAA, 0xBB, 0xCC])

        // Calculate checksum
        let checksum: UInt32 = payload.withUnsafeBytes { bytes in
            bytes.reduce(0 as UInt32) { $0 &+ UInt32($1) }
        }

        var legacyPacket = Data()
        // UUID (16 bytes)
        legacyPacket.append(legacyUUID.data)
        // Sequence (2 bytes, big endian)
        var seq: UInt16 = 0
        legacyPacket.append(withUnsafeBytes(of: &seq) { Data($0.reversed()) })
        // Total (2 bytes, big endian)
        var total: UInt16 = 1
        legacyPacket.append(withUnsafeBytes(of: &total) { Data($0.reversed()) })
        // Checksum (4 bytes, big endian)
        var checksumBE = checksum.bigEndian
        legacyPacket.append(withUnsafeBytes(of: &checksumBE) { Data($0) })
        // Payload
        legacyPacket.append(payload)

        let result = await transport.receive(legacyPacket)

        #expect(result == .rejected(.legacyPacket))
    }

    @Test("Short non-transport data is rejected")
    func testShortDataRejected() async throws {
        let transport = BLETransport.shared

        let shortData = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                              0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
                              0x11, 0x12, 0x13])  // 19 bytes

        let result = await transport.receive(shortData)

        #expect(result == .rejected(.notTransportPacket))
    }

    @Test("JSON payload is rejected without transport framing")
    func testJSONPayloadRejected() async throws {
        let transport = BLETransport.shared

        let jsonString = """
        {"method":"readTemperature","args":[]}
        """
        let jsonData = jsonString.data(using: .utf8)!

        #expect(jsonData.count >= 24, "Test data should be >= 24 bytes")

        let result = await transport.receive(jsonData)

        #expect(result == .rejected(.notTransportPacket))
    }
}
