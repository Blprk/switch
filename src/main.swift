import Cocoa
import IOKit
import IOKit.pwr_mgt

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var assertionIDs: [IOPMAssertionID] = []

    var userWantsOn: Bool = true
    var pausedByLid: Bool = false
    var effectiveOn: Bool { userWantsOn && !pausedByLid }

    var awakeSince: Date?
    var lastSleepLine: String = "—"
    var lastWakeLine: String = "—"
    var sleepCount: Int = 0
    var recentEvents: [String] = []
    var batteryLine: String = "—"
    var powerSource: String = "—"
    var uptimeLine: String = "—"

    var popover: NSPopover?
    var lidTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // initial lid state
        pausedByLid = isLidClosed()
        if effectiveOn { startCaffeinate() }

        refreshStats()
        updateButton()

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.togglePopover(nil)
            }
        }

        lidTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkLid()
        }
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
        for aid in assertionIDs {
            IOPMAssertionRelease(aid)
        }
        assertionIDs.removeAll()
    }

    @objc func toggleAction() {
        userWantsOn.toggle()
        UserDefaults.standard.set(userWantsOn, forKey: "userWantsOn")
        if !pausedByLid {
            if userWantsOn { startCaffeinate() } else { stopCaffeinate() }
        }
        updateButton()
        rebuildPopover()
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

    // MARK: - Popover
    @objc func togglePopover(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: userWantsOn ? "Turn Off" : "Turn On", action: #selector(toggleAction), keyEquivalent: "")
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

    func makePopoverContent() -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        view.wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        let statusText: String
        if pausedByLid {
            statusText = "PAUSED (lid closed)"
        } else {
            statusText = userWantsOn ? "ACTIVE" : "INACTIVE"
        }
        let header = NSTextField(labelWithString: "KeepAwake — \(statusText)")
        header.font = NSFont.boldSystemFont(ofSize: 12)
        if pausedByLid {
            header.textColor = .systemOrange
        } else {
            header.textColor = userWantsOn ? .systemGreen : .secondaryLabelColor
        }
        stack.addArrangedSubview(header)

        let sep1 = NSBox()
        sep1.boxType = .separator
        stack.addArrangedSubview(sep1)
        sep1.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        let stats: [String] = [
            "Power: \(powerSource)",
            "Battery: \(batteryLine)",
            "Uptime: \(uptimeLine)",
            "Awake: \(awakeDurationString())",
            "Last sleep: \(lastSleepLine)",
            "Last wake: \(lastWakeLine)",
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
            let sep2 = NSBox()
            sep2.boxType = .separator
            stack.addArrangedSubview(sep2)
            sep2.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

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

        let sep3 = NSBox()
        sep3.boxType = .separator
        stack.addArrangedSubview(sep3)
        sep3.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true

        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.spacing = 8
        btnRow.alignment = .centerY

        let toggleTitle = userWantsOn ? "Turn Off" : "Turn On"
        let toggleBtn = NSButton(title: toggleTitle, target: self, action: #selector(toggleAction))
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

        view.widthAnchor.constraint(equalToConstant: 260).isActive = true

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
        lidTimer?.invalidate()
        stopCaffeinate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
