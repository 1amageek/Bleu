//
//  Bleu.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/12.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 # Bleu
 
 Bleu can easily control complex control of `CoreBluetooth` with Server client model.
 */
public class Bleu {

    /// Bleu is singleton class.
    public static var shared: Bleu = Bleu()

    /// Bleu Error's
    enum BleuError: Error {
        case invalidGetReceiver
        case invalidPostReceiver
        case invalidNotifyReceiver
    }

    /// Services handled by Bleu
    public var services: [CBMutableService] = []

    // MARK: -

    /// It is a server for responding to clients.
    public let server: Beacon = Beacon()

    /// It is a receiver managed by Bleu.
    private(set) var receivers: Set<Receiver> = []

    // MARK: -

    /// It is a radar for exploring the server.
    private var radars: Set<Radar> = []

    /// Initialize
    public init() {
        server.delegate = self
    }

    // MARK: - Advertising

    /// Returns whether the server (peripheral) is advertising.
    public class var isAdvertising: Bool {
        return shared.server.isAdvertising
    }

    /// Start advertising.
    public class func startAdvertising() {
        shared.server.startAdvertising()
    }

    /// Stop advertising.
    public class func stopAdvertising() {
        shared.server.stopAdvertising()
    }

    // MARK: - Serivce

    /// Add services managed by Bleu.
    private class func addService(_ service: CBMutableService) {
        shared.services.append(service)
    }

    /// Delete the service managed by Bleu.
    private class func removeService(_ service: CBMutableService) {
        if let index: Int = shared.services.index(of: service) {
            shared.services.remove(at: index)
        }
    }

    // MARK: - Request

    /**
     Send the request to the nearby server. The server is called Peripheral in CoreBluetooth.
     Multiple Requests can be sent at once. The Request is controlled by the Rader. Rader is called CentralManager in Corebluetooth.

     - parameter requests: Set an array of Request.
     - parameter options: Set Rader options. It is possible to change to the operation of Rader.
     - parameter completionBlock: Callback is called when all requests are completed. Since there may be more than one Peripheral, each Dictionary is returned.
     - returns: Radar
     */
    @discardableResult
    public class func send(_ requests: [Request], options: Radar.Options = Radar.Options(), completionBlock: (([CBPeripheral: Set<Request>], Error?) -> Void)?) -> Radar? {
        let radar = Radar(requests: requests, options: options)
        shared.radars.insert(radar)
        radar.completionHandler = { [weak radar] (completedRequests, error) in
            shared.radars.remove(radar!)
            completionBlock?(completedRequests, error)
        }
        radar.resume()
        return radar
    }

    // MARK: - Receiver

    /**
     Add a receiver.
     
     - parameter receiver: Set the receiver to respond to the request.
     */
    public class func addReceiver(_ receiver: Receiver) {
        do {
            try shared.validateReceiver(receiver)
            let isAdvertising = Bleu.isAdvertising
            if isAdvertising {
                Bleu.stopAdvertising()
            }
            
            shared.receivers.insert(receiver)
            
            let serviceUUIDs: [CBUUID] = shared.services.map({ return $0.uuid })
            if !serviceUUIDs.contains(receiver.serviceUUID) {
                let service: CBMutableService = CBMutableService(type: receiver.serviceUUID, primary: true)
                service.characteristics = []
                Bleu.addService(service)
            }
            
            shared.services.forEach({ (service) in
                if service.uuid == receiver.serviceUUID {
                    service.characteristics?.append(receiver.characteristic)
                }
            })
            
            if isAdvertising {
                Bleu.startAdvertising()
            }
        } catch BleuError.invalidGetReceiver {
            print("*** Error: When RequestMethod is `get`, it must have get receiver.")
        } catch BleuError.invalidPostReceiver {
            print("*** Error: When RequestMethod is `post`, it must have post receiver.")
        } catch BleuError.invalidNotifyReceiver {
            print("*** Error: When RequestMethod is `notify`, it must have post receiver.")
        } catch {
            print("*** Error: Receiver unkown error.")
        }
    }

    /**
     This function validates the receiver.
     
     - parameter receiver: Set the target receiver.
     */
    private func validateReceiver(_ receiver: Receiver) throws {
        switch receiver.method {
        case .get(let isNotify):
            guard let _: Receiver.ReceiveGetHandler = receiver.get else {
                throw BleuError.invalidGetReceiver
            }
            if isNotify {
                guard let _: Receiver.ReceiveNotifyHandler = receiver.subscribe else {
                    throw BleuError.invalidNotifyReceiver
                }
                guard let _: Receiver.ReceiveNotifyHandler = receiver.unsubscribe else {
                    throw BleuError.invalidNotifyReceiver
                }
            }
        case .post:
            guard let _: Receiver.ReceivePostHandler = receiver.post else {
                throw BleuError.invalidPostReceiver
            }
        case .broadcast: break
        }
    }

    /**
     This function deletes the receiver.

     - parameter receiver: Set the target receiver.
     */
    public class func removeReceiver(_ receiver: Receiver) {
        shared.receivers.remove(receiver)
        shared.services.forEach({ (service) in
            if service.uuid == receiver.serviceUUID {
                if let index: Int = service.characteristics?.index(where: { (characteristic) -> Bool in
                    return characteristic.uuid == receiver.characteristicUUID
                }) {
                    service.characteristics?.remove(at: index)
                }
            }
        })
    }

    /**
     This function deletes all receivers.
     */
    public class func removeAllReceivers() {
        shared.receivers.forEach { (receiver) in
            Bleu.removeReceiver(receiver)
        }
    }

    // MARK: - 

    /**
     Update the value of characteristic.
     
     - parameter value: Set the data to be updated.
     - parameter characteristic: Set the target characteristic.
     - parameter centrals: Set the target centrals.
     - returns: `true` if the update could be sent, or `false` if the underlying transmit queue is full. If `false` was returned, 
     the delegate method peripheralManagerIsReadyToUpdateSubscribers: will be called once space has become available, 
     and the update should be re-sent if so desired.
     */
    @discardableResult
    public class func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        return shared.server.updateValue(value, for: characteristic, onSubscribedCentrals: centrals)
    }
}

protocol BleuServerDelegate: class {

    var services: [CBMutableService] { get }

    var receivers: Set<Receiver> { get }

    func get(peripheralManager: CBPeripheralManager, request: CBATTRequest)

    func post(peripheralManager: CBPeripheralManager, requests: [CBATTRequest])

    func subscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic)

    func unsubscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic)
}

extension Bleu: BleuServerDelegate {

    func get(peripheralManager: CBPeripheralManager, request: CBATTRequest) {
        self.receivers.forEach { (receiver) in
            if receiver.characteristicUUID == request.characteristic.uuid {
                DispatchQueue.main.async {
                    receiver.get?(peripheralManager, request)
                }
            }
        }
    }

    func post(peripheralManager: CBPeripheralManager, requests: [CBATTRequest]) {
        self.receivers.forEach { (receiver) in
            requests.forEach({ (request) in
                if receiver.characteristicUUID == request.characteristic.uuid {
                    DispatchQueue.main.async {
                        receiver.post?(peripheralManager, request)
                    }
                }
            })
        }
    }

    func subscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic) {
        self.receivers.forEach { (receiver) in
            if receiver.characteristicUUID == receiver.characteristic.uuid {
                DispatchQueue.main.async {
                    receiver.subscribe?(peripheralManager, central, characteristic)
                }
            }
        }
    }

    func unsubscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic) {
        self.receivers.forEach { (receiver) in
            if receiver.characteristicUUID == receiver.characteristic.uuid {
                DispatchQueue.main.async {
                    receiver.unsubscribe?(peripheralManager, central, characteristic)
                }
            }
        }
    }
}

