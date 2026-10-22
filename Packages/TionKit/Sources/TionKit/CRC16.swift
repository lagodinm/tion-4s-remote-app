/// CRC-16/CCITT-FALSE (polynomial 0x1021, initial value 0xFFFF), the checksum used by
/// Tion's BLE protocol.
public enum CRC16 {
    public static func ccittFalse<C: Collection>(_ bytes: C, initial: UInt16 = 0xFFFF) -> UInt16 where C.Element == UInt8 {
        var crc = initial
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
