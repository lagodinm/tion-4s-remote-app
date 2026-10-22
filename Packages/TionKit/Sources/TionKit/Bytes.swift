import Foundation

extension FixedWidthInteger {
    /// The value's bytes, least significant first.
    public var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

extension Array where Element == UInt8 {
    /// Reads a little-endian integer of type `T` starting at `offset`.
    public func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: self[offset + index]) << (8 * index)
        }
        return value
    }

    /// Space-separated uppercase hex, e.g. `"80 10 00 3A"`.
    public var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Parses hex text such as `"80 10 00 3A"` or `"8010003A"`.
    public init?(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}

public enum TionProtocolError: Error, Equatable {
    case packetTooShort(Int)
    case badMagic(UInt8)
    case badLength(declared: Int, actual: Int)
    case payloadTooShort(expected: Int, actual: Int)
}
