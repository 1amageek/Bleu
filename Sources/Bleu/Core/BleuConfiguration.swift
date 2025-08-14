import Foundation

/// Configuration for the Bleu framework
public struct BleuConfiguration: Sendable {
    
    // MARK: - Timeout Configuration
    
    /// Timeout for RPC calls
    public var rpcTimeout: TimeInterval
    
    /// Timeout for BLE connection attempts
    public var connectionTimeout: TimeInterval
    
    /// Timeout for service discovery
    public var discoveryTimeout: TimeInterval
    
    /// Timeout for reassembly of fragmented packets
    public var reassemblyTimeout: TimeInterval
    
    // MARK: - Transport Configuration
    
    /// Maximum size of a single BLE packet payload
    public var maxFragmentSize: Int
    
    /// Default write length when MTU is not negotiated
    public var defaultWriteLength: Int
    
    /// Interval for cleanup of timed-out reassembly buffers
    public var cleanupInterval: TimeInterval
    
    // MARK: - Retry Configuration
    
    /// Number of retry attempts for failed operations
    public var maxRetryAttempts: Int
    
    /// Delay between retry attempts
    public var retryDelay: TimeInterval
    
    // MARK: - Scanning Configuration
    
    /// Default timeout for scanning operations
    public var scanTimeout: TimeInterval
    
    /// Allow duplicate advertisements during scanning
    public var allowDuplicatesInScan: Bool
    
    // MARK: - Logging Configuration
    
    /// Enable verbose logging
    public var verboseLogging: Bool
    
    /// Enable performance metrics logging
    public var performanceLogging: Bool
    
    // MARK: - Initialization
    
    /// Initialize with default values
    public init(
        rpcTimeout: TimeInterval = 10.0,
        connectionTimeout: TimeInterval = 10.0,
        discoveryTimeout: TimeInterval = 5.0,
        reassemblyTimeout: TimeInterval = 30.0,
        maxFragmentSize: Int = 512,
        defaultWriteLength: Int = 512,
        cleanupInterval: TimeInterval = 10.0,
        maxRetryAttempts: Int = 3,
        retryDelay: TimeInterval = 1.0,
        scanTimeout: TimeInterval = 10.0,
        allowDuplicatesInScan: Bool = false,
        verboseLogging: Bool = false,
        performanceLogging: Bool = false
    ) {
        self.rpcTimeout = rpcTimeout
        self.connectionTimeout = connectionTimeout
        self.discoveryTimeout = discoveryTimeout
        self.reassemblyTimeout = reassemblyTimeout
        self.maxFragmentSize = maxFragmentSize
        self.defaultWriteLength = defaultWriteLength
        self.cleanupInterval = cleanupInterval
        self.maxRetryAttempts = maxRetryAttempts
        self.retryDelay = retryDelay
        self.scanTimeout = scanTimeout
        self.allowDuplicatesInScan = allowDuplicatesInScan
        self.verboseLogging = verboseLogging
        self.performanceLogging = performanceLogging
    }
    
    /// Default configuration
    public static let `default` = BleuConfiguration()
    
    /// Conservative configuration for slower/less reliable connections
    public static let conservative = BleuConfiguration(
        rpcTimeout: 30.0,
        connectionTimeout: 20.0,
        discoveryTimeout: 10.0,
        reassemblyTimeout: 60.0,
        maxFragmentSize: 256,
        defaultWriteLength: 256,
        cleanupInterval: 30.0,
        maxRetryAttempts: 5,
        retryDelay: 2.0,
        scanTimeout: 20.0
    )
    
    /// Aggressive configuration for fast/reliable connections
    public static let aggressive = BleuConfiguration(
        rpcTimeout: 5.0,
        connectionTimeout: 5.0,
        discoveryTimeout: 3.0,
        reassemblyTimeout: 15.0,
        maxFragmentSize: 1024,
        defaultWriteLength: 1024,
        cleanupInterval: 5.0,
        maxRetryAttempts: 1,
        retryDelay: 0.5,
        scanTimeout: 5.0
    )
    
    /// Debug configuration with verbose logging
    public static let debug = BleuConfiguration(
        verboseLogging: true,
        performanceLogging: true
    )
}

// MARK: - Configuration Management

/// Actor to manage global configuration
public actor BleuConfigurationManager {
    private var configuration: BleuConfiguration
    
    /// Shared instance
    public static let shared = BleuConfigurationManager()
    
    private init() {
        self.configuration = .default
    }
    
    /// Get current configuration
    public func current() -> BleuConfiguration {
        return configuration
    }
    
    /// Update configuration
    public func update(_ newConfiguration: BleuConfiguration) {
        self.configuration = newConfiguration
        BleuLogger.actorSystem.info("Configuration updated")
    }
    
    /// Update specific configuration values
    public func update(_ block: @Sendable (inout BleuConfiguration) -> Void) {
        block(&configuration)
        BleuLogger.actorSystem.info("Configuration updated")
    }
    
    /// Reset to default configuration
    public func reset() {
        self.configuration = .default
        BleuLogger.actorSystem.info("Configuration reset to default")
    }
}