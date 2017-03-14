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

        Bleu.removeAllRequests()
        Bleu.removeAllReceivers()
        
//        Bleu.addRecevier(Receiver(GetUserID(), get: { [weak self] (manager, request) in
//            guard let text: String = self?.peripheralTextField.text else {
//                manager.respond(to: request, withResult: .attributeNotFound)
//                return
//            }
//            request.value = text.data(using: .utf8)
//            manager.respond(to: request, withResult: .success)
//        }))
        

        Bleu.addRecevier(Receiver(PostUserID(), post: { [weak self] (manager, request) in
            let data: Data = request.value!
            let text: String = String(data: data, encoding: .utf8)!
            self?.peripheralTextField.text = text
            manager.respond(to: request, withResult: .success)
        }))
        
        Bleu.startAdvertising()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    @IBOutlet weak var centralTextField: UITextField!
    @IBOutlet weak var peripheralTextField: UITextField!

    @IBAction func post(_ sender: Any) {
        
        let request: Request = Request(item: PostUserID())
        request.post = { [weak self] (peripheral, characteristic) in
            guard let text: String = self?.centralTextField.text else {
                return
            }
            let data: Data = text.data(using: .utf8)!
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
        Bleu.send(request) { (peripheral, characteristic, error) in
            
            if let error = error {
                debugPrint(error)
                return
            }
            
            print("success")
            Bleu.cancelRequests()
        }
        
    }
}
