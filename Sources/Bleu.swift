//
//  Bleu.swift
//  Antenna
//
//  Created by 1amageek on 2017/03/12.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 BleuはCoreBluetoothのラッパーです。
 `Request` `Receiver`を定義することで通信を制御します。
 */

public class Bleu {
    
    static var shared: Bleu = Bleu()
    
    enum BleuError: Error {
        case invalidGetReceiver
        case invalidPostReceiver
        case invalidNotifyReceiver
    }
    
    public var services: [CBMutableService] = []
    
    public let server: Beacon = Beacon()
    
    private(set) var receivers: Set<Receiver> = []
    
    private var radars: Set<Radar> = []
        
    public init() {
        server.delegate = self
    }
    
    // MARK: - Advertising
    
    public class var isAdvertising: Bool {
        return shared.server.isAdvertising
    }
    
    public class func startAdvertising() {
        shared.server.startAdvertising()
    }
    
    public class func stopAdvertising() {
        shared.server.stopAdvertising()
    }
    
    // MARK: -
    
    private class func addService(_ service: CBMutableService) {
        shared.services.append(service)
    }
    
    private class func removeService(_ service: CBMutableService) {
        if let index: Int = shared.services.index(of: service) {
            shared.services.remove(at: index)
        }
    }

    // MARK: - Request
    
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
            Swift.print("*** Error: When RequestMethod is `get`, it must have get receiver.")
        } catch BleuError.invalidPostReceiver {
            Swift.print("*** Error: When RequestMethod is `post`, it must have post receiver.")
        } catch BleuError.invalidNotifyReceiver {
            Swift.print("*** Error: When RequestMethod is `notify`, it must have post receiver.")
        } catch {
            Swift.print("*** Error: Receiver unkown error.")
        }
    }
    
    private func validateReceiver(_ receiver: Receiver) throws {
        switch receiver.method{
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
    
    public class func removeAllReceivers() {
        shared.receivers.forEach { (receiver) in
            Bleu.removeReceiver(receiver)
        }
    }
    
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

