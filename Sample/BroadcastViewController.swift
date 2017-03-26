//
//  BroadcastViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/15.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit

class BroadcastViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        Bleu.removeAllReceivers()
    
        Bleu.addReceiver(Receiver(communication: BroadcastUserID(), get: { (manager, request) in
            request.value = "aaaaaaaaaaaa".data(using: .utf8)
            manager.respond(to: request, withResult: .success)
        }))
        
        Bleu.startAdvertising()
    }
    
    deinit {
        print("deinit notify ViewController")
        Bleu.stopAdvertising()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

    @IBOutlet weak var centralTextField: UITextField!
    @IBOutlet weak var peripheralTextField: UITextField!

    @IBAction func scan(_ sender: Any) {
        
        let request: Request = Request(communication: BroadcastUserID()) { (peripheral, characteristic, error) in
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
}
