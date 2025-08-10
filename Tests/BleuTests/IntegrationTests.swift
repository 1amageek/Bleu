import Testing
import Foundation
@testable import Bleu

// MARK: - Integration and End-to-End Tests

/// Test suite for integration testing
@Suite("Integration Tests")
struct IntegrationTests {
    
    // MARK: - BLE Actor System Integration Tests
    
    @Test("BLE Actor System Basic Communication")
    func testBLEActorSystemCommunication() async throws {
        // Setup mock actor system
        let actorSystem = BLEActorSystem()
        
        // Test actor creation and basic operations
        let testServiceUUID = UUID()
        let testCharacteristicUUID = UUID()
        
        // Create peripheral actor
        let peripheralConfig = ServiceConfiguration(
            serviceUUID: testServiceUUID,
            characteristicUUIDs: [testCharacteristicUUID]
        )
        let advertisementData = AdvertisementData(localName: "Test Device")
        
        let peripheralActor = PeripheralActor(
            actorSystem: actorSystem,
            configuration: peripheralConfig,
            advertisementData: advertisementData
        )
        
        // Verify peripheral actor is created
        #expect(peripheralActor.id != nil)
        
        // Test advertising status
        let isAdvertising = await peripheralActor.getAdvertisingStatus()
        #expect(isAdvertising == false) // Should not be advertising initially
        
        await BleuLogger.shared.info("BLE Actor System integration test completed", category: .general)
    }
    
    @Test("Flow Control Integration")
    func testFlowControlIntegration() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Test Device")
        let testData = "Hello, World!".data(using: .utf8)!
        
        // Initialize flow control
        await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        
        // Test data queuing
        let canSend = await BleuFlowControlManager.shared.canSendData(to: deviceId, size: testData.count)
        #expect(canSend == true)
        
        let packet = await BleuFlowControlManager.shared.queueData(testData, for: deviceId)
        #expect(packet != nil)
        #expect(packet?.data == testData)
        
        // Test packet retrieval
        let nextPacket = await BleuFlowControlManager.shared.getNextPacketToSend(for: deviceId)
        #expect(nextPacket?.sequenceNumber == 0)
        
        // Test statistics
        let stats = await BleuFlowControlManager.shared.getStatistics(for: deviceId)
        #expect(stats?.deviceId == deviceId)
        
        await BleuLogger.shared.info("Flow control integration test completed", category: .general)
    }
    
    @Test("Security Manager Integration")
    func testSecurityManagerIntegration() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Secure Device")
        
        // Test device trust management
        await BleuSecurityManager.shared.trustDevice(deviceId, level: .trusted)
        let isTrusted = await BleuSecurityManager.shared.isDeviceTrusted(deviceId)
        #expect(isTrusted == true)
        
        let trustLevel = await BleuSecurityManager.shared.getTrustLevel(for: deviceId)
        #expect(trustLevel == .trusted)
        
        // Test configuration
        let secureConfig = SecurityConfiguration.secure
        await BleuSecurityManager.shared.updateSecurityConfiguration(secureConfig)
        
        let currentConfig = await BleuSecurityManager.shared.getSecurityConfiguration()
        #expect(currentConfig.requireEncryption == true)
        #expect(currentConfig.requireAuthentication == true)
        
        await BleuLogger.shared.info("Security manager integration test completed", category: .general)
    }
    
    @Test("Connection Manager Integration")
    func testConnectionManagerIntegration() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Connection Test Device")
        
        // Test connection state management
        await BleuConnectionManager.shared.updateConnectionState(
            for: deviceId,
            state: .connecting
        )
        
        let connectionInfo = await BleuConnectionManager.shared.getConnectionInfo(for: deviceId)
        #expect(connectionInfo?.state == .connecting)
        
        // Test quality monitoring
        let quality = ConnectionQuality(rssi: -50, packetLoss: 0.01, latency: 0.05)
        await BleuConnectionManager.shared.updateConnectionQuality(for: deviceId, quality: quality)
        
        let updatedInfo = await BleuConnectionManager.shared.getConnectionInfo(for: deviceId)
        #expect(updatedInfo?.quality?.rssi == -50)
        
        // Test statistics
        let stats = await BleuConnectionManager.shared.getConnectionStatistics()
        #expect(stats.totalConnections > 0)
        
        await BleuLogger.shared.info("Connection manager integration test completed", category: .general)
    }
    
    @Test("Data Optimization Integration")
    func testDataOptimizationIntegration() async throws {
        let testData = String(repeating: "Hello World! ", count: 100).data(using: .utf8)!
        
        // Test data optimization
        let optimizedBuffer = try await BleuDataOptimizer.shared.optimizeForTransmission(testData)
        #expect(optimizedBuffer.originalSize == testData.count)
        
        // For repetitive data, compression should be effective
        if optimizedBuffer.isCompressed {
            #expect(optimizedBuffer.compressionRatio > 0.5) // Should achieve good compression
        }
        
        // Test data restoration
        let restoredData = try await BleuDataOptimizer.shared.restoreOptimizedData(optimizedBuffer)
        #expect(restoredData == testData)
        
        // Test statistics
        let stats = await BleuDataOptimizer.shared.getOptimizationStatistics()
        #expect(stats.totalCompressions >= 0)
        
        await BleuLogger.shared.info("Data optimization integration test completed", category: .general)
    }
}

/// Test suite for end-to-end scenarios
@Suite("End-to-End Tests")
struct EndToEndTests {
    
    @Test("Complete Device Connection Flow")
    func testCompleteDeviceConnectionFlow() async throws {
        let serverDeviceId = DeviceIdentifier(uuid: UUID(), name: "Test Server")
        let clientDeviceId = DeviceIdentifier(uuid: UUID(), name: "Test Client")
        
        // Setup security
        await BleuSecurityManager.shared.trustDevice(serverDeviceId, level: .trusted)
        await BleuSecurityManager.shared.updateSecurityConfiguration(.development) // Less secure for testing
        
        // Setup connection management
        let reconnectionPolicy = ReconnectionPolicy.conservative
        await BleuConnectionManager.shared.setReconnectionPolicy(reconnectionPolicy, for: serverDeviceId)
        
        // Initialize flow control
        await BleuFlowControlManager.shared.initializeFlowControl(for: serverDeviceId)
        
        // Simulate connection establishment
        await BleuConnectionManager.shared.updateConnectionState(
            for: serverDeviceId,
            state: .connecting
        )
        
        // Simulate successful connection
        let quality = ConnectionQuality(rssi: -45, packetLoss: 0.0, latency: 0.02)
        await BleuConnectionManager.shared.updateConnectionState(
            for: serverDeviceId,
            state: .connected,
            quality: quality
        )
        
        // Verify connection state
        let connectionInfo = await BleuConnectionManager.shared.getConnectionInfo(for: serverDeviceId)
        #expect(connectionInfo?.state == .connected)
        #expect(connectionInfo?.quality?.qualityLevel == .excellent)
        
        await BleuLogger.shared.info("Complete device connection flow test completed", category: .general)
    }
    
    @Test("Data Transmission Pipeline")
    func testDataTransmissionPipeline() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Pipeline Test Device")
        let originalMessage = "This is a test message for the complete data transmission pipeline"
        let testData = originalMessage.data(using: .utf8)!
        
        // Step 1: Initialize flow control
        await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        
        // Step 2: Optimize data
        let optimizedBuffer = try await BleuDataOptimizer.shared.optimizeForTransmission(testData)
        
        // Step 3: Queue data with flow control
        let encodedBuffer = try JSONEncoder().encode(optimizedBuffer)
        let packet = await BleuFlowControlManager.shared.queueData(encodedBuffer, for: deviceId)
        #expect(packet != nil)
        
        // Step 4: Simulate transmission
        let transmittedPacket = await BleuFlowControlManager.shared.getNextPacketToSend(for: deviceId)
        #expect(transmittedPacket != nil)
        
        // Step 5: Simulate reception and acknowledgment
        let receivedResult = await BleuFlowControlManager.shared.receivePacket(transmittedPacket!, from: deviceId)
        #expect(receivedResult.data != nil)
        
        if receivedResult.shouldAck {
            let ack = AckPacket(
                packetId: transmittedPacket!.id,
                sequenceNumber: transmittedPacket!.sequenceNumber
            )
            await BleuFlowControlManager.shared.handleAcknowledgment(ack, from: deviceId)
        }
        
        // Step 6: Decode and restore data
        let decodedBuffer = try JSONDecoder().decode(OptimizedBuffer.self, from: receivedResult.data!)
        let restoredData = try await BleuDataOptimizer.shared.restoreOptimizedData(decodedBuffer)
        let restoredMessage = String(data: restoredData, encoding: .utf8)
        
        #expect(restoredMessage == originalMessage)
        
        await BleuLogger.shared.info("Data transmission pipeline test completed", category: .general)
    }
    
    @Test("Error Recovery Scenarios")
    func testErrorRecoveryScenarios() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Error Recovery Device")
        
        // Scenario 1: Connection failure with recovery
        await BleuConnectionManager.shared.updateConnectionState(
            for: deviceId,
            state: .failed,
            error: .connectionFailed("Network timeout")
        )
        
        let failedInfo = await BleuConnectionManager.shared.getConnectionInfo(for: deviceId)
        #expect(failedInfo?.state == .failed)
        #expect(failedInfo?.errors.count == 1)
        
        // Scenario 2: Security validation failure
        await BleuSecurityManager.shared.updateSecurityConfiguration(.secure)
        
        do {
            try await BleuSecurityManager.shared.validateConnection(deviceId)
            #expect(false, "Should have thrown authentication error")
        } catch let error as BleuError {
            #expect(error == .authenticationFailed)
            #expect(error.isRecoverable == true)
            #expect(error.recoveryActions.contains(.reauthenticate))
        }
        
        // Scenario 3: Flow control queue overflow
        let config = FlowControlConfiguration(maxPendingOperations: 1) // Very small limit
        await BleuFlowControlManager.shared.setConfiguration(config, for: deviceId)
        await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        
        let testData = "Test data".data(using: .utf8)!
        
        // Fill up the queue
        _ = await BleuFlowControlManager.shared.queueData(testData, for: deviceId)
        _ = await BleuFlowControlManager.shared.getNextPacketToSend(for: deviceId)
        
        // This should fail due to queue overflow
        let canSendMore = await BleuFlowControlManager.shared.canSendData(to: deviceId, size: testData.count)
        #expect(canSendMore == false)
        
        await BleuLogger.shared.info("Error recovery scenarios test completed", category: .general)
    }
    
    @Test("Performance Under Load")
    func testPerformanceUnderLoad() async throws {
        let deviceCount = 5
        let messagesPerDevice = 20
        let messageSize = 1024
        
        var devices: [DeviceIdentifier] = []
        
        // Setup multiple devices
        for i in 0..<deviceCount {
            let deviceId = DeviceIdentifier(uuid: UUID(), name: "Load Test Device \(i)")
            devices.append(deviceId)
            
            await BleuConnectionManager.shared.updateConnectionState(
                for: deviceId,
                state: .connected,
                quality: ConnectionQuality(rssi: -40 - i * 5)
            )
            
            await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Simulate high load
        await withTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask {
                    for messageIndex in 0..<messagesPerDevice {
                        let testData = Data(count: messageSize)
                        
                        // Optimize data
                        if let optimizedBuffer = try? await BleuDataOptimizer.shared.optimizeForTransmission(testData) {
                            // Queue for transmission
                            if let encodedData = try? JSONEncoder().encode(optimizedBuffer) {
                                _ = await BleuFlowControlManager.shared.queueData(encodedData, for: device)
                            }
                        }
                        
                        // Add small delay to simulate realistic timing
                        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    }
                }
            }
        }
        
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        let totalMessages = deviceCount * messagesPerDevice
        let messagesPerSecond = Double(totalMessages) / duration
        
        await BleuLogger.shared.info(
            "Performance test completed: \(totalMessages) messages in \(String(format: "%.3f", duration))s (\(String(format: "%.1f", messagesPerSecond)) msg/s)",
            category: .performance,
            metadata: [
                "devices": "\(deviceCount)",
                "messages_per_device": "\(messagesPerDevice)",
                "total_duration": String(duration)
            ]
        )
        
        // Verify performance is reasonable (should process at least 10 messages per second)
        #expect(messagesPerSecond > 10.0)
        
        // Check statistics
        let connectionStats = await BleuConnectionManager.shared.getConnectionStatistics()
        #expect(connectionStats.connectedDevices == deviceCount)
        
        let optimizationStats = await BleuDataOptimizer.shared.getOptimizationStatistics()
        #expect(optimizationStats.totalCompressions >= totalMessages)
    }
}

/// Test suite for stress testing
@Suite("Stress Tests")
struct StressTests {
    
    @Test("Memory Pressure Test", .enabled(if: ProcessInfo.processInfo.environment["STRESS_TESTS"] == "1"))
    func testMemoryPressure() async throws {
        let deviceCount = 50
        let dataSize = 64 * 1024 // 64KB per message
        let iterationCount = 100
        
        var devices: [DeviceIdentifier] = []
        
        // Create many devices
        for i in 0..<deviceCount {
            let deviceId = DeviceIdentifier(uuid: UUID(), name: "Stress Device \(i)")
            devices.append(deviceId)
            
            await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        }
        
        // Process large amounts of data
        for iteration in 0..<iterationCount {
            await withTaskGroup(of: Void.self) { group in
                for device in devices {
                    group.addTask {
                        let testData = Data(count: dataSize)
                        _ = try? await BleuDataOptimizer.shared.optimizeForTransmission(testData)
                        
                        if iteration % 10 == 0 {
                            // Periodically clean up to simulate real-world usage
                            await BleuFlowControlManager.shared.resetFlowControl(for: device)
                        }
                    }
                }
            }
            
            if iteration % 20 == 0 {
                await BleuLogger.shared.debug("Stress test progress: \(iteration)/\(iterationCount)", category: .performance)
            }
        }
        
        // Verify system is still responsive
        let stats = await BleuDataOptimizer.shared.getOptimizationStatistics()
        #expect(stats.totalCompressions > 0)
        
        await BleuLogger.shared.info("Memory pressure test completed", category: .performance)
    }
    
    @Test("Concurrent Access Test")
    func testConcurrentAccess() async throws {
        let deviceId = DeviceIdentifier(uuid: UUID(), name: "Concurrent Access Device")
        let concurrentTasks = 20
        let operationsPerTask = 50
        
        await BleuFlowControlManager.shared.initializeFlowControl(for: deviceId)
        await BleuConnectionManager.shared.updateConnectionState(for: deviceId, state: .connected)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Run concurrent operations
        await withTaskGroup(of: Int.self) { group in
            for taskId in 0..<concurrentTasks {
                group.addTask {
                    var successCount = 0
                    
                    for _ in 0..<operationsPerTask {
                        let testData = "Concurrent test data \(taskId)".data(using: .utf8)!
                        
                        // Mix of different operations
                        let operation = Int.random(in: 0...3)
                        
                        switch operation {
                        case 0:
                            // Data optimization
                            if let _ = try? await BleuDataOptimizer.shared.optimizeForTransmission(testData) {
                                successCount += 1
                            }
                            
                        case 1:
                            // Flow control
                            if await BleuFlowControlManager.shared.canSendData(to: deviceId, size: testData.count) {
                                _ = await BleuFlowControlManager.shared.queueData(testData, for: deviceId)
                                successCount += 1
                            }
                            
                        case 2:
                            // Connection quality update
                            let quality = ConnectionQuality(rssi: Int.random(in: -80...(-30)))
                            await BleuConnectionManager.shared.updateConnectionQuality(for: deviceId, quality: quality)
                            successCount += 1
                            
                        case 3:
                            // Security check
                            let trustLevel = await BleuSecurityManager.shared.getTrustLevel(for: deviceId)
                            if trustLevel != .untrusted {
                                successCount += 1
                            }
                            
                        default:
                            break
                        }
                    }
                    
                    return successCount
                }
            }
            
            // Collect results
            var totalSuccesses = 0
            for await success in group {
                totalSuccesses += success
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime
            let totalOperations = concurrentTasks * operationsPerTask
            let successRate = Double(totalSuccesses) / Double(totalOperations)
            
            await BleuLogger.shared.info(
                "Concurrent access test completed: \(totalSuccesses)/\(totalOperations) operations succeeded (\(String(format: "%.1f", successRate * 100))%) in \(String(format: "%.3f", duration))s",
                category: .performance
            )
            
            // Should achieve at least 80% success rate under concurrent load
            #expect(successRate > 0.8)
        }
    }
}

/// Helper functions for testing
extension IntegrationTests {
    
    /// Setup common test environment
    static func setupTestEnvironment() async {
        // Configure logging for testing
        await BleuLogger.shared.setMinimumLevel(.debug)
        await BleuLogger.shared.info("Test environment initialized", category: .general)
        
        // Setup performance monitoring
        await BleuPerformanceMonitor.shared.clearMetrics()
    }
    
    /// Cleanup test environment
    static func cleanupTestEnvironment() async {
        // Cleanup managers
        await BleuConnectionManager.shared.cleanupAll()
        await BleuFlowControlManager.shared.cleanupAll()
        await BleuDataOptimizer.shared.clearStatistics()
        
        await BleuLogger.shared.info("Test environment cleaned up", category: .general)
        await BleuLogger.shared.flush()
    }
}

// MARK: - Test Utilities

/// Mock data generators for testing
enum TestDataGenerator {
    
    static func generateRandomData(size: Int) -> Data {
        var data = Data(capacity: size)
        for _ in 0..<size {
            data.append(UInt8.random(in: 0...255))
        }
        return data
    }
    
    static func generateCompressibleData(size: Int) -> Data {
        let pattern = "Hello World! ".data(using: .utf8)!
        let repeatCount = (size + pattern.count - 1) / pattern.count
        var data = Data()
        
        for _ in 0..<repeatCount {
            data.append(pattern)
        }
        
        return data.prefix(size)
    }
    
    static func generateDeviceInfos(count: Int) -> [DeviceInfo] {
        return (0..<count).map { index in
            DeviceInfo(
                identifier: DeviceIdentifier(uuid: UUID(), name: "Test Device \(index)"),
                rssi: Int.random(in: -80...(-30)),
                advertisementData: AdvertisementData(
                    localName: "Test Device \(index)",
                    serviceUUIDs: [UUID()]
                ),
                isConnectable: true
            )
        }
    }
}

/// Performance assertions
enum PerformanceAssertions {
    
    /// Assert operation completes within expected time
    static func assertPerformance<T>(
        _ operation: () async throws -> T,
        completesWithin duration: TimeInterval,
        file: StaticString = #file,
        line: UInt = #line
    ) async rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let actualDuration = CFAbsoluteTimeGetCurrent() - startTime
        
        if actualDuration > duration {
            Issue.record("Operation took \(String(format: "%.3f", actualDuration))s, expected < \(duration)s", sourceLocation: SourceLocation(file, line))
        }
        
        return result
    }
    
    /// Assert memory usage stays within bounds
    static func assertMemoryUsage(
        staysBelow limit: Int,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let memoryUsage = getCurrentMemoryUsage()
        
        if memoryUsage > limit {
            Issue.record("Memory usage \(memoryUsage) bytes exceeds limit \(limit) bytes", sourceLocation: SourceLocation(file, line))
        }
    }
    
    private static func getCurrentMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return status == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}