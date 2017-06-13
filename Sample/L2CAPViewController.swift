//
//  L2CAPViewController.swift
//  Sample
//
//  Created by 1amageek on 2017/06/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreBluetooth

class L2CAPViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        Bleu.removeAllReceivers()

        Bleu.addReceiver(Receiver(communication: L2CAPID(), get: { [weak self] (manager, request) in

        }))
        Bleu.startAdvertising()
    }
    @IBAction func publishChannel(_ sender: Any) {
        if #available(iOS 11.0, *) {
            Bleu.publishL2CAPChannel(withEncryption: false) { (peripheral, psm, error) in
                if let error = error {
                    debugPrint(error)
                    return
                }
                self.psmLabel.text = String(psm)
            }
        }
    }

    @IBOutlet weak var textField: UITextField!
    @IBOutlet weak var psmLabel: UILabel!
    
    @available(iOS 11.0, *)
    @IBAction func openChannel(_ sender: Any) {
        guard let psmStr: String = self.textField.text else {
            return
        }
        let psm: CBL2CAPPSM = CBL2CAPPSM(psmStr)!
        let request: Request = Request(communication: L2CAPID(), PSM: psm)
        Bleu.openL2CAPChannel(request) { (pheripheral, error) in

        }
    }
}
