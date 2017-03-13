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
    
    public typealias ReceivePostHandler = ((CBPeripheralManager, [CBATTRequest]) -> Void)
    
    public let method: RequestMethod
    
    public let characteristicUUID: CBUUID
    
    public let characteristic: CBMutableCharacteristic
    
    public var get: ReceiveGetHandler?
    
    public var post: ReceivePostHandler?
    
    public init<T: Communicable>(item: T, get: ReceiveGetHandler? = nil, post: ReceivePostHandler? = nil) {
        self.method = item.method
        self.characteristicUUID = item.characteristicUUID
        self.characteristic = item.characteristic
        self.get = get
        self.post = post
    }
    
}
