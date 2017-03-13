//
//  Communicable.swift
//  Antenna
//
//  Created by 1amageek on 2017/01/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public enum RequestMethod {
    case get
    case post
    case notify
    
    var property: CBCharacteristicProperties {
        switch self {
        case .get: return .read
        case .post: return .write
        case .notify: return .notify
        }
    }
    
    var permission: CBAttributePermissions {
        switch self {
        case .get: return .readable
        case .post: return .writeable
        case .notify: return .writeable
        }
    }
}

public protocol BLEService {
    
    var serviceUUID: CBUUID { get }
    
}

public protocol Communicable: BLEService, Hashable {
    
    var method: RequestMethod { get }
    
    var characteristicUUID: CBUUID { get }
    
    var characteristic: CBMutableCharacteristic { get }
    
}

extension Communicable {
    
    public var hashValue: Int {
        return self.characteristicUUID.hash
    }
    
    public var characteristic: CBMutableCharacteristic {
        return CBMutableCharacteristic(type: self.characteristicUUID, properties: self.method.property, value: nil, permissions: self.method.permission)
    }
    
}

public func == <T: Communicable>(lhs: T, rhs: T) -> Bool {
    return lhs.characteristicUUID == rhs.characteristicUUID
}
