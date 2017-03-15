//
//  ViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreBluetooth

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    @IBAction func action(_ sender: Any) {        
        let request: Request = Request(item: PostUserID(), allowDuplicates: true, thresholdRSSI: -28, options: nil)
        request.post = { (peripheral, characteristic) in
            let data: Data = "userID".data(using: .utf8)!
            peripheral.writeValue(data, for: characteristic, type: CBCharacteristicWriteType.withResponse)
        }
        Bleu.send(request) { (peripheral, characteristic, error) in
            print("!!!", peripheral)
        }
    }

}
