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

#### Advertising

``` Swift
Bleu.shared.addRecevier(Receiver(item: GetUserIDItem(), get: { (manager, request) in
    request.value = "hogehoge".data(using: .utf8)
    manager.respond(to: request, withResult: .success)
}))

Bleu.shared.addRecevier(Receiver(item: PostUserIDItem(), post: { (manager, requests) in
    for request: CBATTRequest in requests {
        guard let data: Data = request.value else {
            return
        }
        let text: String = String(data: data, encoding: .utf8)!
        print(text)
    }
}))
Bleu.shared.startAdvertising()
```

#### Scan

``` Swift
let request: Request = Request(item: PostUserIDItem(), allowDuplicates: true, thresholdRSSI: -28, options: nil)
request.post = { (peripheral, characteristic) in
    let data: Data = "userID".data(using: .utf8)!
    peripheral.writeValue(data, for: characteristic, type: CBCharacteristicWriteType.withResponse)
}
Bleu.shared.send(request) { (peripheral, characteristic, error) in
    // DO ANYTHING
}
```
