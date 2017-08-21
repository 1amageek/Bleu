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

    var beacon: Beacon?

    @IBAction func publishChannel(_ sender: Any) {

        Bleu.publishL2CAPChannel(withEncryption: false) { (peripheralManager, psm) in
            self.psmLabel.text = String(psm)
            }.didOpenChannel { (streamer) in
                let outputStream: OutputStream = OutputStream(toMemory: ())
                self.streamer = streamer
                streamer.outputStream = outputStream
                streamer.received({ (error) in
                    print("!!!!!!!!!!!!!!!!!!!!!!!!")
                    if let error = error {
                        debugPrint(error)
                        return
                    }
                    guard let data: Data = outputStream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else {
                        return
                    }
                    let image: UIImage = UIImage(data: data)!
                    self.imageView.image = image
                    self.imageView.setNeedsDisplay()
                }).open()
            }.onError { (error) in
                print(error)
        }
    }

    @IBOutlet weak var imageView: UIImageView!
    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var psmLabel: UILabel!

    var psm: CBL2CAPPSM?

    var radar: Radar?

    var channel: CBL2CAPChannel?

    var peripheral: CBPeripheral?

    var streamer: Streamer?

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
            self.psm = psm
        }
        Bleu.send([request]) { completedRequests, error in
            if error != nil {
                print("timeout")
            }
            print("!!!!!!!!!!!!!!!!!!!!!!!!")
            guard let psm: CBL2CAPPSM = self.psm else { return }
            let radar: Radar = Radar(psm: psm, options: Radar.Options())
            self.radar = radar
            radar.didOpenChannelBlock = { streamer, error in
                if let error = error {
                    print("!!!!!" , error)
                    return
                }
                print(streamer!)
                self.streamer = streamer
                let image: UIImage = #imageLiteral(resourceName: "Bleu")
                let data: Data = UIImagePNGRepresentation(image)!
                let inputStream: InputStream = InputStream(data: data)
                streamer?.inputStream = inputStream
                streamer?.sended({ (error) in
                    print("!!!!!!SENDED!!!!!!!!!!!!!!!!!")
                    if let error = error {
                        debugPrint(error)
                        return
                    }
                }).open()
            }
            radar.resume()

//            Bleu.openL2CAPChannel(psm, didOpenChannelBlock: { (streamer, error) in
//                if let error = error {
//                    print("!!!!!" , error)
//                    return
//                }
//                self.streamer = streamer
//                streamer?.open()
//            })

        }

    }
    
    @IBAction func checkAction(_ sender: Any) {
//        print(self.radar)
//        print(self.radar?.streamer)
//        print(self.radar?.streamer?.channel)
//        print(self.radar?.streamer?.channel.outputStream.streamStatus)
//        print(self.radar?.streamer?.channel.outputStream.streamError)
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        print("Event !!", eventCode)
    }

}
