import Foundation

enum PlotWindowMath {
    static func selected(offset: Double, visible: Double, total: Double, lower: Double, upper: Double) -> (Double, Double)? {
        let width = visible > 0 ? visible : total
        let lo = max(0, min(1, min(lower, upper)))
        let hi = max(0, min(1, max(lower, upper)))
        guard width > 1, hi > lo else { return nil }
        let span = min(width, max(1, (hi - lo) * width))
        let start = max(0, min(offset + lo * width, total - span))
        return (start, span)
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case record = "Record"
    case sessions = "Sessions"
    case shift = "Shift session time"
    var id: String { rawValue }
}

enum SessionTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case files = "Files"
    case events = "Events"
    var id: String { rawValue }
}

enum SessionChart: String, CaseIterable, Identifiable {
    case rr = "R–R intervals"
    case ecg = "ECG"
    case hrv = "HRV"
    case pulseRate = "Pulse Rate"
    var id: String { rawValue }
}

enum HRVDisplayMode: String, CaseIterable, Identifiable {
    case raw = "Raw RR"
    case candidate = "Filtered candidate"
    var id: String { rawValue }
}

struct SessionRRPoint: Identifiable {
    let time: Date
    let milliseconds: Double
    var id: Int64 { Int64(time.timeIntervalSince1970 * 1000) }
}

struct SessionECGPoint: Identifiable {
    let time: Date
    let millivolts: Double
    var id: Int64 { Int64(time.timeIntervalSince1970 * 1000) }
}

struct SessionPulsePoint: Identifiable {
    let time: Date
    let bpm: Double
    var id: Int64 { Int64(time.timeIntervalSince1970 * 1000) }
}

struct SessionHRVRow: Identifiable {
    let start: Date
    let end: Date
    let coverage: Double
    let accepted: Double
    let complete: Bool
    let usable: Bool
    let meanRR: Double?
    let sdrr: Double?
    let rmssd: Double?
    let pnn50: Double?
    let candidateSDNN: Double?
    let candidateRMSSD: Double?
    let candidatePNN50: Double?
    let meanHR: Double?
    var id: Date { start }
}

struct SessionEventItem: Identifiable {
    let time: Date
    let name: String
    let detail: String
    var id: String { "\(time.timeIntervalSince1970)-\(name)" }
    var displayName: String {
        switch name {
        case "connected": return "Connection restored"
        case "disconnected": return "Connection lost · retrying"
        case "recording_started": return "Recording started"
        case "recording_stopped": return "Recording stopped"
        case "mac_clock_changed": return "Mac clock changed"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct SessionFileItem: Identifiable {
    let url: URL
    let bytes: Int64
    var id: String { url.path }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

struct SavedSession: Identifiable {
    let folder: URL
    let start: Date
    let end: Date?
    let status: String
    let device: String
    let timeZone: String
    let meanHR: Double?
    let gaps: [TimeInterval]
    let fileCount: Int
    var id: String { folder.path }
    var duration: TimeInterval { max(0, (end ?? Date()).timeIntervalSince(start)) }
    var gapLabel: String {
        guard !gaps.isEmpty else { return "None" }
        let seconds = Int(gaps.reduce(0,+).rounded())
        return "\(gaps.count) · \(seconds) sec"
    }
    var title: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: timeZone) ?? .current; f.dateFormat = "yyyy-MM-dd, HHmmss"
        return f.string(from: start)
    }
    var subtitle: String { "\(status.capitalized) · \(Self.durationLabel(duration)) · \(device)" }
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

struct SessionDetail {
    let summary: SavedSession
    let rr: [SessionRRPoint]
    let ecg: [SessionECGPoint]
    let pulseRate: [SessionPulsePoint]
    let hrv: [SessionHRVRow]
    let events: [SessionEventItem]
    let files: [SessionFileItem]
}

enum SessionStore {
    static func scan(root: URL) throws -> [SavedSession] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var sessions: [SavedSession] = []
        for folder in children {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let startString = json["start_unix_ns"] as? String,
                  let startNS = Double(startString) else { continue }
            let start = Date(timeIntervalSince1970: startNS / 1e9)
            let end = (json["end_unix_ns"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1e9) }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            let pulse = files.filter { $0.lastPathComponent.hasSuffix("_hr.csv") }.flatMap { parsePulse(rows(url: $0)) }
            let totalHR = pulse.reduce(0.0) { $0 + $1.bpm }, hrCount = pulse.count
            let events = files.filter { $0.lastPathComponent.hasSuffix("_events.csv") }.flatMap { eventRows(url: $0) }
            let gaps = gapDurations(events)
            sessions.append(SavedSession(folder: folder, start: start, end: end, status: json["status"] as? String ?? "unknown",
                device: json["device_name"] as? String ?? "Polar H10", timeZone: json["time_zone"] as? String ?? "Europe/Rome",
                meanHR: hrCount > 0 ? totalHR / Double(hrCount) : nil, gaps: gaps, fileCount: files.filter { $0.pathExtension == "csv" }.count + 1))
        }
        return sessions.sorted { $0.start > $1.start }
    }

    static func detail(for summary: SavedSession) throws -> SessionDetail {
        let contents = try FileManager.default.contentsOfDirectory(at: summary.folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        let files = contents.filter { $0.pathExtension == "csv" || $0.lastPathComponent == "session.json" }.map { url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return SessionFileItem(url: url, bytes: size)
        }.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        let rrRows = contents.filter { $0.lastPathComponent.hasSuffix("_rr.csv") }.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { rows(url: $0).dropFirst() }
        var rr: [SessionRRPoint] = []
        for row in rrRows where row.count > 3 {
            if let ns = Double(row[0]), let ms = Double(row[3]) { rr.append(SessionRRPoint(time: Date(timeIntervalSince1970: ns/1e9), milliseconds: ms)) }
        }
        rr.sort { $0.time < $1.time }
        let hrv = contents.filter { $0.lastPathComponent.hasSuffix("_hrv.csv") }.flatMap { parseHRV(rows(url: $0)) }.sorted { $0.start < $1.start }
        let ecgFiles = contents.filter { $0.lastPathComponent.hasSuffix("_ecg.csv") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let ecg = sampledECG(files: ecgFiles)
        let pulseRate = contents.filter { $0.lastPathComponent.hasSuffix("_hr.csv") }.flatMap { parsePulse(rows(url: $0)) }.sorted { $0.time < $1.time }
        let events = contents.filter { $0.lastPathComponent.hasSuffix("_events.csv") }.flatMap { eventRows(url: $0) }.sorted { $0.time < $1.time }
        return SessionDetail(summary: summary, rr: rr, ecg: ecg, pulseRate: pulseRate, hrv: hrv, events: events, files: files)
    }

    private static func parseHRV(_ rows: [[String]]) -> [SessionHRVRow] {
        guard let header = rows.first else { return [] }
        let idx = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        func value(_ row: [String], _ key: String) -> String? { guard let i = idx[key], i < row.count, !row[i].isEmpty else { return nil }; return row[i] }
        func double(_ row: [String], _ key: String) -> Double? { value(row, key).flatMap(Double.init) }
        func bool(_ row: [String], _ key: String) -> Bool { value(row, key) == "true" }
        return rows.dropFirst().compactMap { row in
            guard let start = double(row, "window_start_unix_ns"), let end = double(row, "window_end_unix_ns") else { return nil }
            return SessionHRVRow(start: Date(timeIntervalSince1970: start/1e9), end: Date(timeIntervalSince1970: end/1e9),
                coverage: double(row, "coverage_fraction") ?? 0, accepted: double(row, "accepted_fraction") ?? 0,
                complete: bool(row, "complete_window"), usable: bool(row, "usable_heuristic"),
                meanRR: double(row, "mean_rr_ms"), sdrr: double(row, "sdrr_ms"), rmssd: double(row, "rmssd_rr_ms"), pnn50: double(row, "pnn50_rr_pct"),
                candidateSDNN: double(row, "sdnn_candidate_ms"), candidateRMSSD: double(row, "rmssd_candidate_ms"), candidatePNN50: double(row, "pnn50_candidate_pct"), meanHR: double(row, "hr_from_mean_rr_bpm"))
        }
    }

    private static func parsePulse(_ rows: [[String]]) -> [SessionPulsePoint] {
        guard let header = rows.first else { return [] }
        let idx = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard let ti = idx["timestamp_unix_ns"], let hi = idx["hr_bpm"] else { return [] }
        return rows.dropFirst().compactMap { row in
            guard max(ti, hi) < row.count, let ns = Double(row[ti]), let bpm = Double(row[hi]) else { return nil }
            return SessionPulsePoint(time: Date(timeIntervalSince1970: ns / 1e9), bpm: bpm)
        }
    }

    // ECG rows are numeric and never contain quoted or multiline fields.
    // Iterate in bounded chunks, including a final line without a newline.
    private static func eachECGLine(_ url: URL, _ body: (String) throws -> Bool) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while true {
            let chunk = try handle.read(upToCount: 262_144) ?? Data()
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: 10) {
                if let line = String(data: pending[start..<newline], encoding: .utf8), try !body(line.trimmingCharacters(in: .newlines)) { return }
                start = pending.index(after: newline)
            }
            if start != pending.startIndex { pending.removeSubrange(pending.startIndex..<start) }
            if chunk.isEmpty {
                if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) { _ = try body(line.trimmingCharacters(in: .newlines)) }
                return
            }
        }
    }

    // Read original samples in a short interval without loading the whole night into memory.
    static func ecgWindow(folder: URL, start: Date, duration: TimeInterval = 10) throws -> [SessionECGPoint] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix("_ecg.csv") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let end = start.addingTimeInterval(duration)
        var result: [SessionECGPoint] = []
        for url in files {
            var ti: Int?, vi: Int?
            try eachECGLine(url) { line in
                let fields = line.components(separatedBy: ",")
                if ti == nil {
                    guard let t = fields.firstIndex(of: "timestamp_unix_ns"), let v = fields.firstIndex(of: "ecg_mv") else { throw CocoaError(.fileReadCorruptFile) }
                    ti = t; vi = v; return true
                }
                guard let ti, let vi, max(ti, vi) < fields.count, let ns = Double(fields[ti]), let mv = Double(fields[vi]) else { return true }
                let time = Date(timeIntervalSince1970: ns / 1e9)
                // Continue through all files: rotated files can overlap in time.
                if time >= start && time < end { result.append(SessionECGPoint(time: time, millivolts: mv)) }
                return time < end
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    // Downsample for the overview; never use these points as an ECG waveform.
    private static func sampledECG(files: [URL], maximumPoints: Int = 120_000) -> [SessionECGPoint] {
        let total = files.reduce(0) { $0 + max(0, lineCount($1) - 1) }
        guard total > 0 else { return [] }
        let stride = max(1, Int(ceil(Double(total) / Double(maximumPoints))))
        var result: [SessionECGPoint] = [], globalIndex = 0
        for url in files {
            var ti: Int?, vi: Int?
            try? eachECGLine(url) { line in
                if ti == nil {
                    let fields = line.components(separatedBy: ",")
                    ti = fields.firstIndex(of: "timestamp_unix_ns")
                    vi = fields.firstIndex(of: "ecg_mv")
                    return ti != nil && vi != nil
                }
                defer { globalIndex += 1 }
                guard globalIndex % stride == 0, let ti, let vi else { return true }
                let fields = line.components(separatedBy: ",")
                guard max(ti, vi) < fields.count, let ns = Double(fields[ti]), let mv = Double(fields[vi]) else { return true }
                result.append(SessionECGPoint(time: Date(timeIntervalSince1970: ns / 1e9), millivolts: mv))
                return true
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func lineCount(_ url: URL) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0, last: UInt8?
        while let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty {
            count += chunk.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            last = chunk.last
        }
        return count + (last == nil || last == 10 ? 0 : 1)
    }

    private static func rows(url: URL) -> [[String]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseCSV(text)
    }
    private static func eventRows(url: URL) -> [SessionEventItem] {
        let parsed = rows(url: url)
        guard let header = parsed.first else { return [] }
        let indices = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })
        guard let ti = indices["timestamp_unix_ns"], let ni = indices["event"] else { return [] }
        return parsed.dropFirst().compactMap { row in
            guard row.count > max(ti, ni), let ns = Double(row[ti]) else { return nil }
            let detail = indices["detail"].flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            return SessionEventItem(time: Date(timeIntervalSince1970: ns/1e9), name: row[ni], detail: detail)
        }
    }
    private static func gapDurations(_ events: [SessionEventItem]) -> [TimeInterval] {
        var disconnected: Date?
        var gaps: [TimeInterval] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if event.name == "disconnected" { disconnected = event.time }
            if event.name == "connected", let start = disconnected {
                gaps.append(max(0, event.time.timeIntervalSince(start))); disconnected = nil
            }
        }
        return gaps
    }
    private static func parseCSV(_ text: String) -> [[String]] {
        var result: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, quotePending = false, afterQuote = false, skipLF = false
        let scalars = Array(text.unicodeScalars); var i = 0
        while i < scalars.count {
            let c = scalars[i]; i += 1
            if skipLF { skipLF = false; if c == "\n" { continue } }
            if quoted {
                if quotePending {
                    quotePending = false
                    if c == "\"" { field.append("\""); continue }
                    quoted = false; afterQuote = true
                } else if c == "\"" { quotePending = true; continue }
                else { field.unicodeScalars.append(c); continue }
            }
            if afterQuote && c != "," && c != "\n" && c != "\r" { field.unicodeScalars.append(c); afterQuote = false; continue }
            if c == "\"" && field.isEmpty { quoted = true }
            else if c == "," { row.append(field); field = ""; afterQuote = false }
            else if c == "\n" || c == "\r" { row.append(field); result.append(row); row = []; field = ""; afterQuote = false; if c == "\r" { skipLF = true } }
            else { field.unicodeScalars.append(c); afterQuote = false }
        }
        if quotePending { quoted = false }
        if !field.isEmpty || !row.isEmpty { row.append(field); result.append(row) }
        return result
    }
}
