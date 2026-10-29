import Foundation

enum TimeShiftError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// Applies one constant UTC offset to a completed PolarPAP session. Original
/// sensor-relative clocks and interval values are preserved, and output is a
/// separate sibling folder. CSV rows are streamed so overnight ECG files stay
/// bounded in memory.
enum TimeShiftProcessor {
    private static let csvNames: Set<String> = ["ecg", "rr", "hr", "hrv", "events", "clock"]
    private static let metadataTimelineKeys: Set<String> = ["start_unix_ns", "end_unix_ns", "mac_clock_unix_anchor_ns"]

    static func shifted(_ fields: [String], headers: [String], deltaNS: Int64,
                        utcFormatter: ISO8601DateFormatter) throws -> [String] {
        guard fields.count == headers.count else { throw TimeShiftError.invalid("CSV row has a different number of fields than its header.") }
        var result = fields
        for (index, header) in headers.enumerated() where header.hasSuffix("_unix_ns") {
            guard let value = Int64(fields[index]) else { throw TimeShiftError.invalid("Invalid Unix timestamp in column \(header).") }
            let (shifted, overflow) = value.addingReportingOverflow(deltaNS)
            guard !overflow else { throw TimeShiftError.invalid("Timestamp overflow in column \(header).") }
            result[index] = String(shifted)
        }
        for (index, header) in headers.enumerated() where header.hasSuffix("_utc") {
            let base = String(header.dropLast(4)) + "_unix_ns"
            guard let timeIndex = headers.firstIndex(of: base), let unix = Int64(result[timeIndex]) else {
                throw TimeShiftError.invalid("UTC column \(header) has no matching \(base) column.")
            }
            result[index] = utcFormatter.string(from: Date(timeIntervalSince1970: Double(unix) / 1e9))
        }
        return result
    }

    static func createShiftedCopy(source: URL, targetStart: Date) throws -> URL {
        let fm = FileManager.default
        let metadataURL = source.appendingPathComponent("session.json")
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let sourceStartString = metadata["start_unix_ns"] as? String,
              let sourceStart = Int64(sourceStartString) else {
            throw TimeShiftError.invalid("This folder does not contain a valid PolarPAP session.json.")
        }
        guard (metadata["status"] as? String) == "completed" else {
            throw TimeShiftError.invalid("Only completed sessions can be shifted. Stop or recover the recording first.")
        }
        let targetNS = Int64((targetStart.timeIntervalSince1970 * 1e9).rounded())
        let (deltaNS, overflow) = targetNS.subtractingReportingOverflow(sourceStart)
        guard !overflow else { throw TimeShiftError.invalid("The requested time shift is outside the supported range.") }
        guard deltaNS != 0 else { throw TimeShiftError.invalid("The selected start time matches the original session time.") }

        let parent = source.deletingLastPathComponent()
        let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX"); local.timeZone = .current; local.dateFormat = "yyyy-MM-dd_HHmmss"
        let folderBase = local.string(from: targetStart) + "_shifted"
        var final = parent.appendingPathComponent(folderBase, isDirectory: true)
        var collision = 2
        while fm.fileExists(atPath: final.path) {
            final = parent.appendingPathComponent("\(folderBase)-\(collision)", isDirectory: true); collision += 1
        }
        let staging = parent.appendingPathComponent(".PolarPAP-shift-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            var csvCount = 0
            for file in contents {
                let name = file.lastPathComponent
                if name == "session.json" { continue }
                if file.pathExtension.lowercased() == "csv" {
                    let stem = file.deletingPathExtension().lastPathComponent
                    let kind = stem.split(separator: "_").dropFirst().joined(separator: "_")
                    guard csvNames.contains(kind) else { continue }
                    try transformCSVFile(file, to: staging.appendingPathComponent(name), deltaNS: deltaNS, formatter: formatter)
                    csvCount += 1
                }
            }
            guard csvCount > 0 else { throw TimeShiftError.invalid("No PolarPAP CSV files were found in this folder.") }

            let oldTimeZone = metadata["time_zone"] as? String
            func shiftMetadataTimes(_ value: Any) throws -> Any {
                if let object = value as? [String: Any] {
                    var changed: [String: Any] = [:]
                    for (key, child) in object {
                        if metadataTimelineKeys.contains(key), let string = child as? String, let ns = Int64(string) {
                            let (newNS, failed) = ns.addingReportingOverflow(deltaNS)
                            guard !failed else { throw TimeShiftError.invalid("Timestamp overflow in session metadata.") }
                            changed[key] = String(newNS)
                        } else {
                            changed[key] = try shiftMetadataTimes(child)
                        }
                    }
                    return changed
                }
                if let values = value as? [Any] { return try values.map { try shiftMetadataTimes($0) } }
                return value
            }
            guard var adjusted = try shiftMetadataTimes(metadata) as? [String: Any] else { throw TimeShiftError.invalid("Cannot update session metadata.") }
            adjusted["time_shift_applied"] = true
            adjusted["time_shift_tool_version"] = "0.1.4"
            adjusted["time_shift_source_start_unix_ns"] = String(sourceStart)
            adjusted["time_shift_target_start_unix_ns"] = String(targetNS)
            adjusted["time_shift_offset_ns"] = String(deltaNS)
            adjusted["time_shift_created_at_unix_ns"] = String(Int64((Date().timeIntervalSince1970 * 1e9).rounded()))
            if let oldTimeZone { adjusted["time_shift_source_time_zone"] = oldTimeZone }
            adjusted["time_zone"] = TimeZone.current.identifier
            adjusted["utc_offset_at_start_s"] = TimeZone.current.secondsFromGMT(for: targetStart)
            let outputMetadata = try JSONSerialization.data(withJSONObject: adjusted, options: [.prettyPrinted, .sortedKeys])
            try outputMetadata.write(to: staging.appendingPathComponent("session.json"), options: .atomic)
            try fm.moveItem(at: staging, to: final)
            return final
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func transformCSVFile(_ source: URL, to destination: URL, deltaNS: Int64,
                                         formatter: ISO8601DateFormatter) throws {
        let input = try FileHandle(forReadingFrom: source)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            try? input.close(); throw TimeShiftError.invalid("Cannot create output file \(destination.lastPathComponent).")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        var field = Data(), fields: [Data] = [], headers: [String] = []
        var inQuotes = false, quotePending = false, afterQuote = false, skipLF = false
        var outputBuffer = Data()

        func encode(_ values: [String]) -> Data {
            var line = Data()
            for i in values.indices {
                if i > 0 { line.append(44) }
                let raw = Data(values[i].utf8)
                if raw.contains(44) || raw.contains(34) || raw.contains(10) || raw.contains(13) {
                    line.append(34)
                    for byte in raw { if byte == 34 { line.append(34) }; line.append(byte) }
                    line.append(34)
                } else { line.append(raw) }
            }
            line.append(10); return line
        }
        func finishRow() throws {
            fields.append(field); field = Data()
            let decoded = fields.compactMap { String(data: $0, encoding: .utf8) }
            guard decoded.count == fields.count else {
                throw TimeShiftError.invalid("CSV contains invalid UTF-8 in \(source.lastPathComponent).")
            }
            let values = decoded
            fields.removeAll(keepingCapacity: true)
            if headers.isEmpty {
                headers = values
                guard headers.contains(where: { $0.hasSuffix("_unix_ns") }) else {
                    throw TimeShiftError.invalid("No Unix timestamp columns found in \(source.lastPathComponent).")
                }
                outputBuffer.append(encode(headers))
            } else {
                let shiftedValues = try shifted(values, headers: headers, deltaNS: deltaNS, utcFormatter: formatter)
                outputBuffer.append(encode(shiftedValues))
            }
            if outputBuffer.count >= 65_536 { try output.write(contentsOf: outputBuffer); outputBuffer.removeAll(keepingCapacity: true) }
        }

        while true {
            guard let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty else { break }
            let bytes = [UInt8](chunk); var i = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                if skipLF { skipLF = false; if b == 10 { continue } }
                if inQuotes {
                    if quotePending {
                        quotePending = false
                        if b == 34 { field.append(34); continue }
                        inQuotes = false; afterQuote = true
                    } else if b == 34 { quotePending = true; continue }
                    else { field.append(b); continue }
                }
                if afterQuote && b != 44 && b != 10 && b != 13 {
                    throw TimeShiftError.invalid("Unexpected characters after a quoted field in \(source.lastPathComponent).")
                }
                if b == 34 {
                    guard field.isEmpty && !afterQuote else { throw TimeShiftError.invalid("Malformed quoted CSV field in \(source.lastPathComponent).") }
                    inQuotes = true
                } else if b == 44 {
                    fields.append(field); field = Data(); afterQuote = false
                } else if b == 10 || b == 13 {
                    try finishRow(); afterQuote = false; if b == 13 { skipLF = true }
                } else { field.append(b); afterQuote = false }
            }
        }
        if quotePending { inQuotes = false; quotePending = false; afterQuote = true }
        guard !inQuotes else { throw TimeShiftError.invalid("Unterminated quoted field in \(source.lastPathComponent).") }
        if !field.isEmpty || !fields.isEmpty || headers.isEmpty { try finishRow() }
        guard !headers.isEmpty else { throw TimeShiftError.invalid("No CSV header found in \(source.lastPathComponent).") }
        if !outputBuffer.isEmpty { try output.write(contentsOf: outputBuffer) }
        try output.synchronize()
    }
}
