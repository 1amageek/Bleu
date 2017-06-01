//
//  Communicable.swift
//  Bleu
//
//  Created by 1amageek on 2017/01/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 RequestMethod simplifies `CBCharacteristicProperties`.
 */
public enum RequestMethod {

    /// Set to receive data from the device to communicate. If you set it to true, you can get notification of value change.
    case get(isNotified: Bool)

    /// Set to transmit data.
    case post

    /// Set to receive data from the device to communicate. If you set it to true, you can get notification of value change.
    case broadcast(isNotified: Bool)

    /// Returns `CBCharacteristicProperties` of CoreBluetooth.
    var properties: CBCharacteristicProperties {
        switch self {
        case .get(let isNotify):
            if isNotify { return [.read, .notify] }
            return .read
        case .post: return .write
        case .broadcast(let isNotify):
            if isNotify { return [.read, .notify, .broadcast] }
            return [.read, .broadcast]
        }
    }

    /// Returns `CBAttributePermissions` of CoreBluetooth.
    var permissions: CBAttributePermissions {
        switch self {
        case .get: return .readable
        case .post: return .writeable
        case .broadcast: return .readable
        }
    }
}

/**
 This is a protocol for communicating with Bleu.
 */
public protocol Communicable: Hashable {

    /// Service UUID
    var serviceUUID: CBUUID { get }

    /// Set the type of communication.
    var method: RequestMethod { get }

    /// Data to send
    var value: Data? { get }

    /// CoreBluetooth characteristic UUID
    var characteristicUUID: CBUUID? { get }

    /// CoreBluetooth characteristic
    var characteristic: CBMutableCharacteristic { get }
}

extension Communicable {

    public var method: RequestMethod {
        return .get(isNotified: false)
    }

    public var value: Data? {
        return nil
    }

    public var hashValue: Int {
        guard let characteristicUUID: CBUUID = self.characteristicUUID else {
            fatalError("*** Error: characteristicUUID must be defined for Communicable.")
        }
        return characteristicUUID.hash
    }

    public var characteristic: CBMutableCharacteristic {
        return CBMutableCharacteristic(type: self.characteristicUUID!, properties: self.method.properties, value: nil, permissions: self.method.permissions)
    }
}

public func == <T: Communicable>(lhs: T, rhs: T) -> Bool {
    return lhs.characteristicUUID == rhs.characteristicUUID
}
