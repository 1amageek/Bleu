import Foundation
import os

/// Logger for Bleu framework
public struct BleuLogger {
    private static let subsystem = "com.bleu.framework"
    
    /// Logger categories
    public enum Category: String {
        case transport = "Transport"
        case actorSystem = "ActorSystem"
        case central = "Central"
        case peripheral = "Peripheral"
        case rpc = "RPC"
        case connection = "Connection"
    }
    
    /// Create a logger for a specific category
    public static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
    
    // Convenience static loggers
    public static let transport = logger(for: .transport)
    public static let actorSystem = logger(for: .actorSystem)
    public static let central = logger(for: .central)
    public static let peripheral = logger(for: .peripheral)
    public static let rpc = logger(for: .rpc)
    public static let connection = logger(for: .connection)
}