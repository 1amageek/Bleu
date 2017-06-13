//
//  L2CAPViewController.swift
//  Sample
//
//  Created by 1amageek on 2017/06/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit

class L2CAPViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
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
    
    @IBAction func openChannel(_ sender: Any) {
        
    }
}
