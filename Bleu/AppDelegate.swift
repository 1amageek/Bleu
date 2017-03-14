//
//  AppDelegate.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/13.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import UIKit
import CoreBluetooth

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?


    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {

        Bleu.addRecevier(Receiver(item: GetUserIDItem(), get: { (manager, request) in
            request.value = "wwwwwwww".data(using: .utf8)
            manager.respond(to: request, withResult: .success)
        }))
        
        Bleu.addRecevier(Receiver(item: PostUserIDItem(), post: { (manager, requests) in
            for request: CBATTRequest in requests {
                guard let data: Data = request.value else {
                    return
                }
                let www: String = String(data: data, encoding: .utf8)!
                print(www)
            }
        }))
        Bleu.startAdvertising()
        
        return true
    }

}
