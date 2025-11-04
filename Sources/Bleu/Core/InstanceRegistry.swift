import Foundation
import Distributed

/// Registry for managing distributed actor instances
public actor InstanceRegistry {
    
    /// Actor instance registration
    private struct Registration {
        let instance: any DistributedActor
        let type: String
        let isLocal: Bool
        let peripheralID: UUID?
        let registeredAt: Date
    }
    
    // Registry storage
    private var instances: [UUID: Registration] = [:]
    private var typeIndex: [String: Set<UUID>] = [:]
    private var peripheralIndex: [UUID: Set<UUID>] = [:]
    
    /// Shared instance
    public static let shared = InstanceRegistry()
    
    private init() {}
    
    /// Register a local actor instance
    public func registerLocal<T: DistributedActor>(_ actor: T, type: String? = nil) where T.ID == UUID {
        let actorType = type ?? String(reflecting: T.self)
        
        let registration = Registration(
            instance: actor,
            type: actorType,
            isLocal: true,
            peripheralID: nil,
            registeredAt: Date()
        )
        
        instances[actor.id] = registration
        
        // Update type index
        if typeIndex[actorType] == nil {
            typeIndex[actorType] = []
        }
        typeIndex[actorType]?.insert(actor.id)
    }
    
    /// Register a remote actor instance
    public func registerRemote<T: DistributedActor>(
        _ actor: T,
        peripheralID: UUID,
        type: String? = nil
    ) where T.ID == UUID {
        let actorType = type ?? String(reflecting: T.self)
        
        let registration = Registration(
            instance: actor,
            type: actorType,
            isLocal: false,
            peripheralID: peripheralID,
            registeredAt: Date()
        )
        
        instances[actor.id] = registration
        
        // Update type index
        if typeIndex[actorType] == nil {
            typeIndex[actorType] = []
        }
        typeIndex[actorType]?.insert(actor.id)
        
        // Update peripheral index
        if peripheralIndex[peripheralID] == nil {
            peripheralIndex[peripheralID] = []
        }
        peripheralIndex[peripheralID]?.insert(actor.id)
    }
    
    /// Get an actor instance by ID (type-erased)
    public func find(_ id: UUID) -> (any DistributedActor)? {
        return instances[id]?.instance
    }

    /// Get an actor instance by ID
    public func get<T: DistributedActor>(_ id: UUID, as type: T.Type) -> T? where T.ID == UUID {
        guard let registration = instances[id] else { return nil }
        return registration.instance as? T
    }
    
    /// Get all actors of a specific type
    public func getAll<T: DistributedActor>(of type: T.Type) -> [T] where T.ID == UUID {
        let typeName = String(reflecting: type)
        guard let actorIDs = typeIndex[typeName] else { return [] }
        
        return actorIDs.compactMap { id in
            instances[id]?.instance as? T
        }
    }
    
    /// Get all actors for a peripheral
    public func getActors(for peripheralID: UUID) -> [any DistributedActor] {
        guard let actorIDs = peripheralIndex[peripheralID] else { return [] }
        
        return actorIDs.compactMap { id in
            instances[id]?.instance
        }
    }
    
    /// Check if an actor is registered
    public func isRegistered(_ id: UUID) -> Bool {
        return instances[id] != nil
    }
    
    /// Unregister an actor
    public func unregister(_ id: UUID) {
        guard let registration = instances.removeValue(forKey: id) else { return }
        
        // Update type index
        typeIndex[registration.type]?.remove(id)
        if typeIndex[registration.type]?.isEmpty == true {
            typeIndex.removeValue(forKey: registration.type)
        }
        
        // Update peripheral index
        if let peripheralID = registration.peripheralID {
            peripheralIndex[peripheralID]?.remove(id)
            if peripheralIndex[peripheralID]?.isEmpty == true {
                peripheralIndex.removeValue(forKey: peripheralID)
            }
        }
    }
    
    /// Unregister all actors for a peripheral
    public func unregisterPeripheral(_ peripheralID: UUID) {
        guard let actorIDs = peripheralIndex.removeValue(forKey: peripheralID) else { return }
        
        for actorID in actorIDs {
            if let registration = instances.removeValue(forKey: actorID) {
                typeIndex[registration.type]?.remove(actorID)
                if typeIndex[registration.type]?.isEmpty == true {
                    typeIndex.removeValue(forKey: registration.type)
                }
            }
        }
    }
    
    /// Clear all registrations
    public func clear() {
        instances.removeAll()
        typeIndex.removeAll()
        peripheralIndex.removeAll()
    }
    
    /// Get statistics
    public func statistics() -> RegistryStatistics {
        let localCount = instances.values.filter { $0.isLocal }.count
        let remoteCount = instances.values.filter { !$0.isLocal }.count
        
        return RegistryStatistics(
            totalInstances: instances.count,
            localInstances: localCount,
            remoteInstances: remoteCount,
            uniqueTypes: typeIndex.count,
            connectedPeripherals: peripheralIndex.count
        )
    }
}

/// Registry statistics
public struct RegistryStatistics: Sendable {
    public let totalInstances: Int
    public let localInstances: Int
    public let remoteInstances: Int
    public let uniqueTypes: Int
    public let connectedPeripherals: Int
}