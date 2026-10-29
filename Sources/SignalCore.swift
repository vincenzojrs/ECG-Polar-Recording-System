import Foundation
import Darwin

enum SignalError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}

struct HRPacket {
    let bpm: Int
    let contact: Bool?
    let rr: [UInt16]
    static func decode(_ data: Data) throws -> HRPacket {
        let b = Array(data)
        guard b.count >= 2 else { throw SignalError.invalid("Truncated HR packet") }
        let flags = b[0], wide = flags & 1 != 0
        var p = wide ? 3 : 2
        guard b.count >= p else { throw SignalError.invalid("Truncated 16-bit HR") }
        let hr = wide ? Int(b[1]) | Int(b[2]) << 8 : Int(b[1])
        if flags & 8 != 0 { p += 2 }
        guard p <= b.count else { throw SignalError.invalid("Truncated HR energy field") }
        var rr: [UInt16] = []
        if flags & 16 != 0 {
            guard (b.count - p) % 2 == 0 else { throw SignalError.invalid("Truncated RR field") }
            while p < b.count { rr.append(UInt16(b[p]) | UInt16(b[p+1]) << 8); p += 2 }
        }
        return HRPacket(bpm: hr, contact: flags & 4 != 0 ? flags & 2 != 0 : nil, rr: rr)
    }
}

struct ECGFrame {
    let lastSensorNS: Int64
    let microvolts: [Int32]
    static func decode(_ data: Data) throws -> ECGFrame {
        let b = Array(data)
        guard b.count >= 13, b[0] == 0, b[9] == 0, (b.count - 10) % 3 == 0 else {
            throw SignalError.invalid("Unsupported/truncated ECG frame (expected Polar raw type 0)")
        }
        let u = (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[$1+1]) << ($1*8) }
        guard u < UInt64(Int64.max) else { throw SignalError.invalid("ECG timestamp overflow") }
        var values: [Int32] = []
        for i in stride(from: 10, to: b.count, by: 3) {
            var v = Int32(b[i]) | Int32(b[i+1]) << 8 | Int32(b[i+2]) << 16
            if v & 0x800000 != 0 { v |= ~0xffffff }
            values.append(v)
        }
        return ECGFrame(lastSensorNS: Int64(u), microvolts: values)
    }
}

/// A wall-clock anchor paired with a monotonic clock. NTP/time-zone changes never
/// silently rewrite an already recorded timeline. Current wall receipt is also saved.
struct MacClock {
    let unixAnchorNS: Int64
    let uptimeAnchorNS: UInt64
    init() { unixAnchorNS = Int64((Date().timeIntervalSince1970 * 1e9).rounded()); uptimeAnchorNS = Self.continuousNS() }
    func nowNS() -> Int64 { unixAnchorNS + Int64(Self.continuousNS() - uptimeAnchorNS) }
    static func wallNS() -> Int64 { Int64((Date().timeIntervalSince1970 * 1e9).rounded()) }
    // Unlike mach_absolute_time / Dispatch uptime, continuous time includes sleep.
    // Manual sleep still loses BLE data but must not shift the recovered UTC axis.
    static func continuousNS() -> UInt64 {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        let t = mach_continuous_time(), numerator = UInt64(info.numer), denominator = UInt64(info.denom)
        return t/denominator*numerator + t%denominator*numerator/denominator
    }
}

struct ECGTimeline {
    var previousSensor: Int64?
    var offsetNS: Int64?
    var calibrationFrames = 0
    mutating func reset() { self = ECGTimeline() }
    mutating func map(_ frame: ECGFrame, receiptNS: Int64, frozen: Bool) -> (sensor: [Int64], unix: [Int64], issue: String?) {
        let n = frame.microvolts.count
        let nominal = 1e9 / 130.0
        var dt = nominal, issue: String?
        if let prev = previousSensor {
            let span = frame.lastSensorNS - prev
            let expected = nominal * Double(n)
            if span <= 0 { issue = "sensor_clock_reset"; offsetNS = nil }
            else if abs(Double(span) - expected) < expected * 0.20 { dt = Double(span) / Double(n) }
            else { issue = "ecg_gap_or_clock_discontinuity" }
        }
        let candidate = receiptNS - frame.lastSensorNS
        // Preview calibration uses lowest observed receipt offset to reduce variable
        // transport delay. Freeze during recording; unknown fixed BLE latency remains.
        if offsetNS == nil { offsetNS = candidate }
        else if !frozen { offsetNS = min(offsetNS!, candidate) }
        previousSensor = frame.lastSensorNS
        calibrationFrames += 1
        let sensor = (0..<n).map { frame.lastSensorNS - Int64((Double(n-1-$0) * dt).rounded()) }
        return (sensor, sensor.map { $0 + offsetNS! }, issue)
    }
}

struct Beat {
    let ns: Int64
    let raw: UInt16
    let accepted: Bool
    let reason: String
    let segment: Int
    var ms: Double { Double(raw) * 1000 / 1024 }
}

struct RRScreen {
    var history: [Double] = []
    mutating func classify(_ raw: UInt16, contact: Bool?) -> (Bool, String) {
        let ms = Double(raw) * 1000 / 1024
        guard contact != false else { return (false, "no_sensor_contact") }
        guard (300...2000).contains(ms) else { return (false, "outside_300_2000ms") }
        let sorted = history.sorted()
        let median = sorted.isEmpty ? ms : sorted[sorted.count/2]
        let ok = history.count < 5 || abs(ms-median) <= 0.2*median
        // Adapt even after sustained changes; this is a transparent heuristic,
        // not ectopic/arrhythmia identification and never changes the raw interval.
        history.append(ms); if history.count > 11 { history.removeFirst() }
        return (ok, ok ? "candidate_only_not_verified_NN" : "over_20pct_recent_median")
    }
}

struct RRTimeline {
    var lastBeatNS: Int64?
    var lastReceiptNS: Int64?
    mutating func map(_ raw: [UInt16], receivedNS: Int64) -> (times: [Int64], reanchored: Bool) {
        guard !raw.isEmpty else { return ([], false) }
        let durations = raw.map { Int64((Double($0)*1e9/1024).rounded()) }
        let total = durations.reduce(0,+)
        var newest = receivedNS, reanchored = false
        if let previous = lastBeatNS, let oldReceipt = lastReceiptNS {
            let candidate = previous+total
            if receivedNS > oldReceipt && receivedNS-oldReceipt < 3_000_000_000 && abs(candidate-receivedNS) <= 1_500_000_000 {
                newest = candidate
            } else { reanchored = true }
        }
        var t = newest-total
        let times = durations.map { d -> Int64 in t += d; return t }
        lastBeatNS = newest; lastReceiptNS = receivedNS
        return (times, reanchored)
    }
}

struct Variability {
    let mean: Double?
    let sd: Double?
    let rmssd: Double?
    let pnn50: Double?
    let pairs: Int
    static func compute(_ beats: [Beat], screened: Bool) -> Variability {
        let used = beats.filter { !screened || $0.accepted }
        guard !used.isEmpty else { return Variability(mean: nil, sd: nil, rmssd: nil, pnn50: nil, pairs: 0) }
        let avg = used.reduce(0) { $0 + $1.ms } / Double(used.count)
        let sd = used.count > 1 ? sqrt(used.reduce(0) { $0 + pow($1.ms-avg, 2) } / Double(used.count-1)) : nil
        var diffs: [Double] = []
        if beats.count > 1 {
            for i in 1..<beats.count {
                let a = beats[i-1], b = beats[i]
                guard a.segment == b.segment, !screened || a.accepted && b.accepted else { continue }
                // Never form successive pairs across a packet loss/reconnection.
                guard abs(Double(b.ns-a.ns)/1e6-b.ms) < max(25, b.ms*0.05) else { continue }
                diffs.append(b.ms-a.ms)
            }
        }
        return Variability(mean: avg, sd: sd,
            rmssd: diffs.isEmpty ? nil : sqrt(diffs.reduce(0) { $0+$1*$1 }/Double(diffs.count)),
            pnn50: diffs.isEmpty ? nil : 100*Double(diffs.filter { abs($0)>50 }.count)/Double(diffs.count), pairs: diffs.count)
    }
}

struct HRVWindow {
    let startNS: Int64
    let endNS: Int64
    let beats: [Beat]
    let complete: Bool
    var coverage: Double { min(1, beats.reduce(0) { $0 + $1.ms } / (Double(endNS-startNS)/1e6)) }
    var acceptedFraction: Double { beats.isEmpty ? 0 : Double(beats.filter(\.accepted).count)/Double(beats.count) }
    var usable: Bool { complete && coverage >= 0.90 && acceptedFraction >= 0.95 && beats.count >= 30 }
    var raw: Variability { Variability.compute(beats, screened: false) }
    var screened: Variability { Variability.compute(beats, screened: true) }
}

struct WindowAccumulator {
    var startNS: Int64
    var beats: [Beat] = []
    let durationNS: Int64 = 300_000_000_000
    mutating func advance(to ns: Int64) -> [HRVWindow] {
        var out: [HRVWindow] = []
        while ns >= startNS + durationNS {
            out.append(HRVWindow(startNS: startNS, endNS: startNS+durationNS, beats: beats, complete: true))
            beats.removeAll(keepingCapacity: true); startNS += durationNS
        }
        return out
    }
    mutating func append(_ beat: Beat) -> [HRVWindow] {
        let out = advance(to: beat.ns)
        if beat.ns >= startNS { beats.append(beat) }
        return out
    }
    func partial(endNS: Int64) -> HRVWindow? {
        guard endNS > startNS, !beats.isEmpty else { return nil }
        return HRVWindow(startNS: startNS, endNS: endNS, beats: beats, complete: false)
    }
}

func number(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "" }
    return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
}
func csv(_ value: String) -> String {
    let text = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value >= 32 || $0.value == 9 || $0.value == 10 || $0.value == 13 }))
    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Buffers bounded batches; only the short plotting ring and current HRV window
/// stay in memory. Each hour gets a complete set of self-describing CSV files.
final class SessionWriter {
    let directory: URL
    let startNS: Int64
    private var handles: [String: FileHandle] = [:]
    private var pending: [String: Data] = [:]
    private var hour = -1
    private var closed = false
    private var metadata: [String: Any]
    private let iso: ISO8601DateFormatter
    static let headers = [
        "ecg": "timestamp_unix_ns,timestamp_utc,polar_timestamp_ns,ecg_uv,ecg_mv,frame_received_unix_ns,connection_segment,timestamp_method",
        "rr": "timestamp_unix_ns,timestamp_utc,rr_raw_1_1024_s,rr_ms,hr_bpm,received_unix_ns,sensor_contact,screen_accepted,screen_reason,connection_segment,timestamp_method",
        "hr": "timestamp_unix_ns,timestamp_utc,hr_bpm,sensor_contact,connection_segment,timestamp_method",
        "hrv": "window_start_unix_ns,window_start_utc,window_end_unix_ns,window_duration_s,complete_window,rr_count,accepted_count,coverage_fraction,accepted_fraction,usable_heuristic,mean_rr_ms,hr_from_mean_rr_bpm,sdrr_ms,rmssd_rr_ms,pnn50_rr_pct,successive_pairs,sdnn_candidate_ms,rmssd_candidate_ms,pnn50_candidate_pct,candidate_pairs,nn_verified",
        "events": "timestamp_unix_ns,timestamp_utc,event,detail",
        "clock": "timestamp_unix_ns,timestamp_utc,wall_clock_unix_ns,uptime_ns,polar_frame_timestamp_ns,ecg_mapping_offset_ns,connection_segment"
    ]
    init(parent: URL, startNS: Int64, device: String, deviceID: String, clock: MacClock, test: Bool = false) throws {
        self.startNS = startNS
        iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let name = iso.string(from: Date(timeIntervalSince1970: Double(startNS)/1e9)).replacingOccurrences(of: ":", with: "-")
        directory = parent.appendingPathComponent("\(test ? "SYNTHETIC-" : "")PolarPAP-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadata = ["schema_version": 1, "app_version": "0.1.8", "status": "recording", "synthetic": test,
            "start_unix_ns": String(startNS), "device_name": device, "device_id": deviceID,
            "time_zone": TimeZone.current.identifier, "utc_offset_at_start_s": TimeZone.current.secondsFromGMT(),
            "mac_clock_unix_anchor_ns": String(clock.unixAnchorNS), "mac_clock_uptime_anchor_ns": String(clock.uptimeAnchorNS),
            "monotonic_clock_source": "mach_continuous_time_in_nanoseconds_including_sleep",
            "ecg_sample_rate_hz": 130, "ecg_timestamp_method": "sensor_relative_time_anchored_to_Mac_receipt_minimum_during_preview; fixed_BLE_latency_unknown",
            "rr_timestamp_method": "cumulative_RR_anchored_to_notification_receipt; estimated_not_absolute_sensor_beat_time",
            "hr_timestamp_method": "Mac_notification_receipt",
            "clock_accuracy": "No guaranteed absolute BLE latency; review clock CSV for drift. Mac and PAP clocks assumed equal by user; no automatic PAP synchronization.",
            "pap_clock_assumption": "Same displayed local time as Mac; CSV uses UTC, convert explicitly when importing PAP wall-clock data.",
            "hrv_window_seconds": 300, "hrv_screen": "RR 300..2000ms; contact not false; within 20 percent of median of up to 11 previous in-range RR after first 5; no interpolation; adjacent pairs never bridged across rejected beats/gaps",
            "hrv_usable_rule": "complete 300s window; >=90 percent RR-duration coverage; >=95 percent screen accepted; >=30 RR",
            "nn_verified": false, "purpose": "Personal recording and exploratory analysis; no diagnostic validation",
            "operating_system": ProcessInfo.processInfo.operatingSystemVersionString]
        try saveMetadata(); try rotate(at: startNS)
    }
    func time(_ ns: Int64) -> String { iso.string(from: Date(timeIntervalSince1970: Double(ns)/1e9)) }
    private func saveMetadata() throws {
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
    }
    private func rotate(at ns: Int64) throws {
        let target = max(hour, max(0, Int((ns-startNS)/3_600_000_000_000)))
        guard target != hour else { return }
        try flush(sync: true)
        for handle in handles.values { try handle.close() }; handles.removeAll()
        hour = target
        for (name, header) in Self.headers {
            let url = directory.appendingPathComponent(String(format: "%03d_%@.csv", hour, name))
            guard !FileManager.default.fileExists(atPath: url.path) else { throw SignalError.invalid("Refusing to overwrite \(url.lastPathComponent)") }
            guard FileManager.default.createFile(atPath: url.path, contents: Data((header+"\n").utf8)) else { throw SignalError.invalid("Cannot create \(url.path)") }
            handles[name] = try FileHandle(forWritingTo: url); try handles[name]!.seekToEnd()
        }
    }
    func row(_ stream: String, ns: Int64, _ fields: [String]) throws {
        guard !closed, handles[stream] != nil else { throw SignalError.invalid("Recording file is closed") }
        try rotate(at: ns)
        pending[stream, default: Data()].append(Data((fields.joined(separator: ",")+"\n").utf8))
        if pending[stream]!.count > 65_536 { try flush(sync: false) }
    }
    func event(_ ns: Int64, _ name: String, _ detail: String) throws { try row("events", ns: ns, [String(ns), time(ns), csv(name), csv(detail)]) }
    func window(_ w: HRVWindow) throws {
        let r = w.raw, s = w.screened
        try row("hrv", ns: max(startNS, w.endNS-1), [String(w.startNS), time(w.startNS), String(w.endNS), number(Double(w.endNS-w.startNS)/1e9), String(w.complete), String(w.beats.count), String(w.beats.filter(\.accepted).count), number(w.coverage), number(w.acceptedFraction), String(w.usable), number(r.mean), number(r.mean.flatMap { $0 > 0 ? 60000/$0 : nil }), number(r.sd), number(r.rmssd), number(r.pnn50), String(r.pairs), number(w.usable ? s.sd : nil), number(w.usable ? s.rmssd : nil), number(w.usable ? s.pnn50 : nil), String(s.pairs), "false"])
    }
    func flush(sync: Bool) throws {
        for (key, bytes) in pending where !bytes.isEmpty { try handles[key]?.write(contentsOf: bytes); pending[key] = Data() }
        if sync { for h in handles.values { try h.synchronize() } }
    }
    func finish(_ endNS: Int64, status: String) throws {
        guard !closed else { return }
        try flush(sync: true)
        for h in handles.values { try h.close() }; handles.removeAll(); closed = true
        metadata["status"] = status; metadata["end_unix_ns"] = String(endNS); try saveMetadata()
    }
    deinit { for h in handles.values { try? h.close() } }
}
