import Cocoa
import IOKit
import IOKit.pwr_mgt

enum SessionMode: String {
    case indefinite
    case minutes
    case hours
    case until
    case app
    case download
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var assertionIDs: [IOPMAssertionID] = []

    var userWantsOn: Bool = true
    var pausedByLid: Bool = false
    var effectiveOn: Bool { userWantsOn && !pausedByLid }

    // Session state
    var sessionMode: SessionMode = .indefinite
    var sessionEndDate: Date?
    var sessionAppBundleID: String?
    var sessionAppName: String?
    var appChoices: [(name: String, bundleID: String)] = []
    var downloadBaseline: [String: Int64] = [:]
    var lastDownloadActivity: Date = Date()

    var awakeSince: Date?
    var lastSleepLine: String = "—"
    var lastWakeLine: String = "—"
    var sleepCount: Int = 0
    var recentEvents: [String] = []
    var batteryLine: String = "—"
    var powerSource: String = "—"
    var uptimeLine: String = "—"

    var popover: NSPopover?
    var monitorTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.user.keepawakeapp")
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("KeepAwake")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let saved = UserDefaults.standard.object(forKey: "userWantsOn")
        userWantsOn = (saved as? Bool) ?? true
        loadSession()

        pausedByLid = isLidClosed()
        if effectiveOn { startCaffeinate() }

        refreshStats()
        updateButton()

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.togglePopover(nil)
            }
        }

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkLid()
            self?.checkSession()
        }
    }

    // MARK: - Session persistence
    func saveSession() {
        let d = UserDefaults.standard
        d.set(sessionMode.rawValue, forKey: "sessionMode")
        d.set(sessionEndDate, forKey: "sessionEndDate")
        d.set(sessionAppBundleID, forKey: "sessionAppBundleID")
        d.set(sessionAppName, forKey: "sessionAppName")
    }

    func loadSession() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "sessionMode"), let m = SessionMode(rawValue: raw) {
            sessionMode = m
        }
        sessionEndDate = d.object(forKey: "sessionEndDate") as? Date
        sessionAppBundleID = d.string(forKey: "sessionAppBundleID")
        sessionAppName = d.string(forKey: "sessionAppName")
        // Expired timed sessions should not auto-resume as "on"
        if [.minutes, .hours, .until].contains(sessionMode),
           let end = sessionEndDate, end <= Date() {
            userWantsOn = false
            UserDefaults.standard.set(false, forKey: "userWantsOn")
            clearSession()
        }
        if sessionMode == .download { resetDownloadBaseline() }
    }

    func clearSession() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "sessionMode")
        d.removeObject(forKey: "sessionEndDate")
        d.removeObject(forKey: "sessionAppBundleID")
        d.removeObject(forKey: "sessionAppName")
    }

    func startSession(_ mode: SessionMode, endDate: Date? = nil, appBundleID: String? = nil, appName: String? = nil) {
        sessionMode = mode
        sessionEndDate = endDate
        sessionAppBundleID = appBundleID
        sessionAppName = appName
        if mode == .download { resetDownloadBaseline() }
        userWantsOn = true
        UserDefaults.standard.set(true, forKey: "userWantsOn")
        saveSession()
        if !pausedByLid { startCaffeinate() }
        updateButton()
        rebuildPopover()
    }

    func endSession() {
        sessionMode = .indefinite
        sessionEndDate = nil
        sessionAppBundleID = nil
        sessionAppName = nil
        userWantsOn = false
        UserDefaults.standard.set(false, forKey: "userWantsOn")
        clearSession()
        stopCaffeinate()
        updateButton()
        rebuildPopover()
    }

    // MARK: - Lid handling
    func isLidClosed() -> Bool {
        let out = shell("ioreg -r -k AppleClamshellState -d 1 2>/dev/null")
        for line in out.components(separatedBy: "\n") {
            if line.lowercased().contains("appleclamshellstate\"") {
                return line.lowercased().contains("= yes")
            }
        }
        return false
    }

    func checkLid() {
        let closed = isLidClosed()
        if closed && !pausedByLid {
            pausedByLid = true
            stopCaffeinate()
            updateButton()
            rebuildPopover()
        } else if !closed && pausedByLid {
            pausedByLid = false
            if userWantsOn { startCaffeinate() }
            updateButton()
            rebuildPopover()
        }
    }

    // MARK: - Session monitoring
    func checkSession() {
        guard userWantsOn else { return }
        switch sessionMode {
        case .indefinite:
            return
        case .minutes, .hours, .until:
            if let end = sessionEndDate, Date() >= end {
                endSession()
            }
        case .app:
            guard let bid = sessionAppBundleID else { endSession(); return }
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bid }
            if !running { endSession() }
        case .download:
            if downloadIsActive() {
                lastDownloadActivity = Date()
            } else if Date().timeIntervalSince(lastDownloadActivity) > 30 {
                endSession()
            }
        }
    }

    func downloadSnapshot() -> [String: Int64] {
        let fm = FileManager.default
        let dir = NSString(string: "~/Downloads").expandingTildeInPath
        var result: [String: Int64] = [:]
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return result }
        for f in files {
            let path = (dir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { continue }
            result[f] = size.int64Value
        }
        return result
    }

    func resetDownloadBaseline() {
        downloadBaseline = downloadSnapshot()
        lastDownloadActivity = Date()
    }

    func downloadIsActive() -> Bool {
        let snap = downloadSnapshot()
        var active = false
        let partials = [".download", ".crdownload", ".part", ".tmp"]
        for (name, size) in snap {
            if partials.contains(where: { name.lowercased().hasSuffix($0) }) {
                active = true
                break
            }
            if let old = downloadBaseline[name], size > old {
                active = true
                break
            }
        }
        downloadBaseline = snap
        return active
    }

    func nextTime(hour: Int, minute: Int = 0) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        var d = Calendar.current.date(from: comps) ?? Date().addingTimeInterval(3600)
        if d <= Date() {
            d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? d
        }
        return d
    }

    func sessionDescription() -> String {
        guard userWantsOn else { return "No active session" }
        switch sessionMode {
        case .indefinite:
            return "Indefinitely"
        case .minutes, .hours, .until:
            guard let end = sessionEndDate else { return "Timed" }
            let secs = Int(end.timeIntervalSinceNow)
            if secs <= 0 { return "Ending…" }
            let h = secs / 3600
            let m = (secs % 3600) / 60
            let left = h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return "\(left) left"
        case .app:
            return "While \(sessionAppName ?? "app") runs"
        case .download:
            return "While downloading"
        }
    }

    // MARK: - Caffeinate (IOPM assertions)
    func startCaffeinate() {
        guard assertionIDs.isEmpty else { return }
        let types = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventDiskIdle", "UserIsActive"]
        for t in types {
            var aid: IOPMAssertionID = 0
            let r = IOPMAssertionCreateWithName(t as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "KeepAwake" as CFString, &aid)
            if r == kIOReturnSuccess {
                assertionIDs.append(aid)
            }
        }
    }

    func stopCaffeinate() {
        for aid in assertionIDs { IOPMAssertionRelease(aid) }
        assertionIDs.removeAll()
    }

    @objc func toggleAction() {
        if userWantsOn { endSession() } else { startSession(.indefinite) }
    }

    @objc func quitAction() {
        stopCaffeinate()
        NSApp.terminate(nil)
    }

    @objc func refreshAction() {
        refreshStats()
        updateButton()
        rebuildPopover()
    }

    // MARK: - Session UI actions
    @objc func startIndefinite() {
        startSession(.indefinite)
    }

    @objc func startDownloadSession() {
        startSession(.download)
    }

    @objc func sessionPreset(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        switch sender.tag {
        case 1:
            startSession(.minutes, endDate: Date().addingTimeInterval(Double(item.tag) * 60))
        case 2:
            startSession(.hours, endDate: Date().addingTimeInterval(Double(item.tag) * 3600))
        case 3:
            let end: Date
            switch item.tag {
            case 1: end = nextTime(hour: 17)
            case 2: end = nextTime(hour: 23)
            case 3: end = nextTime(hour: 0)
            case 4: end = Date().addingTimeInterval(30 * 60)
            case 5: end = Date().addingTimeInterval(2 * 3600)
            default: end = Date().addingTimeInterval(3600)
            }
            startSession(.until, endDate: end)
        case 4:
            let idx = item.tag
            if idx >= 0 && idx < appChoices.count {
                startSession(.app, appBundleID: appChoices[idx].bundleID, appName: appChoices[idx].name)
            }
        default:
            break
        }
    }

    // MARK: - Popover
    @objc func togglePopover(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: userWantsOn ? "End Session" : "Start Indefinite", action: #selector(toggleAction), keyEquivalent: "")
            toggleItem.target = self
            menu.addItem(toggleItem)
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            }
            return
        }

        if popover == nil {
            let p = NSPopover()
            p.behavior = .transient
            p.animates = true
            popover = p
        }
        if popover!.isShown {
            popover!.performClose(sender)
        } else {
            refreshStats()
            updateButton()
            let vc = makePopoverContent()
            popover!.contentViewController = vc
            popover!.contentSize = vc.view.fittingSize
            if let button = statusItem.button {
                popover!.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    func rebuildPopover() {
        guard let popover = popover, popover.isShown else { return }
        let vc = makePopoverContent()
        popover.contentViewController = vc
        popover.contentSize = vc.view.fittingSize
    }

    func sessionRow(label: String, control: NSView) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 11)
        lbl.textColor = .labelColor
        lbl.widthAnchor.constraint(equalToConstant: 118).isActive = true
        row.addArrangedSubview(lbl)
        row.addArrangedSubview(control)
        return row
    }

    func popup(_ items: [(String, Int)], tag: Int, width: CGFloat) -> NSPopUpButton {
        let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        p.controlSize = .small
        p.font = NSFont.systemFont(ofSize: 11)
        p.tag = tag
        p.target = self
        p.action = #selector(sessionPreset(_:))
        for (title, itemTag) in items {
            p.addItem(withTitle: title)
            p.lastItem?.tag = itemTag
        }
        p.widthAnchor.constraint(equalToConstant: width).isActive = true
        return p
    }

    func makePopoverContent() -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        view.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let statusText: String
        if pausedByLid {
            statusText = "PAUSED (lid closed)"
        } else {
            statusText = userWantsOn ? "ACTIVE — \(sessionDescription())" : "INACTIVE"
        }
        let header = NSTextField(labelWithString: "KeepAwake — \(statusText)")
        header.font = NSFont.boldSystemFont(ofSize: 12)
        if pausedByLid {
            header.textColor = .systemOrange
        } else {
            header.textColor = userWantsOn ? .systemGreen : .secondaryLabelColor
        }
        header.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(header)

        func separator() {
            let box = NSBox()
            box.boxType = .separator
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        separator()

        // Session section
        let sessHeader = NSTextField(labelWithString: "Start New Session:")
        sessHeader.font = NSFont.boldSystemFont(ofSize: 11)
        sessHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(sessHeader)

        let indefBtn = NSButton(title: "Indefinitely", target: self, action: #selector(startIndefinite))
        indefBtn.bezelStyle = .rounded
        indefBtn.controlSize = .small
        stack.addArrangedSubview(sessionRow(label: "", control: indefBtn))

        stack.addArrangedSubview(sessionRow(label: "Minutes", control: popup([
            ("5 min", 5), ("10 min", 10), ("15 min", 15), ("30 min", 30), ("45 min", 45), ("60 min", 60)
        ], tag: 1, width: 100)))

        stack.addArrangedSubview(sessionRow(label: "Hours", control: popup([
            ("1 hr", 1), ("2 hr", 2), ("3 hr", 3), ("4 hr", 4), ("6 hr", 6), ("8 hr", 8), ("12 hr", 12)
        ], tag: 2, width: 100)))

        stack.addArrangedSubview(sessionRow(label: "Other Time/Until", control: popup([
            ("5:00 PM", 1), ("11:00 PM", 2), ("Midnight", 3), ("In 30 min", 4), ("In 2 hours", 5)
        ], tag: 3, width: 100)))

        appChoices = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier != nil && $0.bundleIdentifier != "com.user.keepawakeapp" && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            .map { ($0.localizedName!, $0.bundleIdentifier!) }
        let appItems: [(String, Int)] = appChoices.isEmpty
            ? [("No apps", -1)]
            : appChoices.prefix(20).enumerated().map { ($0.element.name, $0.offset) }
        stack.addArrangedSubview(sessionRow(label: "While App Running", control: popup(appItems, tag: 4, width: 100)))

        let dlBtn = NSButton(title: "Start", target: self, action: #selector(startDownloadSession))
        dlBtn.bezelStyle = .rounded
        dlBtn.controlSize = .small
        stack.addArrangedSubview(sessionRow(label: "While Downloading", control: dlBtn))

        separator()

        // Stats
        let stats: [String] = [
            "Power: \(powerSource)",
            "Battery: \(batteryLine)",
            "Uptime: \(uptimeLine)",
            "Awake: \(awakeDurationString())",
            "Last sleep: \(lastSleepLine)",
            "Sleeps (recent): \(sleepCount)"
        ]
        for line in stats {
            let lbl = NSTextField(labelWithString: line)
            lbl.font = NSFont.systemFont(ofSize: 11)
            lbl.textColor = .labelColor
            lbl.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(lbl)
        }

        if !recentEvents.isEmpty {
            separator()
            let recHeader = NSTextField(labelWithString: "Recent Sleep/Wake")
            recHeader.font = NSFont.boldSystemFont(ofSize: 11)
            recHeader.textColor = .secondaryLabelColor
            stack.addArrangedSubview(recHeader)
            for ev in recentEvents {
                let lbl = NSTextField(labelWithString: ev)
                lbl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
                lbl.textColor = .secondaryLabelColor
                lbl.lineBreakMode = .byTruncatingTail
                stack.addArrangedSubview(lbl)
            }
        }

        separator()

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.alignment = .centerY

        let toggleBtn = NSButton(title: userWantsOn ? "End Session" : "Turn On", target: self, action: #selector(toggleAction))
        toggleBtn.bezelStyle = .rounded
        toggleBtn.controlSize = .small
        btnRow.addArrangedSubview(toggleBtn)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.controlSize = .small
        btnRow.addArrangedSubview(refreshBtn)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quitAction))
        quitBtn.bezelStyle = .rounded
        quitBtn.controlSize = .small
        btnRow.addArrangedSubview(quitBtn)

        stack.addArrangedSubview(btnRow)

        view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        view.widthAnchor.constraint(equalToConstant: 280).isActive = true

        vc.view = view
        return vc
    }

    func updateButton() {
        if let button = statusItem.button {
            let title: String
            let color: NSColor
            if pausedByLid {
                title = "⏸"
                color = .systemOrange
            } else if userWantsOn {
                title = "● ON"
                color = .systemGreen
            } else {
                title = "○ OFF"
                color = .secondaryLabelColor
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            ]
            button.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        }
    }

    // MARK: - Stats
    func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func refreshStats() {
        let ps = shell("pmset -g ps")
        if ps.contains("AC Power") {
            powerSource = "AC Power"
        } else if ps.contains("Battery Power") {
            powerSource = "Battery Power"
        } else {
            powerSource = "Unknown"
        }
        if let m = ps.range(of: #"\d+%"#, options: .regularExpression) {
            batteryLine = String(ps[m])
        } else {
            batteryLine = "—"
        }
        if ps.lowercased().contains("charging") && !ps.lowercased().contains("discharging") {
            batteryLine += " (charging)"
        } else if ps.lowercased().contains("discharging") {
            batteryLine += " (discharging)"
        }

        let up = shell("uptime")
        if let r = up.range(of: "up ") {
            var s = String(up[r.upperBound...])
            if let ur = s.range(of: " user") {
                s = String(s[..<ur.lowerBound])
            } else if let lr = s.range(of: " load") {
                s = String(s[..<lr.lowerBound])
            }
            uptimeLine = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy.MM.dd"
        let todayStr = df.string(from: Date())
        let yestStr = df.string(from: Date().addingTimeInterval(-86400))
        let cmd = "syslog -f /var/log/powermanagement/\(yestStr).asl 2>/dev/null | grep -iE 'Entering Sleep|Wake from|DarkWake'; syslog -f /var/log/powermanagement/\(todayStr).asl 2>/dev/null | grep -iE 'Entering Sleep|Wake from|DarkWake'"
        let logOut = shell(cmd)
        let lines = logOut.components(separatedBy: "\n")
        var sleeps: [String] = []
        var wakes: [String] = []
        var recent: [String] = []
        for line in lines {
            if line.contains("Entering Sleep") {
                sleeps.append(line)
                recent.append("⬇ " + shortEvent(line))
            } else if line.contains("Wake from") || line.contains("DarkWake") {
                wakes.append(line)
                recent.append("⬆ " + shortEvent(line))
            }
        }
        sleepCount = sleeps.count
        if let last = sleeps.last { lastSleepLine = shortEvent(last) } else { lastSleepLine = "—" }
        if let last = wakes.last { lastWakeLine = shortEvent(last); parseAwakeSince(last) } else { lastWakeLine = "—"; awakeSince = nil }

        recentEvents = Array(recent.suffix(8)).reversed()
    }

    func shortEvent(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        var ts = ""
        if parts.count >= 3 { ts = "\(parts[0]) \(parts[1]) \(parts[2])" }
        var reason = trimmed
        if let r = trimmed.range(of: "due to '") {
            let rest = trimmed[r.upperBound...]
            if let end = rest.range(of: "'") {
                reason = String(rest[..<end.lowerBound])
            }
        } else if trimmed.contains("Wake from") {
            if let r = trimmed.range(of: "Wake from") {
                var rr = String(trimmed[r.lowerBound...])
                if let end = rr.range(of: "Using") { rr = String(rr[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
                reason = rr
            }
        } else if trimmed.contains("DarkWake") {
            if let r = trimmed.range(of: "DarkWake") {
                var rr = String(trimmed[r.lowerBound...])
                if let end = rr.range(of: "Using") { rr = String(rr[..<end.lowerBound]).trimmingCharacters(in: .whitespaces) }
                reason = rr
            }
        }
        if ts.isEmpty { return reason }
        return "\(ts) — \(reason)"
    }

    func parseAwakeSince(_ line: String) {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        if parts.count >= 3 {
            let year = Calendar.current.component(.year, from: Date())
            let ts = "\(year) \(parts[0]) \(parts[1]) \(parts[2])"
            let df = DateFormatter()
            df.dateFormat = "yyyy MMM dd HH:mm:ss"
            df.locale = Locale(identifier: "en_US_POSIX")
            if let d = df.date(from: ts) {
                awakeSince = d
            }
        }
    }

    func awakeDurationString() -> String {
        guard let since = awakeSince else { return "—" }
        let interval = Date().timeIntervalSince(since)
        if interval < 0 { return "—" }
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        stopCaffeinate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
