//
//  Communicable+.swift
//  Antenna
//
//  Created by 1amageek on 2017/01/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

extension Communicable {
    
    public var serviceUUID: CBUUID {
        return CBUUID(string: "D417C187-D6A0-440B-BB88-B86512966007")
    }
    
}

struct GetUserID: Communicable {
    
    public var method: RequestMethod {
        return .get(isNotified: false)
    }
    
    public var characteristicUUID: CBUUID? {
        return CBUUID(string: "BC9E790A-5682-4B4E-9366-E81BB97107A1")
    }
    
}

struct PostUserID: Communicable {
    
    public var method: RequestMethod {
        return .post
    }
    
    public var characteristicUUID: CBUUID? {
        return CBUUID(string: "55B59CD5-8B59-4BA8-9050-AA4B2320294F")
    }
    
}

struct NotifyUserID: Communicable {
    
    public var method: RequestMethod {
        return .get(isNotified: true)
    }
    
    public var characteristicUUID: CBUUID? {
        return CBUUID(string: "282F7AD3-A1AC-4DB3-AE2D-95BB85832375")
    }
    
}

struct BroadcastUserID: Communicable {
    
//    public var value: Data? {
//        return "hogehoge".data(using: .utf8)
//    }
    
    public var method: RequestMethod {
        return .broadcast(isNotified: false)
    }
    
    public var characteristicUUID: CBUUID? {
        return CBUUID(string: "41F1FC10-F332-4581-9C30-876C6A4EF7A7")
    }
    
}
