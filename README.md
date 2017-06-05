<img src="https://github.com/1amageek/Bleu/blob/master/Bleu.png" width="100%">

# Bleu
Bleu is a Bluetooth library.
Bleu is the easiest way to operate CoreBluetooth.

Bleu is possible to operate by replacing Bluetooth 's `Peripheral` and `Central` with `Server` and `Client`.
Bleu can be developed event-driven.


 [![Version](http://img.shields.io/cocoapods/v/Bleu.svg)](http://cocoapods.org/?q=Bleu)
 [![Platform](http://img.shields.io/cocoapods/p/Bleu.svg)]()
 [![Awesome](https://cdn.rawgit.com/sindresorhus/awesome/d7305f38d29fed78fa85652e3a63e154dd8e8829/media/badge.svg)](https://github.com/sindresorhus/awesome)
 [![Downloads](https://img.shields.io/cocoapods/dt/Bleu.svg?label=Total%20Downloads&colorB=28B9FE)]()


## Installation

<!--
#### [Carthage](https://github.com/Carthage/Carthage)
-->

#### [CocoaPods](https://github.com/cocoapods/cocoapods)

- Insert `pod 'Bleu' ` to your Podfile.
- Run `pod install`.

Note: CocoaPods 1.1.0 is required to install Bleu.
 
## Usage

Please customize `Communicable+.swift`.

``` shell
uuidgen // create uuid
```

``` Swift
extension Communicable {
    
    public var serviceUUID: CBUUID {
        return CBUUID(string: "YOUR UUID")
    }
    
}

struct GetUserIDItem: Communicable {
    
    public var method: RequestMethod {
        return .get(isNotified: false)
    }
    
    public var characteristicUUID: CBUUID {
        return CBUUID(string: "YOUR UUID")
    }
    
}

struct PostUserIDItem: Communicable {
    
    public var method: RequestMethod {
        return .post
    }
    
    public var characteristicUUID: CBUUID {
        return CBUUID(string: "YOUR UUID")
    }
    
}

```


### 😃 Get

#### Peripheral(Server)
``` Swift
Bleu.addReceiver(Receiver(GetUserID(), get: { [weak self] (manager, request) in
    guard let text: String = self?.textField.text else {
        manager.respond(to: request, withResult: .attributeNotFound)
        return
    }
    request.value = text.data(using: .utf8)
    manager.respond(to: request, withResult: .success)
}))

Bleu.startAdvertising()
```

#### Central(Client)
``` Swift
let request: Request = Request(communication: GetUserID()) { [weak self] (peripheral, characteristic, error) in
    if let error = error {
        debugPrint(error)
        return
    }
    
    let data: Data = characteristic.value!
    let text: String = String(data: data, encoding: .utf8)!
    
    self?.centralTextField.text = text
}
Bleu.send([request]) { completedRequests, error in
    if let error = error {
        print("timeout")
    }
}
```

### 😃 Post 

#### Peripheral(Server)
``` Swift
Bleu.addReceiver(Receiver(PostUserID(), post: { (manager, request) in
    let data: Data = request.value!
    let text: String = String(data: data, encoding: .utf8)!
    print(text)
    manager.respond(to: request, withResult: .success)
}))

Bleu.startAdvertising()
```

#### Central(Client)
``` Swift
let data: Data = "Sample".data(using: .utf8)!
let request: Request = Request(communication: PostUserID()) { (peripheral, characteristic, error) in
    if let error = error {
        debugPrint(error)
        return
    }
    
    print("success")
}
request.value = data
Bleu.send([request]) { completedRequests, error in
    if let error = error {
        print("timeout")
    }
}
```
