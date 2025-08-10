import Foundation
import Compression
import CoreBluetooth

// MARK: - Performance Optimization and Data Compression

/// Compression algorithm options
public enum CompressionAlgorithm: Sendable, Codable, CaseIterable {
    case none
    case lz4
    case lzfse
    case zlib
    case lzma
    
    public var algorithm: compression_algorithm {
        switch self {
        case .none:
            return COMPRESSION_LZFSE // Fallback, won't be used
        case .lz4:
            return COMPRESSION_LZ4
        case .lzfse:
            return COMPRESSION_LZFSE
        case .zlib:
            return COMPRESSION_ZLIB
        case .lzma:
            return COMPRESSION_LZMA
        }
    }
    
    public var description: String {
        switch self {
        case .none:
            return "None"
        case .lz4:
            return "LZ4 (Fast)"
        case .lzfse:
            return "LZFSE (Balanced)"
        case .zlib:
            return "ZLIB (Compatible)"
        case .lzma:
            return "LZMA (High Compression)"
        }
    }
    
    /// Recommended algorithm based on data size
    public static func recommended(for dataSize: Int) -> CompressionAlgorithm {
        if dataSize < 512 {
            return .none // Small data doesn't benefit from compression
        } else if dataSize < 4096 {
            return .lz4 // Fast compression for medium data
        } else if dataSize < 65536 {
            return .lzfse // Balanced compression for large data
        } else {
            return .lzma // High compression for very large data
        }
    }
}

/// Buffer management configuration
public struct BufferConfiguration: Sendable, Codable {
    /// Size of individual buffers in bytes
    public let bufferSize: Int
    
    /// Maximum number of buffers to pool
    public let maxBuffers: Int
    
    /// Minimum compression ratio to apply compression (0.0-1.0)
    public let minCompressionRatio: Double
    
    /// Preferred compression algorithm
    public let compressionAlgorithm: CompressionAlgorithm
    
    /// Enable adaptive buffer sizing
    public let adaptiveBuffering: Bool
    
    /// Prefetch buffer count for read operations
    public let prefetchCount: Int
    
    public init(
        bufferSize: Int = 4096,
        maxBuffers: Int = 20,
        minCompressionRatio: Double = 0.1,
        compressionAlgorithm: CompressionAlgorithm = .lzfse,
        adaptiveBuffering: Bool = true,
        prefetchCount: Int = 3
    ) {
        self.bufferSize = bufferSize
        self.maxBuffers = maxBuffers
        self.minCompressionRatio = minCompressionRatio
        self.compressionAlgorithm = compressionAlgorithm
        self.adaptiveBuffering = adaptiveBuffering
        self.prefetchCount = prefetchCount
    }
    
    /// Low-memory configuration
    public static let lowMemory = BufferConfiguration(
        bufferSize: 1024,
        maxBuffers: 5,
        compressionAlgorithm: .lz4,
        adaptiveBuffering: false,
        prefetchCount: 1
    )
    
    /// High-performance configuration
    public static let highPerformance = BufferConfiguration(
        bufferSize: 8192,
        maxBuffers: 50,
        minCompressionRatio: 0.05,
        compressionAlgorithm: .lzfse,
        adaptiveBuffering: true,
        prefetchCount: 5
    )
}

/// Optimized data buffer with compression support
public struct OptimizedBuffer: Sendable {
    public let id: UUID
    public let data: Data
    public let isCompressed: Bool
    public let compressionAlgorithm: CompressionAlgorithm
    public let originalSize: Int
    public let timestamp: Date
    
    public init(
        data: Data,
        isCompressed: Bool = false,
        compressionAlgorithm: CompressionAlgorithm = .none,
        originalSize: Int? = nil
    ) {
        self.id = UUID()
        self.data = data
        self.isCompressed = isCompressed
        self.compressionAlgorithm = compressionAlgorithm
        self.originalSize = originalSize ?? data.count
        self.timestamp = Date()
    }
    
    /// Compression ratio (0.0 = no compression, 1.0 = 100% compression)
    public var compressionRatio: Double {
        guard originalSize > 0 else { return 0.0 }
        return 1.0 - (Double(data.count) / Double(originalSize))
    }
    
    /// Size reduction in bytes
    public var sizeReduction: Int {
        return originalSize - data.count
    }
}

/// Buffer pool for efficient memory management
public actor BufferPool {
    private let configuration: BufferConfiguration
    private var availableBuffers: [Data] = []
    private var usedBuffers: Set<UUID> = []
    private var totalAllocated: Int = 0
    
    public init(configuration: BufferConfiguration = BufferConfiguration()) {
        self.configuration = configuration
    }
    
    /// Get a buffer from the pool
    public func acquireBuffer(minimumSize: Int = 0) -> Data {
        let requiredSize = max(minimumSize, configuration.bufferSize)
        
        // Try to reuse existing buffer
        if let index = availableBuffers.firstIndex(where: { $0.count >= requiredSize }) {
            let buffer = availableBuffers.remove(at: index)
            return Data(buffer.prefix(requiredSize))
        }
        
        // Create new buffer if under limit
        if totalAllocated < configuration.maxBuffers {
            totalAllocated += 1
            return Data(count: requiredSize)
        }
        
        // Force create if no buffers available
        return Data(count: requiredSize)
    }
    
    /// Return a buffer to the pool
    public func releaseBuffer(_ buffer: Data) {
        if availableBuffers.count < configuration.maxBuffers {
            availableBuffers.append(buffer)
        } else {
            // Pool is full, let buffer be deallocated
            if totalAllocated > 0 {
                totalAllocated -= 1
            }
        }
    }
    
    /// Clear all buffers
    public func clearAll() {
        availableBuffers.removeAll()
        usedBuffers.removeAll()
        totalAllocated = 0
    }
    
    /// Get pool statistics
    public var statistics: BufferPoolStatistics {
        return BufferPoolStatistics(
            availableBuffers: availableBuffers.count,
            totalAllocated: totalAllocated,
            maxBuffers: configuration.maxBuffers,
            totalMemoryUsed: availableBuffers.reduce(0) { $0 + $1.count }
        )
    }
}

/// Buffer pool statistics
public struct BufferPoolStatistics: Sendable, Codable {
    public let availableBuffers: Int
    public let totalAllocated: Int
    public let maxBuffers: Int
    public let totalMemoryUsed: Int
    
    public var utilizationRatio: Double {
        return Double(totalAllocated) / Double(maxBuffers)
    }
    
    public init(availableBuffers: Int, totalAllocated: Int, maxBuffers: Int, totalMemoryUsed: Int) {
        self.availableBuffers = availableBuffers
        self.totalAllocated = totalAllocated
        self.maxBuffers = maxBuffers
        self.totalMemoryUsed = totalMemoryUsed
    }
}

/// Data compression utilities
public enum DataCompression {
    
    /// Compress data using specified algorithm
    public static func compress(
        _ data: Data,
        using algorithm: CompressionAlgorithm
    ) throws -> Data {
        guard algorithm != .none else { return data }
        guard !data.isEmpty else { return data }
        
        return try data.withUnsafeBytes { bytes in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            defer { buffer.deallocate() }
            
            let compressedSize = compression_encode_buffer(
                buffer,
                data.count,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                algorithm.algorithm
            )
            
            guard compressedSize > 0 else {
                throw BleuError.serializationFailed
            }
            
            return Data(bytes: buffer, count: compressedSize)
        }
    }
    
    /// Decompress data using specified algorithm
    public static func decompress(
        _ data: Data,
        using algorithm: CompressionAlgorithm,
        originalSize: Int
    ) throws -> Data {
        guard algorithm != .none else { return data }
        guard !data.isEmpty else { return data }
        
        return try data.withUnsafeBytes { bytes in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: originalSize)
            defer { buffer.deallocate() }
            
            let decompressedSize = compression_decode_buffer(
                buffer,
                originalSize,
                bytes.bindMemory(to: UInt8.self).baseAddress!,
                data.count,
                nil,
                algorithm.algorithm
            )
            
            guard decompressedSize > 0 else {
                throw BleuError.deserializationFailed
            }
            
            return Data(bytes: buffer, count: decompressedSize)
        }
    }
    
    /// Test compression efficiency for data
    public static func testCompressionEfficiency(
        _ data: Data,
        algorithms: [CompressionAlgorithm] = [.lz4, .lzfse, .zlib, .lzma]
    ) -> [(CompressionAlgorithm, Double, TimeInterval)] {
        var results: [(CompressionAlgorithm, Double, TimeInterval)] = []
        
        for algorithm in algorithms {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            do {
                let compressed = try compress(data, using: algorithm)
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                let ratio = 1.0 - (Double(compressed.count) / Double(data.count))
                
                results.append((algorithm, ratio, duration))
            } catch {
                results.append((algorithm, 0.0, 0.0))
            }
        }
        
        return results
    }
}

/// Optimized data manager with buffering and compression
public actor BleuDataOptimizer {
    public static let shared = BleuDataOptimizer()
    
    private let bufferPool: BufferPool
    private var configuration: BufferConfiguration
    private var compressionStats: [CompressionAlgorithm: CompressionStatistics] = [:]
    
    private init() {
        self.configuration = BufferConfiguration()
        self.bufferPool = BufferPool(configuration: configuration)
        
        // Initialize compression stats
        for algorithm in CompressionAlgorithm.allCases {
            compressionStats[algorithm] = CompressionStatistics()
        }
    }
    
    // MARK: - Configuration
    
    public func configure(with config: BufferConfiguration) {
        configuration = config
    }
    
    public var configuration: BufferConfiguration {
        return configuration
    }
    
    // MARK: - Data Optimization
    
    /// Optimize data for transmission
    public func optimizeForTransmission(_ data: Data) async throws -> OptimizedBuffer {
        await BleuPerformanceMonitor.shared.measureOperation(
            name: "data_optimization",
            metadata: ["original_size": "\(data.count)"]
        ) {
            
            // Determine best compression algorithm
            let algorithm = configuration.adaptiveBuffering ? 
                await selectOptimalCompression(for: data) : 
                configuration.compressionAlgorithm
            
            // Skip compression for small data or if algorithm is none
            guard algorithm != .none && data.count >= 128 else {
                return OptimizedBuffer(data: data)
            }
            
            do {
                let compressedData = try DataCompression.compress(data, using: algorithm)
                let compressionRatio = 1.0 - (Double(compressedData.count) / Double(data.count))
                
                // Update statistics
                updateCompressionStats(algorithm, originalSize: data.count, compressedSize: compressedData.count)
                
                // Only use compression if it provides significant benefit
                if compressionRatio >= configuration.minCompressionRatio {
                    await BleuLogger.shared.debug(
                        "Data compressed using \(algorithm.description): \(data.count) -> \(compressedData.count) bytes (\(String(format: "%.1f", compressionRatio * 100))% reduction)",
                        category: .performance,
                        metadata: ["algorithm": algorithm.description, "ratio": String(compressionRatio)]
                    )
                    
                    return OptimizedBuffer(
                        data: compressedData,
                        isCompressed: true,
                        compressionAlgorithm: algorithm,
                        originalSize: data.count
                    )
                } else {
                    return OptimizedBuffer(data: data)
                }
            } catch {
                await BleuLogger.shared.warning(
                    "Compression failed, using uncompressed data: \(error)",
                    category: .performance
                )
                return OptimizedBuffer(data: data)
            }
        }
    }
    
    /// Restore optimized data
    public func restoreOptimizedData(_ buffer: OptimizedBuffer) async throws -> Data {
        return await BleuPerformanceMonitor.shared.measureOperation(
            name: "data_restoration",
            metadata: ["compressed": "\(buffer.isCompressed)", "size": "\(buffer.data.count)"]
        ) {
            
            guard buffer.isCompressed else {
                return buffer.data
            }
            
            do {
                let restoredData = try DataCompression.decompress(
                    buffer.data,
                    using: buffer.compressionAlgorithm,
                    originalSize: buffer.originalSize
                )
                
                await BleuLogger.shared.debug(
                    "Data decompressed: \(buffer.data.count) -> \(restoredData.count) bytes",
                    category: .performance
                )
                
                return restoredData
            } catch {
                await BleuLogger.shared.error(
                    "Decompression failed: \(error)",
                    category: .performance
                )
                throw BleuError.deserializationFailed
            }
        }
    }
    
    // MARK: - Adaptive Buffer Management
    
    /// Get optimized buffer for data size
    public func optimizedBuffer(for size: Int) async -> Data {
        let adaptiveSize = configuration.adaptiveBuffering ? 
            calculateOptimalBufferSize(for: size) : 
            configuration.bufferSize
        
        return await bufferPool.acquireBuffer(minimumSize: adaptiveSize)
    }
    
    /// Release buffer back to pool
    public func releaseBuffer(_ buffer: Data) async {
        await bufferPool.releaseBuffer(buffer)
    }
    
    // MARK: - Batch Processing
    
    /// Process multiple data items in batch for efficiency
    public func batchProcess<T>(
        items: [T],
        processor: @Sendable (T) async throws -> OptimizedBuffer
    ) async throws -> [OptimizedBuffer] {
        return await BleuPerformanceMonitor.shared.measureOperation(
            name: "batch_processing",
            metadata: ["count": "\(items.count)"]
        ) {
            
            // Process in chunks to avoid memory pressure
            let chunkSize = 10
            var results: [OptimizedBuffer] = []
            
            for chunk in items.chunked(into: chunkSize) {
                let chunkResults = try await withThrowingTaskGroup(of: OptimizedBuffer.self) { group in
                    for item in chunk {
                        group.addTask {
                            return try await processor(item)
                        }
                    }
                    
                    var chunkResults: [OptimizedBuffer] = []
                    for try await result in group {
                        chunkResults.append(result)
                    }
                    return chunkResults
                }
                
                results.append(contentsOf: chunkResults)
            }
            
            return results
        }
    }
    
    // MARK: - Statistics and Monitoring
    
    public var optimizationStatistics: OptimizationStatistics { get async
        let bufferStats = await bufferPool.getStatistics()
        let totalCompressions = compressionStats.values.reduce(0) { $0 + $1.compressionCount }
        let totalBytesSaved = compressionStats.values.reduce(0) { $0 + $1.totalBytesSaved }
        
        return OptimizationStatistics(
            bufferPoolStats: bufferStats,
            compressionStats: compressionStats,
            totalCompressions: totalCompressions,
            totalBytesSaved: totalBytesSaved
        )
    }
    
    public func clearStatistics() {
        for algorithm in CompressionAlgorithm.allCases {
            compressionStats[algorithm] = CompressionStatistics()
        }
    }
    
    // MARK: - Private Implementation
    
    private func selectOptimalCompression(for data: Data) async -> CompressionAlgorithm {
        // Use historical performance data to select best algorithm
        let stats = compressionStats
        
        // For small data, prefer speed
        if data.count < 1024 {
            return .lz4
        }
        
        // Select algorithm with best efficiency for this size range
        let sizeCategory = categorizeDataSize(data.count)
        let candidates = stats.compactMap { (algorithm, stats) -> (CompressionAlgorithm, Double) in
            guard stats.sizeCategories[sizeCategory] != nil else { return nil }
            return (algorithm, stats.averageCompressionRatio)
        }
        
        if let best = candidates.max(by: { $0.1 < $1.1 }) {
            return best.0
        }
        
        return CompressionAlgorithm.recommended(for: data.count)
    }
    
    private func calculateOptimalBufferSize(for dataSize: Int) -> Int {
        // Calculate buffer size based on data size and performance history
        if dataSize <= 1024 {
            return 2048
        } else if dataSize <= 4096 {
            return 8192
        } else if dataSize <= 16384 {
            return 32768
        } else {
            return min(dataSize * 2, 131072) // Cap at 128KB
        }
    }
    
    private func updateCompressionStats(_ algorithm: CompressionAlgorithm, originalSize: Int, compressedSize: Int) {
        var stats = compressionStats[algorithm] ?? CompressionStatistics()
        
        stats.compressionCount += 1
        stats.totalOriginalBytes += originalSize
        stats.totalCompressedBytes += compressedSize
        stats.totalBytesSaved += max(0, originalSize - compressedSize)
        
        let sizeCategory = categorizeDataSize(originalSize)
        stats.sizeCategories[sizeCategory, default: 0] += 1
        
        compressionStats[algorithm] = stats
    }
    
    private func categorizeDataSize(_ size: Int) -> String {
        if size < 1024 {
            return "small"
        } else if size < 8192 {
            return "medium"
        } else if size < 65536 {
            return "large"
        } else {
            return "extra_large"
        }
    }
}

/// Compression statistics
public struct CompressionStatistics: Sendable, Codable {
    public var compressionCount: Int = 0
    public var totalOriginalBytes: Int = 0
    public var totalCompressedBytes: Int = 0
    public var totalBytesSaved: Int = 0
    public var sizeCategories: [String: Int] = [:]
    
    public var averageCompressionRatio: Double {
        guard totalOriginalBytes > 0 else { return 0.0 }
        return Double(totalBytesSaved) / Double(totalOriginalBytes)
    }
    
    public var averageCompressionRate: Double {
        guard totalOriginalBytes > 0 else { return 0.0 }
        return Double(totalCompressedBytes) / Double(totalOriginalBytes)
    }
    
    public init() {}
}

/// Optimization statistics
public struct OptimizationStatistics: Sendable, Codable {
    public let bufferPoolStats: BufferPoolStatistics
    public let compressionStats: [CompressionAlgorithm: CompressionStatistics]
    public let totalCompressions: Int
    public let totalBytesSaved: Int
    
    public init(
        bufferPoolStats: BufferPoolStatistics,
        compressionStats: [CompressionAlgorithm: CompressionStatistics],
        totalCompressions: Int,
        totalBytesSaved: Int
    ) {
        self.bufferPoolStats = bufferPoolStats
        self.compressionStats = compressionStats
        self.totalCompressions = totalCompressions
        self.totalBytesSaved = totalBytesSaved
    }
}

// MARK: - Extensions

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension CentralActor {
    /// Send data with optimization
    public distributed func sendOptimizedData(
        to deviceId: DeviceIdentifier,
        data: Data,
        serviceUUID: UUID,
        characteristicUUID: UUID
    ) async throws -> Data? {
        
        // Optimize data before sending
        let optimizedBuffer = try await BleuDataOptimizer.shared.optimizeForTransmission(data)
        
        // Create message with optimized data
        let message = BleuMessage(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: try JSONEncoder().encode(optimizedBuffer),
            method: .write
        )
        
        // Send optimized data
        let response = try await sendRequest(to: deviceId, message: message)
        
        // Restore response if it was optimized
        if let responseData = response,
           let responseBuffer = try? JSONDecoder().decode(OptimizedBuffer.self, from: responseData) {
            return try await BleuDataOptimizer.shared.restoreOptimizedData(responseBuffer)
        }
        
        return response
    }
}

extension PeripheralActor {
    /// Handle optimized data request
    public func handleOptimizedRequest(_ data: Data) async throws -> Data? {
        // Decode optimized buffer
        guard let optimizedBuffer = try? JSONDecoder().decode(OptimizedBuffer.self, from: data) else {
            throw BleuError.invalidDataFormat
        }
        
        // Restore original data
        let originalData = try await BleuDataOptimizer.shared.restoreOptimizedData(optimizedBuffer)
        
        // Process original data (placeholder for actual processing)
        let processedData = originalData // Actual processing would happen here
        
        // Optimize response
        let responseBuffer = try await BleuDataOptimizer.shared.optimizeForTransmission(processedData)
        
        // Return optimized response
        return try JSONEncoder().encode(responseBuffer)
    }
}