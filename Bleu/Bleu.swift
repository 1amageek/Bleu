//
//  Bleu.swift
//  Antenna
//
//  Created by 1amageek on 2017/03/12.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Bleu: BLEService {
    
    static var shared: Bleu = Bleu()
    
    enum BleuError: Error {
        case invalidGetRequest
        case invalidPostRequest
        case invalidGetReceiver
        case invalidPostReceiver
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
    
    fileprivate func removeRequest(_ request: Request) {
        self.requests.remove(request)
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
        case .notify:
            // TODO: Notify
            break
        }
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
        } catch {
            
        }
    }
    
    public func removeRecevier(_ receiver: Receiver) {
        self.receivers.remove(receiver)
    }
    
    private func validateReceiver(_ receiver: Receiver) throws {
        switch receiver.method{
        case .get:
            guard let _: Receiver.ReceiveGetHandler = receiver.get else {
                throw BleuError.invalidGetReceiver
            }
        case .post:
            guard let _: Receiver.ReceivePostHandler = receiver.post else {
                throw BleuError.invalidPostReceiver
            }
        case .notify:
            // TODO: Notify
            break
        }
    }
    
}

protocol BleuClientDelegate: class {
    var service: CBMutableService { get }
    var serviceUUID: CBUUID { get }
    var characteristicUUIDs: [CBUUID] { get }
    func get(peripheral: CBPeripheral, characteristic: CBCharacteristic)
    func post(peripheral: CBPeripheral, characteristic: CBCharacteristic)
    func receiveResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?)
}

protocol BleuServerDelegate: class {
    var service: CBMutableService { get }
    var serviceUUID: CBUUID { get }
    var characteristicUUIDs: [CBUUID] { get }
    func get(peripheralManager: CBPeripheralManager, request: CBATTRequest)
    func post(peripheralManager: CBPeripheralManager, requests: [CBATTRequest])
}

extension Bleu: BleuClientDelegate {
    
    func get(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                request.get!(peripheral, characteristic)
            }
        }
    }
    
    func post(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                request.post!(peripheral, characteristic)
            }
            
        }
    }
    
    func receiveResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                if let handler = request.response {
                    handler(peripheral, characteristic, error)
                }
                self.removeRequest(request)
            }
        }
    }
    
}

extension Bleu: BleuServerDelegate {
    
    func get(peripheralManager: CBPeripheralManager, request: CBATTRequest) {
        self.receivers.forEach { (receiver) in
            if receiver.characteristicUUID == receiver.characteristic.uuid {
                receiver.get?(peripheralManager, request)
            }
        }
    }
    
    func post(peripheralManager: CBPeripheralManager, requests: [CBATTRequest]) {
        self.receivers.forEach { (receiver) in
            if receiver.characteristicUUID == receiver.characteristic.uuid {
                receiver.post?(peripheralManager, requests)
            }
        }
    }

}

