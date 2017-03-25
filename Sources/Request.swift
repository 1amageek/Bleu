//
//  Request.swift
//  Antenna
//
//  Created by 1amageek on 2017/03/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Request: Communicable {
    
    public typealias RequestHandler = ((CBPeripheral, CBCharacteristic) -> Void)
    
    public typealias ResponseHandler = ((CBPeripheral, CBCharacteristic, Error?) -> Void)

    public let serviceUUID: CBUUID
    
    public let method: RequestMethod
    
    public let characteristicUUID: CBUUID?
    
    public let characteristic: CBMutableCharacteristic
    
    public var options: [String: Any]?
    
    public var value: Data?
    
    public var response: ResponseHandler?
    
    public init<T: Communicable>(communication: T, response: @escaping ResponseHandler) {
        self.serviceUUID = communication.serviceUUID
        self.method = communication.method
        self.response = response
        self.characteristicUUID = communication.characteristicUUID
        self.characteristic = CBMutableCharacteristic(type: communication.characteristicUUID!,
                                                      properties: method.properties,
                                                      value: communication.value,
                                                      permissions: method.permissions)
    }
    
}
