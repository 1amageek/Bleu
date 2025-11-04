// RECOMMENDED FIX: RPC Response Transmission with Retry Logic
// File: Sources/Bleu/Core/EventBridge.swift
//
// This file shows the recommended changes to fix critical RPC response transmission issues.
// See CRITICAL_RPC_RESPONSE_TRANSMISSION_ANALYSIS.md for detailed analysis.

import Foundation
import CoreBluetooth
import Distributed
import ActorRuntime

// MARK: - New Helper Methods for EventBridge

extension EventBridge {

    // MARK: - Layer 1: Retry Logic

    /// Send a single packet with retry logic for transient failures
    /// - Parameters:
    ///   - packet: The packet to send
    ///   - characteristicUUID: UUID of the RPC characteristic
    ///   - peripheralManager: The peripheral manager to use for transmission
    ///   - maxRetries: Maximum number of retry attempts (default: 3)
    /// - Throws: BleuError if all retries exhausted or permanent error encountered
    private func sendPacketWithRetry(
        _ packet: BLETransport.Packet,
        characteristicUUID: UUID,
        peripheralManager: BLEPeripheralManagerProtocol,
        maxRetries: Int = 3
    ) async throws {
        let transport = BLETransport.shared
        var retries = 0
        var lastError: Error?
        let baseDelay: UInt64 = 50_000_000  // 50ms

        while retries <= maxRetries {
            do {
                let packetData = await transport.packPacket(packet)
                let success = try await peripheralManager.updateValue(
                    packetData,
                    for: characteristicUUID,
                    to: nil
                )

                if success {
                    // Success - log if retried
                    if retries > 0 {
                        BleuLogger.rpc.info("Packet sent successfully after \(retries) retries")
                    }
                    return
                }

                // success=false but no error thrown - treat as transient quota issue
                if retries < maxRetries {
                    retries += 1
                    let delay = baseDelay * UInt64(1 << (retries - 1))  // Exponential backoff
                    BleuLogger.rpc.debug("Packet send returned false, retrying (\(retries)/\(maxRetries)) after \(Double(delay) / 1_000_000)ms")
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }

                throw BleuError.operationNotSupported

            } catch let error as BleuError {
                // Check if error is permanent or transient
                switch error {
                case .disconnected, .bluetoothUnavailable, .characteristicNotFound, .bluetoothPoweredOff:
                    // Permanent errors - abort immediately without retry
                    BleuLogger.rpc.error("Permanent error during packet send: \(error), aborting")
                    throw error

                case .quotaExceeded, .connectionFailed:
                    // Transient errors - retry with exponential backoff
                    lastError = error
                    if retries < maxRetries {
                        retries += 1
                        let delay = baseDelay * UInt64(1 << (retries - 1))
                        BleuLogger.rpc.warning("Transient error during packet send: \(error), retrying (\(retries)/\(maxRetries)) after \(Double(delay) / 1_000_000)ms")
                        try await Task.sleep(nanoseconds: delay)
                        continue
                    }

                default:
                    // Unknown errors - retry conservatively
                    lastError = error
                    if retries < maxRetries {
                        retries += 1
                        let delay = baseDelay * 2  // Fixed 100ms delay for unknown errors
                        BleuLogger.rpc.warning("Unknown error during packet send: \(error), retrying (\(retries)/\(maxRetries)) after \(Double(delay) / 1_000_000)ms")
                        try await Task.sleep(nanoseconds: delay)
                        continue
                    }
                }
            } catch {
                // Non-BleuError - retry conservatively
                lastError = error
                if retries < maxRetries {
                    retries += 1
                    let delay = baseDelay * 2
                    BleuLogger.rpc.warning("Unexpected error during packet send: \(error), retrying (\(retries)/\(maxRetries))")
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }
            }
        }

        // Exhausted all retries
        let finalError = lastError ?? BleuError.operationNotSupported
        BleuLogger.rpc.error("Failed to send packet after \(maxRetries) retries: \(finalError)")
        throw finalError
    }

    // MARK: - Layer 2: Error Response Handling

    /// Send error response to central when response transmission fails
    /// - Parameters:
    ///   - callID: Original RPC call ID
    ///   - error: The error that occurred
    ///   - characteristicUUID: UUID of the RPC characteristic
    ///   - peripheralManager: The peripheral manager to use
    /// - Note: This is a best-effort send with no retries to avoid infinite loops
    private func sendErrorResponse(
        callID: String,
        error: Error,
        characteristicUUID: UUID,
        peripheralManager: BLEPeripheralManagerProtocol
    ) async {
        // Convert error to RuntimeError
        let runtimeError: RuntimeError
        if let bleuError = error as? BleuError {
            runtimeError = convertToRuntimeError(bleuError)
        } else {
            runtimeError = .transportFailed("Response transmission failed: \(error.localizedDescription)")
        }

        // Create error response envelope
        let errorResponse = ResponseEnvelope(
            callID: callID,
            result: .failure(runtimeError)
        )

        // Try to send error response (single packet, no fragmentation)
        do {
            guard let errorData = try? JSONEncoder().encode(errorResponse) else {
                BleuLogger.rpc.error("Failed to encode error response")
                return
            }

            let transport = BLETransport.shared
            let packets = await transport.fragment(errorData)

            // If error response needs multiple packets, only send first packet
            // (to keep error response simple and avoid recursive failure)
            if let firstPacket = packets.first {
                let packetData = await transport.packPacket(firstPacket)

                // Best-effort send (no retry to avoid infinite loop)
                let success = try? await peripheralManager.updateValue(
                    packetData,
                    for: characteristicUUID,
                    to: nil
                )

                if success == true {
                    BleuLogger.rpc.info("Successfully sent error response to central")
                } else {
                    BleuLogger.rpc.warning("Failed to send error response, central will timeout")
                }
            }
        }
    }

    /// Helper to convert BleuError to RuntimeError
    private func convertToRuntimeError(_ error: BleuError) -> RuntimeError {
        switch error {
        case .disconnected:
            return .transportFailed("Disconnected")
        case .bluetoothUnavailable:
            return .transportFailed("Bluetooth unavailable")
        case .connectionFailed(let message):
            return .transportFailed(message)
        case .quotaExceeded:
            return .transportFailed("Quota exceeded")
        case .operationNotSupported:
            return .transportFailed("Operation not supported")
        default:
            return .transportFailed(String(describing: error))
        }
    }

    // MARK: - Modified handleWriteRequest (with retry and error handling)

    /// Handle write requests with improved reliability
    /// REPLACES: EventBridge.handleWriteRequest() lines 187-249
    func handleWriteRequestWithRetry(_ characteristicUUID: UUID, data: Data) async {
        let startTime = Date()

        // Unpack the data using BLETransport (handles fragmentation)
        let transport = BLETransport.shared
        guard let completeData = await transport.receive(data) else {
            return  // Waiting for more fragments
        }

        // Try to decode as InvocationEnvelope
        guard let envelope = try? JSONDecoder().decode(InvocationEnvelope.self, from: completeData) else {
            BleuLogger.rpc.warning("Failed to decode InvocationEnvelope from write request")
            return
        }

        BleuLogger.rpc.info("Received RPC request: \(envelope.target) (callID: \(envelope.callID))")

        // Process the RPC request if handler is set
        guard let handler = rpcRequestHandler,
              let peripheralManager = peripheralManager else {
            BleuLogger.rpc.error("No RPC handler or peripheral manager available")
            return
        }

        // Execute the RPC method
        let response = await handler(envelope)

        // Try to send response with retry logic
        do {
            guard let responseData = try? JSONEncoder().encode(response) else {
                BleuLogger.rpc.error("Failed to encode RPC response")
                return
            }

            let packets = await transport.fragment(responseData)
            BleuLogger.rpc.info("Sending RPC response: \(packets.count) packets, \(responseData.count) bytes")

            // Send all packets with retry
            for (index, packet) in packets.enumerated() {
                try await sendPacketWithRetry(
                    packet,
                    characteristicUUID: characteristicUUID,
                    peripheralManager: peripheralManager
                )

                // Small delay between packets to avoid overwhelming the connection
                if index < packets.count - 1 {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }

            let duration = Date().timeIntervalSince(startTime)
            BleuLogger.rpc.info("Successfully sent RPC response: \(packets.count) packets in \(String(format: "%.2f", duration * 1000))ms")

        } catch {
            // Transmission failed after retries - send error response
            let duration = Date().timeIntervalSince(startTime)
            BleuLogger.rpc.error("Failed to send RPC response after retries: \(error) (duration: \(String(format: "%.2f", duration * 1000))ms)")

            // Send error response to central (best-effort)
            await sendErrorResponse(
                callID: envelope.callID,
                error: error,
                characteristicUUID: characteristicUUID,
                peripheralManager: peripheralManager
            )

            // Even if error response fails to send, Central will timeout
            // But at least we tried to notify it
        }
    }
}

// MARK: - Layer 3: Timeout Coordination

extension BLETransport {

    /// Cleanup a specific reassembly buffer (called on RPC timeout)
    /// PUBLIC API addition
    public func cleanupBuffer(_ id: UUID) async {
        if reassemblyBuffers.removeValue(forKey: id) != nil {
            BleuLogger.transport.debug("Cleaned up timed-out reassembly buffer for \(id)")
        }
    }
}

extension EventBridge {

    /// Modified registerRPCCall with buffer cleanup on timeout
    /// REPLACES: EventBridge.registerRPCCall() lines 266-295
    func registerRPCCallWithCleanup(_ callID: String, peripheralID: UUID? = nil) async throws -> ResponseEnvelope {
        // Convert String callID to UUID for internal tracking
        guard let id = UUID(uuidString: callID) else {
            throw BleuError.invalidData
        }

        // Get timeout from configuration
        let timeoutSec = await BleuConfigurationManager.shared.current().rpcTimeout

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[id] = continuation

            // Track peripheral association if provided
            if let peripheralID = peripheralID {
                callToPeripheral[id] = peripheralID
                if peripheralCalls[peripheralID] == nil {
                    peripheralCalls[peripheralID] = []
                }
                peripheralCalls[peripheralID]?.insert(id)
            }

            // Set timeout using configuration
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                if let cont = self.takePending(id) {
                    BleuLogger.rpc.warning("RPC call timed out after \(timeoutSec)s: \(id)")
                    cont.resume(throwing: BleuError.connectionTimeout)

                    // NEW: Cleanup reassembly buffer on timeout to prevent memory leak
                    let transport = BLETransport.shared
                    await transport.cleanupBuffer(id)
                }
            }
        }
    }
}

// MARK: - Usage Example

/*
 To integrate these changes into the existing codebase:

 1. Add the extension methods to EventBridge.swift
 2. Replace the existing handleWriteRequest() method with handleWriteRequestWithRetry()
 3. Replace the existing registerRPCCall() method with registerRPCCallWithCleanup()
 4. Add cleanupBuffer() method to BLETransport.swift
 5. Update configuration defaults in BleuConfiguration.swift:

    public static let `default` = BleuConfiguration(
        rpcTimeout: 10.0,              // Keep same
        reassemblyTimeout: 15.0,       // Reduce from 30s to 15s
        cleanupInterval: 5.0,          // Increase from 10s to 5s
        maxRetryAttempts: 3,           // Use in retry logic
        retryDelay: 0.05               // 50ms base delay
    )

 6. Add unit tests for retry logic:
    - testPartialTransmissionFailure()
    - testRetrySuccess()
    - testPermanentFailure()
    - testErrorResponseSent()

 7. Add integration tests:
    - testRPCWithNetworkIssues()
    - testRPCWithRandomPacketLoss()

 8. Add telemetry/metrics:
    - Track retry counts per RPC
    - Track transmission duration
    - Track failure rates by error type

 Expected improvements:
 - Reduce timeout rate from 5-40% to <1%
 - Better error messages (specific errors instead of generic timeout)
 - Eliminate memory leaks
 - Minimal performance impact (50-200ms for retries)
 */

// MARK: - Alternative: Use BLE Indications

/*
 Optional advanced approach: Use BLE Indications instead of Notifications

 Indications provide acknowledgment from Central, making transmission reliable
 without needing application-level retry logic.

 Changes needed:

 1. In ServiceMapper.swift, change characteristic properties:

    CharacteristicMetadata(
        uuid: rpcCharUUID,
        properties: [.read, .write, .indicate],  // ← Changed from .notify
        permissions: [.readable, .writeable]
    )

 2. CoreBluetooth automatically waits for ACK when characteristic has .indicate
    Returns false if Central doesn't ACK within timeout

 3. No retry logic needed at application level

 Trade-offs:
 - Pro: Guaranteed delivery at BLE protocol level
 - Pro: Immediate failure detection
 - Pro: Simpler application code
 - Con: ~2x slower (ACK round-trip per packet)
 - Con: Still fails on disconnection (but detected immediately)

 Recommendation: Start with retry logic (easy, backward compatible)
                 Consider indications later if retry isn't sufficient
 */
