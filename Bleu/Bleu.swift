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

public class Bleu: BLEService {
    
    static var shared: Bleu = Bleu()
    
    enum BleuError: Error {
        case invalidGetRequest
        case invalidPostRequest
        case invalidNotifyRequest
        case invalidGetReceiver
        case invalidPostReceiver
        case invalidNotifyReceiver
    }
    
    var service: CBMutableService {
        let service: CBMutableService = CBMutableService(type: self.serviceUUID, primary: true)
        service.characteristics = self.characteristics
        return service
    }
    
    public let server: Beacon = Beacon()
    
    public let client: Antenna = Antenna()
    
    private(set) var requests: Set<Request> = []
    
    private(set) var receivers: Set<Receiver> = []
    
    var characteristicUUIDs: [CBUUID] {
        return self.receivers.map({ return $0.characteristicUUID })
    }
    
    var characteristics: [CBMutableCharacteristic] {
        return self.receivers.map({ return $0.characteristic })
    }
    
    public init() {
        client.delegate = self
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
    
    // MARK: - Request
    
    public class func send(_ request: Request, block: ((CBPeripheral, CBCharacteristic, Error?) -> Void)?) {
        request.response = block
        shared.addRequest(request)
        shared.client.startScan(thresholdRSSI: request.thresholdRSSI,
                              allowDuplicates: request.allowDuplicates,
                              options: nil)
    }
    
    public class func cancelRequests() {
        shared.client.stopScan(cleaned: true)
    }
    
    private func addRequest(_ request: Request) {
        do {
            try validateRequest(request)
            self.requests.insert(request)
        } catch BleuError.invalidGetRequest {
            Swift.print("*** Error: When RequestMethod is `get`, it must have get request ")
        } catch BleuError.invalidPostRequest {
            Swift.print("*** Error: When RequestMethod is `post`, it must have post request ")
        } catch {
            
        }
    }
    
    private func validateRequest(_ request: Request) throws {
        switch request.method{
        case .get:
            guard let _: Request.RequestHandler = request.get else {
                throw BleuError.invalidGetRequest
            }
        case .post:
            guard let _: Request.RequestHandler = request.post else {
                throw BleuError.invalidPostRequest
            }
        }
    }
    
    public class func removeRequest(_ request: Request) {
        shared.requests.remove(request)
    }
    
    public class func removeAllRequests() {
        shared.requests = []
    }
    
    // MARK: - Receiver
    
    public class func addRecevier(_ receiver: Receiver) {
        do {
            try shared.validateReceiver(receiver)
            let isAdvertising = Bleu.isAdvertising
            if isAdvertising {
                Bleu.stopAdvertising()
            }
            shared.receivers.insert(receiver)
            if isAdvertising {
                Bleu.startAdvertising()
            }
        } catch BleuError.invalidGetReceiver {
            Swift.print("*** Error: When RequestMethod is `get`, it must have get receiver ")
        } catch BleuError.invalidPostReceiver {
            Swift.print("*** Error: When RequestMethod is `post`, it must have post receiver ")
        } catch BleuError.invalidNotifyReceiver {
            Swift.print("*** Error: When RequestMethod is `notify`, it must have post receiver ")
        } catch {
            
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
        }
    }
    
    public class func removeReceiver(_ receiver: Receiver) {
        shared.receivers.remove(receiver)
    }
    
    public class func removeAllReceivers() {
        shared.receivers = []
    }
    
    @discardableResult
    public class func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        return shared.server.updateValue(value, for: characteristic, onSubscribedCentrals: centrals)
    }
    
}

protocol BleuClientDelegate: class {
    var service: CBMutableService { get }
    var serviceUUID: CBUUID { get }
    var characteristicUUIDs: [CBUUID] { get }
    func get(peripheral: CBPeripheral, characteristic: CBCharacteristic)
    func post(peripheral: CBPeripheral, characteristic: CBCharacteristic)
    func notify(peripheral: CBPeripheral, characteristic: CBCharacteristic)
    func receiveResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?)
}

protocol BleuServerDelegate: class {
    var service: CBMutableService { get }
    var serviceUUID: CBUUID { get }
    var characteristicUUIDs: [CBUUID] { get }
    func get(peripheralManager: CBPeripheralManager, request: CBATTRequest)
    func post(peripheralManager: CBPeripheralManager, requests: [CBATTRequest])
    func subscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic)
    func unsubscribe(peripheralManager: CBPeripheralManager, central: CBCentral, characteristic: CBCharacteristic)
}

extension Bleu: BleuClientDelegate {
    
    func get(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                DispatchQueue.main.async {
                    request.get!(peripheral, characteristic)
                }
            }
        }
    }
    
    func post(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                DispatchQueue.main.async {
                    request.post!(peripheral, characteristic)
                }
            }
        }
    }
    
    func notify(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                switch request.method {
                case .get(let isNotify): peripheral.setNotifyValue(isNotify, for: characteristic)
                default: break
                }
            }            
        }
    }
    
    func receiveResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                if let handler = request.response {
                    DispatchQueue.main.async {
                        handler(peripheral, characteristic, error)
                    }                    
                }
                if !characteristic.isNotifying {
                    Bleu.removeRequest(request)
                }                
            }
        }
    }
    
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

