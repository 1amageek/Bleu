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
    public var characteristicUUID: CBUUID?

    /// CoreBluetooth characteristic
    public var characteristic: CBMutableCharacteristic?

    /// CoreBluetooth options
    public var options: [String: Any]?

    /// Data to send
    public var value: Data?

    /// Callback to process the received response
    public var response: ResponseHandler?

    ///
    private(set) var PSM: CBL2CAPPSM?

    public init<T: Communicable>(communication: T) {
        self.serviceUUID = communication.serviceUUID
        self.method = communication.method
    }

    /**
     It communicates with the server with the method defined by Communicable.

     - parameter communication: Set Communicable compliant Struct.
     - parameter response: Set the handler for the response. 
    */
    public convenience init<T: Communicable>(communication: T, response: @escaping ResponseHandler) {
        self.init(communication: communication)
        self.response = response
        self.characteristicUUID = communication.characteristicUUID
        self.characteristic = CBMutableCharacteristic(type: communication.characteristicUUID!,
                                                      properties: method.properties,
                                                      value: communication.value,
                                                      permissions: method.permissions)
    }

    /**
     It communicates with the server with the method defined by Communicable.

     - parameter communication: Set Communicable compliant Struct.
     - parameter PSM: Set channel PSM
     */
    public convenience init<T: Communicable>(communication: T, PSM: CBL2CAPPSM) {
        self.init(communication: communication)
        self.PSM = PSM
    }
}
