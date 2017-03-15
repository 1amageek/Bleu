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

    public let method: RequestMethod
    
    public let allowDuplicates: Bool
    
    public let thresholdRSSI: NSNumber?
    
    public let characteristicUUID: CBUUID
    
    public let characteristic: CBMutableCharacteristic
    
    public var options: [String: Any]?
    
    public var get: RequestHandler?
    
    public var post: RequestHandler?
    
    public var response: ResponseHandler?
    
    public init<T: Communicable>(item: T, allowDuplicates: Bool = false, thresholdRSSI: NSNumber? = nil, options: [String: Any]? = nil) {
        self.method = item.method
        self.characteristicUUID = item.characteristicUUID
        self.allowDuplicates = allowDuplicates
        self.thresholdRSSI = thresholdRSSI
        self.options = options
        self.characteristic = CBMutableCharacteristic(type: item.characteristicUUID, properties: method.property, value: nil, permissions: method.permission)
    }
    
}
