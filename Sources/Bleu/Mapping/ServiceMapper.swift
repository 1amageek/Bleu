import Foundation

/// Builds the single BLE service surface used by the distributed actor runtime.
enum ServiceMapper {
    static func createServiceMetadata<T: PeripheralActor>(
        from type: T.Type,
        actorID: UUID? = nil
    ) -> ServiceMetadata {
        ServiceMetadata(
            uuid: UUID.serviceUUID(for: type),
            isPrimary: true,
            characteristics: [
                CharacteristicMetadata(
                    uuid: UUID.characteristicUUID(for: "__actor_id__", in: type),
                    properties: [.read],
                    permissions: [.readable],
                    value: actorID?.data
                ),
                CharacteristicMetadata(
                    uuid: UUID.characteristicUUID(for: "__rpc__", in: type),
                    properties: [.write, .notify],
                    permissions: [.writeable, .readable]
                )
            ]
        )
    }
}
