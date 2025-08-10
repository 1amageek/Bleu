import Testing
import Foundation
@testable import Bleu

// MARK: - Unit Tests

@Suite("Core Types Tests")
struct CoreTypesTests {
    
    @Test("DeviceIdentifier")
    func testDeviceIdentifier() {
        let uuid = UUID()
        let name = "Test Device"
        
        let deviceId = DeviceIdentifier(uuid: uuid, name: name)
        
        #expect(deviceId.uuid == uuid)
        #expect(deviceId.name == name)
        
        // Test Hashable conformance
        let deviceId2 = DeviceIdentifier(uuid: uuid, name: name)
        #expect(deviceId == deviceId2)
        
        let deviceIdSet: Set<DeviceIdentifier> = [deviceId, deviceId2]
        #expect(deviceIdSet.count == 1)
    }
    
    @Test("ServiceConfiguration")
    func testServiceConfiguration() {
        let serviceUUID = UUID()
        let characteristicUUIDs = [UUID(), UUID()]
        
        let config = ServiceConfiguration(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            isPrimary: true
        )
        
        #expect(config.serviceUUID == serviceUUID)
        #expect(config.characteristicUUIDs == characteristicUUIDs)
        #expect(config.isPrimary == true)
    }
    
    @Test("BleuMessage")
    func testBleuMessage() {
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let testData = "Hello".data(using: .utf8)!
        
        let message = BleuMessage(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: testData,
            method: .write
        )
        
        #expect(message.serviceUUID == serviceUUID)
        #expect(message.characteristicUUID == characteristicUUID)
        #expect(message.data == testData)
        #expect(message.method == .write)
        #expect(message.id != UUID()) // Should have a valid ID
    }
    
    @Test("RequestMethod Properties")
    func testRequestMethodProperties() {
        #expect(RequestMethod.read.properties.contains(.read))
        #expect(RequestMethod.write.properties.contains(.write))
        #expect(RequestMethod.writeWithoutResponse.properties.contains(.writeWithoutResponse))
        #expect(RequestMethod.notify.properties.contains(.notify))
        #expect(RequestMethod.indicate.properties.contains(.indicate))
        
        #expect(RequestMethod.read.permissions == .readable)
        #expect(RequestMethod.write.permissions == .writeable)
    }
}

@Suite("Error Handling Tests")
struct ErrorHandlingTests {
    
    @Test("BleuError Properties")
    func testBleuErrorProperties() {
        let connectionError = BleuError.connectionFailed("Network timeout")
        #expect(connectionError.severity == .medium)
        #expect(connectionError.isRecoverable == true)
        #expect(connectionError.recoveryActions.contains(.retry))
        
        let criticalError = BleuError.bluetoothUnavailable
        #expect(criticalError.severity == .critical)
        #expect(criticalError.isRecoverable == false)
        
        let authError = BleuError.authenticationFailed
        #expect(authError.severity == .high)
        #expect(authError.isRecoverable == true)
        #expect(authError.recoveryActions.contains(.reauthenticate))
    }
    
    @Test("ErrorContext")
    func testErrorContext() {
        let context = ErrorContext(
            operation: "connect",
            deviceId: "test-device",
            additionalInfo: ["attempt": "1", "reason": "timeout"]
        )
        
        #expect(context.operation == "connect")
        #expect(context.deviceId == "test-device")
        #expect(context.additionalInfo["attempt"] == "1")
        #expect(context.additionalInfo["reason"] == "timeout")
    }
    
    @Test("BleuErrorWithContext")
    func testBleuErrorWithContext() {
        let error = BleuError.connectionFailed("Timeout")
        let context = ErrorContext(operation: "connect", deviceId: "test-device")
        
        let contextualError = BleuErrorWithContext(
            error: error,
            context: context
        )
        
        let description = contextualError.localizedDescription
        #expect(description.contains("Connection failed"))
        #expect(description.contains("connect"))
        #expect(description.contains("test-device"))
    }
}

@Suite("Security Tests")
struct SecurityTests {
    
    @Test("SecurityConfiguration")
    func testSecurityConfiguration() {
        let secureConfig = SecurityConfiguration.secure
        #expect(secureConfig.requirePairing == true)
        #expect(secureConfig.requireEncryption == true)
        #expect(secureConfig.requireAuthentication == true)
        
        let devConfig = SecurityConfiguration.development
        #expect(devConfig.requirePairing == false)
        #expect(devConfig.requireEncryption == false)
        #expect(devConfig.requireAuthentication == false)
    }
    
    @Test("TrustLevel")
    func testTrustLevel() {
        #expect(TrustLevel.untrusted.description == "Untrusted")
        #expect(TrustLevel.trusted.description == "Trusted")
        #expect(TrustLevel.verified.description == "Verified")
    }
    
    @Test("SecurityCredentials Validation")
    func testSecurityCredentialsValidation() {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Test Device")
        
        // Valid credentials
        let validCredentials = SecurityCredentials(
            deviceIdentifier: deviceId,
            trustLevel: .trusted,
            authenticationState: .authenticated(Date()),
            expirationDate: Calendar.current.date(byAdding: .hour, value: 1, to: Date())
        )
        #expect(validCredentials.isValid == true)
        
        // Expired credentials
        let expiredCredentials = SecurityCredentials(
            deviceIdentifier: deviceId,
            trustLevel: .trusted,
            authenticationState: .authenticated(Date()),
            expirationDate: Calendar.current.date(byAdding: .hour, value: -1, to: Date())
        )
        #expect(expiredCredentials.isValid == false)
        
        // Unauthenticated credentials
        let unauthenticatedCredentials = SecurityCredentials(
            deviceIdentifier: deviceId,
            trustLevel: .trusted,
            authenticationState: .unauthenticated
        )
        #expect(unauthenticatedCredentials.isValid == false)
    }
}

@Suite("Connection Management Tests")
struct ConnectionManagementTests {
    
    @Test("ConnectionState Properties")
    func testConnectionStateProperties() {
        #expect(ConnectionState.connected.isConnected == true)
        #expect(ConnectionState.disconnected.isConnected == false)
        
        #expect(ConnectionState.connecting.isConnecting == true)
        #expect(ConnectionState.reconnecting.isConnecting == true)
        #expect(ConnectionState.connected.isConnecting == false)
    }
    
    @Test("ConnectionQuality Calculations")
    func testConnectionQualityCalculations() {
        // Excellent quality
        let excellentQuality = ConnectionQuality(
            rssi: -35,
            packetLoss: 0.0,
            latency: 0.01
        )
        #expect(excellentQuality.qualityLevel == .excellent)
        #expect(excellentQuality.qualityScore > 0.8)
        
        // Poor quality
        let poorQuality = ConnectionQuality(
            rssi: -85,
            packetLoss: 0.5,
            latency: 1.0
        )
        #expect(poorQuality.qualityLevel == .poor)
        #expect(poorQuality.qualityScore < 0.4)
    }
    
    @Test("ReconnectionPolicy Delay Calculation")
    func testReconnectionPolicyDelayCalculation() {
        let policy = ReconnectionPolicy(
            initialDelay: 1.0,
            maxDelay: 60.0,
            backoffMultiplier: 2.0,
            jitterFactor: 0.0 // No jitter for predictable testing
        )
        
        let delay0 = policy.delayForAttempt(0)
        let delay1 = policy.delayForAttempt(1)
        let delay2 = policy.delayForAttempt(2)
        
        #expect(delay0 == 1.0)
        #expect(delay1 == 2.0)
        #expect(delay2 == 4.0)
        
        // Test max delay cap
        let delay10 = policy.delayForAttempt(10)
        #expect(delay10 <= 60.0)
    }
    
    @Test("ConnectionInfo Properties")
    func testConnectionInfoProperties() {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Test Device")
        let connectedAt = Date()
        
        let connectionInfo = ConnectionInfo(
            deviceId: deviceId,
            state: .connected,
            connectedAt: connectedAt
        )
        
        #expect(connectionInfo.deviceId == deviceId)
        #expect(connectionInfo.state == .connected)
        #expect(connectionInfo.uptime != nil)
        #expect(connectionInfo.timeSinceLastSeen < 1.0) // Should be very recent
    }
}

@Suite("Flow Control Tests")
struct FlowControlTests {
    
    @Test("FlowControlConfiguration Presets")
    func testFlowControlConfigurationPresets() {
        let conservative = FlowControlConfiguration.conservative
        #expect(conservative.maxPendingOperations == 3)
        #expect(conservative.windowSize == 2)
        #expect(conservative.ackTimeout == 10.0)
        
        let aggressive = FlowControlConfiguration.aggressive
        #expect(aggressive.maxPendingOperations == 20)
        #expect(aggressive.windowSize == 10)
        #expect(aggressive.ackTimeout == 2.0)
    }
    
    @Test("DataPacket Creation")
    func testDataPacketCreation() {
        let testData = "Hello".data(using: .utf8)!
        let packet = DataPacket(sequenceNumber: 42, data: testData, requiresAck: true)
        
        #expect(packet.sequenceNumber == 42)
        #expect(packet.data == testData)
        #expect(packet.requiresAck == true)
        #expect(packet.id != UUID()) // Should have valid UUID
    }
    
    @Test("AckPacket Creation")
    func testAckPacketCreation() {
        let packetId = UUID()
        let ack = AckPacket(packetId: packetId, sequenceNumber: 123)
        
        #expect(ack.packetId == packetId)
        #expect(ack.sequenceNumber == 123)
        #expect(ack.receivedSuccessfully == true)
    }
}

@Suite("Data Optimization Tests")
struct DataOptimizationTests {
    
    @Test("CompressionAlgorithm Recommendations")
    func testCompressionAlgorithmRecommendations() {
        #expect(CompressionAlgorithm.recommended(for: 100) == .none)
        #expect(CompressionAlgorithm.recommended(for: 1024) == .lz4)
        #expect(CompressionAlgorithm.recommended(for: 8192) == .lzfse)
        #expect(CompressionAlgorithm.recommended(for: 100000) == .lzma)
    }
    
    @Test("BufferConfiguration Presets")
    func testBufferConfigurationPresets() {
        let lowMemory = BufferConfiguration.lowMemory
        #expect(lowMemory.bufferSize == 1024)
        #expect(lowMemory.maxBuffers == 5)
        #expect(lowMemory.compressionAlgorithm == .lz4)
        
        let highPerf = BufferConfiguration.highPerformance
        #expect(highPerf.bufferSize == 8192)
        #expect(highPerf.maxBuffers == 50)
        #expect(highPerf.adaptiveBuffering == true)
    }
    
    @Test("OptimizedBuffer Properties")
    func testOptimizedBufferProperties() {
        let originalData = "Hello World".data(using: .utf8)!
        let compressedData = "Compressed".data(using: .utf8)!
        
        let buffer = OptimizedBuffer(
            data: compressedData,
            isCompressed: true,
            compressionAlgorithm: .lzfse,
            originalSize: originalData.count
        )
        
        #expect(buffer.isCompressed == true)
        #expect(buffer.compressionAlgorithm == .lzfse)
        #expect(buffer.originalSize == originalData.count)
        
        let compressionRatio = buffer.compressionRatio
        #expect(compressionRatio >= 0.0)
        #expect(compressionRatio <= 1.0)
        
        let sizeReduction = buffer.sizeReduction
        #expect(sizeReduction == originalData.count - compressedData.count)
    }
    
    @Test("Data Compression Roundtrip")
    func testDataCompressionRoundtrip() throws {
        let originalData = String(repeating: "Hello World! ", count: 50).data(using: .utf8)!
        
        // Test LZ4 compression
        let compressedLZ4 = try DataCompression.compress(originalData, using: .lz4)
        let decompressedLZ4 = try DataCompression.decompress(
            compressedLZ4,
            using: .lz4,
            originalSize: originalData.count
        )
        #expect(decompressedLZ4 == originalData)
        #expect(compressedLZ4.count < originalData.count) // Should be compressed
        
        // Test LZFSE compression
        let compressedLZFSE = try DataCompression.compress(originalData, using: .lzfse)
        let decompressedLZFSE = try DataCompression.decompress(
            compressedLZFSE,
            using: .lzfse,
            originalSize: originalData.count
        )
        #expect(decompressedLZFSE == originalData)
    }
}

@Suite("Logging Tests")
struct LoggingTests {
    
    @Test("LogLevel Ordering")
    func testLogLevelOrdering() {
        #expect(LogLevel.debug.rawValue < LogLevel.info.rawValue)
        #expect(LogLevel.info.rawValue < LogLevel.warning.rawValue)
        #expect(LogLevel.warning.rawValue < LogLevel.error.rawValue)
        #expect(LogLevel.error.rawValue < LogLevel.critical.rawValue)
    }
    
    @Test("LogEntry Creation")
    func testLogEntryCreation() {
        let entry = LogEntry(
            level: .info,
            category: .connection,
            message: "Test message",
            deviceId: "test-device",
            metadata: ["key": "value"]
        )
        
        #expect(entry.level == .info)
        #expect(entry.category == .connection)
        #expect(entry.message == "Test message")
        #expect(entry.deviceId == "test-device")
        #expect(entry.metadata["key"] == "value")
        
        let formatted = entry.formattedMessage
        #expect(formatted.contains("INFO"))
        #expect(formatted.contains("Connection"))
        #expect(formatted.contains("Test message"))
        #expect(formatted.contains("test-device"))
        #expect(formatted.contains("key=value"))
    }
    
    @Test("PerformanceMetrics")
    func testPerformanceMetrics() {
        let metrics = PerformanceMetrics(
            operationName: "test_operation",
            duration: 1.5,
            deviceId: "test-device",
            success: true,
            metadata: ["attempts": "3"]
        )
        
        #expect(metrics.operationName == "test_operation")
        #expect(metrics.duration == 1.5)
        #expect(metrics.deviceId == "test-device")
        #expect(metrics.success == true)
        #expect(metrics.metadata["attempts"] == "3")
    }
}

@Suite("Performance Tests")
struct PerformanceTests {
    
    @Test("Large Data Compression Performance")
    func testLargeDataCompressionPerformance() async throws {
        let largeData = Data(repeating: 0x42, count: 1024 * 1024) // 1MB of repeated data
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let optimizedBuffer = try await BleuDataOptimizer.shared.optimizeForTransmission(largeData)
        let compressionTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // Should compress efficiently for repeated data
        #expect(optimizedBuffer.isCompressed == true)
        #expect(optimizedBuffer.compressionRatio > 0.9) // Very high compression for repeated data
        
        // Should complete in reasonable time (less than 1 second)
        #expect(compressionTime < 1.0)
        
        // Verify decompression
        let restoreStartTime = CFAbsoluteTimeGetCurrent()
        let restoredData = try await BleuDataOptimizer.shared.restoreOptimizedData(optimizedBuffer)
        let decompressionTime = CFAbsoluteTimeGetCurrent() - restoreStartTime
        
        #expect(restoredData == largeData)
        #expect(decompressionTime < 1.0)
    }
    
    @Test("Concurrent Buffer Pool Access")
    func testConcurrentBufferPoolAccess() async {
        let config = BufferConfiguration(bufferSize: 4096, maxBuffers: 10)
        let pool = BufferPool(configuration: config)
        
        let concurrentCount = 20
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrentCount {
                group.addTask {
                    // Acquire and release buffers concurrently
                    let buffer = await pool.acquireBuffer()
                    
                    // Simulate some work
                    try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
                    
                    await pool.releaseBuffer(buffer)
                }
            }
        }
        
        let stats = await pool.getStatistics()
        #expect(stats.totalAllocated <= config.maxBuffers)
    }
    
    @Test("Flow Control High Throughput")
    func testFlowControlHighThroughput() async {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "High Throughput Device")
        let config = FlowControlConfiguration.aggressive
        
        await BleuFlowControlManager.shared.configure(with: config, for: deviceId)
        await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        
        let messageCount = 1000
        let messageSize = 1024
        let testData = Data(count: messageSize)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var successCount = 0
        for _ in 0..<messageCount {
            if await BleuFlowControlManager.shared.canSendData(to: deviceId, size: testData.count) {
                if let _ = await BleuFlowControlManager.shared.queueData(testData, for: deviceId) {
                    successCount += 1
                }
            }
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let throughput = Double(successCount) / duration
        
        // Should achieve high throughput
        #expect(throughput > 100.0) // At least 100 messages per second
        #expect(Double(successCount) / Double(messageCount) > 0.8) // At least 80% success rate
        
        await BleuLogger.shared.info(
            "Flow control throughput test: \(successCount)/\(messageCount) messages queued in \(String(format: "%.3f", duration))s (\(String(format: "%.1f", throughput)) msg/s)",
            category: .performance
        )
    }
}

// MARK: - Test Utilities

extension UnitTests {
    /// Helper to create test device identifier
    static func createTestDeviceId(name: String = "Test Device") -> DeviceIdentifier {
        return DeviceIdentifier(uuid: UUID(), name: name)
    }
    
    /// Helper to create test service configuration
    static func createTestServiceConfig() -> ServiceConfiguration {
        return ServiceConfiguration(
            serviceUUID: UUID(),
            characteristicUUIDs: [UUID(), UUID()]
        )
    }
    
    /// Helper to create test advertisement data
    static func createTestAdvertisementData(name: String = "Test Advertisement") -> AdvertisementData {
        return AdvertisementData(
            localName: name,
            serviceUUIDs: [UUID()],
            manufacturerData: Data([0x01, 0x02, 0x03, 0x04])
        )
    }
}

/// Mock implementations for testing
class MockLogDestination: LogDestination {
    var logEntries: [LogEntry] = []
    
    func write(_ entry: LogEntry) async {
        logEntries.append(entry)
    }
    
    func flush() async {
        // Mock implementation - nothing to flush
    }
}