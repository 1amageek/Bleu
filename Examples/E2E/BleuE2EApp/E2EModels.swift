import Foundation

enum E2ERole: String, CaseIterable, Identifiable {
    case peripheral
    case central

    var id: String { rawValue }

    var title: String {
        switch self {
        case .peripheral:
            return "Peripheral"
        case .central:
            return "Central"
        }
    }
}

enum E2EPhase: String {
    case idle = "Idle"
    case advertising = "Advertising"
    case scanning = "Scanning"
    case connected = "Connected"
    case running = "Running"
    case passed = "Passed"
    case failed = "Failed"
}

enum E2ETestStatus: String {
    case pending = "Pending"
    case passed = "Passed"
    case failed = "Failed"
}

struct E2EHandshakeRequest: Codable, Sendable, Equatable {
    let runID: UUID
    let clientPlatform: String
    let startedAt: Date
}

struct E2EHandshakeResponse: Codable, Sendable, Equatable {
    let runID: UUID
    let peripheralID: UUID
    let serverPlatform: String
    let serverName: String
    let receivedAt: Date
}

struct E2EPayload: Codable, Sendable, Equatable {
    let runID: UUID
    let sequence: Int
    let bytes: Data
    let sentAt: Date
}

struct E2EPeripheralMetrics: Codable, Sendable, Equatable {
    let handshakeCount: Int
    let echoCount: Int
    let bytesReceived: Int
    let updatedAt: Date
}

struct E2EPeer: Identifiable, Equatable {
    let id: UUID
    let title: String
}

struct E2ETestResult: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let status: E2ETestStatus
    let detail: String
    let duration: TimeInterval
}

struct E2ELogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

enum E2EPlatform {
    static var name: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "Unknown"
        #endif
    }

    static var defaultRole: E2ERole {
        #if os(macOS)
        return .central
        #else
        return .peripheral
        #endif
    }
}

extension UUID {
    var e2eShortID: String {
        String(uuidString.prefix(8))
    }
}
