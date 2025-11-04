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

            // Fragment
            let packets = await transport.fragment(testData)

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
}
