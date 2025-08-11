#!/usr/bin/env swift

import Foundation
import Bleu
import Distributed

// Simple test to verify basic functionality
@main
struct BasicTest {
    static func main() async {
        print("🚀 Starting Bleu v2 Basic Test")
        print("================================")
        
        // Initialize the actor system
        let actorSystem = BLEActorSystem.shared
        
        print("✅ BLEActorSystem initialized")
        
        // Test basic transport functionality
        let transport = BLETransport.shared
        
        // Test fragmentation
        let testData = Data("Hello Bleu v2! This is a test message for fragmentation.".utf8)
        let packets = await transport.fragment(testData)
        print("✅ Data fragmented into \(packets.count) packet(s)")
        
        // Test binary packing
        if let firstPacket = packets.first {
            let packedData = await transport.packPacket(firstPacket)
            print("✅ Packet packed: \(packedData.count) bytes")
            
            // Test unpacking and reassembly
            if let reassembledData = await transport.receive(packedData) {
                print("✅ Data reassembled: \(reassembledData.count) bytes")
                if let message = String(data: reassembledData, encoding: .utf8) {
                    print("✅ Message: \(message)")
                }
            }
        }
        
        // Test event bridge
        let eventBridge = EventBridge.shared
        let stats = await eventBridge.statistics()
        print("✅ EventBridge stats - Handlers: \(stats.eventHandlers), Subscriptions: \(stats.characteristicSubscriptions)")
        
        print("\n✨ Basic test completed successfully!")
        print("================================")
    }
}