//
//  Streamer.swift
//  Bleu
//
//  Created by 1amageek on 2017/06/11.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Streamer: NSObject, StreamDelegate {

    private(set) var channel: CBL2CAPChannel

    private(set) var peripheralManager: CBPeripheralManager?

    private(set) var peripheral: CBPeripheral?

    var psm: CBL2CAPPSM {
        return channel.psm
    }

    var outputStream: OutputStream {
        return channel.outputStream
    }

    var inputStream: InputStream {
        return channel.inputStream
    }

    init(channel: CBL2CAPChannel, peripheralManager: CBPeripheralManager) {
        self.channel = channel
        self.peripheralManager = peripheralManager
        super.init()
        channel.outputStream.delegate = self
        channel.inputStream.delegate = self
        channel.outputStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
        channel.inputStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
    }

    init(channel: CBL2CAPChannel, peripheral: CBPeripheral) {
        self.channel = channel
        self.peripheral = peripheral
        super.init()
        channel.outputStream.delegate = self
        channel.inputStream.delegate = self
        channel.outputStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
        channel.inputStream.schedule(in: RunLoop.current, forMode: .defaultRunLoopMode)
    }

    public func open() {
        channel.outputStream.open()
        channel.inputStream.open()
    }

    // MARK: - StreamDelegate

    private var _outputStreamHandler: ((Stream, Stream.Event) -> Void)?

    private var _inputStreamHandler: ((Stream, Stream.Event) -> Void)?

    public func output(_ handler: @escaping (Stream, Stream.Event) -> Void) {
        self._outputStreamHandler = handler
    }

    public func input(_ handler: @escaping (Stream, Stream.Event) -> Void) {
        self._inputStreamHandler = handler
    }

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        print("Event !!", aStream, eventCode)
        if aStream is InputStream {
            self._inputStreamHandler?(aStream, eventCode)
        } else {
            self._outputStreamHandler?(aStream, eventCode)
            switch eventCode {
            case [.openCompleted]: print("openCompleted")
            case [.endEncountered]: print("endEncountered")
            case [.hasBytesAvailable]: print("hasBytesAvailable")
            case [.hasSpaceAvailable]: print("hasSpaceAvailable")
            case [.errorOccurred]: print("errorOccurred")
            default: break
            }
        }



    }
}
