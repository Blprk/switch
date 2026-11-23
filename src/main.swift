import Cocoa
import IOKit
import IOKit.pwr_mgt

// MARK: - Explicit state model

enum SessionMode: String {
    case indefinite
    case minutes
    case hours
    case until
    case app
    case download
}

/// The single source of truth for what the app is doing.
enum AppState: String {
    case off = "OFF"
    case active = "ACTIVE"
    case lidPaused = "LID PAUSED"
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover?
    var monitorTimer: Timer?

    // State machine
    var state: AppState = .off
    var lastEvent: String = "Started"

    // Session configuration (meaningful while state is .active or .lidPaused)
    var sessionMode: SessionMode = .indefinite
    var sessionEndDate: Date?
    var sessionStartedAt: Date?
    var sessionAppBundleID: String?
    var sessionAppName: String?
    var appChoices: [(name: String, bundleID: String)] = []

    // Download monitoring
    var downloadBaseline: [String: Int64] = [:]
    var lastDownloadActivity: Date = Date()
    var downloadSource: String = "Downloads folder"

    // Live display stats
    var batteryLine: String = "—"
    var powerSource: String = "—"
    var uptimeLine: String = "—"
    var lidIsClosed: Bool = false

    // IOPM assertions
    var assertionIDs: [IOPMAssertionID] = []
    static let assertionTypes = [
        "PreventUserIdleDisplaySleep",
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "PreventDiskIdle",
        "UserIsActive"
    ]

    // MARK: - Lifecycle

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

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "isOn") // stale key from older versions
        let savedOn = (defaults.object(forKey: "userWantsOn") as? Bool) ?? true
        loadSession()

        let lidClosed = isLidClosed()
        state = savedOn ? (lidClosed ? .lidPaused : .active) : .off
        lastEvent = "Launched"
        if state != .off { sessionStartedAt = Date() }
        if state == .active { acquireAssertions() }
        if sessionMode == .download { resetDownloadBaseline() }

        refreshStats()
        updateUI()

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        releaseAssertions()
    }

    // MARK: - State machine

    /// Every change of state goes through here: assertions, persistence, UI.
    func transition(to newState: AppState, event: String) {
        let old = state
        state = newState
        lastEvent = event

        switch newState {
        case .off:
            releaseAssertions()
            clearSession()
            UserDefaults.standard.set(false, forKey: "userWantsOn")
        case .active:
            acquireAssertions()
            UserDefaults.standard.set(true, forKey: "userWantsOn")
            saveSession()
        case .lidPaused:
            releaseAssertions()
        }

        if old != newState { updateUI() }
    }

    func startSession(_ mode: SessionMode,
                      endDate: Date? = nil,
                      appBundleID: String? = nil,
                      appName: String? = nil,
                      event: String) {
        sessionMode = mode
        sessionEndDate = endDate
        sessionStartedAt = Date()
        sessionAppBundleID = appBundleID
        sessionAppName = appName
        if mode == .download { resetDownloadBaseline() }
        transition(to: isLidClosed() ? .lidPaused : .active, event: event)
    }

    func endSession(event: String) {
        transition(to: .off, event: event)
    }

    // MARK: - Assertions

    func acquireAssertions() {
        guard assertionIDs.isEmpty else { return }
        for type in Self.assertionTypes {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "KeepAwake" as CFString,
                &id
            )
            if result == kIOReturnSuccess { assertionIDs.append(id) }
        }
    }

    func releaseAssertions() {
        for id in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs.removeAll()
    }

    // MARK: - Monitoring

    func tick() {
        checkLid()
        checkSession()
        // Only the menu-bar title changes every 2s. Rebuilding the popover
        // here would recreate its view while it is open and cause flicker.
        updateButton()
    }

    func isLidClosed() -> Bool {
        let out = shell("ioreg -r -k AppleClamshellState -d 1 2>/dev/null")
        var closed = false
        for line in out.components(separatedBy: "\n") where line.lowercased().contains("appleclamshellstate\"") {
            closed = line.lowercased().contains("= yes")
        }
        lidIsClosed = closed
        return closed
    }

    func checkLid() {
        let closed = isLidClosed()
        if closed && state == .active {
            transition(to: .lidPaused, event: "Lid closed — assertions paused")
        } else if !closed && state == .lidPaused {
            transition(to: .active, event: "Lid opened — assertions resumed")
        }
    }

    func checkSession() {
        guard state != .off else { return }
        switch sessionMode {
        case .indefinite:
            break
        case .minutes, .hours, .until:
            if let end = sessionEndDate, Date() >= end {
                endSession(event: "Timer expired")
            }
        case .app:
            guard let bid = sessionAppBundleID else {
                endSession(event: "App session lost its target")
                return
            }
            let stillRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bid }
            if !stillRunning {
                endSession(event: "\(sessionAppName ?? "App") quit")
            }
        case .download:
            let status = downloadStatus()
            downloadSource = status.source
            if status.active {
                lastDownloadActivity = Date()
            } else if Date().timeIntervalSince(lastDownloadActivity) > 30 {
                endSession(event: "No download activity for 30s")
            }
        }
    }

    // MARK: - Download detection (returns values; no hidden side effects)

    func downloadSnapshot() -> [String: Int64] {
        let fm = FileManager.default
        let dir = NSString(string: "~/Downloads").expandingTildeInPath
        var result: [String: Int64] = [:]
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return result }
        for file in files {
            let path = (dir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber else { continue }
            result[file] = size.int64Value
        }
        return result
    }

    func resetDownloadBaseline() {
        downloadBaseline = downloadSnapshot()
        lastDownloadActivity = Date()
        downloadSource = downloadStatus().source
    }

    /// Returns whether a download is active and which source was readable.
    func downloadStatus() -> (active: Bool, source: String) {
        var active = false
        var browserReadable = false

        // Safari: ~/Library/Safari/Downloads.plist
        let safari = NSString(string: "~/Library/Safari/Downloads.plist").expandingTildeInPath
        if FileManager.default.fileExists(atPath: safari) {
            let out = shell("/usr/bin/plutil -convert json -o - \"\(safari)\" 2>/dev/null")
            if let data = out.data(using: .utf8), !out.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: data),
               let dict = json as? [String: Any],
               let items = dict["DownloadHistory"] as? [[String: Any]] {
                browserReadable = true
                for item in items {
                    if let s = item["DownloadEntryState"] as? Int, s == 0 { active = true }
                    if let soFar = item["DownloadEntryProgressBytesSoFar"] as? Int,
                       let total = item["DownloadEntryProgressTotalToLoad"] as? Int,
                       total > 0, soFar < total { active = true }
                }
            }
        }

        // Chromium browsers (state 0 = in progress)
        let cmd = """
        setopt NULL_GLOB
        for f in "$HOME/Library/Application Support/Google/Chrome"/*/History \
                 "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"/*/History \
                 "$HOME/Library/Application Support/Microsoft Edge"/*/History \
                 "$HOME/Library/Application Support/Vivaldi"/*/History; do
          [ -f "$f" ] || continue
          n=$(/usr/bin/sqlite3 "file:$f?immutable=1" "SELECT count(*) FROM downloads WHERE state=0;" 2>/dev/null)
          [ -n "$n" ] && [ "$n" != "0" ] && echo ACTIVE
        done
        """
        if shell(cmd).contains("ACTIVE") {
            active = true
            browserReadable = true
        }

        // ~/Downloads heuristic (also covers browsers we can't read)
        let snap = downloadSnapshot()
        let partials = [".download", ".crdownload", ".part", ".tmp"]
        for (name, size) in snap {
            if partials.contains(where: { name.lowercased().hasSuffix($0) }) { active = true }
            if let old = downloadBaseline[name], size > old { active = true }
        }
        downloadBaseline = snap

        let source = browserReadable
            ? "Browser events + Downloads folder"
            : "Downloads folder (grant Full Disk Access for browser events)"
        return (active, source)
    }

    // MARK: - Persistence

    func saveSession() {
        let d = UserDefaults.standard
        d.set(sessionMode.rawValue, forKey: "sessionMode")
        d.set(sessionEndDate, forKey: "sessionEndDate")
        d.set(sessionAppBundleID, forKey: "sessionAppBundleID")
        d.set(sessionAppName, forKey: "sessionAppName")
    }

    func loadSession() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "sessionMode"), let mode = SessionMode(rawValue: raw) {
            sessionMode = mode
        }
        sessionEndDate = d.object(forKey: "sessionEndDate") as? Date
        sessionAppBundleID = d.string(forKey: "sessionAppBundleID")
        sessionAppName = d.string(forKey: "sessionAppName")

        if [.minutes, .hours, .until].contains(sessionMode),
           let end = sessionEndDate, end <= Date() {
            clearSession()
            d.set(false, forKey: "userWantsOn")
        }
    }

    func clearSession() {
        let d = UserDefaults.standard
        for key in ["sessionMode", "sessionEndDate", "sessionAppBundleID", "sessionAppName"] {
            d.removeObject(forKey: key)
        }
        sessionStartedAt = nil
    }

    // MARK: - Explicit descriptions

    func sessionDescription() -> String {
        switch sessionMode {
        case .indefinite:
            return "Runs until you end it"
        case .minutes, .hours, .until:
            guard let end = sessionEndDate else { return "Timed" }
            let seconds = Int(end.timeIntervalSinceNow)
            if seconds <= 0 { return "Ending now" }
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "Ends in \(h > 0 ? "\(h)h \(m)m" : "\(m)m")"
        case .app:
            return "Ends when \(sessionAppName ?? "the app") quits"
        case .download:
            return "Ends 30s after downloads stop"
        }
    }

    func sessionUptimeString() -> String {
        guard let started = sessionStartedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(started))
        if seconds < 0 { return "—" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    func sessionEndTimeString() -> String {
        guard let end = sessionEndDate else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: end)
    }

    func menuBarTitle() -> String {
        switch state {
        case .off:
            return "○ OFF"
        case .lidPaused:
            return "⏸"
        case .active:
            if [.minutes, .hours, .until].contains(sessionMode),
               let end = sessionEndDate {
                let s = Int(end.timeIntervalSinceNow)
                if s <= 0 { return "● 0m" }
                let h = s / 3600
                let m = (s % 3600) / 60
                return h > 0 ? "● \(h)h\(m)m" : "● \(m)m"
            }
            return "● ON"
        }
    }

    func nextTime(hour: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        var date = Calendar.current.date(from: comps) ?? Date().addingTimeInterval(3600)
        if date <= Date() {
            date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: - Actions

    @objc func toggleAction() {
        if state == .off {
            startSession(.indefinite, event: "Indefinite session started")
        } else {
            endSession(event: "Ended by you")
        }
    }

    @objc func quitAction() {
        releaseAssertions()
        NSApp.terminate(nil)
    }

    @objc func refreshAction() {
        refreshStats()
        updateUI()
    }

    @objc func startIndefinite() {
        startSession(.indefinite, event: "Indefinite session started")
    }

    @objc func startDownloadSession() {
        startSession(.download, event: "Download session started")
    }

    @objc func sessionPreset(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        switch sender.tag {
        case 1:
            startSession(.minutes, endDate: Date().addingTimeInterval(Double(item.tag) * 60),
                         event: "\(item.tag) minute session started")
        case 2:
            startSession(.hours, endDate: Date().addingTimeInterval(Double(item.tag) * 3600),
                         event: "\(item.tag) hour session started")
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
            startSession(.until, endDate: end, event: "Until session started")
        case 4:
            let index = item.tag
            guard index >= 0, index < appChoices.count else { return }
            startSession(.app, appBundleID: appChoices[index].bundleID, appName: appChoices[index].name,
                         event: "App session started for \(appChoices[index].name)")
        default:
            break
        }
    }

    // MARK: - UI

    func updateButton() {
        guard let button = statusItem.button else { return }
        let color: NSColor
        switch state {
        case .off: color = .secondaryLabelColor
        case .active: color = .systemGreen
        case .lidPaused: color = .systemOrange
        }
        button.attributedTitle = NSAttributedString(string: menuBarTitle(), attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        ])
    }

    func updateUI() {
        updateButton()
        rebuildPopover()
    }

    @objc func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: state == .off ? "Start Indefinite" : "End Session",
                                    action: #selector(toggleAction), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)
            menu.addItem(NSMenuItem.separator())
            let quit = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
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
            updateUI()
            showPopover()
        }
    }

    func showPopover() {
        guard let popover else { return }
        let vc = makePopoverContent()
        popover.contentViewController = vc
        popover.contentSize = vc.view.fittingSize
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func rebuildPopover() {
        guard let popover, popover.isShown else { return }
        let vc = makePopoverContent()
        popover.contentViewController = vc
        popover.contentSize = vc.view.fittingSize
    }

    func row(label: String, control: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11)
        text.widthAnchor.constraint(equalToConstant: 118).isActive = true
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(control)
        return stack
    }

    func popup(_ items: [(String, Int)], tag: Int, width: CGFloat) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.tag = tag
        button.target = self
        button.action = #selector(sessionPreset(_:))
        for (title, itemTag) in items {
            button.addItem(withTitle: title)
            button.lastItem?.tag = itemTag
        }
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    func makePopoverContent() -> NSViewController {
        let vc = NSViewController()
        let view = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

        func line(_ text: String, font: NSFont = .systemFont(ofSize: 11), color: NSColor = .labelColor) {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(label)
        }
        func divider() {
            let box = NSBox()
            box.boxType = .separator
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }

        let stateColor: NSColor
        switch state {
        case .off: stateColor = .secondaryLabelColor
        case .active: stateColor = .systemGreen
        case .lidPaused: stateColor = .systemOrange
        }
        line("KeepAwake — \(state.rawValue)", font: .boldSystemFont(ofSize: 12), color: stateColor)
        if state != .off {
            line("Session: \(sessionDescription())")
        }
        line("Last event: \(lastEvent)", color: .secondaryLabelColor)
        line("Assertions held: \(assertionIDs.count)/\(Self.assertionTypes.count)", color: .secondaryLabelColor)
        divider()

        line("Start New Session:", font: .boldSystemFont(ofSize: 11), color: .secondaryLabelColor)

        let indefinite = NSButton(title: "Indefinitely", target: self, action: #selector(startIndefinite))
        indefinite.bezelStyle = .rounded
        indefinite.controlSize = .small
        stack.addArrangedSubview(row(label: "", control: indefinite))

        stack.addArrangedSubview(row(label: "Minutes", control: popup([
            ("5 min", 5), ("10 min", 10), ("15 min", 15), ("30 min", 30), ("45 min", 45), ("60 min", 60)
        ], tag: 1, width: 100)))
        stack.addArrangedSubview(row(label: "Hours", control: popup([
            ("1 hr", 1), ("2 hr", 2), ("3 hr", 3), ("4 hr", 4), ("6 hr", 6), ("8 hr", 8), ("12 hr", 12)
        ], tag: 2, width: 100)))
        stack.addArrangedSubview(row(label: "Other Time/Until", control: popup([
            ("5:00 PM", 1), ("11:00 PM", 2), ("Midnight", 3), ("In 30 min", 4), ("In 2 hours", 5)
        ], tag: 3, width: 100)))

        appChoices = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName,
                  let bundle = app.bundleIdentifier,
                  bundle != "com.user.keepawakeapp" else { return nil }
            return (name, bundle)
        }.sorted { $0.name < $1.name }
        let appItems: [(String, Int)] = appChoices.isEmpty
            ? [("No apps", -1)]
            : appChoices.prefix(20).enumerated().map { ($0.element.name, $0.offset) }
        stack.addArrangedSubview(row(label: "While App Running", control: popup(appItems, tag: 4, width: 100)))

        let download = NSButton(title: "Start", target: self, action: #selector(startDownloadSession))
        download.bezelStyle = .rounded
        download.controlSize = .small
        stack.addArrangedSubview(row(label: "While Downloading", control: download))
        divider()

        line("Power: \(powerSource)")
        line("Battery: \(batteryLine)")
        line("Lid: \(lidIsClosed ? "Closed" : "Open")")
        line("Uptime: \(uptimeLine)")
        line("Session age: \(sessionUptimeString())")
        if [.minutes, .hours, .until].contains(sessionMode), sessionEndDate != nil {
            line("Ends at: \(sessionEndTimeString())")
        }
        line("Download source: \(downloadSource)", color: .secondaryLabelColor)

        divider()
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let toggle = NSButton(title: state == .off ? "Start Indefinite" : "End Session",
                              target: self, action: #selector(toggleAction))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitAction))
        for button in [toggle, refresh, quit] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)

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

    // MARK: - Stats helpers

    func shell(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
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
        if let match = ps.range(of: #"\d+%"#, options: .regularExpression) {
            batteryLine = String(ps[match])
        } else {
            batteryLine = "—"
        }
        if ps.lowercased().contains("charging") && !ps.lowercased().contains("discharging") {
            batteryLine += " (charging)"
        } else if ps.lowercased().contains("discharging") {
            batteryLine += " (discharging)"
        }

        let uptime = shell("uptime")
        if let range = uptime.range(of: "up ") {
            var value = String(uptime[range.upperBound...])
            if let end = value.range(of: " user") {
                value = String(value[..<end.lowerBound])
            } else if let end = value.range(of: " load") {
                value = String(value[..<end.lowerBound])
            }
            uptimeLine = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }

    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
