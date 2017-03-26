//
//  PostViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/14.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit

class PostViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        Bleu.removeAllReceivers()
        Bleu.addReceiver(Receiver(communication: PostUserID(), post: { [weak self] (manager, request) in
            let data: Data = request.value!
            let text: String = String(data: data, encoding: .utf8)!
            self?.peripheralTextField.text = text
            manager.respond(to: request, withResult: .success)
        }))
        
        Bleu.startAdvertising()
    }
    
    deinit {
        print("deinit post ViewController")
        Bleu.stopAdvertising()
    }


    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @IBOutlet weak var centralTextField: UITextField!
    @IBOutlet weak var peripheralTextField: UITextField!

    @IBAction func post(_ sender: Any) {
        guard let text: String = self.centralTextField.text else {
            return
        }
        let data: Data = text.data(using: .utf8)!
        let request: Request = Request(communication: PostUserID()) { (peripheral, characteristic, error) in
            if let error = error {
                debugPrint(error)
                return
            }
            
            print("success")
        }
        request.value = data
        Bleu.send([request]) { completedRequests, error in
            print("timeout")
        }
    }
}
