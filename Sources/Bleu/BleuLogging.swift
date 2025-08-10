import Foundation
import os.log
import CoreBluetooth

// MARK: - Logging and Monitoring System

/// Log levels for Bleu framework
public enum LogLevel: Int, Sendable, Codable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case critical = 4
    
    public var description: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        case .critical:
            return "CRITICAL"
        }
    }
    
    public var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        case .critical:
            return .fault
        }
    }
}

/// Log categories for better organization
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case connection = "Connection"
    case communication = "Communication"
    case security = "Security"
    case performance = "Performance"
    case actorSystem = "ActorSystem"
    case flowControl = "FlowControl"
    case general = "General"
    
    public var subsystem: String {
        return "com.bleu.framework"
    }
}

/// Structured log entry
public struct LogEntry: Sendable, Codable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let file: String
    public let function: String
    public let line: Int
    public let deviceId: String?
    public let metadata: [String: String]
    
    public init(
        level: LogLevel,
        category: LogCategory,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.timestamp = Date()
        self.level = level
        self.category = category
        self.message = message
        self.file = String(file.split(separator: "/").last ?? "")
        self.function = function
        self.line = line
        self.deviceId = deviceId
        self.metadata = metadata
    }
    
    /// Formatted log message
    public var formattedMessage: String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var msg = "[\(dateFormatter.string(from: timestamp))] "
        msg += "[\(level.description)] "
        msg += "[\(category.rawValue)] "
        
        if let deviceId = deviceId {
            msg += "[Device: \(deviceId)] "
        }
        
        msg += message
        
        if !metadata.isEmpty {
            let metadataStr = metadata.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            msg += " {\(metadataStr)}"
        }
        
        msg += " (\(file):\(line) in \(function))"
        
        return msg
    }
}

/// Log destination protocol
public protocol LogDestination: Sendable {
    func write(_ entry: LogEntry) async
    func flush() async
}

/// Console log destination
public struct ConsoleLogDestination: LogDestination {
    public init() {}
    
    public func write(_ entry: LogEntry) async {
        print(entry.formattedMessage)
    }
    
    public func flush() async {
        // Console doesn't need flushing
    }
}

/// OS Log destination (using unified logging)
public struct OSLogDestination: LogDestination {
    private let log: OSLog
    
    public init(category: LogCategory) {
        self.log = OSLog(subsystem: category.subsystem, category: category.rawValue)
    }
    
    public func write(_ entry: LogEntry) async {
        os_log("%{public}@", log: log, type: entry.level.osLogType, entry.formattedMessage)
    }
    
    public func flush() async {
        // OS Log handles flushing automatically
    }
}

/// File log destination
public actor FileLogDestination: LogDestination {
    private let fileURL: URL
    private let maxFileSize: Int
    private let maxBackupFiles: Int
    private var currentFileSize: Int = 0
    
    public init(
        fileURL: URL,
        maxFileSize: Int = 10 * 1024 * 1024, // 10MB
        maxBackupFiles: Int = 5
    ) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
        self.maxBackupFiles = maxBackupFiles
        
        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Get current file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            currentFileSize = attributes[.size] as? Int ?? 0
        }
    }
    
    public func write(_ entry: LogEntry) async {
        let logLine = entry.formattedMessage + "\n"
        guard let data = logLine.data(using: .utf8) else { return }
        
        // Check if rotation is needed
        if currentFileSize + data.count > maxFileSize {
            await rotateLogFile()
        }
        
        // Write to file
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.append(to: fileURL)
        } else {
            try? data.write(to: fileURL)
        }
        
        currentFileSize += data.count
    }
    
    public func flush() async {
        // File system handles flushing
    }
    
    private func rotateLogFile() async {
        let fileManager = FileManager.default
        let basePath = fileURL.deletingPathExtension().path
        let pathExtension = fileURL.pathExtension
        
        // Remove oldest backup
        let oldestBackup = "\(basePath).\(maxBackupFiles).\(pathExtension)"
        try? fileManager.removeItem(atPath: oldestBackup)
        
        // Rotate existing backups
        for i in (1..<maxBackupFiles).reversed() {
            let oldPath = "\(basePath).\(i).\(pathExtension)"
            let newPath = "\(basePath).\(i + 1).\(pathExtension)"
            if fileManager.fileExists(atPath: oldPath) {
                try? fileManager.moveItem(atPath: oldPath, toPath: newPath)
            }
        }
        
        // Move current file to backup
        let backupPath = "\(basePath).1.\(pathExtension)"
        try? fileManager.moveItem(atPath: fileURL.path, toPath: backupPath)
        
        currentFileSize = 0
    }
}

/// Remote log destination (for centralized logging)
public actor RemoteLogDestination: LogDestination {
    private let endpoint: URL
    private let batchSize: Int
    private let flushInterval: TimeInterval
    private var buffer: [LogEntry] = []
    private var lastFlush: Date = Date()
    
    public init(
        endpoint: URL,
        batchSize: Int = 100,
        flushInterval: TimeInterval = 30.0
    ) {
        self.endpoint = endpoint
        self.batchSize = batchSize
        self.flushInterval = flushInterval
        
        // Start periodic flush
        Task {
            while true {
                try? await Task.sleep(nanoseconds: UInt64(flushInterval * 1_000_000_000))
                await flush()
            }
        }
    }
    
    public func write(_ entry: LogEntry) async {
        buffer.append(entry)
        
        if buffer.count >= batchSize {
            await flush()
        }
    }
    
    public func flush() async {
        guard !buffer.isEmpty else { return }
        
        let entries = buffer
        buffer.removeAll()
        
        // Send logs to remote endpoint
        do {
            let data = try JSONEncoder().encode(entries)
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            _ = try await URLSession.shared.data(for: request)
            lastFlush = Date()
        } catch {
            // Re-add entries to buffer on failure
            buffer.insert(contentsOf: entries, at: 0)
        }
    }
}

/// Main logging manager
public actor BleuLogger {
    public static let shared = BleuLogger()
    
    private var destinations: [LogDestination] = []
    private var minimumLevel: LogLevel = .info
    private var isEnabled: Bool = true
    
    // Performance metrics
    private var logCounts: [LogLevel: Int] = [:]
    private var categoryFilters: Set<LogCategory> = []
    
    private init() {
        // Initialize with console destination by default
        destinations = [ConsoleLogDestination()]
        
        // Initialize log counts
        for level in LogLevel.allCases {
            logCounts[level] = 0
        }
    }
    
    // MARK: - Configuration
    
    public func configure(minimumLevel level: LogLevel) {
        minimumLevel = level
    }
    
    public func configure(enabled: Bool) {
        isEnabled = enabled
    }
    
    public func addDestination(_ destination: LogDestination) {
        destinations.append(destination)
    }
    
    public func removeAllDestinations() {
        destinations.removeAll()
    }
    
    public func configure(categoryFilter categories: Set<LogCategory>) {
        categoryFilters = categories
    }
    
    public func addCategoryFilter(_ category: LogCategory) {
        categoryFilters.insert(category)
    }
    
    public func removeCategoryFilter(_ category: LogCategory) {
        categoryFilters.remove(category)
    }
    
    // MARK: - Logging Methods
    
    public func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        guard isEnabled else { return }
        guard level.rawValue >= minimumLevel.rawValue else { return }
        guard categoryFilters.isEmpty || categoryFilters.contains(category) else { return }
        
        let entry = LogEntry(
            level: level,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
        
        logCounts[level, default: 0] += 1
        
        Task {
            for destination in destinations {
                await destination.write(entry)
            }
        }
    }
    
    // Convenience methods
    public func debug(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        log(
            level: .debug,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
    }
    
    public func info(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        log(
            level: .info,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
    }
    
    public func warning(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        log(
            level: .warning,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
    }
    
    public func error(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        log(
            level: .error,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
    }
    
    public func critical(
        _ message: String,
        category: LogCategory = .general,
        file: String = #file,
        function: String = #function,
        line: Int = #line,
        deviceId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        log(
            level: .critical,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line,
            deviceId: deviceId,
            metadata: metadata
        )
    }
    
    // MARK: - Metrics and Statistics
    
    public var logStatistics: LogStatistics {
        return LogStatistics(
            totalLogs: logCounts.values.reduce(0, +),
            logsByLevel: logCounts,
            minimumLevel: minimumLevel,
            isEnabled: isEnabled,
            activeCategories: categoryFilters
        )
    }
    
    public func flush() async {
        for destination in destinations {
            await destination.flush()
        }
    }
}

/// Log statistics
public struct LogStatistics: Sendable, Codable {
    public let totalLogs: Int
    public let logsByLevel: [LogLevel: Int]
    public let minimumLevel: LogLevel
    public let isEnabled: Bool
    public let activeCategories: Set<LogCategory>
    
    public init(
        totalLogs: Int,
        logsByLevel: [LogLevel: Int],
        minimumLevel: LogLevel,
        isEnabled: Bool,
        activeCategories: Set<LogCategory>
    ) {
        self.totalLogs = totalLogs
        self.logsByLevel = logsByLevel
        self.minimumLevel = minimumLevel
        self.isEnabled = isEnabled
        self.activeCategories = activeCategories
    }
}

// MARK: - Performance Monitoring

/// Performance metrics for monitoring
public struct PerformanceMetrics: Sendable, Codable {
    public let operationName: String
    public let duration: TimeInterval
    public let timestamp: Date
    public let deviceId: String?
    public let success: Bool
    public let metadata: [String: String]
    
    public init(
        operationName: String,
        duration: TimeInterval,
        deviceId: String? = nil,
        success: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.operationName = operationName
        self.duration = duration
        self.timestamp = Date()
        self.deviceId = deviceId
        self.success = success
        self.metadata = metadata
    }
}

/// Performance monitor
public actor BleuPerformanceMonitor {
    public static let shared = BleuPerformanceMonitor()
    
    private var metrics: [PerformanceMetrics] = []
    private var maxMetricsCount: Int = 1000
    
    private init() {}
    
    // MARK: - Metrics Collection
    
    public func recordMetric(_ metric: PerformanceMetrics) {
        metrics.append(metric)
        
        // Keep only recent metrics
        if metrics.count > maxMetricsCount {
            metrics.removeFirst(metrics.count - maxMetricsCount)
        }
        
        // Log slow operations
        if metric.duration > 5.0 {
            Task {
                await BleuLogger.shared.warning(
                    "Slow operation detected: \(metric.operationName) took \(String(format: "%.3f", metric.duration))s",
                    category: .performance,
                    deviceId: metric.deviceId,
                    metadata: metric.metadata
                )
            }
        }
    }
    
    public func measureOperation<T>(
        name: String,
        deviceId: String? = nil,
        metadata: [String: String] = [:],
        operation: () async throws -> T
    ) async rethrows -> T {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        do {
            let result = try await operation()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            
            recordMetric(PerformanceMetrics(
                operationName: name,
                duration: duration,
                deviceId: deviceId,
                success: true,
                metadata: metadata
            ))
            
            return result
        } catch {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            
            recordMetric(PerformanceMetrics(
                operationName: name,
                duration: duration,
                deviceId: deviceId,
                success: false,
                metadata: metadata.merging(["error": String(describing: error)]) { _, new in new }
            ))
            
            throw error
        }
    }
    
    // MARK: - Statistics
    
    public var performanceStatistics: PerformanceStatistics {
        let operationStats = Dictionary(grouping: metrics, by: \.operationName)
            .mapValues { metrics in
                let durations = metrics.map(\.duration)
                let successRate = Double(metrics.filter(\.success).count) / Double(metrics.count)
                
                return OperationStatistics(
                    count: metrics.count,
                    averageDuration: durations.reduce(0, +) / Double(durations.count),
                    minDuration: durations.min() ?? 0,
                    maxDuration: durations.max() ?? 0,
                    successRate: successRate
                )
            }
        
        return PerformanceStatistics(
            totalOperations: metrics.count,
            operationStatistics: operationStats,
            timeRange: TimeRange(
                start: metrics.first?.timestamp ?? Date(),
                end: metrics.last?.timestamp ?? Date()
            )
        )
    }
    
    public func clearMetrics() {
        metrics.removeAll()
    }
    
    public func configure(maxMetricsCount count: Int) {
        maxMetricsCount = count
    }
}

/// Operation statistics
public struct OperationStatistics: Sendable, Codable {
    public let count: Int
    public let averageDuration: TimeInterval
    public let minDuration: TimeInterval
    public let maxDuration: TimeInterval
    public let successRate: Double
    
    public init(
        count: Int,
        averageDuration: TimeInterval,
        minDuration: TimeInterval,
        maxDuration: TimeInterval,
        successRate: Double
    ) {
        self.count = count
        self.averageDuration = averageDuration
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.successRate = successRate
    }
}

/// Performance statistics
public struct PerformanceStatistics: Sendable, Codable {
    public let totalOperations: Int
    public let operationStatistics: [String: OperationStatistics]
    public let timeRange: TimeRange
    
    public init(
        totalOperations: Int,
        operationStatistics: [String: OperationStatistics],
        timeRange: TimeRange
    ) {
        self.totalOperations = totalOperations
        self.operationStatistics = operationStatistics
        self.timeRange = timeRange
    }
}

/// Time range
public struct TimeRange: Sendable, Codable {
    public let start: Date
    public let end: Date
    
    public var duration: TimeInterval {
        return end.timeIntervalSince(start)
    }
    
    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

// MARK: - Extensions

extension Data {
    func append(to url: URL) throws {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        } else {
            try write(to: url)
        }
    }
}

// MARK: - Debug Utilities

#if DEBUG
/// Debug tools for development
public enum BleuDebugTools {
    
    /// Enable verbose logging for development
    public static func enableVerboseLogging() async {
        await BleuLogger.shared.configure(minimumLevel: .debug)
        await BleuLogger.shared.setCategoryFilter(Set(LogCategory.allCases))
        await BleuLogger.shared.info("Verbose logging enabled", category: .general)
    }
    
    /// Setup file logging for debugging
    public static func setupFileLogging(to directory: URL) async {
        let logFileURL = directory.appendingPathComponent("bleu-debug.log")
        let fileDestination = await FileLogDestination(fileURL: logFileURL)
        await BleuLogger.shared.addDestination(fileDestination)
        await BleuLogger.shared.info("File logging enabled: \(logFileURL.path)", category: .general)
    }
    
    /// Print current statistics
    public static func printStatistics() async {
        let logStats = await BleuLogger.shared.getLogStatistics()
        let perfStats = await BleuPerformanceMonitor.shared.getPerformanceStatistics()
        
        print("=== Bleu Debug Statistics ===")
        print("Logs: \(logStats.totalLogs) total")
        print("Performance: \(perfStats.totalOperations) operations tracked")
        
        for (operation, stats) in perfStats.operationStatistics {
            print("  \(operation): avg \(String(format: "%.3f", stats.averageDuration))s (\(stats.count) calls, \(String(format: "%.1f", stats.successRate * 100))% success)")
        }
        print("=============================")
    }
}
#endif