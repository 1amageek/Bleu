//
//  Streamer.swift
//  Bleu
//
//  Created by 1amageek on 2017/06/11.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

public class Streamer: NSObject {

    public enum StreamError: Error {
        case sendControllerReadFileStreamError
        case sendControllerOutputStreamError
        case receiveControllerWriteFileStreamError
        case receiveControllerInputStreamError
        case streamError
    }

    static let sendBufferSize: Int = 2035

    private(set) var channel: CBL2CAPChannel

    private(set) var peripheralManager: CBPeripheralManager?

    private(set) var peripheral: CBPeripheral?

    private let _sendController: SendController

    private let _receiveController: ReceiveController

    var psm: CBL2CAPPSM {
        return channel.psm
    }

    var inputStream: InputStream? {
        set {
            self._sendController.fileStream = newValue
        }
        get {
            return self._sendController.fileStream
        }
    }

    var outputStream: OutputStream? {
        set {
            self._receiveController.fileStream = newValue
        }
        get {
            return self._receiveController.fileStream
        }
    }

    init(channel: CBL2CAPChannel, peripheralManager: CBPeripheralManager) {
        self.channel = channel
        self.peripheralManager = peripheralManager
        self._sendController = SendController(channel)
        self._receiveController = ReceiveController(channel)
        super.init()
    }

    init(channel: CBL2CAPChannel, peripheral: CBPeripheral) {
        self.channel = channel
        self.peripheral = peripheral
        self._sendController = SendController(channel)
        self._receiveController = ReceiveController(channel)
        super.init()
    }

    @discardableResult
    public func sended(_ block: @escaping (Error?) -> Void) -> Self {
        _sendController.completionBlock = block
        return self
    }

    @discardableResult
    public func received(_ block: @escaping (Error?) -> Void) -> Self {
        _receiveController.completionBlock = block
        return self
    }

    func open() {
        self._sendController.open()
        self._receiveController.open()
    }

    func close() {
        self._sendController.close()
        self._receiveController.close()
    }
}

private class SendController: NSObject, StreamDelegate {

    let channel: CBL2CAPChannel

    private var _buffer: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Streamer.sendBufferSize)

    private var _bufferOffset: Int = 0

    private var _bufferLimit: Int = 0

    var outputStream: OutputStream {
        return channel.outputStream
    }

    var fileStream: InputStream?

    var completionBlock: ((Error?) -> Void)?

    init(_ channel: CBL2CAPChannel) {
        self.channel = channel
        super.init()
    }

    // MARK: - StreamDelegate

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        switch eventCode {
        case [.openCompleted]: print("openCompleted")
        case [.hasSpaceAvailable]:

            if _bufferOffset == _bufferLimit {
                let bytesRead: Int = (self.fileStream!.read(_buffer, maxLength: Streamer.sendBufferSize))
                print("hasSpaceAvailable", bytesRead)
                if bytesRead == -1 {
                    _stop(.sendControllerReadFileStreamError)
                } else if bytesRead == 0 {
                    _stop()
                } else {
                    _bufferOffset = 0
                    _bufferLimit = bytesRead
                }
            }

            if _bufferOffset != _bufferLimit {
                print(_buffer.pointee, _bufferLimit, _bufferOffset)
                let bytesWritten: Int = self.outputStream.write(&_buffer[_bufferOffset], maxLength: _bufferLimit - _bufferOffset)
                if bytesWritten == -1 {
                    _stop(.sendControllerOutputStreamError)
                } else {
                    _bufferOffset += bytesWritten
                }
            }

        case [.errorOccurred]:
            _stop(.streamError)
        default: break
        }
    }

    public func open() {
        guard let fileStream: InputStream = self.fileStream else {
            debugPrint("[Bleu Streamer.SendController] The file to be sent is not set.")
            return
        }
        fileStream.open()
        channel.outputStream.delegate = self
        channel.outputStream.schedule(in: .current, forMode: .defaultRunLoopMode)
        channel.outputStream.open()
    }

    public func close() {
        fileStream?.close()
        fileStream = nil
        channel.outputStream.delegate = nil
        channel.outputStream.remove(from: .current, forMode: .defaultRunLoopMode)
        channel.outputStream.close()
    }

    private func _stop(_ error: Streamer.StreamError? = nil) {
        print("Stop!!!!!!")
        completionBlock?(error)
        close()
    }
}

private class ReceiveController: NSObject, StreamDelegate {

    let channel: CBL2CAPChannel

    private var _buffer: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Streamer.sendBufferSize)

    private var _bufferOffset: Int = 0

    private var _bufferLimit: Int = 0

    var inputStream: InputStream {
        return channel.inputStream
    }

    var fileStream: OutputStream?

    var completionBlock: ((Error?) -> Void)?

    init(_ channel: CBL2CAPChannel) {
        self.channel = channel
        super.init()
    }
    public func open() {

        guard let fileStreame: OutputStream = self.fileStream else {
            debugPrint("[Bleu Streamer.SendController] A outputStream for receive is not set.")
            return
        }
        fileStreame.open()
        channel.inputStream.delegate = self
        channel.inputStream.schedule(in: .current, forMode: .defaultRunLoopMode)
        channel.inputStream.open()
    }

    public func close() {
        fileStream?.close()
        fileStream = nil
        channel.inputStream.delegate = nil
        channel.inputStream.remove(from: .current, forMode: .defaultRunLoopMode)
        channel.inputStream.close()
    }

    // MARK: - StreamDelegate

    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {

        print(eventCode)
        switch eventCode {
        case [.hasBytesAvailable]:
            let bytesRead: Int = self.inputStream.read(_buffer, maxLength: Streamer.sendBufferSize)
            print("hasBytesAvailable", bytesRead, Streamer.sendBufferSize) // データを受信
            if bytesRead == -1 {
                _stop(.receiveControllerInputStreamError)
            } else if bytesRead == 0 {
                _stop()
            } else {
                var bytesWrittenSoFar: Int = 0
                repeat {
                    let bytesWritten: Int = self.fileStream!.write(&_buffer[bytesWrittenSoFar], maxLength: bytesRead - bytesWrittenSoFar)
                    if bytesWritten == -1 {
                        _stop(.receiveControllerWriteFileStreamError)
                        break
                    } else {
                        bytesWrittenSoFar += bytesWritten
                    }
                } while bytesWrittenSoFar != bytesRead
            }
        case [.endEncountered]:
            print("endEncountered")
            _stop()
        case [.errorOccurred]:
            _stop(.streamError)
        default: break
        }
    }

    private func _stop(_ error: Streamer.StreamError? = nil) {
        print("Stop!!!!!!")
        completionBlock?(error)
        close()
    }
}
