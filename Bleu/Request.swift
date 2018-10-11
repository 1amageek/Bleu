//
//  Request.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 # Request

 Request controls CoreBluetooth's Central in a simple way.
 */
public class Request: Communicable {

    /// It is a response handler.
    public typealias ResponseHandler = ((CBPeripheral, CBCharacteristic, Error?) -> Void)

    /// CoreBluetooth service UUID
    public let serviceUUID: CBUUID

    /// Request method
    public let method: RequestMethod

    /// CoreBluetooth characteristic UUID
    public let characteristicUUID: CBUUID?

    /// CoreBluetooth characteristic UUID
    public let characteristic: CBMutableCharacteristic

    /// CoreBluetooth options
    public var options: [String: Any]?

    /// Data to send
    public var value: Data?

    /// Callback to process the received response
    public var response: ResponseHandler?

    /**
     It communicates with the server with the method defined by Communicable.

     - parameter communication: Set Communicable compliant Struct.
     - parameter response: Set the handler for the response. 
    */
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
