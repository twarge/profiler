import Foundation

/// Sony PC Remote session: handshake, property table, live-view frames, ISO control.
///
/// The property-descriptor layout Sony uses deviates from ISO 15740 by inserting a second
/// mutability byte after `getSet`. The parser below accounts for that and bails out cleanly
/// on anything it can't make sense of rather than walking off the end of the blob.
final class SonySession {

    private let transport: PTPTransport
    private var liveViewHandle: UInt32?
    private var liveViewFailures = 0
    private(set) var properties: [UInt16: PTPPropertyDescriptor] = [:]

    init(transport: PTPTransport) {
        self.transport = transport
    }

    // MARK: - Handshake

    /// Sony's PC Remote handshake. The connect call is issued in stages with an
    /// ext-device-info exchange in the middle; the camera refuses property access until
    /// the sequence completes.
    func connect() async throws {
        _ = try? await transport.send(PTPOperation.openSession, parameters: [1], throwOnError: false)

        _ = try await transport.send(
            PTPOperation.sonySDIOConnect, parameters: [1, 0, 0])
        _ = try await transport.send(
            PTPOperation.sonySDIOConnect, parameters: [2, 0, 0])

        // Version word: 0x00C8 (200) is the widely-used value for modern Alpha bodies.
        let info = try await transport.send(
            PTPOperation.sonyGetSDIOExtDeviceInfo, parameters: [0x00C8])
        guard !info.data.isEmpty else {
            throw PTPError.handshakeFailed("camera returned no extended device info")
        }

        _ = try await transport.send(
            PTPOperation.sonySDIOConnect, parameters: [3, 0, 0])

        try await refreshProperties()
        guard properties[SonyProperty.iso] != nil else {
            throw PTPError.handshakeFailed(
                "connected, but the camera did not expose an ISO property — "
                + "check that the mode dial is on M, S, A or P rather than AUTO")
        }
    }

    // MARK: - Properties

    /// Pulls the whole property table in one transaction. Sony returns every property with
    /// its descriptor and current value, which is cheaper than polling individually.
    func refreshProperties() async throws {
        let response = try await transport.send(PTPOperation.sonyGetAllDevicePropData)
        guard !response.data.isEmpty else { return }

        var r = PTPReader(response.data)
        let count = Int(try r.u32())
        _ = try r.u32()  // version / reserved

        var parsed: [UInt16: PTPPropertyDescriptor] = [:]
        for _ in 0..<count {
            guard let desc = try? parseDescriptor(&r) else { break }
            parsed[desc.code] = desc
        }
        if !parsed.isEmpty { properties = parsed }
    }

    private func parseDescriptor(_ r: inout PTPReader) throws -> PTPPropertyDescriptor {
        let code = try r.u16()
        let dataType = try r.u16()
        let getSet = try r.u8()
        let enabled = try r.u8()
        let defaultValue = try r.value(ofType: dataType)
        let currentValue = try r.value(ofType: dataType)
        let formFlag = try r.u8()

        var form = PTPPropertyDescriptor.Form.none
        switch formFlag {
        case 0x01:
            let lo = try r.value(ofType: dataType)
            let hi = try r.value(ofType: dataType)
            let step = try r.value(ofType: dataType)
            form = .range(min: lo, max: hi, step: step)
        case 0x02:
            let n = Int(try r.u16())
            var values: [PTPValue] = []
            values.reserveCapacity(n)
            for _ in 0..<n { values.append(try r.value(ofType: dataType)) }
            form = .enumeration(values)
        default:
            form = .none
        }

        return PTPPropertyDescriptor(
            code: code,
            dataType: dataType,
            writable: getSet != 0,
            enabled: enabled != 0,
            defaultValue: defaultValue,
            currentValue: currentValue,
            form: form
        )
    }

    /// Writes a settings-type property (ISO, aperture, shutter). Sony wants these through
    /// SetControlDeviceA with the property code as parameter 1 and the value as the data phase.
    func setProperty(_ code: UInt16, value: PTPValue) async throws {
        guard let desc = properties[code] else { throw PTPError.deviceResponse(code: PTPResponseCode.devicePropNotSupported) }
        let payload = value.encoded(as: desc.dataType)
        _ = try await transport.send(
            PTPOperation.sonySetControlDeviceA,
            parameters: [UInt32(code)],
            outData: payload
        )
    }

    // MARK: - ISO

    /// Sony packs ISO into a 32-bit word: the low 24 bits carry the numeric value and the
    /// top byte carries mode flags (multi-frame NR and similar). 0x00FFFFFF means AUTO.
    struct ISOSetting: Equatable, Identifiable {
        var raw: UInt32
        var id: UInt32 { raw }

        var isAuto: Bool { (raw & 0x00FF_FFFF) == 0x00FF_FFFF }
        var value: Int { Int(raw & 0x00FF_FFFF) }
        var mode: UInt8 { UInt8((raw >> 24) & 0xFF) }

        var label: String {
            if isAuto { return "AUTO" }
            return mode == 0 ? "\(value)" : "\(value)†"
        }
    }

    var currentISO: ISOSetting? {
        guard let desc = properties[SonyProperty.iso],
              let bits = desc.currentValue.rawBits else { return nil }
        return ISOSetting(raw: UInt32(truncatingIfNeeded: bits))
    }

    var isoIsWritable: Bool {
        guard let desc = properties[SonyProperty.iso] else { return false }
        return desc.writable && desc.enabled
    }

    /// Selectable ISO values, AUTO and multi-frame-NR variants removed, ascending.
    /// Those are the only ones a gain servo can meaningfully step through.
    var availableISOValues: [ISOSetting] {
        guard let desc = properties[SonyProperty.iso] else { return [] }
        return desc.allowedValues
            .compactMap { $0.rawBits.map { ISOSetting(raw: UInt32(truncatingIfNeeded: $0)) } }
            .filter { !$0.isAuto && $0.mode == 0 && $0.value > 0 }
            .sorted { $0.value < $1.value }
    }

    func setISO(_ setting: ISOSetting) async throws {
        try await setProperty(SonyProperty.iso, value: .u32(setting.raw))
    }

    /// Human-readable shutter speed. Sony encodes it as a packed rational:
    /// high 16 bits numerator, low 16 bits denominator.
    var shutterSpeedLabel: String? {
        guard let desc = properties[SonyProperty.shutterSpeed],
              let bits = desc.currentValue.rawBits else { return nil }
        let raw = UInt32(truncatingIfNeeded: bits)
        let numerator = Int(raw >> 16)
        let denominator = Int(raw & 0xFFFF)
        guard denominator > 0 else { return nil }
        if numerator == 1 { return "1/\(denominator)s" }
        let seconds = Double(numerator) / Double(denominator)
        return String(format: "%.1fs", seconds)
    }

    var apertureLabel: String? {
        let code = properties[SonyProperty.fNumber] != nil
            ? SonyProperty.fNumber : SonyProperty.standardFNumber
        guard let desc = properties[code], let bits = desc.currentValue.rawBits else { return nil }
        let value = Double(bits) / 100.0
        // With no lens fitted — the normal case for beam profiling on a bare sensor — the
        // body reports an undefined aperture. Suppress it rather than dressing up a
        // placeholder as a real f-number.
        guard value >= 0.7, value <= 99 else { return nil }
        return String(format: "f/%.1f", value)
    }

    // MARK: - Live view

    /// Fetches one live-view frame as JPEG data.
    ///
    /// Sony prefixes the JPEG with a variable header, so rather than hard-coding its layout
    /// we locate the JPEG by its SOI/EOI markers. That survives header changes across bodies.
    func liveViewJPEG() async throws -> Data {
        // Once a handle is known, stay on it. A single miss is almost always the camera
        // being briefly busy — re-probing all three candidates on every miss turns one
        // dropped frame into three round trips and visibly wrecks the cadence.
        if let handle = liveViewHandle {
            if let jpeg = try await fetchLiveView(handle) {
                liveViewFailures = 0
                return jpeg
            }
            liveViewFailures += 1
            if liveViewFailures < 5 { throw PTPError.noLiveView }
            liveViewHandle = nil
            liveViewFailures = 0
        }

        for handle in SonyLiveView.candidateHandles {
            if let jpeg = try await fetchLiveView(handle) {
                liveViewHandle = handle
                liveViewFailures = 0
                return jpeg
            }
        }
        throw PTPError.noLiveView
    }

    private func fetchLiveView(_ handle: UInt32) async throws -> Data? {
        let response = try await transport.send(
            PTPOperation.getObject,
            parameters: [handle],
            throwOnError: false
        )
        guard response.isOK, !response.data.isEmpty else { return nil }
        return Self.extractJPEG(from: response.data)
    }

    static func extractJPEG(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }

        var start: Int?
        var i = 0
        while i < bytes.count - 1 {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD8 { start = i; break }
            i += 1
        }
        guard let s = start else { return nil }

        var end: Int?
        var j = bytes.count - 1
        while j > s {
            if bytes[j - 1] == 0xFF, bytes[j] == 0xD9 { end = j; break }
            j -= 1
        }
        guard let e = end, e > s else { return nil }
        return data.subdata(in: s..<(e + 1))
    }
}
