import Foundation
import CoreBluetooth
import os

/// Handles reliable data transport over BLE
public actor BLETransport {
    
    /// Maximum write length for BLE packets (including header)
    private var maxWriteLength: Int
    
    /// Header overhead for packet metadata (UUID:16B + sequence:2B + total:2B + checksum:4B)
    private let headerOverhead = 24
    
    /// Packet for fragmented data transmission
    public struct Packet: Codable, Sendable {
        public let id: UUID
        public let sequenceNumber: UInt16
        public let totalPackets: UInt16
        public let payload: Data
        public let checksum: UInt32
        
        public init(id: UUID, sequenceNumber: UInt16, totalPackets: UInt16, payload: Data) {
            self.id = id
            self.sequenceNumber = sequenceNumber
            self.totalPackets = totalPackets
            self.payload = payload
            self.checksum = payload.withUnsafeBytes { bytes in
                bytes.reduce(0 as UInt32) { $0 &+ UInt32($1) }
            }
        }
        
        public func validate() -> Bool {
            let calculatedChecksum: UInt32 = payload.withUnsafeBytes { bytes in
                bytes.reduce(0 as UInt32) { $0 &+ UInt32($1) }
            }
            return calculatedChecksum == checksum
        }
    }
    
    /// Reassembly buffer for incoming packets
    private struct ReassemblyBuffer {
        let id: UUID
        let totalPackets: UInt16
        var packets: [UInt16: Packet] = [:]
        let startTime: Date
        
        init(id: UUID, totalPackets: UInt16) {
            self.id = id
            self.totalPackets = totalPackets
            self.startTime = Date()
        }
        
        var isComplete: Bool {
            packets.count == totalPackets
        }
        
        func assembleData() -> Data? {
            guard isComplete else { return nil }
            
            var data = Data()
            for i in 0..<totalPackets {
                guard let packet = packets[i] else { return nil }
                data.append(packet.payload)
            }
            return data
        }
    }
    
    // Transport state
    private var reassemblyBuffers: [UUID: ReassemblyBuffer] = [:]
    private var outgoingQueue: [Packet] = []
    private var cleanupTask: Task<Void, Never>?
    private let configManager = BleuConfigurationManager.shared
    
    /// Shared instance
    public static let shared = BLETransport(defaultWriteLength: 512)
    
    public init(defaultWriteLength: Int = 512) {
        self.maxWriteLength = defaultWriteLength
        
        // Start cleanup task for timed-out reassembly buffers
        Task {
            await self.assignCleanupTask()
        }
    }
    
    private func assignCleanupTask() {
        cleanupTask = Task {
            await startCleanupTask()
        }
    }
    
    deinit {
        // Cancel cleanup task when transport is deallocated
        cleanupTask?.cancel()
    }
    
    /// Update maximum payload size based on negotiated MTU
    public func updateMaxPayloadSize(from peripheral: CBPeripheral, type: CBCharacteristicWriteType) {
        // Get the maximum write value length for the specific write type
        let maxWriteLength = peripheral.maximumWriteValueLength(for: type)
        updateMaxPayloadSize(maxWriteLength: maxWriteLength)
    }
    
    /// Update maximum payload size with a specific write length
    public func updateMaxPayloadSize(maxWriteLength: Int) {
        // Store the write length directly, ensuring minimum viable size
        self.maxWriteLength = max(20, maxWriteLength)
    }
    
    /// Fragment data into packets
    public func fragment(_ data: Data) -> [Packet] {
        guard !data.isEmpty else { return [] }
        
        let id = UUID()
        // Calculate payload size by subtracting header overhead
        let payloadSize = max(1, maxWriteLength - headerOverhead)
        let totalPackets = UInt16((data.count + payloadSize - 1) / payloadSize)
        
        var packets: [Packet] = []
        
        for i in 0..<totalPackets {
            let start = Int(i) * payloadSize
            let end = min(start + payloadSize, data.count)
            let payload = data[start..<end]
            
            let packet = Packet(
                id: id,
                sequenceNumber: i,
                totalPackets: totalPackets,
                payload: payload
            )
            packets.append(packet)
        }
        
        return packets
    }
    
    // MARK: - Binary Packing
    
    /// Pack packet into binary format (24B header + payload)
    public func packPacket(_ packet: Packet) -> Data {
        return pack(packet)
    }
    
    /// Pack packet into binary format (24B header + payload)
    private func pack(_ packet: Packet) -> Data {
        var data = Data()
        
        // UUID (16 bytes)
        data.append(packet.id.data)
        
        // Sequence number (2 bytes, big endian)
        var seq = packet.sequenceNumber.bigEndian
        data.append(withUnsafeBytes(of: &seq) { Data($0) })
        
        // Total packets (2 bytes, big endian)
        var total = packet.totalPackets.bigEndian
        data.append(withUnsafeBytes(of: &total) { Data($0) })
        
        // Checksum (4 bytes, big endian)
        var checksum = packet.checksum.bigEndian
        data.append(withUnsafeBytes(of: &checksum) { Data($0) })
        
        // Payload
        data.append(packet.payload)
        
        return data
    }
    
    /// Unpack binary data into packet
    private func unpack(_ data: Data) -> Packet? {
        guard data.count >= 24, let id = UUID(data: data.prefix(16)) else { return nil }
        
        var offset = 16
        
        // Helper to read bytes safely without alignment issues
        func readU16() -> UInt16? {
            guard data.count >= offset + 2 else { return nil }
            let b0 = UInt16(data[offset])
            let b1 = UInt16(data[offset + 1])
            offset += 2
            // Big-endian: most significant byte first
            return (b0 << 8) | b1
        }
        
        func readU32() -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            let b0 = UInt32(data[offset])
            let b1 = UInt32(data[offset + 1])
            let b2 = UInt32(data[offset + 2])
            let b3 = UInt32(data[offset + 3])
            offset += 4
            // Big-endian: most significant byte first
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        
        // Sequence number (2 bytes)
        guard let seq = readU16() else { return nil }
        
        // Total packets (2 bytes)
        guard let total = readU16() else { return nil }
        
        // Checksum (4 bytes)
        guard let checksum = readU32() else { return nil }
        
        // Payload
        let payload = data.suffix(from: offset)
        
        // Create packet and validate checksum
        let packet = Packet(id: id, sequenceNumber: seq, totalPackets: total, payload: payload)
        return packet.checksum == checksum ? packet : nil
    }
    
    /// Reassemble packets into data
    public func reassemble(_ packet: Packet) async -> Data? {
        // Validate packet
        guard packet.validate() else {
            BleuLogger.transport.warning("Invalid packet checksum for packet \(packet.id)")
            return nil
        }
        
        // Get or create reassembly buffer
        if reassemblyBuffers[packet.id] == nil {
            reassemblyBuffers[packet.id] = ReassemblyBuffer(
                id: packet.id,
                totalPackets: packet.totalPackets
            )
        }
        
        guard var buffer = reassemblyBuffers[packet.id] else { return nil }
        
        // Add packet to buffer
        buffer.packets[packet.sequenceNumber] = packet
        reassemblyBuffers[packet.id] = buffer
        
        // Check if complete
        if buffer.isComplete {
            reassemblyBuffers.removeValue(forKey: packet.id)
            return buffer.assembleData()
        }
        
        return nil
    }
    
    /// Send data with fragmentation if needed
    public func send(
        _ data: Data,
        to deviceID: UUID,
        using localCentral: LocalCentralActor,
        characteristicUUID: UUID
    ) async throws {
        let packets = fragment(data)
        
        for packet in packets {
            let packetData = pack(packet)
            
            try await localCentral.writeValue(
                packetData,
                for: CBUUID(nsuuid: characteristicUUID),
                in: deviceID,
                type: .withResponse
            )
            
            // Small delay between packets to avoid overwhelming the connection
            if packets.count > 1 {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
    }
    
    /// Receive data with reassembly
    public func receive(_ data: Data) async -> Data? {
        if let packet = unpack(data) {
            return await reassemble(packet)
        } else {
            // If unpacking as packet fails, assume it's raw data (single packet)
            return data
        }
    }
    
    /// Queue data for transmission
    public func queueForTransmission(_ data: Data) async {
        let packets = fragment(data)
        outgoingQueue.append(contentsOf: packets)
    }
    
    /// Get next packet from queue
    public func dequeuePacket() async -> Packet? {
        guard !outgoingQueue.isEmpty else { return nil }
        return outgoingQueue.removeFirst()
    }
    
    /// Clear all buffers
    public func clear() {
        reassemblyBuffers.removeAll()
        outgoingQueue.removeAll()
    }
    
    /// Cleanup timed-out reassembly buffers
    private func cleanupTimedOutBuffers() async {
        let now = Date()
        let timeout = await configManager.current().reassemblyTimeout
        let timedOutIDs = reassemblyBuffers.compactMap { (id, buffer) -> UUID? in
            if now.timeIntervalSince(buffer.startTime) > timeout {
                return id
            }
            return nil
        }
        
        for id in timedOutIDs {
            reassemblyBuffers.removeValue(forKey: id)
            BleuLogger.transport.debug("Removed timed-out reassembly buffer for \(id)")
        }
    }
    
    /// Start periodic cleanup task
    private func startCleanupTask() async {
        while !Task.isCancelled {
            await cleanupTimedOutBuffers()
            
            // Use Task.sleep with cancellation support
            let interval = await configManager.current().cleanupInterval
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                // Task was cancelled, exit gracefully
                break
            }
        }
        
        // Clean up any remaining buffers on cancellation
        await cleanupTimedOutBuffers()
    }
    
    /// Get statistics
    public func statistics() -> TransportStatistics {
        return TransportStatistics(
            activeReassemblyBuffers: reassemblyBuffers.count,
            queuedPackets: outgoingQueue.count,
            maxPayloadSize: max(1, maxWriteLength - headerOverhead)
        )
    }
}

/// Transport statistics
public struct TransportStatistics: Sendable {
    public let activeReassemblyBuffers: Int
    public let queuedPackets: Int
    public let maxPayloadSize: Int
}