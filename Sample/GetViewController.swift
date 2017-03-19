//
//  GetViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/14.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit

class GetViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        Bleu.removeAllRequests()
        Bleu.removeAllReceivers()
        
        Bleu.addRecevier(Receiver(GetUserID(), get: { [weak self] (manager, request) in
            guard let text: String = self?.peripheralTextField.text else {
                manager.respond(to: request, withResult: .attributeNotFound)
                return
            }
            request.value = text.data(using: .utf8)
            manager.respond(to: request, withResult: .success)
        }))
        Bleu.startAdvertising()
    }
    
    deinit {
        print("deinit get ViewController")
        Bleu.stopAdvertising()
        Bleu.cancelRequests()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @IBOutlet weak var centralTextField: UITextField!
    @IBOutlet weak var peripheralTextField: UITextField!

    @IBAction func get(_ sender: Any) {
        
        let request: Request = Request(item: GetUserID())
        Bleu.send(request) { [weak self] (peripheral, characteristic, error) in
            
            if let error = error {
                debugPrint(error)
                return
            }
            
            let data: Data = characteristic.value!
            let text: String = String(data: data, encoding: .utf8)!
            
            self?.centralTextField.text = text
        }
        
    }
}
