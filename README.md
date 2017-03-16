<img src="https://github.com/1amageek/Bleu/blob/master/Bleu.png" width="400px">

# Bleu
BLE for U🎁

## Usage

Please customize `Communicable+.swift`.

``` shell
uuidgen // create uuid
```

``` Swift
extension BLEService {
    
    public var serviceUUID: CBUUID {
        return CBUUID(string: "4E6C6189-D06B-4835-8F3B-F5CBC36560FB")
    }
    
}

struct GetUserIDItem: Communicable {
    
    public var method: RequestMethod {
        return .get
    }
    
    public var characteristicUUID: CBUUID {
        return CBUUID(string: "BC9E790A-5682-4B4E-9366-E81BB97107A1")
    }
    
}

struct PostUserIDItem: Communicable {
    
    public var method: RequestMethod {
        return .post
    }
    
    public var characteristicUUID: CBUUID {
        return CBUUID(string: "55B59CD5-8B59-4BA8-9050-AA4B2320294F")
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
let request: Request = Request(item: GetUserID())
Bleu.send(request) { (peripheral, characteristic, error) in
    
    if let error = error {
        debugPrint(error)
        return
    }
    
    let data: Data = characteristic.value!
    let text: String = String(data: data, encoding: .utf8)!
    print(text)
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
let data: Data = "sample".data(using: .utf8)!
let request: Request = Request(item: PostUserID())
request.value = data
Bleu.send(request) { (peripheral, characteristic, error) in
    
    if let error = error {
        debugPrint(error)
        return
    }
    
    print("success")
}
```
