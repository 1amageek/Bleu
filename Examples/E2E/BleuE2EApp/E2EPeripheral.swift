import Distributed
import Foundation
import Bleu

distributed actor E2EPeripheral: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private let serverName: String
    private var handshakeCount = 0
    private var echoCount = 0
    private var bytesReceived = 0

    init(actorSystem: ActorSystem, serverName: String) {
        self.actorSystem = actorSystem
        self.serverName = serverName
    }

    distributed func handshake(_ request: E2EHandshakeRequest) async throws -> E2EHandshakeResponse {
        handshakeCount += 1
        return E2EHandshakeResponse(
            runID: request.runID,
            peripheralID: id,
            serverPlatform: E2EPlatform.name,
            serverName: serverName,
            receivedAt: Date()
        )
    }

    distributed func echo(_ payload: E2EPayload) async throws -> E2EPayload {
        echoCount += 1
        bytesReceived += payload.bytes.count
        return payload
    }

    distributed func metrics() async throws -> E2EPeripheralMetrics {
        E2EPeripheralMetrics(
            handshakeCount: handshakeCount,
            echoCount: echoCount,
            bytesReceived: bytesReceived,
            updatedAt: Date()
        )
    }
}
