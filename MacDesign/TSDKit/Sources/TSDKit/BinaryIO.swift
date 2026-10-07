import Foundation

/// Little-endian reader over the raw bytes of a 2D Design file.
/// Accessors return nil rather than trapping when they would read past the end.
public struct BinaryReader {
    public let bytes: [UInt8]
    public var offset: Int = 0

    public init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    public var count: Int { bytes.count }
    public var remaining: Int { bytes.count - offset }

    public func u8(_ o: Int) -> UInt8? {
        guard o >= 0, o < bytes.count else { return nil }
        return bytes[o]
    }

    public func u16(_ o: Int) -> UInt16? {
        guard o >= 0, o + 2 <= bytes.count else { return nil }
        return UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)
    }

    public func u32(_ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[o + i]) << (8 * UInt32(i)) }
        return v
    }

    public func f64(_ o: Int) -> Double? {
        guard o >= 0, o + 8 <= bytes.count else { return nil }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
        return Double(bitPattern: bits)
    }

    /// MFC CArchive Unicode CString: FF FE FF, a length (BYTE; or FF + WORD; or FF FF FF + DWORD),
    /// then that many UTF-16LE code units. Returns the string and the offset just past it.
    public func cString(at o: Int) -> (value: String, end: Int)? {
        guard o >= 0, o + 4 <= bytes.count,
              bytes[o] == 0xFF, bytes[o + 1] == 0xFE, bytes[o + 2] == 0xFF else { return nil }
        var p = o + 3
        var length = Int(bytes[p])
        p += 1
        if length == 0xFF {
            guard let l16 = u16(p) else { return nil }
            length = Int(l16)
            p += 2
            if length == 0xFFFF {
                guard let l32 = u32(p) else { return nil }
                length = Int(l32)
                p += 4
            }
        }
        let byteLength = length * 2
        guard length >= 0, p + byteLength <= bytes.count else { return nil }
        var units = [UInt16]()
        units.reserveCapacity(length)
        for k in 0..<length {
            units.append(UInt16(bytes[p + 2 * k]) | (UInt16(bytes[p + 2 * k + 1]) << 8))
        }
        return (String(decoding: units, as: UTF16.self), p + byteLength)
    }

    /// Offsets of every CString marker (FF FE FF) in the file.
    public func cStringOffsets() -> [Int] {
        var result: [Int] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xFE && bytes[i + 2] == 0xFF {
                result.append(i)
                i += 3
            } else {
                i += 1
            }
        }
        return result
    }

    /// First index at or after `from` where `pattern` occurs.
    public func find(_ pattern: [UInt8], from: Int = 0) -> Int? {
        guard !pattern.isEmpty, pattern.count <= bytes.count else { return nil }
        var i = max(0, from)
        let last = bytes.count - pattern.count
        while i <= last {
            if bytes[i] == pattern[0] {
                var ok = true
                for k in 1..<pattern.count where bytes[i + k] != pattern[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Sequential reading

    public mutating func readU8() throws -> UInt8 {
        guard let v = u8(offset) else { throw TSDError.truncated(offset) }
        offset += 1
        return v
    }

    public mutating func readU16() throws -> UInt16 {
        guard let v = u16(offset) else { throw TSDError.truncated(offset) }
        offset += 2
        return v
    }

    public mutating func readU32() throws -> UInt32 {
        guard let v = u32(offset) else { throw TSDError.truncated(offset) }
        offset += 4
        return v
    }

    public mutating func readF64() throws -> Double {
        guard let v = f64(offset) else { throw TSDError.truncated(offset) }
        offset += 8
        return v
    }

    public mutating func readBytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= bytes.count else { throw TSDError.truncated(offset) }
        let d = Data(bytes[offset..<(offset + n)])
        offset += n
        return d
    }

    public mutating func readCString() throws -> String {
        guard let s = cString(at: offset) else { throw TSDError.unexpected("string", at: offset) }
        offset = s.end
        return s.value
    }

    public mutating func expect(_ expected: [UInt8], _ what: String) throws {
        guard offset + expected.count <= bytes.count else { throw TSDError.truncated(offset) }
        for (k, b) in expected.enumerated() where bytes[offset + k] != b {
            throw TSDError.unexpected(what, at: offset)
        }
        offset += expected.count
    }

    public func peek(_ pattern: [UInt8], at o: Int) -> Bool {
        guard o >= 0, o + pattern.count <= bytes.count else { return false }
        for (k, b) in pattern.enumerated() where bytes[o + k] != b { return false }
        return true
    }
}

/// Little-endian writer.
public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func u8(_ v: UInt8) { data.append(v) }

    public mutating func u16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8(v >> 8))
    }

    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }

    public mutating func f64(_ v: Double) {
        let bits = v.bitPattern
        for i in 0..<8 { data.append(UInt8((bits >> (8 * UInt64(i))) & 0xFF)) }
    }

    public mutating func bytes(_ b: [UInt8]) { data.append(contentsOf: b) }
    public mutating func bytes(_ d: Data) { data.append(d) }
    public mutating func zeros(_ n: Int) { data.append(Data(count: n)) }

    /// MFC Unicode CString.
    public mutating func cString(_ s: String) {
        let units = Array(s.utf16)
        bytes([0xFF, 0xFE, 0xFF])
        if units.count < 0xFF {
            u8(UInt8(units.count))
        } else if units.count < 0xFFFF {
            u8(0xFF)
            u16(UInt16(units.count))
        } else {
            bytes([0xFF, 0xFF, 0xFF])
            u32(UInt32(units.count))
        }
        for u in units { u16(u) }
    }
}

public enum TSDError: Error, LocalizedError {
    case notA2DDesignFile
    case truncated(Int)
    case unexpected(String, at: Int)
    case unknownRecordType(UInt16, at: Int)
    case unreadable(String)
    case cannotWrite(String)

    public var errorDescription: String? {
        switch self {
        case .notA2DDesignFile: return "This doesn't look like a 2D Design V3 file."
        case .truncated(let o): return "The file ends unexpectedly at byte \(o)."
        case .unexpected(let what, let o): return "Unexpected data where \(what) was expected (byte \(o))."
        case .unknownRecordType(let t, let o): return String(format: "Unknown object type 0x%02X at byte %d.", t, o)
        case .unreadable(let why): return "Couldn't read the file: \(why)"
        case .cannotWrite(let why): return "Couldn't write the file: \(why)"
        }
    }
}
