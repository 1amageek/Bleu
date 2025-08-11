import Foundation
@preconcurrency import CoreBluetooth

/// Delegate proxy for CBPeripheralManager to forward callbacks to LocalPeripheralActor
final class PeripheralManagerDelegateProxy: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    weak var actor: LocalPeripheralActor?
    
    init(actor: LocalPeripheralActor) {
        self.actor = actor
        super.init()
    }
    
    // MARK: - CBPeripheralManagerDelegate
    
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { [weak actor] in
            await actor?.handleStateUpdate(peripheral.state)
        }
    }
    
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { [weak actor] in
            await actor?.handleAdvertisingStarted(error: error)
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { [weak actor] in
            await actor?.handleServiceAdded(service, error: error)
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Extract necessary data before Task
        let characteristicUUID = request.characteristic.uuid.uuidString
        let serviceUUID = request.characteristic.service?.uuid.uuidString
        let offset = request.offset
        
        Task { [weak actor, peripheral] in
            await actor?.handleReadRequest(
                characteristicUUID: characteristicUUID,
                serviceUUID: serviceUUID,
                offset: offset,
                peripheral: peripheral,
                request: request
            )
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Extract data from requests to avoid Sendable issues
        let extractedRequests: [(serviceUUID: String?, characteristicUUID: String, value: Data?, offset: Int)] = 
            requests.map { request in
                (
                    serviceUUID: request.characteristic.service?.uuid.uuidString,
                    characteristicUUID: request.characteristic.uuid.uuidString,
                    value: request.value,
                    offset: request.offset
                )
            }
        
        // Respond immediately (as per Apple's documentation)
        if let firstRequest = requests.first {
            peripheral.respond(to: firstRequest, withResult: .success)
        }
        
        // Process requests asynchronously
        Task { [weak actor] in
            await actor?.handleWriteRequests(extractedRequests)
        }
    }
    
    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let characteristicUUID = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid.uuidString
        
        Task { [weak actor] in
            await actor?.handleSubscription(
                central: central,
                characteristicUUID: characteristicUUID,
                serviceUUID: serviceUUID,
                subscribed: true
            )
        }
    }
    
    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let characteristicUUID = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid.uuidString
        
        Task { [weak actor] in
            await actor?.handleSubscription(
                central: central,
                characteristicUUID: characteristicUUID,
                serviceUUID: serviceUUID,
                subscribed: false
            )
        }
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        Task { [weak actor] in
            await actor?.handleReadyToUpdateSubscribers()
        }
    }
}