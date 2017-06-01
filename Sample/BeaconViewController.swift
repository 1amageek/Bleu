//
//  BeaconViewController.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/20.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreLocation

class BeaconViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let uuid: UUID = UUID(uuidString: "97D52D26-CF3E-4FF0-9456-2D39D98F6E78")!
        let beaconRegion: CLBeaconRegion = CLBeaconRegion(proximityUUID: uuid, major: 0, minor: 0, identifier: "bleu.beacon")
        
        _ = beaconRegion.peripheralData(withMeasuredPower: nil)
        
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

}
