import SwiftUI
import AppKit
import CoreBluetooth

struct FoundDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    var id: UUID { peripheral.identifier }
}

final class Recorder: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [FoundDevice] = []
    @Published var selected: UUID?
    @Published var status = "Bluetooth not started"
    @Published var detail = "Select Scan to find your Polar H10."
    @Published var scanning = false
    @Published var connected = false
    @Published var ecgReady = false
    @Published var recording = false
    @Published var hr: Int?
    @Published var rr: Double?
    @Published var battery: Int?
    @Published var samples: [Double] = []
    @Published var sampleCount = 0
    @Published var beatCount = 0
    @Published var elapsed = "00:00:00"
    @Published var windowRMSSD: Double?
    @Published var windowQuality = "Waiting for a complete 5-minute window"
    @Published var errorText: String?
    @Published var folderName = "Choose a folder before recording"
    @Published var lastFolder: URL?
    @Published var canConnect = false
    @Published var timeShiftFolder: URL?
    @Published var timeShiftOriginalStart: Date?
    @Published var timeShiftOriginalEnd: Date?
    @Published var timeShiftDevice = "Polar H10"
    @Published var timeShiftZone = TimeZone.current.identifier
    @Published var timeShiftTargetStart = Date()
    @Published var timeShiftTargetSecond = Calendar.current.component(.second, from: Date())
    @Published var timeShiftTargetText = Recorder.shiftDateFormatter.string(from: Date())
    @Published var timeShiftTargetTextValid = true
    @Published var timeShiftOutput: URL?
    @Published var timeShiftMessage: String?
    @Published var timeShiftBusy = false
    @Published var page: AppPage = .record
    @Published var sessionsRoot: URL?
    @Published var sessions: [SavedSession] = []
    @Published var selectedSession: SavedSession?
    @Published var selectedSessionDetail: SessionDetail?
    @Published var sessionTab: SessionTab = .overview
    @Published var sessionChart: SessionChart = .rr
    @Published var hrvDisplayMode: HRVDisplayMode = .candidate
    @Published var sessionsLoading = false
    @Published var sessionsMessage: String?
    @Published var liveRecentEvents: [SessionEventItem] = []
    @Published var sensorContact = "Unknown"
    @Published var recordingStart: Date?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cp: CBCharacteristic?
    private var ecgChar: CBCharacteristic?
    private var hrChar: CBCharacteristic?
    private var pendingCommand: UInt8?
    private var commandSent: TimeInterval = 0
    private var cpData = Data()
    private var ecgStarted = false
    private var deviceName = "Polar H10"
    private var deviceFirmware = "unknown"
    private var clock = MacClock()
    private var timeline = ECGTimeline()
    private var writer: SessionWriter?
    private var accumulator: WindowAccumulator?
    private var screen = RRScreen()
    private var rrTimeline = RRTimeline()
    private var lastHRReceiptNS: Int64?
    private var lastECGReceiptNS: Int64?
    private var lastECGGapLogged = false
    private var lastHRGapLogged = false
    private var connectionSegment = 0
    private var parentFolder: URL?
    private var activity: NSObjectProtocol?
    private var timer: Timer?
    fileprivate static let shiftDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "dd/MM/yyyy, HH:mm:ss"
        return formatter
    }()
    private var ticks = 0
    private var desiredConnection = false
    private var requestScan = false
    private var reconnectAt: TimeInterval?
    private var connectedAt: TimeInterval?
    private var settingsRequested = false
    private var plotBuffer: [Double] = []
    private var lastClockWarningNS: Int64 = 0
    private var cliRecordingSeconds: Double?
    private var cliParent: URL?
    private var cliDeadline: TimeInterval?
    private var cliRecordStart: TimeInterval?
    private var testLog: FileHandle?

    static let pmd = CBUUID(string: "FB005C80-02E7-F387-1CAD-8ACD2D8DF0C8")
    static let cpID = CBUUID(string: "FB005C81-02E7-F387-1CAD-8ACD2D8DF0C8")
    static let dataID = CBUUID(string: "FB005C82-02E7-F387-1CAD-8ACD2D8DF0C8")
    static let hrID = CBUUID(string: "2A37")
    private let hrService = CBUUID(string: "180D")

    override init() {
        super.init()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hardware-test"), args.count > i+2,
           let seconds = Double(args[i+1]), seconds > 0 {
            cliRecordingSeconds = min(seconds, 3600)
            cliParent = URL(fileURLWithPath: args[i+2], isDirectory: true)
            cliDeadline = ProcessInfo.processInfo.systemUptime + 90
            try? FileManager.default.createDirectory(at: cliParent!, withIntermediateDirectories: true)
            let log = cliParent!.appendingPathComponent("hardware-test.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            testLog = try? FileHandle(forWritingTo: log)
            DispatchQueue.main.async { self.scan() }
        }
    }
    private func log(_ text: String) {
        guard let testLog else { return }
        try? testLog.write(contentsOf: Data((ISO8601DateFormatter().string(from: Date())+" "+text+"\n").utf8))
        try? testLog.synchronize()
    }
    func scan() {
        errorText = nil
        guard !recording, !desiredConnection else { return }
        requestScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central.state == .poweredOn { beginScan() }
        else { centralManagerDidUpdateState(central) }
    }
    private func beginScan() {
        devices = []; selected = nil; scanning = true
        status = "Scanning"; detail = "Wear the H10 and moisten the electrodes."
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log("Scanning")
        DispatchQueue.main.asyncAfter(deadline: .now()+20) { [weak self] in
            guard let self, self.scanning else { return }
            self.stopScan(); self.status = self.devices.isEmpty ? "No H10 found" : "Select a device"
        }
    }
    func stopScan() { central?.stopScan(); scanning = false; requestScan = false }
    func connectSelected() {
        guard !recording, let id = selected, let found = devices.first(where: { $0.id == id }) else { return }
        if let previous = peripheral, previous.identifier != id { central.cancelPeripheralConnection(previous) }
        stopScan(); peripheral = found.peripheral; deviceName = found.name
        desiredConnection = true; errorText = nil; status = "Connecting"; detail = found.name
        resetTransport(); peripheral!.delegate = self
        connectedAt = ProcessInfo.processInfo.systemUptime
        central.connect(peripheral!, options: nil); log("Connecting \(found.name)")
    }
    private func resetTransport() {
        cp = nil; ecgChar = nil; hrChar = nil; ecgStarted = false; settingsRequested = false
        pendingCommand = nil; cpData = Data(); ecgReady = false
        timeline.reset(); rrTimeline = RRTimeline(); lastHRReceiptNS = nil; lastECGReceiptNS = nil
        lastECGGapLogged = false; lastHRGapLogged = false; screen = RRScreen()
        plotBuffer.removeAll(keepingCapacity: true); samples = []
    }
    func disconnect() {
        guard !recording else { return }
        desiredConnection = false; reconnectAt = nil; connectedAt = nil
        if let p = peripheral {
            if let cp, cp.isNotifying, ecgStarted { p.writeValue(Data([3,0]), for: cp, type: .withResponse) }
            central.cancelPeripheralConnection(p)
        }
        connected = false; resetTransport(); hr = nil; rr = nil; status = "Disconnected"
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        canConnect = central.state == .poweredOn
        switch central.state {
        case .poweredOn:
            if desiredConnection, let p = peripheral { central.connect(p, options: nil); connectedAt = ProcessInfo.processInfo.systemUptime }
            else if requestScan { beginScan() }
            else { status = "Bluetooth ready" }
        case .unauthorized: status = "Bluetooth permission required"; errorText = "Allow PolarPAP in System Settings → Privacy & Security → Bluetooth, then scan again."
        case .poweredOff: status = "Bluetooth is off"; detail = "Enable Bluetooth in System Settings."
        case .unsupported: status = "Bluetooth LE unavailable"
        default: status = "Bluetooth initializing"
        }
        if central.state != .poweredOn {
            connected = false; scanning = false; ecgReady = false
            event("bluetooth_state", "\(central.state.rawValue)")
        }
        log(status)
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().contains("polar h10") else { return }
        if !devices.contains(where: { $0.id == p.identifier }) { devices.append(FoundDevice(peripheral: p, name: name, rssi: RSSI.intValue)) }
        if selected == nil { selected = p.identifier }
        log("Found \(name), RSSI \(RSSI)")
        if cliRecordingSeconds != nil && !desiredConnection { connectSelected() }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        connected = true; connectedAt = ProcessInfo.processInfo.systemUptime; reconnectAt = nil
        resetTransport(); connectionSegment += 1; status = "Preparing ECG"
        detail = "Discovering HR and Polar measurement services…"
        p.delegate = self; p.discoverServices([Self.pmd, hrService, CBUUID(string: "180F"), CBUUID(string: "180A")])
        event("connected", "\(deviceName); segment=\(connectionSegment)"); log("Connected")
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { lostConnection(error?.localizedDescription ?? "Connection failed") }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { lostConnection(error?.localizedDescription ?? "Disconnected") }
    private func lostConnection(_ reason: String) {
        connected = false; connectedAt = nil; hr = nil; rr = nil; resetTransport()
        event("disconnected", reason); log(reason)
        status = desiredConnection ? "Reconnecting" : "Disconnected"
        detail = desiredConnection ? "Recording keeps running; missing data are left blank." : "Scan to connect again."
        if desiredConnection { reconnectAt = ProcessInfo.processInfo.systemUptime+3 }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { transportError(error.localizedDescription); return }
        guard let services = p.services, services.contains(where: { $0.uuid == Self.pmd }) else {
            transportError("Polar ECG service missing. Check that this is an H10 with current firmware."); return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { transportError(error.localizedDescription); return }
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.cpID: cp = c; p.setNotifyValue(true, for: c)
            case Self.dataID: ecgChar = c; p.setNotifyValue(true, for: c)
            case Self.hrID: hrChar = c; p.setNotifyValue(true, for: c)
            case CBUUID(string: "2A19"), CBUUID(string: "2A26"): p.readValue(for: c)
            default: break
            }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        if let error { transportError("Notification failed: \(error.localizedDescription)"); return }
        if !c.isNotifying { transportError("Notification disabled for \(c.uuid)"); return }
        if cp?.isNotifying == true, ecgChar?.isNotifying == true, !settingsRequested {
            settingsRequested = true; command(1, payload: Data([1,0]))
        }
    }
    private func command(_ opcode: UInt8, payload: Data) {
        guard let p = peripheral, let cp else { return }
        pendingCommand = opcode; commandSent = ProcessInfo.processInfo.systemUptime; cpData.removeAll()
        p.writeValue(payload, for: cp, type: .withResponse)
        log("PMD command \(payload.map { String(format: "%02x", $0) }.joined())")
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error { pendingCommand = nil; transportError("BLE write failed: \(error.localizedDescription)") }
    }
    private func controlResponse(_ data: Data) throws {
        let b = Array(data)
        guard b.count >= 4, b[0] == 0xf0, b[2] == 0 else { return }
        log("PMD response \(b.map { String(format: "%02x", $0) }.joined())")
        guard let pending = pendingCommand, b[1] == pending else { return }
        guard b[3] == 0 else { pendingCommand = nil; throw SignalError.invalid("Polar ECG command \(b[1]) rejected (code \(b[3])). Close other sensor apps and reconnect.") }
        if b.count > 5 { cpData.append(contentsOf: b[5...]) }
        if b.count > 4, b[4] != 0 { return }
        pendingCommand = nil
        if pending == 1 {
            // PMD settings: type, count, little-endian values. Select exactly the
            // H10's documented ECG format; never silently decode another resolution.
            let settings = Array(cpData); var pos = 0, rates: [Int] = [], resolutions: [Int] = []
            let sizes: [UInt8: Int] = [0:2,1:2,2:2,3:4,4:1,5:4]
            while pos < settings.count {
                guard pos+2 <= settings.count, let size = sizes[settings[pos]] else { throw SignalError.invalid("Unknown ECG settings format") }
                let kind = settings[pos], count = Int(settings[pos+1]); pos += 2
                guard pos+count*size <= settings.count else { throw SignalError.invalid("Truncated ECG settings") }
                var values: [Int] = []
                for _ in 0..<count { var v = 0; for j in 0..<size { v |= Int(settings[pos+j]) << (8*j) }; pos += size; values.append(v) }
                if kind == 0 { rates = values }; if kind == 1 { resolutions = values }
            }
            guard rates.contains(130), resolutions.contains(14) else { throw SignalError.invalid("H10 does not advertise ECG 130 Hz / 14-bit. Found rates \(rates), resolutions \(resolutions)") }
            command(2, payload: Data([2,0, 0,1,130,0, 1,1,14,0]))
        } else if pending == 2 {
            ecgStarted = true; status = "Calibrating time"; detail = "Collecting preview packets before recording."
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let error { transportError(error.localizedDescription); return }
        guard let data = c.value else { return }
        do {
            switch c.uuid {
            case Self.cpID: try controlResponse(data)
            case Self.dataID:
                guard data.first == 0 else { return }
                try consumeECG(ECGFrame.decode(data))
            case Self.hrID: try consumeHR(HRPacket.decode(data))
            case CBUUID(string: "2A19"): battery = data.first.map(Int.init)
            case CBUUID(string: "2A26"): deviceFirmware = (String(data: data, encoding: .utf8) ?? "unknown").trimmingCharacters(in: .controlCharacters); event("firmware", deviceFirmware)
            default: break
            }
        } catch { transportError(error.localizedDescription) }
    }
    private func consumeECG(_ frame: ECGFrame) throws {
        let received = clock.nowNS()
        let mapped = timeline.map(frame, receiptNS: received, frozen: recording)
        if let issue = mapped.issue { event(issue, "sensor_ns=\(frame.lastSensorNS)"); connectionSegment += 1; rrTimeline = RRTimeline(); screen = RRScreen() }
        lastECGReceiptNS = received; lastECGGapLogged = false
        plotBuffer.append(contentsOf: frame.microvolts.map { Double($0)/1000 })
        if plotBuffer.count > 1300 { plotBuffer.removeFirst(plotBuffer.count-1300) }
        if timeline.calibrationFrames >= 10 && ecgStarted { ecgReady = true; status = recording ? "Recording" : "Ready"; detail = recording ? "ECG + HR + RR · files saved locally" : "ECG 130 Hz · Mac time anchor · ready to record" }
        guard let writer else { return }
        for i in frame.microvolts.indices {
            guard mapped.unix[i] >= writer.startNS else { continue }
            try writer.row("ecg", ns: received, [String(mapped.unix[i]), writer.time(mapped.unix[i]), String(mapped.sensor[i]), String(frame.microvolts[i]), number(Double(frame.microvolts[i])/1000), String(received), String(connectionSegment), "sensor_relative_mac_anchor_estimated"])
            sampleCount += 1
        }
    }
    private func consumeHR(_ packet: HRPacket) throws {
        let received = clock.nowNS()
        hr = packet.bpm; rr = packet.rr.last.map { Double($0)*1000/1024 }
        lastHRReceiptNS = received; lastHRGapLogged = false
        let contact = packet.contact.map { String($0) } ?? "unknown"
        sensorContact = packet.contact.map { $0 ? "Good" : "Check strap" } ?? "Unknown"
        if let writer { try writer.row("hr", ns: received, [String(received), writer.time(received), String(packet.bpm), contact, String(connectionSegment), "mac_notification_receipt"]) }
        guard !packet.rr.isEmpty else { return }
        let mapping = rrTimeline.map(packet.rr, receivedNS: received)
        if mapping.reanchored { event("rr_time_reanchor", "BLE timing gap; new beat-time estimate"); connectionSegment += 1; screen = RRScreen() }
        for (i, raw) in packet.rr.enumerated() {
            let t = mapping.times[i]
            let quality = screen.classify(raw, contact: packet.contact)
            let beat = Beat(ns: t, raw: raw, accepted: quality.0, reason: quality.1, segment: connectionSegment)
            if let writer, t >= writer.startNS {
                if let start = accumulator?.startNS, t < start { event("hrv_late_rr", "RR remains in raw CSV but arrived after its HRV window was closed") }
                let windows = accumulator?.append(beat) ?? []
                for w in windows { try saveWindow(w) }
                try writer.row("rr", ns: received, [String(t), writer.time(t), String(raw), number(beat.ms), String(packet.bpm), String(received), contact, String(beat.accepted), beat.reason, String(connectionSegment), "cumulative_rr_mac_receipt_anchor_estimated"])
                beatCount += 1
            }
        }
    }
    private func saveWindow(_ w: HRVWindow) throws {
        try writer?.window(w)
        windowRMSSD = w.complete && w.coverage >= 0.90 ? w.raw.rmssd : nil
        windowQuality = "Last 5 min: \(w.beats.count) RR · \(String(format: "%.1f", w.coverage*100))% coverage · \(String(format: "%.1f", w.acceptedFraction*100))% passed screening · NN unverified"
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use folder"; panel.message = "Choose where PolarPAP should save recording sessions."
        if panel.runModal() == .OK, let url = panel.url {
            parentFolder = url; folderName = url.path
            sessionsRoot = url; refreshSessions()
        }
    }
    func chooseSessionsFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.prompt = "Use folder"; panel.message = "Choose either a PolarPAP session folder or the parent folder containing your sessions."
        if panel.runModal() == .OK, let url = panel.url {
            let selectedSession = url.appendingPathComponent("session.json")
            if FileManager.default.fileExists(atPath: selectedSession.path) {
                openSessionFolder(url)
                return
            }
            sessionsRoot = url
            if parentFolder == nil { parentFolder = url; folderName = url.path }
            refreshSessions()
        }
    }
    private func openSessionFolder(_ folder: URL) {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("session.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let startText = json["start_unix_ns"] as? String, let startNS = Double(startText) else {
                throw TimeShiftError.invalid("This folder does not contain valid PolarPAP session metadata.")
            }
            let summary = SavedSession(folder: folder, start: Date(timeIntervalSince1970: startNS / 1e9),
                end: (json["end_unix_ns"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1e9) },
                status: json["status"] as? String ?? "unknown", device: json["device_name"] as? String ?? "Polar H10",
                timeZone: json["time_zone"] as? String ?? TimeZone.current.identifier, meanHR: nil, gaps: [],
                fileCount: ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "csv" }.count + 1)
            sessionsRoot = folder.deletingLastPathComponent()
            if parentFolder == nil { parentFolder = sessionsRoot; folderName = sessionsRoot?.path ?? "" }
            openSession(summary)
        } catch { sessionsMessage = error.localizedDescription }
    }
    func refreshSessions() {
        guard let root = sessionsRoot else { sessions = []; return }
        do { sessions = try SessionStore.scan(root: root); sessionsMessage = sessions.isEmpty ? "No PolarPAP sessions found in this folder." : nil }
        catch { sessionsMessage = error.localizedDescription }
    }
    func openSession(_ session: SavedSession) {
        guard session.status == "completed" else { sessionsMessage = "Session details are available after recording is completed."; return }
        selectedSession = session; selectedSessionDetail = nil; sessionTab = .overview; sessionsLoading = true; sessionsMessage = nil
        Task { @MainActor [weak self] in
            do {
                let detail = try await Task.detached(priority: .userInitiated) { try SessionStore.detail(for: session) }.value
                self?.selectedSessionDetail = detail
            } catch { self?.sessionsMessage = error.localizedDescription }
            self?.sessionsLoading = false
        }
    }
    func closeSessionDetail() { selectedSession = nil; selectedSessionDetail = nil; refreshSessions() }
    func recordRecentEvent(_ name: String, detail: String = "") {
        liveRecentEvents.insert(SessionEventItem(time: Date(timeIntervalSince1970: Double(clock.nowNS())/1e9), name: name, detail: detail), at: 0)
        if liveRecentEvents.count > 4 { liveRecentEvents.removeLast(liveRecentEvents.count-4) }
    }
    func chooseTimeShiftFolder() {
        timeShiftMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false
        panel.prompt = "Select session"; panel.message = "Choose a completed PolarPAP session folder containing session.json and CSV files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        timeShiftFolder = nil; timeShiftOriginalStart = nil; timeShiftOriginalEnd = nil; timeShiftOutput = nil
        do {
            let data = try Data(contentsOf: url.appendingPathComponent("session.json"))
            guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let start = metadata["start_unix_ns"] as? String, let ns = Int64(start) else {
                throw TimeShiftError.invalid("This folder does not contain valid PolarPAP session metadata.")
            }
            guard metadata["status"] as? String == "completed" else {
                throw TimeShiftError.invalid("Select a completed session. Active or incomplete recordings cannot be shifted.")
            }
            timeShiftFolder = url
            timeShiftOriginalStart = Date(timeIntervalSince1970: Double(ns) / 1e9)
            timeShiftOriginalEnd = (metadata["end_unix_ns"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1e9) }
            timeShiftDevice = metadata["device_name"] as? String ?? "Polar H10"
            timeShiftZone = metadata["time_zone"] as? String ?? TimeZone.current.identifier
            timeShiftTargetStart = Date(timeIntervalSince1970: Double(ns) / 1e9)
            timeShiftTargetSecond = Calendar.current.component(.second, from: timeShiftTargetStart)
            timeShiftTargetText = Self.shiftDateFormatter.string(from: timeShiftTargetStart)
            timeShiftTargetTextValid = true
            timeShiftOutput = nil
            timeShiftMessage = nil
        } catch { timeShiftMessage = error.localizedDescription }
    }
    func createShiftedCopy() {
        guard let source = timeShiftFolder else { return }
        guard timeShiftTargetTextValid else { timeShiftMessage = "Enter a valid date and time in DD/MM/YYYY, HH:MM:SS format."; return }
        let target = timeShiftTargetStart
        timeShiftBusy = true; timeShiftMessage = "Creating a shifted copy…"; timeShiftOutput = nil
        Task { @MainActor [weak self] in
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try TimeShiftProcessor.createShiftedCopy(source: source, targetStart: target)
                }.value
                self?.timeShiftOutput = output
                self?.timeShiftMessage = "Shifted copy created. The source session is unchanged."
            } catch { self?.timeShiftMessage = error.localizedDescription }
            self?.timeShiftBusy = false
        }
    }
    func startRecording() {
        guard !recording, connected, ecgReady, hrChar?.isNotifying == true else { errorText = "Wait for ECG and HR notifications before recording."; return }
        if parentFolder == nil { chooseFolder() }
        guard let parentFolder else { return }
        do {
            let ns = clock.nowNS()
            writer = try SessionWriter(parent: parentFolder, startNS: ns, device: deviceName, deviceID: peripheral?.identifier.uuidString ?? "", clock: clock)
            lastFolder = writer!.directory; accumulator = WindowAccumulator(startNS: ns)
            if sessionsRoot == nil { sessionsRoot = parentFolder }
            sampleCount = 0; beatCount = 0; recording = true; recordingStart = Date(timeIntervalSince1970: Double(ns)/1e9); errorText = nil; windowRMSSD = nil
            windowQuality = "Waiting for a complete 5-minute window"; status = "Recording"
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Recording Polar H10 ECG and RR")
            try writer!.event(ns, "recording_started", "firmware=\(deviceFirmware); Mac/PAP same local clock assumed; NN not verified")
            recordRecentEvent("recording_started")
            refreshSessions()
            try clockRow()
            log("Recording started: \(writer!.directory.path)")
        } catch { diskFailure(error) }
    }
    func stopRecording() {
        guard recording || writer != nil else { return }
        let ns = clock.nowNS()
        do {
            // Timer already closes completed windows. Export the remaining partial
            // interval explicitly, with no qualified candidate metrics.
            for w in accumulator?.advance(to: ns) ?? [] { try saveWindow(w) }
            if let w = accumulator?.partial(endNS: ns) { try writer?.window(w) }
            try writer?.event(ns, "recording_stopped", "ecg_samples=\(sampleCount); rr_intervals=\(beatCount)")
            try writer?.finish(ns, status: "completed")
        } catch { errorText = "Could not finalize files: \(error.localizedDescription). Preserve the session folder."; log(errorText!) }
        writer = nil; accumulator = nil; recording = false
        recordingStart = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        status = connected ? "Ready" : "Disconnected"; detail = "Files saved in the session folder."
        refreshSessions()
        log("Recording stopped; ECG=\(sampleCount), RR=\(beatCount)")
    }
    private func event(_ name: String, _ detail: String) {
        recordRecentEvent(name, detail: detail)
        guard let writer else { return }
        do { try writer.event(clock.nowNS(), name, detail) } catch { diskFailure(error) }
    }
    private func diskFailure(_ error: Error) {
        errorText = "Recording stopped: \(error.localizedDescription). Preserve the session folder and check free disk space."
        log(errorText!); try? writer?.finish(clock.nowNS(), status: "write_error")
        writer = nil; accumulator = nil; recording = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }; activity = nil
        status = "File error"
    }
    private func transportError(_ text: String) {
        errorText = text; event("bluetooth_or_parse_error", text); log(text)
        // Keep other streams and the recording alive, with errors in the event log.
    }
    private func clockRow() throws {
        guard let writer else { return }
        let ns = clock.nowNS(), wall = MacClock.wallNS()
        try writer.row("clock", ns: ns, [String(ns), writer.time(ns), String(wall), String(MacClock.continuousNS()), timeline.previousSensor.map(String.init) ?? "", timeline.offsetNS.map(String.init) ?? "", String(connectionSegment)])
        if abs(wall-ns) > 250_000_000 && ns-lastClockWarningNS > 60_000_000_000 {
            lastClockWarningNS = ns; try writer.event(ns, "mac_clock_changed", "wall-minus-monotonic-anchor-ns=\(wall-ns); timeline retained")
        }
    }
    private func tick() {
        ticks += 1; samples = plotBuffer
        let uptime = ProcessInfo.processInfo.systemUptime
        if let reconnectAt, uptime >= reconnectAt, desiredConnection, central?.state == .poweredOn, let p = peripheral {
            self.reconnectAt = nil; connectedAt = uptime; central.connect(p, options: nil)
        }
        if let connectedAt, desiredConnection, !ecgReady, uptime-connectedAt > 35, let p = peripheral {
            self.connectedAt = nil; transportError("Connection setup timed out; retrying."); central.cancelPeripheralConnection(p)
        }
        if pendingCommand != nil && uptime-commandSent > 12 { pendingCommand = nil; transportError("Polar measurement command timed out. Disconnect and retry.") }
        if let lastECGReceiptNS, clock.nowNS()-lastECGReceiptNS > 3_000_000_000, !lastECGGapLogged {
            lastECGGapLogged = true; ecgReady = false; status = "ECG interrupted"; event("ecg_notifications_missing", "No ECG for more than 3 seconds")
        }
        if let lastHRReceiptNS, clock.nowNS()-lastHRReceiptNS > 4_000_000_000, !lastHRGapLogged {
            lastHRGapLogged = true; hr = nil; rr = nil; event("hr_notifications_missing", "No HR for more than 4 seconds")
        }
        if connected, desiredConnection, let lastHRReceiptNS, clock.nowNS()-lastHRReceiptNS > 12_000_000_000, let p = peripheral {
            self.lastHRReceiptNS = nil; event("reconnect_requested", "HR stream stalled for more than 12 seconds"); central.cancelPeripheralConnection(p)
        }
        if recording, let writer {
            let seconds = max(0, Int((clock.nowNS()-writer.startNS)/1_000_000_000))
            elapsed = String(format: "%02d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60)
            if ticks % 5 == 0 {
                do {
                    // Allow late HR packets two seconds to complete their estimated
                    // beat times before closing a five-minute window.
                    for w in accumulator?.advance(to: clock.nowNS()-2_000_000_000) ?? [] { try saveWindow(w) }
                    try writer.flush(sync: ticks % 50 == 0)
                    if ticks % 50 == 0 { try clockRow() }
                } catch { diskFailure(error) }
            }
        }
        if let seconds = cliRecordingSeconds {
            if recording, let start = cliRecordStart, uptime-start >= seconds {
                stopRecording(); disconnect(); log("HARDWARE_TEST_COMPLETED")
                DispatchQueue.main.asyncAfter(deadline: .now()+1) { NSApp.terminate(nil) }
                cliRecordingSeconds = nil
            } else if !recording && ecgReady && cliRecordStart == nil {
                parentFolder = cliParent; startRecording()
                if recording { cliRecordStart = uptime }
            }
            if let deadline = cliDeadline, uptime > deadline && cliRecordStart == nil {
                log("HARDWARE_TEST_NOT_STARTED: \(status); \(errorText ?? "no ECG")")
                desiredConnection = false; NSApp.terminate(nil)
            }
        }
    }
    func shutdown() { stopRecording(); desiredConnection = false; stopScan(); if let p = peripheral { central?.cancelPeripheralConnection(p) } }
}

struct ECGPlot: View {
    let samples: [Double]
    var body: some View {
        Canvas { context, size in
            let center = size.height/2, scale = min(size.height/4, 60.0)
            var grid = Path()
            for x in stride(from: 0.0, through: size.width, by: 26) { grid.move(to: CGPoint(x:x,y:0)); grid.addLine(to: CGPoint(x:x,y:size.height)) }
            for y in stride(from: 0.0, through: size.height, by: scale/2) { grid.move(to: CGPoint(x:0,y:y)); grid.addLine(to: CGPoint(x:size.width,y:y)) }
            context.stroke(grid, with: .color(.gray.opacity(0.14)), lineWidth: 0.5)
            guard samples.count > 1 else { return }
            var path = Path()
            for (i, v) in samples.enumerated() {
                let point = CGPoint(x: Double(i)/1299*size.width, y: center-max(-4,min(4,v))*scale)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.teal), lineWidth: 1.2)
        }.background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: Recorder?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if recorder?.recording == true {
            let a = NSAlert(); a.messageText = "Stop recording and quit?"; a.informativeText = "The current CSV files will be finalized before quitting."; a.addButton(withTitle: "Stop and quit"); a.addButton(withTitle: "Keep recording")
            if a.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        recorder?.shutdown(); return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct PolarPAPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var recorder = Recorder()
    var body: some Scene {
        WindowGroup { ContentView(r: recorder).onAppear { delegate.recorder = recorder } }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
