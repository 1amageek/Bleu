import Foundation

/// Configuration for the Bleu framework.
public struct BleuConfiguration: Sendable {
    public var rpcTimeout: TimeInterval
    public var connectionTimeout: TimeInterval
    public var reassemblyTimeout: TimeInterval
    public var cleanupInterval: TimeInterval
    public var maxConcurrentIncomingRPCs: Int
    public var incomingRPCQueueCapacity: Int
    public var allowDuplicatesInScan: Bool

    public init(
        rpcTimeout: TimeInterval = 10.0,
        connectionTimeout: TimeInterval = 10.0,
        reassemblyTimeout: TimeInterval = 30.0,
        cleanupInterval: TimeInterval = 10.0,
        maxConcurrentIncomingRPCs: Int = 4,
        incomingRPCQueueCapacity: Int = 64,
        allowDuplicatesInScan: Bool = false
    ) {
        self.rpcTimeout = rpcTimeout
        self.connectionTimeout = connectionTimeout
        self.reassemblyTimeout = reassemblyTimeout
        self.cleanupInterval = cleanupInterval
        self.maxConcurrentIncomingRPCs = max(1, maxConcurrentIncomingRPCs)
        self.incomingRPCQueueCapacity = max(1, incomingRPCQueueCapacity)
        self.allowDuplicatesInScan = allowDuplicatesInScan
    }

    public static let `default` = BleuConfiguration()

    public static let conservative = BleuConfiguration(
        rpcTimeout: 30.0,
        connectionTimeout: 20.0,
        reassemblyTimeout: 60.0,
        cleanupInterval: 30.0,
        maxConcurrentIncomingRPCs: 2,
        incomingRPCQueueCapacity: 128
    )

    public static let aggressive = BleuConfiguration(
        rpcTimeout: 5.0,
        connectionTimeout: 5.0,
        reassemblyTimeout: 15.0,
        cleanupInterval: 5.0,
        maxConcurrentIncomingRPCs: 8,
        incomingRPCQueueCapacity: 32
    )
}

/// Actor to manage global configuration.
public actor BleuConfigurationManager {
    private var configuration: BleuConfiguration

    public static let shared = BleuConfigurationManager()

    private init() {
        self.configuration = .default
    }

    public func current() -> BleuConfiguration {
        configuration
    }

    public func update(_ newConfiguration: BleuConfiguration) {
        self.configuration = newConfiguration
        BleuLogger.actorSystem.info("Configuration updated")
    }

    public func update(_ block: @Sendable (inout BleuConfiguration) -> Void) {
        block(&configuration)
        BleuLogger.actorSystem.info("Configuration updated")
    }

    public func reset() {
        self.configuration = .default
        BleuLogger.actorSystem.info("Configuration reset to default")
    }
}
