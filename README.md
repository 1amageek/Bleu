# Bleu
BLE for U🎁

## Usage

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
