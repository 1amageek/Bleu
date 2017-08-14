//
//  L2CAPViewController.swift
//  Sample
//
//  Created by 1amageek on 2017/06/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreBluetooth

class L2CAPViewController: UIViewController, StreamDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()
        Bleu.removeAllReceivers()

        Bleu.addReceiver(Receiver(communication: GetUserID(), get: { [weak self] (manager, request) in
            guard let text: String = self?.psmLabel.text else {
                manager.respond(to: request, withResult: .attributeNotFound)
                return
            }
            request.value = text.data(using: .utf8)
            manager.respond(to: request, withResult: .success)
        }))

        Bleu.startAdvertising()
    }
    @IBAction func publishChannel(_ sender: Any) {
        Bleu.publishL2CAPChannel(withEncryption: false) { (peripheral, psm, error) in
            if let error = error {
                debugPrint(error)
                return
            }
            self.psmLabel.text = String(psm)
        }
    }

    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var psmLabel: UILabel!

    @IBAction func openChannel(_ sender: Any) {

        let request: Request = Request(communication: GetUserID()) { (peripheral, characteristic, error) in
            if let error = error {
                debugPrint(error)
                return
            }

            let data: Data = characteristic.value!
            let text: String = String(data: data, encoding: .utf8)!
            self.textField.text = text
            let psm: CBL2CAPPSM = CBL2CAPPSM(text)!
            let request: Request = Request(communication: L2CAPID(), PSM: psm)

            let streamer: Streamer = Bleu.openL2CAPChannel(request) { (peripheralRequests, error) in
                if let error = error {
                    debugPrint(error)
                    return
                }
                print("!!!!!!Completed", peripheralRequests)
            }
            streamer.didOpenChannelBlock = { (peripheral, channel, error) in
                if let error = error {
                    debugPrint(error)
                    return
                }
                channel?.outputStream.delegate = self
                channel?.inputStream.delegate = self
                print("Did Open !!!!")
                print("Input !", channel?.inputStream)
                print("Output!", channel?.outputStream)
                let runloop: RunLoop = RunLoop.current
                channel?.outputStream.schedule(in: runloop, forMode: RunLoopMode.defaultRunLoopMode)
                channel?.outputStream.open()
            }
            streamer.on({ (steam, event) in

            })
        }
        Bleu.send([request]) { completedRequests, error in
            if error != nil {
                print("timeout")
            }
        }

    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Event !!", eventCode)
    }

}
