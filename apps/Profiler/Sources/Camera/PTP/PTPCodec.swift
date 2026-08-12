import Foundation

enum PTPError: Error, LocalizedError {
    case truncated(needed: Int, available: Int)
    case badContainer(String)
    case deviceResponse(code: UInt16)
    case notConnected
    case unsupportedDataType(UInt16)
    case timeout(String)
    case noLiveView
    case handshakeFailed(String)
    case noCameraFound
    case cameraRejectsPTP(String)

    var errorDescription: String? {
        switch self {
        case let .truncated(needed, available):
            return "Truncated PTP payload: needed \(needed) bytes, had \(available)."
        case let .badContainer(why):
            return "Malformed PTP container: \(why)"
        case let .deviceResponse(code):
            return "Camera returned \(PTPResponseCode.name(code)) (0x\(String(code, radix: 16, uppercase: true)))."
        case .notConnected:
            return "No camera session is open."
        case let .unsupportedDataType(t):
            return "Unsupported PTP data type 0x\(String(t, radix: 16, uppercase: true))."
        case let .timeout(what):
            return "Timed out waiting for \(what)."
        case .noLiveView:
            return "Camera did not return a live-view frame."
        case let .handshakeFailed(why):
            return "Sony PC Remote handshake failed: \(why)"
        case .noCameraFound:
            return "No camera found. Connect it by USB, set USB Connection Mode to "
                + "PC Remote, and check it is powered on and not showing playback."
        case let .cameraRejectsPTP(name):
            return "\(name) does not accept PTP pass-through commands. "
                + "If this is the α7C, it is probably in USB Streaming or Mass Storage mode "
                + "rather than PC Remote."
        }
    }
}

/// Little-endian cursor over a PTP payload.
struct PTPReader {
    private let bytes: [UInt8]
    private(set) var offset: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    init(_ array: [UInt8]) {
        bytes = array
        offset = 0
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { remaining <= 0 }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard remaining >= n else { throw PTPError.truncated(needed: n, available: remaining) }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    mutating func skip(_ n: Int) throws { _ = try take(n) }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }

    mutating func u16() throws -> UInt16 {
        let s = try take(2)
        let b = Array(s)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    mutating func u32() throws -> UInt32 {
        let b = Array(try take(4))
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | (hi << 32)
    }

    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    /// PTP string: one byte character count (including the trailing NUL), then UTF-16LE.
    mutating func string() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            units.append(try u16())
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    /// PTP array: UInt32 element count followed by the elements.
    mutating func array<T>(_ element: (inout PTPReader) throws -> T) throws -> [T] {
        let count = Int(try u32())
        // Guard against a corrupt length driving a huge allocation.
        guard count >= 0, count <= remaining else {
            throw PTPError.badContainer("array length \(count) exceeds \(remaining) remaining bytes")
        }
        var out: [T] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(try element(&self))
        }
        return out
    }

    mutating func value(ofType type: UInt16) throws -> PTPValue {
        switch type {
        case PTPDataType.int8: return .i8(try i8())
        case PTPDataType.uint8: return .u8(try u8())
        case PTPDataType.int16: return .i16(try i16())
        case PTPDataType.uint16: return .u16(try u16())
        case PTPDataType.int32: return .i32(try i32())
        case PTPDataType.uint32: return .u32(try u32())
        case PTPDataType.int64: return .i64(try i64())
        case PTPDataType.uint64: return .u64(try u64())
        case PTPDataType.int128, PTPDataType.uint128:
            // Read and discard the high half; nothing we care about needs 128 bits.
            let lo = try u64()
            _ = try u64()
            return .u64(lo)
        case PTPDataType.string: return .string(try string())
        default:
            if type & 0x4000 != 0 {
                let scalar = type & 0x3FFF
                let items = try array { r in try r.value(ofType: scalar) }
                return .array(items)
            }
            throw PTPError.unsupportedDataType(type)
        }
    }
}

/// A decoded PTP device-property value.
enum PTPValue: Equatable {
    case i8(Int8), u8(UInt8)
    case i16(Int16), u16(UInt16)
    case i32(Int32), u32(UInt32)
    case i64(Int64), u64(UInt64)
    case string(String)
    case array([PTPValue])

    /// Signed interpretation, for properties that use negative values (exposure compensation).
    var intValue: Int64? {
        switch self {
        case let .i8(v): return Int64(v)
        case let .u8(v): return Int64(v)
        case let .i16(v): return Int64(v)
        case let .u16(v): return Int64(v)
        case let .i32(v): return Int64(v)
        case let .u32(v): return Int64(v)
        case let .i64(v): return v
        case let .u64(v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .string, .array: return nil
        }
    }

    /// Raw bit pattern, for properties that pack flags into the high bits (Sony ISO).
    var rawBits: UInt64? {
        switch self {
        case let .i8(v): return UInt64(UInt8(bitPattern: v))
        case let .u8(v): return UInt64(v)
        case let .i16(v): return UInt64(UInt16(bitPattern: v))
        case let .u16(v): return UInt64(v)
        case let .i32(v): return UInt64(UInt32(bitPattern: v))
        case let .u32(v): return UInt64(v)
        case let .i64(v): return UInt64(bitPattern: v)
        case let .u64(v): return v
        case .string, .array: return nil
        }
    }

    /// Encode back to wire format using the property's declared data type.
    func encoded(as type: UInt16) -> Data {
        var w = PTPWriter()
        let bits = rawBits ?? 0
        switch type {
        case PTPDataType.int8, PTPDataType.uint8: w.u8(UInt8(truncatingIfNeeded: bits))
        case PTPDataType.int16, PTPDataType.uint16: w.u16(UInt16(truncatingIfNeeded: bits))
        case PTPDataType.int32, PTPDataType.uint32: w.u32(UInt32(truncatingIfNeeded: bits))
        case PTPDataType.int64, PTPDataType.uint64: w.u64(bits)
        default: w.u32(UInt32(truncatingIfNeeded: bits))
        }
        return w.data
    }
}

/// Little-endian byte builder.
struct PTPWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func u32(_ v: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v))
        u32(UInt32(truncatingIfNeeded: v >> 32))
    }

    mutating func append(_ other: Data) { data.append(other) }
}
