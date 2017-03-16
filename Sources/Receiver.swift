//
//  Receiver.swift
//  Antenna
//
//  Created by 1amageek on 2017/03/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Receiver: Communicable {
    
    public typealias ReceiveGetHandler = ((CBPeripheralManager, CBATTRequest) -> Void)
    
    public typealias ReceivePostHandler = ((CBPeripheralManager, CBATTRequest) -> Void)
    
    public typealias ReceiveNotifyHandler = ((CBPeripheralManager, CBCentral, CBCharacteristic) -> Void)
    
    public let method: RequestMethod
    
    public let characteristicUUID: CBUUID
    
    public let characteristic: CBMutableCharacteristic
    
    public var get: ReceiveGetHandler?
    
    public var post: ReceivePostHandler?
    
    public var subscribe: ReceiveNotifyHandler?
    
    public var unsubscribe: ReceiveNotifyHandler?
    
    public init<T: Communicable>(_ item: T,
                get: ReceiveGetHandler? = nil,
                post: ReceivePostHandler? = nil,
                subscribe: ReceiveNotifyHandler? = nil,
                unsubscribe: ReceiveNotifyHandler? = nil) {
        self.method = item.method
        self.characteristicUUID = item.characteristicUUID
        self.get = get
        self.post = post
        self.subscribe = subscribe
        self.unsubscribe = unsubscribe
        self.characteristic = CBMutableCharacteristic(type: item.characteristicUUID, properties: method.properties, value: nil, permissions: method.permissions)
    }
    
}
