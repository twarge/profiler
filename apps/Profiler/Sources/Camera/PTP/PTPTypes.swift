import Foundation

// PTP wire constants. Operation and property codes in the 0x9xxx / 0xDxxx vendor ranges are
// Sony extensions, taken from the public libgphoto2 ptp2 camera library and ISO 15740 for the
// standard ranges. No Sony SDK source or binary was consulted — see README "Protocol provenance".

enum PTPContainerType {
    static let command: UInt16 = 1
    static let data: UInt16 = 2
    static let response: UInt16 = 3
    static let event: UInt16 = 4
}

enum PTPDataType {
    static let int8: UInt16 = 0x0001
    static let uint8: UInt16 = 0x0002
    static let int16: UInt16 = 0x0003
    static let uint16: UInt16 = 0x0004
    static let int32: UInt16 = 0x0005
    static let uint32: UInt16 = 0x0006
    static let int64: UInt16 = 0x0007
    static let uint64: UInt16 = 0x0008
    static let int128: UInt16 = 0x0009
    static let uint128: UInt16 = 0x000A
    static let string: UInt16 = 0xFFFF
}

enum PTPOperation {
    // ISO 15740 standard operations.
    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let closeSession: UInt16 = 0x1003
    static let getObjectInfo: UInt16 = 0x1008
    static let getObject: UInt16 = 0x1009
    static let getDevicePropDesc: UInt16 = 0x1014
    static let getDevicePropValue: UInt16 = 0x1015
    static let setDevicePropValue: UInt16 = 0x1016

    // Sony vendor extensions.
    static let sonySDIOConnect: UInt16 = 0x9201
    static let sonyGetSDIOExtDeviceInfo: UInt16 = 0x9202
    static let sonyGetDevicePropDesc: UInt16 = 0x9203
    static let sonyGetDevicePropValue: UInt16 = 0x9204
    /// Sets "settings"-type properties that persist, e.g. ISO, aperture, shutter speed.
    static let sonySetControlDeviceA: UInt16 = 0x9205
    static let sonyGetControlDeviceDesc: UInt16 = 0x9206
    /// Sets "momentary" controls, e.g. shutter release, autofocus trigger.
    static let sonySetControlDeviceB: UInt16 = 0x9207
    static let sonyGetAllDevicePropData: UInt16 = 0x9209
}

enum PTPResponseCode {
    static let ok: UInt16 = 0x2001
    static let generalError: UInt16 = 0x2002
    static let sessionNotOpen: UInt16 = 0x2003
    static let operationNotSupported: UInt16 = 0x2005
    static let parameterNotSupported: UInt16 = 0x2006
    static let incompleteTransfer: UInt16 = 0x2007
    static let invalidObjectHandle: UInt16 = 0x2009
    static let devicePropNotSupported: UInt16 = 0x200A
    static let invalidDevicePropValue: UInt16 = 0x200C
    static let accessDenied: UInt16 = 0x200F
    static let deviceBusy: UInt16 = 0x2019

    static func name(_ code: UInt16) -> String {
        switch code {
        case ok: return "OK"
        case generalError: return "GeneralError"
        case sessionNotOpen: return "SessionNotOpen"
        case operationNotSupported: return "OperationNotSupported"
        case parameterNotSupported: return "ParameterNotSupported"
        case incompleteTransfer: return "IncompleteTransfer"
        case invalidObjectHandle: return "InvalidObjectHandle"
        case devicePropNotSupported: return "DevicePropNotSupported"
        case invalidDevicePropValue: return "InvalidDevicePropValue"
        case accessDenied: return "AccessDenied"
        case deviceBusy: return "DeviceBusy"
        default: return "Response"
        }
    }
}

/// Sony device property codes.
enum SonyProperty {
    static let iso: UInt16 = 0xD21E
    static let shutterSpeed: UInt16 = 0xD20D
    static let fNumber: UInt16 = 0xD20E
    static let exposureCompensation: UInt16 = 0xD200
    static let exposureProgramMode: UInt16 = 0xD25A
    static let liveViewStatus: UInt16 = 0xD221
    static let focusMode: UInt16 = 0xD20F
    static let batteryLevel: UInt16 = 0xD218

    // Standard-range properties Sony also reports.
    static let standardFNumber: UInt16 = 0x5007
    static let standardExposureTime: UInt16 = 0x500D
    static let standardExposureIndex: UInt16 = 0x500F

    static func name(_ code: UInt16) -> String {
        switch code {
        case iso: return "ISO"
        case shutterSpeed: return "Shutter Speed"
        case fNumber, standardFNumber: return "Aperture"
        case exposureCompensation: return "Exposure Compensation"
        case exposureProgramMode: return "Exposure Mode"
        case liveViewStatus: return "Live View Status"
        case focusMode: return "Focus Mode"
        case batteryLevel: return "Battery"
        case standardExposureTime: return "Exposure Time"
        case standardExposureIndex: return "Exposure Index"
        default: return "0x\(String(code, radix: 16, uppercase: true))"
        }
    }
}

/// Object handles Sony uses for the live-view stream. Tried in order; the first that
/// yields a JPEG is remembered for the session.
enum SonyLiveView {
    static let candidateHandles: [UInt32] = [0xFFFF_C002, 0xFFFF_C001, 0xFFFF_C003]
}

/// A parsed PTP device property descriptor.
struct PTPPropertyDescriptor {
    enum Form {
        case none
        case range(min: PTPValue, max: PTPValue, step: PTPValue)
        case enumeration([PTPValue])
    }

    var code: UInt16
    var dataType: UInt16
    var writable: Bool
    /// Sony reports a second mutability byte; when zero the property is present but currently
    /// locked out by camera state (e.g. ISO in a fully-automatic exposure mode).
    var enabled: Bool
    var defaultValue: PTPValue
    var currentValue: PTPValue
    var form: Form

    var name: String { SonyProperty.name(code) }

    /// The values this property will actually accept, if it advertises an enumeration.
    var allowedValues: [PTPValue] {
        if case let .enumeration(values) = form { return values }
        return []
    }
}

/// Response from a single PTP transaction.
struct PTPResponse {
    var code: UInt16
    var parameters: [UInt32]
    var data: Data

    var isOK: Bool { code == PTPResponseCode.ok }
}

/// Builds PTP command containers.
enum PTPCommand {
    static func container(code: UInt16, parameters: [UInt32] = []) -> Data {
        var w = PTPWriter()
        w.u32(UInt32(12 + parameters.count * 4))
        w.u16(PTPContainerType.command)
        w.u16(code)
        // ImageCaptureCore owns transaction numbering; this field is a placeholder.
        w.u32(0)
        for p in parameters { w.u32(p) }
        return w.data
    }

    /// Decodes a response container. Returns nil if the blob isn't a response container,
    /// which lets the caller disambiguate ImageCaptureCore's two NSData arguments.
    static func parseResponse(_ data: Data) -> (code: UInt16, parameters: [UInt32])? {
        guard data.count >= 12 else { return nil }
        var r = PTPReader(data)
        guard let length = try? r.u32(),
              let type = try? r.u16(),
              let code = try? r.u16(),
              let _ = try? r.u32()
        else { return nil }
        guard type == PTPContainerType.response else { return nil }
        guard length >= 12, Int(length) <= data.count else { return nil }
        var params: [UInt32] = []
        let paramCount = (Int(length) - 12) / 4
        for _ in 0..<paramCount {
            guard let p = try? r.u32() else { break }
            params.append(p)
        }
        return (code, params)
    }
}
