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

    static let sendBufferSize: Int = 65535

    private(set) var channel: CBL2CAPChannel

    private(set) var peripheralManager: CBPeripheralManager?

    private(set) var peripheral: CBPeripheral?

    var psm: CBL2CAPPSM {
        return channel.psm
    }

    var fileStream: InputStream?

    var outputStream: OutputStream {
        return channel.outputStream
    }

    var inputStream: InputStream {
        return channel.inputStream
    }

    private var _buffer: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: Streamer.sendBufferSize)

    private var _bufferOffset: Int = 0

    private var _bufferLimit: Int = 0

    init(channel: CBL2CAPChannel, peripheralManager: CBPeripheralManager) {
        self.channel = channel
        self.peripheralManager = peripheralManager
        super.init()

    }

    init(channel: CBL2CAPChannel, peripheral: CBPeripheral) {
        self.channel = channel
        self.peripheral = peripheral
        super.init()
    }

    public func open() {
        guard let fileStream: InputStream = self.fileStream else {
            debugPrint("[Bleu Streamer] The file to be sent is not set.")
            return
        }
        fileStream.open()
        channel.outputStream.delegate = self
        channel.inputStream.delegate = self
        channel.outputStream.schedule(in: .current, forMode: .defaultRunLoopMode)
        channel.inputStream.schedule(in: .current, forMode: .defaultRunLoopMode)
        channel.outputStream.open()
        channel.inputStream.open()
    }

    public func close() {
        fileStream?.close()
        channel.outputStream.delegate = nil
        channel.inputStream.delegate = nil
        channel.outputStream.remove(from: .current, forMode: .defaultRunLoopMode)
        channel.inputStream.remove(from: .current, forMode: .defaultRunLoopMode)
        channel.outputStream.close()
        channel.inputStream.close()
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
        if aStream == self.inputStream {
            self._inputStreamHandler?(aStream, eventCode)
            switch eventCode {
            case [.openCompleted]: print("openCompleted")
            case [.endEncountered]: print("endEncountered")
            case [.hasBytesAvailable]: print("hasBytesAvailable") // データを受信
            case [.errorOccurred]: print("errorOccurred")
            default: break
            }
        } else if aStream == self.outputStream {
            self._outputStreamHandler?(aStream, eventCode)
            switch eventCode {
            case [.openCompleted]: print("openCompleted")
            case [.endEncountered]: print("endEncountered")
            case [.hasBytesAvailable]: print("hasBytesAvailable")
            case [.hasSpaceAvailable]:
                print("hasSpaceAvailable")

                if _bufferOffset == _bufferLimit {
                    let bytesRead: Int = (self.fileStream!.read(_buffer, maxLength: Streamer.sendBufferSize))
                    if bytesRead == -1 {
                        debugPrint("error bytesRead")
                        _stop()
                    } else if bytesRead == 0 {
                        _stop()
                    } else {
                        _bufferOffset = 0
                        _bufferLimit = bytesRead
                    }
                }

                if _bufferOffset != _bufferLimit {
                    let bytesWritten: Int = self.outputStream.write(&_buffer[_bufferOffset], maxLength: _bufferLimit - _bufferOffset)
                    if bytesWritten == -1 {
                        debugPrint("error bytesWritteh")
                        _stop()
                    } else {
                        _bufferOffset += bytesWritten
                    }
                }

            case [.errorOccurred]: print("errorOccurred")
            default: break
            }
        }
    }

    private func _stop() {
        print("[Bleu Streamer] Stop")
        close()
    }

}
