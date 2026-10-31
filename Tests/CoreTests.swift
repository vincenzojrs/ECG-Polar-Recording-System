import Foundation

@main struct CoreTests {
    static var assertions = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError("FAILED: \(message)") }
    }
    static func near(_ a: Double?, _ b: Double, _ message: String) { check(a != nil && abs(a!-b)<0.00001, message) }
    static func throwsError(_ name: String, _ f: () throws -> Void) {
        do { try f(); fatalError("Expected error: \(name)") } catch { assertions += 1 }
    }
    static func main() throws {
        let firstZoom = PlotWindowMath.selected(offset: 0, visible: 0, total: 3600, lower: 0.25, upper: 0.5)
        check(firstZoom != nil && abs(firstZoom!.0 - 900) < 0.001 && abs(firstZoom!.1 - 900) < 0.001, "drag zoom maps the night to the selected time")
        let nestedZoom = PlotWindowMath.selected(offset: 900, visible: 900, total: 3600, lower: 0.8, upper: 0.2)
        check(nestedZoom != nil && abs(nestedZoom!.0 - 1080) < 0.001 && abs(nestedZoom!.1 - 540) < 0.001, "reverse drag and nested zoom use the current time window")
        check(PlotWindowMath.selected(offset: 0, visible: 0, total: 3600, lower: 0.5, upper: 0.5) == nil, "empty drag does not zoom")
        let hr = try HRPacket.decode(Data([0x16,60, 0x00,0x04, 0x80,0x03]))
        check(hr.bpm == 60 && hr.contact == true && hr.rr == [1024,896], "HR contact + multiple RR")
        let wide = try HRPacket.decode(Data([0x19,0x2c,0x01,0xff,0,0,4]))
        check(wide.bpm == 300 && wide.contact == nil && wide.rr == [1024], "16-bit HR + energy")
        for b: [UInt8] in [[],[1],[1,60],[0x10,60,1],[0x08,60,1]] { throwsError("short HR") { _ = try HRPacket.decode(Data(b)) } }
        let sensor: Int64 = 600_000_000_000_000_000
        var bytes: [UInt8] = [0]
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: sensor >> (8*$0)) }
        bytes += [0, 0xff,0xff,0xff, 0,0,0x80, 0xff,0xff,0x7f]
        let frame = try ECGFrame.decode(Data(bytes))
        check(frame.lastSensorNS == sensor && frame.microvolts == [-1,-8388608,8388607], "signed 24-bit and LE timestamp")
        throwsError("ECG truncated") { _ = try ECGFrame.decode(Data(bytes.dropLast())) }
        var compressed = bytes; compressed[9] = 0x80
        throwsError("compressed ECG") { _ = try ECGFrame.decode(Data(compressed)) }
        let receipt: Int64 = 1_790_000_000_000_000_000
        var rrTime = RRTimeline()
        let batch = rrTime.map([1024,1024], receivedNS:receipt)
        check(batch.times == [receipt-1_000_000_000,receipt], "RR batch preserves order and spacing")
        let jittered = rrTime.map([1024], receivedNS:receipt+1_100_000_000)
        check(jittered.times == [receipt+1_000_000_000] && !jittered.reanchored,"RR cumulative timing ignores small arrival jitter")
        let lost = rrTime.map([1024], receivedNS:receipt+8_000_000_000)
        check(lost.reanchored && lost.times == [receipt+8_000_000_000], "RR loss reanchors without bridging")
        check(rrTime.map([],receivedNS:receipt+9_000_000_000).times.isEmpty,"HR without RR creates no beats")
        let shiftHeaders = ["timestamp_unix_ns", "timestamp_utc", "received_unix_ns", "polar_timestamp_ns", "detail"]
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; iso.timeZone = TimeZone(secondsFromGMT: 0)
        let shiftedRow = try TimeShiftProcessor.shifted(["1790000000000000000", "old", "1790000000000000005", "600000000000", "comma, quote \" and newline\nkept"], headers: shiftHeaders, deltaNS: 3_600_000_000_000, utcFormatter: iso)
        check(shiftedRow[0] == "1790003600000000000" && shiftedRow[2] == "1790003600000000005", "time shift applies exact offset to all Unix timestamps")
        check(shiftedRow[1] == "2026-09-21T15:13:20.000Z" && shiftedRow[3] == "600000000000", "time shift rebuilds UTC and preserves Polar sensor clock")
        check(shiftedRow[4] == "comma, quote \" and newline\nkept", "time shift preserves quoted CSV content")
        let shiftRoot = FileManager.default.temporaryDirectory.appendingPathComponent("polarpap-shift-test-\(UUID().uuidString)", isDirectory: true)
        let sourceFolder = shiftRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shiftRoot) }
        let testStart: Int64 = 1_700_000_000_000_000_000
        let metadata: [String: Any] = ["status": "completed", "start_unix_ns": String(testStart), "end_unix_ns": String(testStart+60_000_000_000), "mac_clock_unix_anchor_ns": String(testStart), "time_shift_created_at_unix_ns": "1600000000000000000", "time_zone": "UTC"]
        try JSONSerialization.data(withJSONObject: metadata).write(to: sourceFolder.appendingPathComponent("session.json"))
        let csvFixtures: [String: String] = [
            "000_ecg.csv": SessionWriter.headers["ecg"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,600000000000,10,0.010,\(testStart),1,sensor_relative_mac_anchor_estimated\n",
            "000_rr.csv": SessionWriter.headers["rr"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,1024,1000.000000,60,\(testStart),true,true,candidate_only_not_verified_NN,1,cumulative_rr_mac_receipt_anchor_estimated\n",
            "000_hr.csv": SessionWriter.headers["hr"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,60,true,1,mac_notification_receipt\n",
            "000_hrv.csv": SessionWriter.headers["hrv"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,\(testStart+300_000_000_000),300.000000,true,1,1,1.000000,1.000000,false,1000,60,0,0,0,0,,,,,false\n",
            "000_events.csv": SessionWriter.headers["events"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,test,\"quoted, detail\"\n",
            "000_clock.csv": SessionWriter.headers["clock"]! + "\n\(testStart),2023-11-14T22:13:20.000Z,\(testStart),1234,600000000000,100,1\n"
        ]
        for (name, contents) in csvFixtures { try contents.write(to: sourceFolder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let later = testStart + 3_600_000_000_000
        try (SessionWriter.headers["hr"]! + "\n\(later),time,80,true,1,test\n").write(to: sourceFolder.appendingPathComponent("001_hr.csv"), atomically: true, encoding: .utf8)
        try (SessionWriter.headers["rr"]! + "\n\(later),time,1024,1000,80,\(later),true,true,test,1,test\n").write(to: sourceFolder.appendingPathComponent("001_rr.csv"), atomically: true, encoding: .utf8)
        let laterHRV = csvFixtures["000_hrv.csv"]!.replacingOccurrences(of: String(testStart), with: String(later)).replacingOccurrences(of: String(testStart+300_000_000_000), with: String(later+300_000_000_000))
        try laterHRV.write(to: sourceFolder.appendingPathComponent("001_hrv.csv"), atomically: true, encoding: .utf8)
        try (SessionWriter.headers["ecg"]! + "\n\(later),time,600000000000,25,0.025,\(later),1,test").write(to: sourceFolder.appendingPathComponent("001_ecg.csv"), atomically: true, encoding: .utf8)
        let summaries = try SessionStore.scan(root: shiftRoot)
        let detail = try SessionStore.detail(for: summaries[0])
        check(detail.pulseRate.count == 2 && detail.pulseRate[0].bpm == 60 && detail.pulseRate[1].bpm == 80, "rotated heart-rate files are parsed and sorted")
        near(summaries[0].meanHR, 70, "mean heart rate includes each rotated file")
        check(detail.rr.count == 2 && detail.rr[0].time < detail.rr[1].time, "rotated RR files are sorted")
        check(detail.hrv.count == 2 && detail.hrv[0].start < detail.hrv[1].start, "rotated HRV files are parsed and sorted")
        let rawWindow = try SessionStore.ecgWindow(folder: sourceFolder, start: Date(timeIntervalSince1970: Double(testStart)/1e9))
        check(rawWindow.count == 1 && rawWindow[0].millivolts == 0.01, "ECG window reads original samples")
        let laterWindow = try SessionStore.ecgWindow(folder: sourceFolder, start: Date(timeIntervalSince1970: Double(later)/1e9))
        check(laterWindow.count == 1 && laterWindow[0].millivolts == 0.025, "ECG window reads a final line without newline across rotated files")
        let createdBeforeShift = Int64((Date().timeIntervalSince1970 * 1e9).rounded())
        let shiftedFolder = try TimeShiftProcessor.createShiftedCopy(source: sourceFolder, targetStart: Date(timeIntervalSince1970: 1_700_003_600))
        let createdAfterShift = Int64((Date().timeIntervalSince1970 * 1e9).rounded())
        let shiftedMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: shiftedFolder.appendingPathComponent("session.json"))) as! [String: Any]
        let originalMetadata = try JSONSerialization.jsonObject(with: Data(contentsOf: sourceFolder.appendingPathComponent("session.json"))) as! [String: Any]
        check(shiftedMetadata["start_unix_ns"] as? String == String(testStart+3_600_000_000_000), "session metadata start shifts")
        let createdStamp = Int64(shiftedMetadata["time_shift_created_at_unix_ns"] as? String ?? "0") ?? 0
        check(createdStamp >= createdBeforeShift && createdStamp <= createdAfterShift, "time-shift provenance uses actual creation time")
        check(originalMetadata["start_unix_ns"] as? String == String(testStart), "source session stays unchanged")
        let shiftedRR = try String(contentsOf: shiftedFolder.appendingPathComponent("000_rr.csv"), encoding: .utf8)
        check(shiftedRR.contains("1700003600000000000,2023-11-14T23:13:20.000Z") && shiftedRR.contains("candidate_only_not_verified_NN"), "end-to-end shift updates timestamps and keeps data fields")
        let shiftedEvents = try String(contentsOf: shiftedFolder.appendingPathComponent("000_events.csv"), encoding: .utf8)
        check(shiftedEvents.contains("\"quoted, detail\""), "streamed time shift preserves quoted commas")
        // The optional export filter compares across rotated files and preserves source rows.
        let rrHeader = SessionWriter.headers["rr"]!
        let rr = { (t: Int64) in "\(t),time,1024,1000,80,\(t),true,true,test,1,test\n" }
        let rawRR = rrHeader + "\n" + rr(testStart + 2_000_000_000) + rr(testStart + 1_000_000_000)
        try rawRR.write(to: sourceFolder.appendingPathComponent("000_rr.csv"), atomically: true, encoding: .utf8)
        try (rrHeader + "\n" + rr(testStart + 1_500_000_000) + rr(testStart + 3_000_000_000)).write(to: sourceFolder.appendingPathComponent("001_rr.csv"), atomically: true, encoding: .utf8)
        let filteredFolder = try TimeShiftProcessor.createShiftedCopy(source: sourceFolder, targetStart: Date(timeIntervalSince1970: 1_700_003_600), dropBackwardRR: true)
        let filteredMeta = try JSONSerialization.jsonObject(with: Data(contentsOf: filteredFolder.appendingPathComponent("session.json"))) as! [String: Any]
        let filterInfo = filteredMeta["rr_timestamp_filter"] as? [String: Any]
        check(filterInfo?["dropped_rows"] as? Int == 2, "RR filter counts backwards rows across rotated files")
        let sourceAfterFilter = try String(contentsOf: sourceFolder.appendingPathComponent("000_rr.csv"), encoding: .utf8)
        check(sourceAfterFilter == rawRR, "RR filter preserves original source")
        let filteredSecond = try String(contentsOf: filteredFolder.appendingPathComponent("001_rr.csv"), encoding: .utf8)
        check(filteredSecond.split(separator: "\n").count == 2, "RR filter keeps only ordered rows")
        var timeline = ECGTimeline()
        let first = timeline.map(frame, receiptNS: receipt, frozen: false)
        check(first.unix.last == receipt, "frame endpoint anchor")
        check(first.sensor[1]-first.sensor[0] >= 7_692_307, "130Hz interpolation")
        let next = ECGFrame(lastSensorNS: sensor+23_076_923, microvolts: [0,1,2])
        let second = timeline.map(next, receiptNS: receipt+100_000_000, frozen: true)
        check(second.unix.last == receipt+23_076_923, "frozen timeline ignores arrival jitter")
        let gap = ECGFrame(lastSensorNS: sensor+2_000_000_000, microvolts: [0,1,2])
        let afterGap = timeline.map(gap, receiptNS: receipt+2_100_000_000, frozen: true)
        check(afterGap.issue == "ecg_gap_or_clock_discontinuity", "gap is explicit")
        check(afterGap.sensor[1]-afterGap.sensor[0] < 8_000_000, "do not stretch samples across loss")
        let reset = timeline.map(ECGFrame(lastSensorNS: 100_000_000, microvolts:[1]), receiptNS: receipt+3_000_000_000, frozen:true)
        check(reset.issue == "sensor_clock_reset" && reset.unix.last == receipt+3_000_000_000, "clock reset gets new anchor")
        var screen = RRScreen()
        check(!screen.classify(100,contact:true).0, "short interval rejected")
        check(!screen.classify(1024,contact:false).0, "contact loss rejected")
        for _ in 0..<8 { check(screen.classify(1024,contact:true).0, "steady RR accepted") }
        check(!screen.classify(1600,contact:true).0, "outlier rejected")
        let raws: [UInt16] = [1024, 896, 1152]
        var t: Int64 = 0
        let beats = raws.map { raw -> Beat in t += Int64(raw)*1_000_000_000/1024; return Beat(ns:t,raw:raw,accepted:true,reason:"test",segment:1) }
        let variability = Variability.compute(beats,screened:false)
        near(variability.mean, 1000, "mean RR")
        near(variability.sd, 125, "sample standard deviation n-1")
        near(variability.rmssd, sqrt((125.0*125+250*250)/2), "RMSSD hand calculation")
        near(variability.pnn50, 100, "pNN50 denominator is successive pair count")
        let rejected = [beats[0], Beat(ns:beats[1].ns,raw:896,accepted:false,reason:"outlier",segment:1), beats[2]]
        check(Variability.compute(rejected,screened:true).pairs == 0, "no bridge across rejected interval")
        let disconnected = [beats[0],Beat(ns:beats[1].ns,raw:896,accepted:true,reason:"test",segment:2)]
        check(Variability.compute(disconnected,screened:false).pairs == 0, "no bridge across reconnect")
        let delayed = [beats[0],Beat(ns:beats[1].ns+10_000_000_000,raw:896,accepted:true,reason:"test",segment:1)]
        check(Variability.compute(delayed,screened:false).pairs == 0,"no bridge across undetected time gap within same segment")
        check(Variability.compute([beats[0]],screened:false).sd == nil,"single RR has no sample SD")
        let exact50 = [Beat(ns:1_000_000_000,raw:1024,accepted:true,reason:"test",segment:1),Beat(ns:2_062_500_000,raw:1088,accepted:true,reason:"test",segment:1)]
        near(Variability.compute(exact50,screened:false).pnn50,100,"62.5ms successive change exceeds 50ms")
        var accumulator = WindowAccumulator(startNS:receipt)
        for i in 1..<300 { let b = Beat(ns:receipt+Int64(i)*1_000_000_000,raw:1024,accepted:true,reason:"test",segment:1); _ = accumulator.append(b) }
        let completed = accumulator.advance(to:receipt+300_000_000_000)
        check(completed.count == 1 && completed[0].usable && completed[0].beats.count == 299, "complete high-quality window")
        near(completed[0].screened.rmssd,0,"steady HRV zero")
        let empties = accumulator.advance(to:receipt+900_000_000_000)
        check(empties.count == 2 && empties.allSatisfy { !$0.usable }, "empty windows declared unusable")
        let partial = HRVWindow(startNS:receipt,endNS:receipt+299_000_000_000,beats:completed[0].beats,complete:false)
        check(!partial.usable,"partial window cannot qualify despite high coverage")
        var long = WindowAccumulator(startNS:receipt)
        var windows = 0, peak = 0
        // 24 hours of RR prove memory is bounded to one 5-minute window.
        for i in 1...86400 {
            let b = Beat(ns:receipt+Int64(i)*1_000_000_000,raw:1024,accepted:true,reason:"test",segment:1)
            windows += long.append(b).count; peak = max(peak,long.beats.count)
        }
        check(windows == 288 && peak <= 300, "24-hour RR window memory bound")
        var longECG = ECGTimeline(), countECG = 0
        let values = [Int32](repeating:0,count:73)
        for i in 1...77000 {
            let end = sensor+Int64((Double(i*73)/130*1e9).rounded())
            let mapped = longECG.map(ECGFrame(lastSensorNS:end,microvolts:values),receiptNS:receipt+(end-sensor),frozen:true)
            if mapped.issue != nil { fatalError("Unexpected gap in long ECG simulation") }
            countECG += mapped.unix.count
        }
        check(countECG == 5_621_000,"12-hour ECG timeline simulation without gaps or accumulated sample-count error")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("PolarPAP-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        let writer = try SessionWriter(parent:temp,startNS:receipt,device:"Synthetic",deviceID:"test",clock:MacClock(),test:true)
        try writer.event(receipt,"test_event","a,b\n\"quoted\"")
        try writer.window(completed[0])
        try writer.event(receipt+3_600_000_000_000,"rotation","hour one")
        // Estimated RR can fall just before an already rotated hour. Do not
        // reopen/overwrite a previous file; row timestamps remain authoritative.
        try writer.row("hr",ns:receipt+3_599_000_000_000,[String(receipt),writer.time(receipt),"60","true","1","test"])
        try writer.finish(receipt+3_601_000_000_000,status:"completed")
        let files = try FileManager.default.contentsOfDirectory(atPath:writer.directory.path)
        check(files.contains("000_ecg.csv") && files.contains("001_ecg.csv"),"hourly rotation")
        let event = try String(contentsOf:writer.directory.appendingPathComponent("000_events.csv"),encoding:.utf8)
        check(event.contains("\"a,b\n\"\"quoted\"\"\""),"CSV escaping including newline and quote")
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:writer.directory.appendingPathComponent("session.json"))) as! [String:Any]
        check(json["status"] as? String == "completed" && json["synthetic"] as? Bool == true, "metadata finalized")
        throwsError("closed file") { try writer.event(receipt,"late","no") }
        check(csv("x,y") == "\"x,y\"", "CSV separator escaped")
        check(csv("5.0.0\0") == "\"5.0.0\"", "Polar firmware trailing NUL excluded from CSV")
        print("PASS: \(assertions) assertions; binary decoders, timeline, HRV formulas/quality, 24-hour bounded memory, CSV rotation/finalization")
        if let i = CommandLine.arguments.firstIndex(of:"--fixture"), CommandLine.arguments.count > i+1 {
            try fixture(parent:URL(fileURLWithPath:CommandLine.arguments[i+1]),start:receipt)
        }
    }
    static func fixture(parent:URL,start:Int64) throws {
        let writer = try SessionWriter(parent:parent,startNS:start,device:"SYNTHETIC NOT HUMAN",deviceID:"fixture",clock:MacClock(),test:true)
        var acc = WindowAccumulator(startNS:start)
        for second in 0..<360 {
            for j in 0..<130 {
                let ns = start+Int64(second)*1_000_000_000+Int64((Double(j)*1e9/130).rounded())
                let uv = Int32((sin(Double(j)*2 * .pi/130)*1000).rounded())
                try writer.row("ecg",ns:ns,[String(ns),writer.time(ns),String(ns-start),String(uv),number(Double(uv)/1000),String(ns),"1","synthetic_fixture"])
            }
            let ns = start+Int64(second+1)*1_000_000_000
            let b = Beat(ns:ns,raw:1024,accepted:true,reason:"synthetic",segment:1)
            for window in acc.append(b) { try writer.window(window) }
            try writer.row("rr",ns:ns,[String(ns),writer.time(ns),"1024","1000.000000","60",String(ns),"true","true","synthetic","1","synthetic_fixture"])
            try writer.row("hr",ns:ns,[String(ns),writer.time(ns),"60","true","1","synthetic_fixture"])
            if second == 30 { try writer.event(ns,"test_event","synthetic event, with comma\nand newline") }
        }
        if let partial = acc.partial(endNS:start+361_000_000_000) { try writer.window(partial) }
        try writer.finish(start+361_000_000_000,status:"completed")
        print("FIXTURE: \(writer.directory.path)")
    }
}
