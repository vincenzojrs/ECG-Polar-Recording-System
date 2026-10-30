import SwiftUI

private typealias PolarPlotState<Value> = SwiftUI.State<Value>
import AppKit

private enum PAPStyle {
    static let blue = Color(nsColor: .systemBlue)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let divider = Color(nsColor: .separatorColor).opacity(0.65)
    static let muted = Color.secondary
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
}

struct ContentView: View {
    @ObservedObject var r: Recorder
    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(r: r).frame(width: 224)
            Rectangle().fill(PAPStyle.divider).frame(width: 1)
            Group {
                switch r.page {
                case .record: RecordPage(r: r)
                case .sessions: SessionsPage(r: r)
                case .shift: ShiftPage(r: r)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PAPStyle.canvas)
        }
        .frame(minWidth: 1120, idealWidth: 1400, minHeight: 760, idealHeight: 900)
        .background(PAPStyle.canvas)
    }
}

private struct AppSidebar: View {
    @ObservedObject var r: Recorder
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 25, weight: .semibold)).foregroundStyle(PAPStyle.blue)
                Text("PolarPAP").font(.system(size: 20, weight: .bold))
            }.padding(.horizontal, 16).padding(.top, 18)
            VStack(spacing: 5) {
                ForEach(AppPage.allCases) { page in
                    Button {
                        r.page = page
                        if page == .sessions { r.refreshSessions() }
                    } label: {
                        Label(page.rawValue, systemImage: icon(for: page))
                            .font(.system(size: 15, weight: r.page == page ? .semibold : .regular))
                            .foregroundStyle(r.page == page ? PAPStyle.blue : Color.primary.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(r.page == page ? PAPStyle.blue.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 10)
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 8) {
                Label("Stored on this Mac", systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Version 0.2.0").font(.system(size: 12)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 18).padding(.bottom, 18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    private func icon(for page: AppPage) -> String {
        switch page { case .record: return "record.circle"; case .sessions: return "list.bullet.rectangle"; case .shift: return "clock" }
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(subtitle).font(.system(size: 15)).foregroundStyle(.secondary)
            }
            Spacer()
            if let trailing { trailing }
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(PAPStyle.divider).frame(height: 1) }
    }
}

private struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(16)
            .background(PAPStyle.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(PAPStyle.divider, lineWidth: 0.7))
    }
}

private struct RecordPage: View {
    @ObservedObject var r: Recorder
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                PageHeader(title: "Record", subtitle: "Capture ECG and R–R intervals from your Polar H10.", trailing: AnyView(connectionBadge))
                Surface {
                    HStack(spacing: 12) {
                        Picker("Polar H10", selection: $r.selected) {
                            Text(r.devices.isEmpty ? "Scan for Polar H10" : "Select Polar H10").tag(nil as UUID?)
                            ForEach(r.devices) { device in Text("\(device.name) · \(device.rssi) dBm").tag(device.id as UUID?) }
                        }.frame(maxWidth: 340).disabled(r.connected || r.recording)
                        Button(r.scanning ? "Stop scan" : "Scan devices") { r.scanning ? r.stopScan() : r.scan() }
                            .disabled(r.recording || r.connected)
                        if r.connected {
                            Button("Disconnect") { r.disconnect() }.disabled(r.recording)
                        } else if r.selected != nil {
                            Button("Connect") { r.connectSelected() }.disabled(r.recording || !r.canConnect)
                        }
                        Spacer()
                        if let battery = r.battery {
                            Label("\(battery)%", systemImage: "battery.100percent").font(.system(size: 15, weight: .medium))
                        }
                    }
                }
                Surface {
                    HStack(spacing: 15) {
                        Circle().fill(r.recording ? PAPStyle.red : r.connected ? PAPStyle.green : Color.gray).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.recording ? "Recording" : r.connected ? (r.ecgReady ? "Ready" : r.status) : r.status)
                                .font(.system(size: 17, weight: .semibold))
                            Text(r.recording ? "Started \(dateText(r.recordingStart ?? Date(), zone: TimeZone.current.identifier, includeDate: true))" : r.detail)
                                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Rectangle().fill(PAPStyle.divider).frame(width: 1, height: 36).padding(.horizontal, 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Elapsed time").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(r.elapsed).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                        }
                        Spacer()
                        if r.recording {
                            Button { r.stopRecording() } label: { Label("Stop recording", systemImage: "stop.fill") }
                                .buttonStyle(.bordered).tint(.red).keyboardShortcut("r", modifiers: [.command])
                        } else {
                            Button { r.startRecording() } label: { Label("Start recording", systemImage: "record.circle") }
                                .buttonStyle(.borderedProminent).disabled(!r.ecgReady)
                                .keyboardShortcut("r", modifiers: [.command])
                        }
                    }.padding(.vertical, 3)
                }
                HStack(spacing: 12) {
                    MetricTile(title: "Heart rate", value: r.hr.map(String.init) ?? "—", unit: "bpm", accent: PAPStyle.blue)
                    MetricTile(title: "Latest R–R", value: r.rr.map { String(format: "%.0f", $0) } ?? "—", unit: "ms", accent: PAPStyle.blue)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Sensor contact").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(r.sensorContact).font(.system(size: 24, weight: .medium)).foregroundStyle(r.sensorContact == "Good" ? PAPStyle.green : r.sensorContact == "Check strap" ? PAPStyle.orange : .primary)
                    }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading).padding(16)
                        .background(PAPStyle.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(PAPStyle.divider, lineWidth: 0.7))
                }
                Surface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Live ECG").font(.system(size: 17, weight: .semibold)); Spacer(); Text("Last 10 seconds · 130 Hz").font(.system(size: 12)).foregroundStyle(.secondary) }
                        ECGPlot(samples: r.samples).frame(height: 270)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Surface {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("Recent events").font(.system(size: 17, weight: .semibold))
                            if r.liveRecentEvents.isEmpty { Text("Connection and recording events will appear here.").font(.system(size: 13)).foregroundStyle(.secondary) }
                            ForEach(r.liveRecentEvents) { event in
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(event.name == "connected" || event.name == "recording_started" ? PAPStyle.green : event.name == "disconnected" ? PAPStyle.red : Color.gray).frame(width: 8, height: 8).padding(.top, 5)
                                    Text(dateText(event.time, zone: TimeZone.current.identifier, includeDate: false)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.displayName).font(.system(size: 13, weight: .medium))
                                        if !event.detail.isEmpty { Text(event.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Surface {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Image(systemName: "doc.text").font(.system(size: 23)).foregroundStyle(PAPStyle.blue); Text("Session files").font(.system(size: 17, weight: .semibold)); Spacer() }
                            if let folder = r.lastFolder {
                                Text(folder.lastPathComponent).font(.system(size: 14, weight: .medium))
                                Text(r.recording ? "Writing CSV files as you record" : "Session saved on this Mac").font(.system(size: 12)).foregroundStyle(.secondary)
                                HStack { Button("Change save location…") { r.chooseFolder() }; Spacer(); Button("Show in Finder") { NSWorkspace.shared.open(folder) } }
                            } else {
                                Text("Choose a local folder before recording.").font(.system(size: 13)).foregroundStyle(.secondary)
                                Button("Choose save location…") { r.chooseFolder() }
                            }
                        }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                    }
                }
                if let error = r.errorText { Text(error).font(.system(size: 12)).foregroundStyle(PAPStyle.red).textSelection(.enabled) }
                Text("Keep your Mac awake, nearby, and the lid open. Personal exploratory recording · NN beats unverified · not for diagnosis.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(28)
        }
    }
    private var connectionBadge: some View {
        HStack(spacing: 8) { Circle().fill(r.connected ? PAPStyle.green : Color.gray).frame(width: 10,height:10); Text(r.connected ? "Connected" : "Not connected").font(.system(size: 14, weight: .medium)) }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 15)).foregroundStyle(.secondary)
            }.foregroundStyle(accent)
        }.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading).padding(16)
            .background(PAPStyle.card, in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(PAPStyle.divider, lineWidth: 0.7))
    }
}

private struct SessionsPage: View {
    @ObservedObject var r: Recorder
    var body: some View {
        Group {
            if let summary = r.selectedSession { SessionDetailPage(r: r, summary: summary) }
            else { sessionList }
        }
    }
    private var sessionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Sessions", subtitle: "Browse your local Polar H10 recordings.", trailing: AnyView(HStack {
                    Button { r.chooseSessionsFolder() } label: { Label("Choose folder…", systemImage: "folder") }
                    if r.sessionsRoot != nil { Button { r.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh sessions") }
                }))
                if let root = r.sessionsRoot {
                    Text(root.path).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let message = r.sessionsMessage {
                    Surface { HStack { Image(systemName: r.sessions.isEmpty ? "folder" : "info.circle").foregroundStyle(.secondary); Text(message).foregroundStyle(.secondary); if r.sessionsRoot == nil { Spacer(); Button("Choose folder…") { r.chooseSessionsFolder() } } } }
                }
                if r.sessions.isEmpty && r.sessionsRoot == nil {
                    Surface {
                        VStack(spacing: 12) {
                            Image(systemName: "folder.badge.waveform").font(.system(size: 36)).foregroundStyle(PAPStyle.blue)
                            Text("Choose your sessions folder").font(.system(size: 19, weight: .semibold))
                            Text("Select the folder PolarPAP uses to save completed recordings.").font(.system(size: 14)).foregroundStyle(.secondary)
                            Button("Choose folder…") { r.chooseSessionsFolder() }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(28)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(r.sessions) { session in
                            Button { r.openSession(session) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "waveform.path.ecg").font(.system(size: 24)).foregroundStyle(PAPStyle.blue).frame(width: 44,height:44).background(PAPStyle.blue.opacity(0.09),in:RoundedRectangle(cornerRadius:9))
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack { Text(session.title).font(.system(size: 16, weight: .semibold)); statusPill(session.status) }
                                        Text(session.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(session.meanHR.map { "\(Int($0.rounded())) bpm mean" } ?? "No HR values").font(.system(size: 13)).foregroundStyle(.secondary)
                                    Text("\(session.fileCount) files").font(.system(size: 12)).foregroundStyle(.tertiary)
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                                }.padding(14).background(PAPStyle.card, in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(PAPStyle.divider,lineWidth:0.7))
                            }.buttonStyle(.plain).disabled(session.status != "completed")
                        }
                    }
                }
            }.padding(28)
        }
    }
}

private struct SessionDetailPage: View {
    @ObservedObject var r: Recorder
    let summary: SavedSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Button { r.closeSessionDetail() } label: { Label("Sessions", systemImage: "chevron.left") }.buttonStyle(.plain)
                    Text("/").foregroundStyle(.tertiary)
                    Text(summary.start.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                    Spacer()
                    Button { NSWorkspace.shared.open(summary.folder) } label: { Label("Show in Finder", systemImage: "folder") }
                }.font(.system(size: 13))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) { Text(summary.start.formatted(date: .complete, time: .omitted)).font(.system(size: 29, weight: .bold, design: .rounded)); statusPill(summary.status) }
                        Text("\(dateText(summary.start, zone: summary.timeZone, includeDate: false))–\(summary.end.map { dateText($0, zone: summary.timeZone, includeDate: false) } ?? "In progress")  ·  \(summary.timeZone)  ·  \(summary.device)")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 0) {
                    DetailStat(title: "Duration", value: SavedSession.durationLabel(summary.duration))
                    Rectangle().fill(PAPStyle.divider).frame(width: 1,height: 42)
                    DetailStat(title: "Mean heart rate", value: summary.meanHR.map { "\(Int($0.rounded())) bpm" } ?? "—")
                    Rectangle().fill(PAPStyle.divider).frame(width: 1,height: 42)
                    DetailStat(title: "Connection gaps", value: summary.gapLabel)
                }.background(PAPStyle.card, in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(PAPStyle.divider,lineWidth:0.7))
                HStack(spacing: 0) {
                    ForEach(SessionTab.allCases) { tab in
                        Button { r.sessionTab = tab } label: {
                            Text(tab.rawValue).font(.system(size: 14, weight: r.sessionTab == tab ? .semibold : .regular))
                                .foregroundStyle(r.sessionTab == tab ? .white : Color.primary)
                                .frame(width: 130).padding(.vertical, 9)
                                .background(r.sessionTab == tab ? PAPStyle.blue : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }.padding(3).background(PAPStyle.card, in:RoundedRectangle(cornerRadius:9)).frame(maxWidth:.infinity, alignment:.leading)
                if r.sessionsLoading { ProgressView("Loading session…").frame(maxWidth:.infinity,minHeight:260) }
                else if let detail = r.selectedSessionDetail {
                    switch r.sessionTab {
                    case .overview: SessionOverview(detail: detail, chart: $r.sessionChart, mode: $r.hrvDisplayMode).id(detail.summary.id)
                    case .files: SessionFiles(detail: detail)
                    case .events: SessionEvents(detail: detail, zone: summary.timeZone)
                    }
                } else if let message = r.sessionsMessage { Text(message).foregroundStyle(PAPStyle.red) }
                Text("For personal exploration. Not for diagnosis or treatment decisions.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}

private struct DetailStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded))
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,18).padding(.vertical,12)
    }
}

private struct SessionOverview: View {
    let detail: SessionDetail
    @Binding var chart: SessionChart
    @Binding var mode: HRVDisplayMode
    @PolarPlotState private var requestedSpan = 0
    @PolarPlotState private var requestedOffset: Double = 0
    @PolarPlotState private var visibleOffset: Double = 0
    @PolarPlotState private var visibleSpan: Double = 0
    @PolarPlotState private var ecgWindow: [SessionECGPoint] = []
    @PolarPlotState private var ecgWindowStart: Date?
    @PolarPlotState private var ecgLoading = false
    @PolarPlotState private var ecgError: String?
    @PolarPlotState private var requestID = 0
    @PolarPlotState private var zoomHistory: [(Double, Double)] = []
    private var windowStart: Date { detail.summary.start.addingTimeInterval(visibleOffset) }
    private var windowEnd: Date { windowStart.addingTimeInterval(visibleSpan > 0 ? visibleSpan : detail.summary.duration) }
    private func inWindow(_ time: Date) -> Bool { time >= windowStart && time <= windowEnd }
    private var activeWindow: SessionHRVRow? { detail.hrv.first(where: { $0.usable }) ?? detail.hrv.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Signal view").font(.system(size: 18, weight: .semibold))
                        Picker("Signal view", selection: $chart) { ForEach(SessionChart.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).frame(maxWidth: 520)
                        Spacer()
                    }
                    navigationControls
                    selectedChart
                }
            }
            if chart == .hrv { Surface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("HRV · 5-minute windows").font(.system(size: 18, weight: .semibold))
                        Picker("HRV mode", selection: $mode) { ForEach(HRVDisplayMode.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 200)
                        Spacer()
                    }
                    Label(mode == .raw ? "Raw RR variability · artifacts and non-sinus beats may be present" : "Heuristic filtering · NN beats not verified", systemImage: "info.circle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let window = activeWindow {
                        HStack(spacing: 0) {
                            hrvMetric("Mean R–R", value: mode == .raw ? window.meanRR : nil, unit: "ms")
                            hrvMetric("SDRR", value: mode == .raw ? window.sdrr : window.candidateSDNN, unit: "ms")
                            hrvMetric("RMSSD", value: mode == .raw ? window.rmssd : window.candidateRMSSD, unit: "ms")
                            hrvMetric("pNN50", value: mode == .raw ? window.pnn50 : window.candidatePNN50, unit: "%")
                        }
                        LazyVStack(spacing: 0) {
                            HStack { tableHead("Window"); tableHead("Coverage"); tableHead("Flagged R–R"); tableHead("Candidate values") }.padding(.vertical,8).background(PAPStyle.card)
                            ForEach(detail.hrv) { row in
                                HStack {
                                    tableCell("\(dateText(row.start, zone: detail.summary.timeZone, includeDate: false))–\(dateText(row.end, zone: detail.summary.timeZone, includeDate: false))")
                                    tableCell(String(format:"%.1f%%",row.coverage*100))
                                    tableCell(String(format:"%.1f%%",max(0,1-row.accepted)*100))
                                    tableCell(row.candidateRMSSD == nil ? "Withheld" : "Available · unverified")
                                }.padding(.vertical,7).overlay(alignment:.bottom){Rectangle().fill(PAPStyle.divider).frame(height:0.6)}
                            }
                        }.overlay(RoundedRectangle(cornerRadius:7).stroke(PAPStyle.divider,lineWidth:0.7))
                    } else { Text("No HRV windows in this session.").font(.system(size:13)).foregroundStyle(.secondary) }
                }
            } }
        }.onChange(of: chart) { selection in
            if selection == .ecg && !ecgLoading && ecgWindowStart != windowStart && visibleSpan > 0 && visibleSpan <= 30 { loadECGWindow() }
        }
    }
    private var navigationControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Time range").font(.system(size: 12, weight: .medium))
                Picker("Time range", selection: $requestedSpan) {
                    Text("Whole session").tag(0); Text("1 hour").tag(3600)
                    Text("5 minutes").tag(300); Text("30 seconds").tag(30); Text("10 seconds").tag(10)
                    Text("Custom selection").tag(-1)
                }.labelsHidden().frame(width: 150)
                Button("Apply") { applyWindow() }
                Button("◀") { moveWindow(-1) }.disabled(visibleSpan == 0 || visibleOffset <= 0).help("Previous window")
                Button("▶") { moveWindow(1) }.disabled(visibleSpan == 0 || visibleOffset + visibleSpan >= detail.summary.duration).help("Next window")
                Button("Back") { zoomBack() }.disabled(zoomHistory.isEmpty)
                Button("Whole session") { showWholeSession() }
                if ecgLoading { ProgressView().controlSize(.small) }
                Spacer()
            }
            Slider(value: $requestedOffset, in: 0...max(1, detail.summary.duration - (visibleSpan > 0 ? visibleSpan : detail.summary.duration)), onEditingChanged: { editing in
                if !editing && visibleSpan > 0 { setWindow(offset: requestedOffset, span: visibleSpan) }
            }).disabled(visibleSpan == 0)
            HStack {
                Text("Drag on the chart to zoom · right-click for options")
                Spacer()
                Text("Showing \(dateText(windowStart, zone: detail.summary.timeZone, includeDate: false))–\(dateText(windowEnd, zone: detail.summary.timeZone, includeDate: false))")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func setWindow(offset: Double, span: Double) {
        let total = max(0, detail.summary.duration)
        visibleSpan = span <= 0 || span >= total ? 0 : max(1, span)
        visibleOffset = visibleSpan == 0 ? 0 : max(0, min(offset, total - visibleSpan))
        requestedOffset = visibleOffset
        if visibleSpan == 0 { requestedSpan = 0 }
        else if [10, 30, 300, 3600].contains(Int(visibleSpan)) && abs(visibleSpan - visibleSpan.rounded()) < 0.001 { requestedSpan = Int(visibleSpan) }
        else { requestedSpan = -1 }
        requestID += 1
        ecgLoading = false; ecgWindowStart = nil; ecgError = nil
        if chart == .ecg && visibleSpan > 0 && visibleSpan <= 30 { loadECGWindow() }
    }
    private func applyWindow() {
        guard requestedSpan != -1 else { return }
        zoomHistory.append((visibleOffset, visibleSpan))
        setWindow(offset: visibleOffset, span: Double(requestedSpan))
    }
    private func moveWindow(_ direction: Double) {
        guard visibleSpan > 0 else { return }
        setWindow(offset: visibleOffset + direction * visibleSpan, span: visibleSpan)
    }
    private func zoomSelection(_ lower: Double, _ upper: Double) {
        guard let selection = PlotWindowMath.selected(offset: visibleOffset, visible: visibleSpan, total: detail.summary.duration, lower: lower, upper: upper) else { return }
        zoomHistory.append((visibleOffset, visibleSpan))
        setWindow(offset: selection.0, span: selection.1)
    }
    private func zoomBack() {
        guard let previous = zoomHistory.popLast() else { return }
        setWindow(offset: previous.0, span: previous.1)
    }
    private func showWholeSession() {
        if visibleSpan > 0 { zoomHistory.append((visibleOffset, visibleSpan)) }
        setWindow(offset: 0, span: 0)
    }
    private var plotRange: ClosedRange<Date> { windowStart...max(windowStart.addingTimeInterval(0.001), windowEnd) }
    private func interactive<Content: View>(_ content: Content) -> some View {
        InteractiveSessionPlot(content: content, onSelect: zoomSelection, onBack: zoomBack, onWhole: showWholeSession, canBack: !zoomHistory.isEmpty)
    }
    @ViewBuilder private var selectedChart: some View {
        switch chart {
        case .rr:
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("R–R intervals").font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(detail.rr.count.formatted()) intervals · ms").font(.system(size: 12)).foregroundStyle(.secondary) }
                interactive(SessionRRPlot(points: detail.rr.filter { inWindow($0.time) }, events: detail.events.filter { inWindow($0.time) }, zone: detail.summary.timeZone, range: plotRange)).frame(height: 260)
            }
        case .ecg:
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("ECG").font(.system(size: 15, weight: .semibold)); Spacer(); Text(visibleSpan > 0 && visibleSpan <= 30 ? "Full-resolution samples" : "Downsampled overview").font(.system(size: 12)).foregroundStyle(.secondary) }
                if let ecgError { Text(ecgError).foregroundStyle(PAPStyle.red).font(.system(size: 12)) }
                if ecgLoading { Text("Loading ECG samples…").foregroundStyle(.secondary) }
                else if visibleSpan > 0 && visibleSpan <= 30 {
                    interactive(SessionECGPlot(points: ecgWindowStart == windowStart ? ecgWindow : [], zone: detail.summary.timeZone, range: plotRange)).frame(height: 300)
                } else {
                    interactive(SessionECGPlot(points: detail.ecg.filter { inWindow($0.time) }, zone: detail.summary.timeZone, range: plotRange)).frame(height: 300)
                }
                Text("Zoom to 30 seconds or less to inspect original ECG samples. Longer ranges are downsampled and cannot reliably show individual beats; spikes may affect the scale.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .pulseRate:
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("Pulse Rate").font(.system(size: 15, weight: .semibold)); Spacer(); Text("\(detail.pulseRate.count.formatted()) readings · bpm").font(.system(size: 12)).foregroundStyle(.secondary) }
                interactive(SessionPulsePlot(points: detail.pulseRate.filter { inWindow($0.time) }, zone: detail.summary.timeZone, range: plotRange)).frame(height: 260)
            }
        case .hrv:
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("HRV trend").font(.system(size: 15, weight: .semibold)); Spacer(); Text("5-minute windows").font(.system(size: 12)).foregroundStyle(.secondary) }
                HStack { Text(mode == .raw ? "Raw RMSSD · ms" : "Candidate RMSSD · ms").font(.system(size: 12, weight: .medium)); Spacer(); Text(mode == .candidate ? "NN beats not verified" : "Raw intervals").font(.system(size: 11)).foregroundStyle(.secondary) }
                interactive(SessionHRVPlot(rows: detail.hrv.filter { inWindow($0.start.addingTimeInterval($0.end.timeIntervalSince($0.start) / 2)) }, mode: mode, zone: detail.summary.timeZone, range: plotRange)).frame(height: 260)
            }
        }
    }
    private func loadECGWindow() {
        let start = windowStart
        let duration = visibleSpan
        let folder = detail.summary.folder
        let token = requestID
        ecgLoading = true; ecgError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionStore.ecgWindow(folder: folder, start: start, duration: duration) }
            DispatchQueue.main.async {
                guard token == requestID else { return }
                ecgLoading = false
                switch result {
                case .success(let points): ecgWindow = points; ecgWindowStart = start
                case .failure(let error): ecgError = "Could not load ECG: \(error.localizedDescription)"
                }
            }
        }
    }
    private func hrvMetric(_ title:String,value:Double?,unit:String)->some View {
        VStack(alignment:.leading,spacing:3){Text(title).font(.system(size:12)).foregroundStyle(.secondary);HStack(alignment:.firstTextBaseline,spacing:4){Text(value.map{String(format:"%.0f",$0)} ?? "—").font(.system(size:23,weight:.semibold,design:.rounded));Text(unit).font(.system(size:12)).foregroundStyle(.secondary)}}
            .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,5)
    }
    private func tableHead(_ value:String)->some View{Text(value).font(.system(size:12,weight:.medium)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,9)}
    private func tableCell(_ value:String)->some View{Text(value).font(.system(size:12)).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,9)}
}

private struct InteractiveSessionPlot<Content: View>: View {
    let content: Content
    let onSelect: (Double, Double) -> Void
    let onBack: () -> Void
    let onWhole: () -> Void
    let canBack: Bool
    @PolarPlotState private var dragStart: CGFloat?
    @PolarPlotState private var dragEnd: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 69)
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                        if let start = dragStart, let end = dragEnd {
                            Rectangle().fill(PAPStyle.blue.opacity(0.22))
                                .frame(width: abs(end - start))
                                .offset(x: min(start, end))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: width, height: max(1, geometry.size.height - 40))
                    .offset(x: 54, y: 12)
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            dragStart = max(0, min(width, value.startLocation.x))
                            dragEnd = max(0, min(width, value.location.x))
                        }
                        .onEnded { value in
                            let a = max(0, min(width, value.startLocation.x))
                            let b = max(0, min(width, value.location.x))
                            dragStart = nil; dragEnd = nil
                            if abs(a - b) >= 4 { onSelect(Double(min(a,b) / width), Double(max(a,b) / width)) }
                        })
                    .contextMenu {
                        Button("Whole session", action: onWhole)
                        Button("Back to previous zoom", action: onBack).disabled(!canBack)
                    }
                }
        }
    }
}

private struct SessionRRPlot: View {
    let points: [SessionRRPoint]
    let events: [SessionEventItem]
    let zone: String
    let range: ClosedRange<Date>
    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else {
                context.draw(Text("No R–R data available").font(.system(size:13)).foregroundColor(.secondary), at: CGPoint(x:size.width/2,y:size.height/2)); return
            }
            let first = range.lowerBound, last = range.upperBound
            let left: CGFloat = 54, right: CGFloat = 15, top: CGFloat = 12, bottom: CGFloat = 28
            let width=size.width-left-right, height=size.height-top-bottom
            let minValue=(points.map(\.milliseconds).min() ?? 500)-100
            let maxValue=(points.map(\.milliseconds).max() ?? 1500)+100
            let lo=floor(minValue/100)*100, hi=ceil(maxValue/100)*100
            for i in 0...4 {
                let y=top+height*CGFloat(i)/4
                var line=Path();line.move(to:CGPoint(x:left,y:y));line.addLine(to:CGPoint(x:left+width,y:y))
                context.stroke(line,with:.color(PAPStyle.divider),lineWidth:0.7)
                let value=hi-(hi-lo)*Double(i)/4
                context.draw(Text(String(format:"%.0f",value)).font(.system(size:10)).foregroundColor(.secondary),at:CGPoint(x:26,y:y))
            }
            for i in 0...6 {
                let x=left+width*CGFloat(i)/6
                var line=Path();line.move(to:CGPoint(x:x,y:top));line.addLine(to:CGPoint(x:x,y:top+height))
                context.stroke(line,with:.color(PAPStyle.divider.opacity(0.6)),lineWidth:0.6)
                let t=first.addingTimeInterval(last.timeIntervalSince(first)*Double(i)/6)
                context.draw(Text(dateText(t,zone:zone,includeDate:false)).font(.system(size:9)).foregroundColor(.secondary),at:CGPoint(x:x,y:size.height-8))
            }
            for event in events where event.name == "disconnected" {
                let x=left+width*CGFloat(event.time.timeIntervalSince(first)/last.timeIntervalSince(first))
                var marker=Path();marker.move(to:CGPoint(x:x,y:top));marker.addLine(to:CGPoint(x:x,y:top+height))
                context.stroke(marker,with:.color(PAPStyle.orange),style:StrokeStyle(lineWidth:1.2,dash:[4,4]))
            }
            var path=Path();var previous:Date?
            for point in points {
                let x=left+width*CGFloat(point.time.timeIntervalSince(first)/last.timeIntervalSince(first))
                let y=top+height*CGFloat((hi-point.milliseconds)/(hi-lo))
                if let previous, point.time.timeIntervalSince(previous)>3 { path.move(to:CGPoint(x:x,y:y)) }
                else if previous == nil { path.move(to:CGPoint(x:x,y:y)) }
                else { path.addLine(to:CGPoint(x:x,y:y)) }
                previous=point.time
            }
            context.stroke(path,with:.color(PAPStyle.blue),lineWidth:1.5)
        }
    }
}

private struct TimeSeriesPlot: View {
    let values: [(Date, Double)]
    let zone: String
    let unit: String
    let color: Color
    let fixedRange: ClosedRange<Double>?
    let showPoints: Bool
    var maxGap: TimeInterval = 3
    let range: ClosedRange<Date>
    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else {
                context.draw(Text("No data available for this signal").font(.system(size: 13)).foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2)); return
            }
            let first = range.lowerBound, last = range.upperBound
            guard last > first else { return }
            let left: CGFloat = 54, right: CGFloat = 15, top: CGFloat = 12, bottom: CGFloat = 28
            let width = max(1, size.width - left - right), height = max(1, size.height - top - bottom)
            let numericValues = values.map { $0.1 }
            let minimumValue = numericValues.min() ?? 0
            let maximumValue = numericValues.max() ?? 1
            let padding = max(1.0, maximumValue - minimumValue) * 0.08
            let low = fixedRange?.lowerBound ?? (minimumValue - padding)
            let high = fixedRange?.upperBound ?? (maximumValue + padding)
            let span = max(0.000001, high - low)
            for i in 0...4 {
                let y = top + height * CGFloat(i) / 4
                var grid = Path(); grid.move(to: CGPoint(x: left, y: y)); grid.addLine(to: CGPoint(x: left + width, y: y))
                context.stroke(grid, with: .color(PAPStyle.divider), lineWidth: 0.7)
                let value = high - span * Double(i) / 4
                context.draw(Text(String(format: "%.1f", value)).font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: 27, y: y))
            }
            for i in 0...6 {
                let x = left + width * CGFloat(i) / 6
                var grid = Path(); grid.move(to: CGPoint(x: x, y: top)); grid.addLine(to: CGPoint(x: x, y: top + height))
                context.stroke(grid, with: .color(PAPStyle.divider.opacity(0.55)), lineWidth: 0.6)
                let time = first.addingTimeInterval(last.timeIntervalSince(first) * Double(i) / 6)
                context.draw(Text(dateText(time, zone: zone, includeDate: false)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x, y: size.height - 8))
            }
            var path = Path(); var prior: Date?
            for (time, value) in values {
                let x = left + width * CGFloat(time.timeIntervalSince(first) / last.timeIntervalSince(first))
                let y = top + height * CGFloat((high - value) / span)
                if prior == nil || time.timeIntervalSince(prior!) > maxGap || time <= prior! { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
                prior = time
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: showPoints ? 1.7 : 1.2, lineCap: .round, lineJoin: .round))
            if showPoints {
                for (time, value) in values {
                    let x = left + width * CGFloat(time.timeIntervalSince(first) / last.timeIntervalSince(first))
                    let y = top + height * CGFloat((high - value) / span)
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(color))
                }
            }
            context.draw(Text(unit).font(.system(size: 10)).foregroundColor(.secondary), at: CGPoint(x: left - 22, y: top - 2))
        }
    }
}

private struct SessionECGPlot: View {
    let points: [SessionECGPoint]
    let zone: String
    let range: ClosedRange<Date>
    var body: some View {
        TimeSeriesPlot(values: points.map { ($0.time, $0.millivolts) }, zone: zone, unit: "mV", color: PAPStyle.blue, fixedRange: nil, showPoints: false, range: range)
    }
}

private struct SessionPulsePlot: View {
    let points: [SessionPulsePoint]
    let zone: String
    let range: ClosedRange<Date>
    var body: some View {
        TimeSeriesPlot(values: points.map { ($0.time, $0.bpm) }, zone: zone, unit: "bpm", color: PAPStyle.green, fixedRange: nil, showPoints: false, range: range)
    }
}

private struct SessionHRVPlot: View {
    let rows: [SessionHRVRow]
    let mode: HRVDisplayMode
    let zone: String
    let range: ClosedRange<Date>
    var body: some View {
        let values = rows.compactMap { row -> (Date, Double)? in
            let value = mode == .raw ? row.rmssd : row.candidateRMSSD
            guard let value else { return nil }
            return (row.start.addingTimeInterval(row.end.timeIntervalSince(row.start) / 2), value)
        }
        TimeSeriesPlot(values: values, zone: zone, unit: "ms", color: PAPStyle.orange, fixedRange: nil, showPoints: true, maxGap: 450, range: range)
    }
}

private struct SessionFiles: View {
    let detail: SessionDetail
    var body: some View {
        Surface {
            VStack(alignment:.leading,spacing:0) {
                HStack { Text("Session files").font(.system(size:18,weight:.semibold));Spacer();Button("Show in Finder"){NSWorkspace.shared.open(detail.summary.folder)} }.padding(.bottom,12)
                ForEach(detail.files) { file in
                    HStack(spacing:12){Image(systemName:file.url.lastPathComponent.hasSuffix(".json") ? "curlybraces" : "doc.text").foregroundStyle(PAPStyle.blue).frame(width:24);Text(file.url.lastPathComponent).font(.system(size:13,design:.monospaced));Spacer();Text(file.sizeLabel).font(.system(size:12)).foregroundStyle(.secondary);Button("Open"){NSWorkspace.shared.open(file.url)}.buttonStyle(.borderless)}
                        .padding(.vertical,9).overlay(alignment:.bottom){Rectangle().fill(PAPStyle.divider).frame(height:0.6)}
                }
            }
        }
    }
}

private struct SessionEvents: View {
    let detail: SessionDetail
    let zone: String
    var body: some View {
        Surface {
            VStack(alignment:.leading,spacing:0){Text("Session events").font(.system(size:18,weight:.semibold)).padding(.bottom,12)
                ForEach(detail.events.reversed()) { event in
                    HStack(alignment:.top,spacing:12){Circle().fill(event.name == "connected" ? PAPStyle.green : event.name == "disconnected" ? PAPStyle.red : Color.gray).frame(width:8,height:8).padding(.top,5);Text(dateText(event.time,zone:zone,includeDate:true)).font(.system(size:12,design:.monospaced)).frame(width:155,alignment:.leading);VStack(alignment:.leading,spacing:3){Text(event.displayName).font(.system(size:13,weight:.medium));Text(event.detail).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)};Spacer()}.padding(.vertical,9).overlay(alignment:.bottom){Rectangle().fill(PAPStyle.divider).frame(height:0.6)}
                }
                if detail.events.isEmpty { Text("No events recorded.").font(.system(size:13)).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct ShiftPage: View {
    @ObservedObject var r: Recorder
    private var offset: TimeInterval { r.timeShiftOriginalStart.map { r.timeShiftTargetStart.timeIntervalSince($0) } ?? 0 }
    private var shiftedEnd: Date? { r.timeShiftOriginalEnd.map { $0.addingTimeInterval(offset) } }
    private var folderName: String {
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone = .current;f.dateFormat="yyyy-MM-dd_HHmmss"
        return f.string(from:r.timeShiftTargetStart)+"_shifted"
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:17){
                PageHeader(title:"Shift session time",subtitle:"Align a completed session with your PAP timeline.",trailing:AnyView(Button(r.timeShiftFolder == nil ? "Choose folder…" : "Choose another…"){r.chooseTimeShiftFolder()}))
                VStack(alignment:.leading,spacing:15){
                    HStack { Text("Source session").font(.system(size:17,weight:.semibold));Spacer() }
                    if let folder=r.timeShiftFolder {
                        HStack(spacing:12){Image(systemName:"folder").font(.system(size:28)).foregroundStyle(.secondary);VStack(alignment:.leading,spacing:3){Text(folder.lastPathComponent).font(.system(size:15,weight:.semibold));Text("Completed · \(r.timeShiftOriginalEnd.map{SavedSession.durationLabel($0.timeIntervalSince(r.timeShiftOriginalStart ?? $0))} ?? "Duration unavailable") · \(r.timeShiftDevice)").font(.system(size:13)).foregroundStyle(.secondary)};Spacer()}
                        HStack(alignment:.top,spacing:70){metaValue("Original start",r.timeShiftOriginalStart.map{dateText($0,zone:r.timeShiftZone,includeDate:true)} ?? "—");metaValue("Time zone",r.timeShiftZone);Spacer()}
                    }else{
                        HStack(spacing:12){Image(systemName:"folder").font(.system(size:28)).foregroundStyle(.secondary);Text("Choose a completed PolarPAP session folder.").font(.system(size:14)).foregroundStyle(.secondary)}
                    }
                }.padding(18).background(PAPStyle.card,in:RoundedRectangle(cornerRadius:11)).overlay(RoundedRectangle(cornerRadius:11).stroke(PAPStyle.divider,lineWidth:0.7))
                VStack(alignment:.leading,spacing:13){
                    Text("New start time").font(.system(size:17,weight:.semibold))
                    TextField("DD/MM/YYYY, HH:MM:SS",text:$r.timeShiftTargetText)
                        .font(.system(size:15,design:.monospaced)).textFieldStyle(.roundedBorder).frame(maxWidth:390)
                        .disabled(r.timeShiftFolder == nil || r.timeShiftBusy)
                        .onChange(of:r.timeShiftTargetText){_,text in
                            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_GB");formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone = .current;formatter.isLenient=false;formatter.dateFormat="dd/MM/yyyy, HH:mm:ss"
                            if let value=formatter.date(from:text),formatter.string(from:value)==text{
                                r.timeShiftTargetStart=value;r.timeShiftTargetSecond=Calendar.current.component(.second,from:value);r.timeShiftTargetTextValid=true
                            }else{r.timeShiftTargetTextValid=false}
                        }
                    if !r.timeShiftTargetTextValid { Text("Enter a valid date and time: DD/MM/YYYY, HH:MM:SS.").font(.system(size:12)).foregroundStyle(PAPStyle.red) }
                    Text("Uses your Mac’s current time zone: \(TimeZone.current.identifier).").font(.system(size:13)).foregroundStyle(.secondary)
                }.padding(.vertical,5)
                Divider()
                VStack(alignment:.leading,spacing:12){Text("Preview").font(.system(size:17,weight:.semibold));previewTable}
                VStack(alignment:.leading,spacing:7){Label("All absolute timestamps and UTC columns shift together.",systemImage:"checkmark.circle.fill").foregroundStyle(PAPStyle.green);Label("Signal values, Polar relative time, and monotonic time stay unchanged.",systemImage:"checkmark.circle.fill").foregroundStyle(PAPStyle.green)}.font(.system(size:13))
                Divider()
                VStack(alignment:.leading,spacing:5){Text("New folder").font(.system(size:16,weight:.semibold));Text(folderName).font(.system(size:13,design:.monospaced)).padding(9).frame(maxWidth:.infinity,alignment:.leading).background(PAPStyle.card,in:RoundedRectangle(cornerRadius:7)).overlay(RoundedRectangle(cornerRadius:7).stroke(PAPStyle.divider,lineWidth:0.7));Text("Saved beside the source. Original files stay unchanged.").font(.system(size:12)).foregroundStyle(.secondary)}
                HStack { Text("This aligns the data timeline; it does not synchronize devices.").font(.system(size:12)).foregroundStyle(.secondary);Spacer();Button(r.timeShiftBusy ? "Creating copy…" : "Create shifted copy"){r.createShiftedCopy()}.buttonStyle(.borderedProminent).disabled(r.timeShiftFolder == nil || r.timeShiftBusy || r.recording || !r.timeShiftTargetTextValid) }
                if let message=r.timeShiftMessage { HStack { Text(message).font(.system(size:12)).foregroundStyle(r.timeShiftOutput == nil && !message.hasPrefix("Creating") ? PAPStyle.red : PAPStyle.muted);Spacer();if let output=r.timeShiftOutput{Button("Show in Finder"){NSWorkspace.shared.open(output)}} } }
            }.padding(30)
        }
    }
    private var previewTable: some View {
        VStack(spacing:0){
            HStack{Text("");Text("Original").foregroundStyle(.secondary);Text("Shifted copy").foregroundStyle(.secondary)}.font(.system(size:13,weight:.semibold)).padding(.vertical,10)
            Divider()
            previewRow("Start",original:r.timeShiftOriginalStart.map{dateText($0,zone:r.timeShiftZone,includeDate:true)} ?? "—",shifted:r.timeShiftFolder == nil ? "—" : dateText(r.timeShiftTargetStart,zone:TimeZone.current.identifier,includeDate:true))
            Divider()
            previewRow("End",original:r.timeShiftOriginalEnd.map{dateText($0,zone:r.timeShiftZone,includeDate:true)} ?? "—",shifted:shiftedEnd.map{dateText($0,zone:TimeZone.current.identifier,includeDate:true)} ?? "—")
            Divider()
            HStack{Text("Time offset").foregroundStyle(.secondary);Text("");Text(r.timeShiftFolder == nil ? "—" : offsetLabel(offset)).font(.system(size:16,weight:.bold))}.padding(.vertical,10)
        }.padding(.horizontal,14).background(PAPStyle.card,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).stroke(PAPStyle.divider,lineWidth:0.7))
    }
    private func previewRow(_ label:String,original:String,shifted:String)->some View{HStack{Text(label).foregroundStyle(.secondary);Text(original);Text(shifted)}.font(.system(size:13)).padding(.vertical,10)}
    private func metaValue(_ title:String,_ value:String)->some View{VStack(alignment:.leading,spacing:3){Text(title).font(.system(size:12)).foregroundStyle(.secondary);Text(value).font(.system(size:13))}}
}

private func statusPill(_ status: String) -> some View {
    let complete=status == "completed"
    return HStack(spacing:4){if complete{Image(systemName:"checkmark.circle.fill")};Text(status.capitalized)}
        .font(.system(size:11,weight:.medium)).foregroundStyle(complete ? Color(nsColor:.systemGreen) : PAPStyle.orange)
        .padding(.horizontal,8).padding(.vertical,4).background((complete ? PAPStyle.green : PAPStyle.orange).opacity(0.10),in:Capsule())
}

private func dateText(_ date: Date, zone: String, includeDate: Bool) -> String {
    let f=DateFormatter();f.locale=Locale(identifier:"en_GB");f.timeZone=TimeZone(identifier:zone) ?? .current;f.dateFormat=includeDate ? "dd MMM yyyy, HH:mm:ss" : "HH:mm:ss"
    return f.string(from:date)
}

private func offsetLabel(_ interval: TimeInterval) -> String {
    let seconds=Int(interval.rounded()), sign=seconds < 0 ? "−" : "+", absolute=abs(seconds)
    if absolute >= 3600 { return "\(sign)\(absolute/3600) h \((absolute%3600)/60) min" }
    if absolute >= 60 { return "\(sign)\(absolute/60) min" }
    return "\(sign)\(absolute) sec"
}
