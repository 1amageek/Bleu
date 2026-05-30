import Foundation
import Bleu

struct E2ELaunchConfiguration: Sendable, Equatable {
    var role: E2ERole?
    var startsPeripheral = false
    var runsCentral = false
    var exitsAfterRun = false
    var resultPath: String?
    var readinessTimeout: TimeInterval = 10.0
    var scanTimeout: TimeInterval = 8.0
    var scanAttempts = 2
    var iterations = 1
    var payloadSizes: [Int] = [16, 1_024]
    var reconnectBetweenIterations = false
    var minimumPeerCount = 1

    static func parse(arguments: [String] = CommandLine.arguments) -> E2ELaunchConfiguration {
        var configuration = E2ELaunchConfiguration()
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--role":
                if let value = iterator.next() {
                    configuration.role = E2ERole(rawValue: value)
                }
            case "--start-peripheral":
                configuration.startsPeripheral = true
            case "--run-central":
                configuration.runsCentral = true
            case "--exit-after-run":
                configuration.exitsAfterRun = true
            case "--result-path":
                configuration.resultPath = iterator.next()
            case "--ready-timeout":
                if let value = iterator.next(), let timeout = TimeInterval(value) {
                    configuration.readinessTimeout = timeout
                }
            case "--scan-timeout":
                if let value = iterator.next(), let timeout = TimeInterval(value) {
                    configuration.scanTimeout = timeout
                }
            case "--scan-attempts":
                if let value = iterator.next(), let attempts = Int(value) {
                    configuration.scanAttempts = max(1, attempts)
                }
            case "--iterations":
                if let value = iterator.next(), let iterations = Int(value) {
                    configuration.iterations = max(1, iterations)
                }
            case "--payload-sizes":
                if let value = iterator.next() {
                    let sizes = value
                        .split(separator: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .filter { $0 >= 0 }
                    if !sizes.isEmpty {
                        configuration.payloadSizes = sizes
                    }
                }
            case "--reconnect-between-iterations":
                configuration.reconnectBetweenIterations = true
            case "--minimum-peer-count":
                if let value = iterator.next(), let count = Int(value) {
                    configuration.minimumPeerCount = max(1, count)
                }
            default:
                continue
            }
        }

        return configuration
    }

    var hasAutomation: Bool {
        role != nil || startsPeripheral || runsCentral || exitsAfterRun || resultPath != nil
    }
}

struct E2ERunSummary: Codable, Sendable {
    let phase: String
    let passed: Bool
    let configuration: ConfigurationSummary
    let results: [ResultSummary]
    let logs: [LogSummary]
    let diagnostics: BleuDiagnosticMetrics?

    struct ConfigurationSummary: Codable, Sendable {
        let platform: String
        let role: String
        let iterations: Int
        let payloadSizes: [Int]
        let reconnectBetweenIterations: Bool
        let minimumPeerCount: Int
        let scanTimeout: TimeInterval
        let scanAttempts: Int
        let readinessTimeout: TimeInterval
    }

    struct ResultSummary: Codable, Sendable {
        let name: String
        let status: String
        let detail: String
        let duration: TimeInterval
    }

    struct LogSummary: Codable, Sendable {
        let timestamp: Date
        let message: String
    }
}
