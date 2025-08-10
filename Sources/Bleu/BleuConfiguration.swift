import Foundation
import CoreBluetooth

// MARK: - Production Configuration Management

/// Environment types for different deployment scenarios
public enum Environment: String, Sendable, Codable, CaseIterable {
    case development = "development"
    case staging = "staging"
    case production = "production"
    
    public var description: String {
        return rawValue.capitalized
    }
}

/// Global configuration for Bleu framework
public struct BleuConfiguration: Sendable, Codable {
    
    // MARK: - Environment Settings
    public let environment: Environment
    public let enableDebugLogging: Bool
    public let enablePerformanceMonitoring: Bool
    public let enableMetricsCollection: Bool
    
    // MARK: - Network and Communication
    public let connectionTimeoutSeconds: TimeInterval
    public let maxConcurrentConnections: Int
    public let defaultScanTimeout: TimeInterval
    public let enableHeartbeat: Bool
    public let heartbeatInterval: TimeInterval
    
    // MARK: - Security Settings
    public let securityConfiguration: SecurityConfiguration
    public let enableEncryptionByDefault: Bool
    public let requireDeviceAuthentication: Bool
    public let certificateValidationEnabled: Bool
    
    // MARK: - Performance Settings
    public let bufferConfiguration: BufferConfiguration
    public let flowControlConfiguration: FlowControlConfiguration
    public let enableDataCompression: Bool
    public let compressionThreshold: Int
    
    // MARK: - Retry and Recovery
    public let reconnectionPolicy: ReconnectionPolicy
    public let maxRetryAttempts: Int
    public let enableAutomaticRecovery: Bool
    public let errorRecoveryDelay: TimeInterval
    
    // MARK: - Resource Management
    public let maxMemoryUsageMB: Int
    public let resourceCleanupInterval: TimeInterval
    public let enableResourceMonitoring: Bool
    
    // MARK: - Feature Flags
    public let featureFlags: [String: Bool]
    
    public init(
        environment: Environment = .development,
        enableDebugLogging: Bool? = nil,
        enablePerformanceMonitoring: Bool = true,
        enableMetricsCollection: Bool = true,
        connectionTimeoutSeconds: TimeInterval = 30.0,
        maxConcurrentConnections: Int = 10,
        defaultScanTimeout: TimeInterval = 10.0,
        enableHeartbeat: Bool = true,
        heartbeatInterval: TimeInterval = 30.0,
        securityConfiguration: SecurityConfiguration? = nil,
        enableEncryptionByDefault: Bool? = nil,
        requireDeviceAuthentication: Bool? = nil,
        certificateValidationEnabled: Bool? = nil,
        bufferConfiguration: BufferConfiguration? = nil,
        flowControlConfiguration: FlowControlConfiguration? = nil,
        enableDataCompression: Bool = true,
        compressionThreshold: Int = 512,
        reconnectionPolicy: ReconnectionPolicy? = nil,
        maxRetryAttempts: Int = 3,
        enableAutomaticRecovery: Bool = true,
        errorRecoveryDelay: TimeInterval = 5.0,
        maxMemoryUsageMB: Int = 100,
        resourceCleanupInterval: TimeInterval = 300.0,
        enableResourceMonitoring: Bool = true,
        featureFlags: [String: Bool] = [:]
    ) {
        self.environment = environment
        
        // Environment-specific defaults
        switch environment {
        case .development:
            self.enableDebugLogging = enableDebugLogging ?? true
            self.securityConfiguration = securityConfiguration ?? .development
            self.enableEncryptionByDefault = enableEncryptionByDefault ?? false
            self.requireDeviceAuthentication = requireDeviceAuthentication ?? false
            self.certificateValidationEnabled = certificateValidationEnabled ?? false
            self.bufferConfiguration = bufferConfiguration ?? .lowMemory
            self.flowControlConfiguration = flowControlConfiguration ?? .conservative
            self.reconnectionPolicy = reconnectionPolicy ?? .conservative
            
        case .staging:
            self.enableDebugLogging = enableDebugLogging ?? true
            self.securityConfiguration = securityConfiguration ?? .secure
            self.enableEncryptionByDefault = enableEncryptionByDefault ?? true
            self.requireDeviceAuthentication = requireDeviceAuthentication ?? true
            self.certificateValidationEnabled = certificateValidationEnabled ?? true
            self.bufferConfiguration = bufferConfiguration ?? BufferConfiguration()
            self.flowControlConfiguration = flowControlConfiguration ?? FlowControlConfiguration()
            self.reconnectionPolicy = reconnectionPolicy ?? ReconnectionPolicy()
            
        case .production:
            self.enableDebugLogging = enableDebugLogging ?? false
            self.securityConfiguration = securityConfiguration ?? .secure
            self.enableEncryptionByDefault = enableEncryptionByDefault ?? true
            self.requireDeviceAuthentication = requireDeviceAuthentication ?? true
            self.certificateValidationEnabled = certificateValidationEnabled ?? true
            self.bufferConfiguration = bufferConfiguration ?? .highPerformance
            self.flowControlConfiguration = flowControlConfiguration ?? .aggressive
            self.reconnectionPolicy = reconnectionPolicy ?? .aggressive
        }
        
        self.enablePerformanceMonitoring = enablePerformanceMonitoring
        self.enableMetricsCollection = enableMetricsCollection
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.maxConcurrentConnections = maxConcurrentConnections
        self.defaultScanTimeout = defaultScanTimeout
        self.enableHeartbeat = enableHeartbeat
        self.heartbeatInterval = heartbeatInterval
        self.enableDataCompression = enableDataCompression
        self.compressionThreshold = compressionThreshold
        self.maxRetryAttempts = maxRetryAttempts
        self.enableAutomaticRecovery = enableAutomaticRecovery
        self.errorRecoveryDelay = errorRecoveryDelay
        self.maxMemoryUsageMB = maxMemoryUsageMB
        self.resourceCleanupInterval = resourceCleanupInterval
        self.enableResourceMonitoring = enableResourceMonitoring
        self.featureFlags = featureFlags
    }
    
    // MARK: - Preset Configurations
    
    /// Development configuration - optimized for debugging and development
    public static let development = BleuConfiguration(
        environment: .development,
        enableDebugLogging: true,
        maxConcurrentConnections: 3,
        enableEncryptionByDefault: false,
        maxMemoryUsageMB: 50,
        featureFlags: [
            "enableVerboseLogging": true,
            "enableMockMode": true,
            "skipCertificateValidation": true
        ]
    )
    
    /// Staging configuration - balanced for testing
    public static let staging = BleuConfiguration(
        environment: .staging,
        enableDebugLogging: true,
        maxConcurrentConnections: 8,
        enableEncryptionByDefault: true,
        maxMemoryUsageMB: 75,
        featureFlags: [
            "enableTestMetrics": true,
            "enablePerformanceTesting": true
        ]
    )
    
    /// Production configuration - optimized for performance and security
    public static let production = BleuConfiguration(
        environment: .production,
        enableDebugLogging: false,
        maxConcurrentConnections: 20,
        enableEncryptionByDefault: true,
        maxMemoryUsageMB: 150,
        featureFlags: [
            "enableTelemetry": true,
            "enableCrashReporting": true
        ]
    )
}

/// Configuration manager for runtime configuration management
public actor BleuConfigurationManager {
    public static let shared = BleuConfigurationManager()
    
    private var currentConfiguration: BleuConfiguration
    private var configurationObservers: [UUID: (BleuConfiguration) -> Void] = [:]
    
    // Configuration sources
    private let userDefaults = UserDefaults.standard
    private let configFileManager = ConfigFileManager()
    
    private init() {
        // Load configuration with fallback chain:
        // 1. Environment variables
        // 2. User defaults
        // 3. Configuration file
        // 4. Default configuration
        
        if let envConfig = Self.loadFromEnvironment() {
            self.currentConfiguration = envConfig
        } else if let userDefaultsConfig = loadFromUserDefaults() {
            self.currentConfiguration = userDefaultsConfig
        } else if let fileConfig = configFileManager.loadConfiguration() {
            self.currentConfiguration = fileConfig
        } else {
            #if DEBUG
            self.currentConfiguration = .development
            #else
            self.currentConfiguration = .production
            #endif
        }
        
        // Apply configuration immediately
        applyConfiguration(currentConfiguration)
    }
    
    // MARK: - Configuration Management
    
    /// Current configuration
    public var configuration: BleuConfiguration {
        return currentConfiguration
    }
    
    /// Update configuration
    public func update(_ configuration: BleuConfiguration) {
        let previousConfig = currentConfiguration
        currentConfiguration = configuration
        
        // Apply the new configuration
        applyConfiguration(configuration)
        
        // Save to persistent storage
        saveToUserDefaults(configuration)
        configFileManager.saveConfiguration(configuration)
        
        // Notify observers
        notifyConfigurationChange(configuration)
        
        Task {
            await BleuLogger.shared.info(
                "Configuration updated from \(previousConfig.environment) to \(configuration.environment)",
                category: .general,
                metadata: [
                    "previous_env": previousConfig.environment.rawValue,
                    "new_env": configuration.environment.rawValue
                ]
            )
        }
    }
    
    /// Update specific configuration values
    public func update(values updates: [String: Any]) {
        var config = currentConfiguration
        
        // Apply updates (simplified implementation - in production, use proper reflection or codable updates)
        if let newTimeout = updates["connectionTimeoutSeconds"] as? TimeInterval {
            config = BleuConfiguration(
                environment: config.environment,
                connectionTimeoutSeconds: newTimeout,
                maxConcurrentConnections: config.maxConcurrentConnections,
                // ... other parameters
                featureFlags: config.featureFlags
            )
        }
        
        update(config)
    }
    
    /// Enable/disable feature flag
    public func configure(flag: String, enabled: Bool) {
        var newFlags = currentConfiguration.featureFlags
        newFlags[flag] = enabled
        
        let newConfig = BleuConfiguration(
            environment: currentConfiguration.environment,
            featureFlags: newFlags
        )
        
        update(newConfig)
    }
    
    /// Check if feature flag is enabled
    public func isEnabled(flag: String) -> Bool {
        return currentConfiguration.featureFlags[flag] ?? false
    }
    
    // MARK: - Configuration Observers
    
    /// Add configuration change observer
    @discardableResult
    public func addConfigurationObserver(
        _ observer: @escaping (BleuConfiguration) -> Void
    ) -> UUID {
        let id = UUID()
        configurationObservers[id] = observer
        
        // Call immediately with current configuration
        observer(currentConfiguration)
        
        return id
    }
    
    /// Remove configuration observer
    public func removeConfigurationObserver(_ id: UUID) {
        configurationObservers.removeValue(forKey: id)
    }
    
    // MARK: - Configuration Validation
    
    /// Validate configuration for consistency
    public func validateConfiguration(_ configuration: BleuConfiguration) throws {
        // Validate timeouts
        if configuration.connectionTimeoutSeconds <= 0 {
            throw BleuError.invalidRequest
        }
        
        if configuration.defaultScanTimeout <= 0 {
            throw BleuError.invalidRequest
        }
        
        // Validate resource limits
        if configuration.maxConcurrentConnections <= 0 {
            throw BleuError.invalidRequest
        }
        
        if configuration.maxMemoryUsageMB <= 0 {
            throw BleuError.invalidRequest
        }
        
        // Validate security settings for production
        if configuration.environment == .production {
            if !configuration.enableEncryptionByDefault {
                throw BleuError.securityViolation("Encryption must be enabled in production")
            }
            
            if !configuration.requireDeviceAuthentication {
                throw BleuError.securityViolation("Device authentication must be required in production")
            }
        }
        
        // Validate performance settings
        if configuration.bufferConfiguration.bufferSize <= 0 {
            throw BleuError.invalidRequest
        }
        
        if configuration.flowControlConfiguration.windowSize <= 0 {
            throw BleuError.invalidRequest
        }
    }
    
    // MARK: - Environment Detection
    
    /// Auto-detect environment based on various factors
    public static func detectEnvironment() -> Environment {
        // Check for explicit environment variable
        if let envVar = ProcessInfo.processInfo.environment["BLEU_ENVIRONMENT"] {
            return Environment(rawValue: envVar.lowercased()) ?? .development
        }
        
        // Check bundle identifier patterns
        if let bundleId = Bundle.main.bundleIdentifier {
            if bundleId.contains(".dev") || bundleId.contains(".debug") {
                return .development
            } else if bundleId.contains(".staging") || bundleId.contains(".beta") {
                return .staging
            }
        }
        
        // Check for debug build
        #if DEBUG
        return .development
        #else
        // Check for TestFlight
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .staging
        }
        
        return .production
        #endif
    }
    
    // MARK: - Configuration Loading/Saving
    
    private static func loadFromEnvironment() -> BleuConfiguration? {
        let env = ProcessInfo.processInfo.environment
        
        guard let environmentString = env["BLEU_ENVIRONMENT"],
              let environment = Environment(rawValue: environmentString) else {
            return nil
        }
        
        return BleuConfiguration(
            environment: environment,
            enableDebugLogging: env["BLEU_DEBUG_LOGGING"]?.lowercased() == "true",
            connectionTimeoutSeconds: TimeInterval(env["BLEU_CONNECTION_TIMEOUT"] ?? "") ?? 30.0,
            maxConcurrentConnections: Int(env["BLEU_MAX_CONNECTIONS"] ?? "") ?? 10,
            enableEncryptionByDefault: env["BLEU_ENCRYPTION_DEFAULT"]?.lowercased() == "true"
        )
    }
    
    private func loadFromUserDefaults() -> BleuConfiguration? {
        guard let data = userDefaults.data(forKey: "BleuConfiguration") else { return nil }
        return try? JSONDecoder().decode(BleuConfiguration.self, from: data)
    }
    
    private func saveToUserDefaults(_ configuration: BleuConfiguration) {
        if let data = try? JSONEncoder().encode(configuration) {
            userDefaults.set(data, forKey: "BleuConfiguration")
        }
    }
    
    // MARK: - Configuration Application
    
    private func applyConfiguration(_ configuration: BleuConfiguration) {
        Task {
            // Apply logging configuration
            await BleuLogger.shared.configure(enabled: true) // Always enabled, but level controlled
            await BleuLogger.shared.configure(minimumLevel:
                configuration.enableDebugLogging ? .debug : .info
            )
            
            // Apply security configuration
            await BleuSecurityManager.shared.configure(with:
                configuration.securityConfiguration
            )
            
            // Apply data optimization configuration
            await BleuDataOptimizer.shared.configure(with:
                configuration.bufferConfiguration
            )
            
            // Apply performance monitoring
            if configuration.enablePerformanceMonitoring {
                await BleuPerformanceMonitor.shared.setMaxMetricsCount(10000)
            }
            
            // Apply feature flags
            for (flag, enabled) in configuration.featureFlags {
                await applyFeatureFlag(flag, enabled: enabled)
            }
            
            await BleuLogger.shared.info(
                "Configuration applied for \(configuration.environment) environment",
                category: .general,
                metadata: [
                    "debug_logging": "\(configuration.enableDebugLogging)",
                    "encryption_default": "\(configuration.enableEncryptionByDefault)",
                    "max_connections": "\(configuration.maxConcurrentConnections)"
                ]
            )
        }
    }
    
    private func applyFeatureFlag(_ flag: String, enabled: Bool) async {
        switch flag {
        case "enableVerboseLogging":
            if enabled {
                await BleuLogger.shared.configure(minimumLevel: .debug)
                await BleuLogger.shared.configure(categoryFilter: Set(LogCategory.allCases))
            }
            
        case "enableMockMode":
            // This would enable mock implementations for testing
            break
            
        case "skipCertificateValidation":
            // This would disable certificate validation (development only)
            break
            
        case "enableTelemetry":
            // This would enable telemetry data collection
            break
            
        case "enableCrashReporting":
            // This would enable crash reporting
            break
            
        default:
            await BleuLogger.shared.debug("Unknown feature flag: \(flag)", category: .general)
        }
    }
    
    private func notifyConfigurationChange(_ configuration: BleuConfiguration) {
        for observer in configurationObservers.values {
            observer(configuration)
        }
    }
}

/// Configuration file manager for persistent storage
private class ConfigFileManager {
    private let configFileName = "bleu-config.json"
    
    private var configFileURL: URL? {
        let fileManager = FileManager.default
        
        // Try Documents directory first
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let configURL = documentsURL.appendingPathComponent(configFileName)
            if fileManager.fileExists(atPath: configURL.path) {
                return configURL
            }
        }
        
        // Try bundle resource
        return Bundle.main.url(forResource: "bleu-config", withExtension: "json")
    }
    
    func loadConfiguration() -> BleuConfiguration? {
        guard let configURL = configFileURL else { return nil }
        
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(BleuConfiguration.self, from: data)
        } catch {
            print("Failed to load configuration from file: \(error)")
            return nil
        }
    }
    
    func saveConfiguration(_ configuration: BleuConfiguration) {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let configURL = documentsURL.appendingPathComponent(configFileName)
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(configuration)
            try data.write(to: configURL)
        } catch {
            print("Failed to save configuration to file: \(error)")
        }
    }
}

// MARK: - Runtime Configuration Updates

/// Configuration update notifications
public struct ConfigurationUpdateNotification {
    public let previousConfiguration: BleuConfiguration
    public let newConfiguration: BleuConfiguration
    public let changedKeys: Set<String>
    public let timestamp: Date
    
    public init(
        previous: BleuConfiguration,
        new: BleuConfiguration,
        changedKeys: Set<String>
    ) {
        self.previousConfiguration = previous
        self.newConfiguration = new
        self.changedKeys = changedKeys
        self.timestamp = Date()
    }
}

/// Hot configuration reloading support
public actor HotConfigurationReloader {
    private let configurationManager: BleuConfigurationManager
    private var reloadTimer: Timer?
    private let reloadInterval: TimeInterval = 60.0 // Check every minute
    
    public init(configurationManager: BleuConfigurationManager = .shared) {
        self.configurationManager = configurationManager
    }
    
    public func enableAutoReload() {
        disableAutoReload()
        
        reloadTimer = Timer.scheduledTimer(withTimeInterval: reloadInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.checkForConfigurationUpdates()
            }
        }
        
        Task {
            await BleuLogger.shared.info(
                "Hot configuration reloading started (interval: \(reloadInterval)s)",
                category: .general
            )
        }
    }
    
    public func disableAutoReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
    }
    
    private func checkForConfigurationUpdates() async {
        // In a real implementation, this would check:
        // - Remote configuration service
        // - Configuration file modification time
        // - Environment variable changes
        
        // For now, just check environment variables
        if let envConfig = BleuConfigurationManager.loadFromEnvironment() {
            let currentConfig = await configurationManager.configuration
            
            if !areConfigurationsEqual(envConfig, currentConfig) {
                await configurationManager.update(envConfig)
                
                await BleuLogger.shared.info(
                    "Configuration hot-reloaded from environment",
                    category: .general
                )
            }
        }
    }
    
    private func areConfigurationsEqual(_ config1: BleuConfiguration, _ config2: BleuConfiguration) -> Bool {
        // Simple comparison - in production, implement proper equality checking
        return config1.environment == config2.environment &&
               config1.enableDebugLogging == config2.enableDebugLogging &&
               config1.enableEncryptionByDefault == config2.enableEncryptionByDefault
    }
}

// MARK: - Configuration Extensions

extension BleuConfiguration {
    /// Get configuration as dictionary for debugging
    public var debugDescription: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        return "BleuConfiguration(environment: \(environment))"
    }
    
    /// Check if running in development mode
    public var isDevelopment: Bool {
        return environment == .development
    }
    
    /// Check if running in production mode
    public var isProduction: Bool {
        return environment == .production
    }
}

// MARK: - Global Configuration Access

/// Global access to current configuration
public func BleuConfig() async -> BleuConfiguration {
    return await BleuConfigurationManager.shared.configuration
}

/// Check if feature flag is enabled
public func isFeatureEnabled(_ flag: String) async -> Bool {
    return await BleuConfigurationManager.shared.isEnabled(flag: flag)
}