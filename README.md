<img src="https://github.com/1amageek/Bleu/blob/master/Bleu.png" width="400px">

# Bleu
BLE for U🎁

 [![Version](http://img.shields.io/cocoapods/v/Bleu.svg)](http://cocoapods.org/?q=PaperKit)
 [![Platform](http://img.shields.io/cocoapods/p/Bleu.svg)]()


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
        return .get
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
Bleu.addRecevier(Receiver(GetUserID(), get: { [weak self] (manager, request) in
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
Bleu.addRecevier(Receiver(PostUserID(), post: { (manager, request) in
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
