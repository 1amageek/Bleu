//
//  NotifyViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/14.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreBluetooth

class NotifyViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        Bleu.removeAllReceivers()
        
        Bleu.addReceiver(Receiver(communication: NotifyUserID(), get: { [weak self] (manager, request) in
            guard let text: String = self?.peripheralTextField.text else {
                manager.respond(to: request, withResult: .attributeNotFound)
                return
            }
            request.value = text.data(using: .utf8)
            manager.respond(to: request, withResult: .success)
        }, post: nil, subscribe: { (peripheralManager, central, characteristic) in
            print("subscribe", characteristic.isNotifying, characteristic)
            self.characteristic = characteristic as? CBMutableCharacteristic
        }, unsubscribe: { (peripheralManager, central, characteristic) in
            print("unsubscribe", characteristic.isNotifying)
        }))

        Bleu.startAdvertising()
    }
    
    deinit {
        print("deinit notify ViewController")
        Bleu.stopAdvertising()
    }
    
    var characteristic: CBMutableCharacteristic?
    @IBOutlet weak var centralTextField: UITextField!
    @IBOutlet weak var peripheralTextField: UITextField!
    @IBAction func notify(_ sender: Any) {
        
        let request: Request = Request(communication: NotifyUserID()) { (peripheral, characteristic, error) in
            if let error = error {
                debugPrint(error)
                return
            }
            
            guard let data: Data = characteristic.value else {
                return
            }
            self.centralTextField.text = String(data: data, encoding: .utf8)
        }
        Bleu.send([request]) { completedRequests, error in
            print("timeout")
        }
        
    }

    @IBAction func update(_ sender: Any) {
        guard let text: String = self.peripheralTextField.text else {
            return
        }

        let data: Data = text.data(using: .utf8)!
        Bleu.updateValue(data, for: self.characteristic!, onSubscribedCentrals: nil)
    }
}
