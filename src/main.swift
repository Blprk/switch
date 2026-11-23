import Cocoa
import IOKit
import IOKit.pwr_mgt

// MARK: - Models

enum SessionMode: String {
    case indefinite
    case minutes
    case hours
    case until
    case app
    case download
}

enum AppState: String {
    case off = "OFF"
    case active = "ACTIVE"
    case lidPaused = "LID PAUSED"
}

enum MenuBarStyle: String {
    case countdown
    case dot
    case icon
}

struct SleepEvent {
    let time: String
    let symbol: String
    let reason: String
}

/// A custom pill toggle: rounded track + sliding knob, never renders as a checkbox.
final class PillToggle: NSView {
    var isOn: Bool = false {
        didSet { applyState() }
    }
    var onToggle: (() -> Void)?

    private let knob = NSView()
    private let label = NSTextField(labelWithString: "")
    private var knobOnConstraint: NSLayoutConstraint!
    private var knobOffConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = true

        label.font = .boldSystemFont(ofSize: 9)
        label.textColor = .white
        label.alignment = .center
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        knob.wantsLayer = true
        knob.layer?.cornerRadius = 8
        knob.layer?.backgroundColor = NSColor.white.cgColor
        knob.layer?.shadowOpacity = 0.15
        knob.layer?.shadowRadius = 2
        knob.translatesAutoresizingMaskIntoConstraints = false
        addSubview(knob)

        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: 16),
            knob.heightAnchor.constraint(equalToConstant: 16)
        ])
        // Both constraints are created once; only their active state changes.
        knobOnConstraint = knob.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        knobOffConstraint = knob.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
        let hover = NSTrackingArea(rect: bounds,
                                   options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                   owner: self, userInfo: nil)
        addTrackingArea(hover)
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 42, height: 22) }

    private func applyState() {
        knobOnConstraint.isActive = isOn
        knobOffConstraint.isActive = !isOn
        layer?.backgroundColor = (isOn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        label.stringValue = isOn ? "ON" : "OFF"
        label.textColor = isOn ? .white : .controlTextColor
        // No needsLayout: pure appearance change, stable intrinsic size.
    }

    @objc private func clicked() {
        isOn.toggle()
        onToggle?()
    }
}

struct Preferences {
    var keepDisplay: Bool = true
    var keepSystem: Bool = true
    var keepDisk: Bool = true
    var downloadFolder: String = NSString(string: "~/Downloads").expandingTildeInPath
    var defaultSession: String = "indefinite" // "indefinite" | "lastUsed"
    var menuBarStyle: String = MenuBarStyle.countdown.rawValue
    var lastSessionMode: String = SessionMode.indefinite.rawValue
    var lastDuration: TimeInterval = 0
    var lastAppBundleID: String?
    var lastAppName: String?
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover?
    var monitorTimer: Timer?

    // State machine
    var state: AppState = .off
    var lastEvent: String = "Started"
    var eventLog: [String] = []

    // Session configuration
    var sessionMode: SessionMode = .indefinite
    var sessionEndDate: Date?
    var sessionStartedAt: Date?
    var sessionAppBundleID: String?
    var sessionAppName: String?
    var appChoices: [(name: String, bundleID: String)] = []

    // Downloads
    var downloadBaseline: [String: Int64] = [:]
    var lastDownloadActivity: Date = Date()
    var downloadSource: String = "Downloads folder"

    // Settings
    var prefs = Preferences()

    // Display stats
    var batteryLine: String = "—"
    var powerSource: String = "—"
    var uptimeLine: String = "—"
    var lidIsClosed: Bool = false
    var sleepEvents: [SleepEvent] = []

    // Collapsible popup sections
    var debugExpanded: Bool = false
    var sleepLogExpanded: Bool = true

    // Live label references (updated in place — no popover rebuild)
    weak var headerLabel: NSTextField?
    weak var powerSwitch: PillToggle?
    weak var sessionLabel: NSTextField?
    weak var lastEventLabel: NSTextField?
    weak var assertionsLabel: NSTextField?

    // Collapsible log containers
    weak var sleepLogContainer: NSStackView?
    weak var debugLogContainer: NSStackView?

    // Assertion IDs by type
    var assertionIDs: [String: IOPMAssertionID] = [:]
    static let allAssertionTypes = [
        "PreventUserIdleDisplaySleep",
        "PreventUserIdleSystemSleep",
        "PreventSystemSleep",
        "PreventDiskIdle",
        "UserIsActive"
    ]

    var loginAgentPath: String {
        NSString(string: "~/Library/LaunchAgents/com.user.keepawakeapp.plist").expandingTildeInPath
    }
    var loginEnabled: Bool { FileManager.default.fileExists(atPath: loginAgentPath) }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.user.keepawakeapp")
        if running.count > 1 {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        ProcessInfo.processInfo.disableAutomaticTermination("KeepAwake")
        registerAppleScriptHandlers()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        UserDefaults.standard.removeObject(forKey: "isOn") // stale key
        loadPreferences()

        loadSession() // may clear an expired session and reset userWantsOn
        refreshStats()
        let defaults = UserDefaults.standard
        let savedOn = (defaults.object(forKey: "userWantsOn") as? Bool) ?? true
        let closed = isLidClosed()
        state = savedOn ? ((closed && powerSource != "AC Power") ? .lidPaused : .active) : .off
        if state != .off { sessionStartedAt = Date() }
        if state == .active { acquireAssertions() }
        if sessionMode == .download { resetDownloadBaseline() }

        logEvent("Launched (v2.0.0)")
        updateUI()

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.tick()
        }

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePopover(nil)
                self?.popover?.contentViewController?.view.window?.level = .floating
                self?.popover?.contentViewController?.view.window?.orderFrontRegardless()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitorTimer?.invalidate()
        releaseAssertions()
    }

    // MARK: - AppleScript

    func registerAppleScriptHandlers() {
        let manager = NSAppleEventManager.shared()
        let eventClass = OSType(0x4B61776B) // 'Kawk'
        for eventID in [OSType(0x41637476), OSType(0x53747274), OSType(0x456E6453), OSType(0x54696D65)] {
            manager.setEventHandler(self,
                                    andSelector: #selector(handleAppleEvent(_:withReplyEvent:)),
                                    forEventClass: eventClass,
                                    andEventID: eventID)
        }
    }

    @objc func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        let directKeyword = AEKeyword(0x2D2D2D2D)
        switch event.eventID {
        case OSType(0x41637476): // session is active
            reply.setParam(NSAppleEventDescriptor(boolean: state != .off), forKeyword: directKeyword)
        case OSType(0x53747274): // start session
            let minutes = event.paramDescriptor(forKeyword: directKeyword)?.int32Value ?? 0
            if minutes > 0 {
                startSession(.minutes, endDate: Date().addingTimeInterval(Double(minutes) * 60),
                             event: "AppleScript: \(minutes) minute session")
            } else {
                startSession(.indefinite, event: "AppleScript: indefinite session")
            }
        case OSType(0x456E6453): // end session
            endSession(event: "AppleScript: end session")
        case OSType(0x54696D65): // time remaining
            let seconds: Int
            if state != .off, let end = sessionEndDate {
                seconds = Int(end.timeIntervalSinceNow)
            } else {
                seconds = 0
            }
            reply.setParam(NSAppleEventDescriptor(int32: Int32(max(0, seconds))), forKeyword: directKeyword)
        default:
            break
        }
    }

    // MARK: - Logging

    func logEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        eventLog.append("\(formatter.string(from: Date())) \(message)")
        if eventLog.count > 100 { eventLog.removeFirst(eventLog.count - 100) }
    }

    // MARK: - Preferences

    func loadPreferences() {
        let d = UserDefaults.standard
        var p = Preferences()
        if d.object(forKey: "keepDisplay") != nil { p.keepDisplay = d.bool(forKey: "keepDisplay") }
        if d.object(forKey: "keepSystem") != nil { p.keepSystem = d.bool(forKey: "keepSystem") }
        if d.object(forKey: "keepDisk") != nil { p.keepDisk = d.bool(forKey: "keepDisk") }
        if let folder = d.string(forKey: "downloadFolder") { p.downloadFolder = folder }
        if let value = d.string(forKey: "defaultSession") { p.defaultSession = value }
        if let value = d.string(forKey: "menuBarStyle"),
           let style = MenuBarStyle(rawValue: value) { p.menuBarStyle = style.rawValue }
        if let value = d.string(forKey: "lastSessionMode") { p.lastSessionMode = value }
        if let value = d.object(forKey: "lastDuration") as? TimeInterval { p.lastDuration = value }
        p.lastAppBundleID = d.string(forKey: "lastAppBundleID")
        p.lastAppName = d.string(forKey: "lastAppName")
        prefs = p
    }

    func savePreferences() {
        let d = UserDefaults.standard
        d.set(prefs.keepDisplay, forKey: "keepDisplay")
        d.set(prefs.keepSystem, forKey: "keepSystem")
        d.set(prefs.keepDisk, forKey: "keepDisk")
        d.set(prefs.downloadFolder, forKey: "downloadFolder")
        d.set(prefs.defaultSession, forKey: "defaultSession")
        d.set(prefs.menuBarStyle, forKey: "menuBarStyle")
        d.set(prefs.lastSessionMode, forKey: "lastSessionMode")
        d.set(prefs.lastDuration, forKey: "lastDuration")
        d.set(prefs.lastAppBundleID, forKey: "lastAppBundleID")
        d.set(prefs.lastAppName, forKey: "lastAppName")
    }

    // MARK: - State machine

    func transition(to newState: AppState, event: String) {
        let old = state
        state = newState
        lastEvent = event
        logEvent(event)

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

        prefs.lastSessionMode = mode.rawValue
        prefs.lastDuration = endDate.map { max(0, $0.timeIntervalSinceNow) } ?? 0
        prefs.lastAppBundleID = appBundleID
        prefs.lastAppName = appName
        savePreferences()

        let lidClosed = isLidClosed()
        let target: AppState = (lidClosed && powerSource != "AC Power") ? .lidPaused : .active
        transition(to: target, event: event)
    }

    func endSession(event: String) {
        transition(to: .off, event: event)
    }

    func restoreLastSession() {
        let mode = SessionMode(rawValue: prefs.lastSessionMode) ?? .indefinite
        switch mode {
        case .minutes, .hours, .until:
            startSession(mode, endDate: Date().addingTimeInterval(prefs.lastDuration), event: "Restored last session")
        case .app:
            if let bundle = prefs.lastAppBundleID {
                startSession(.app, appBundleID: bundle, appName: prefs.lastAppName, event: "Restored last app session")
            } else {
                startSession(.indefinite, event: "Restored indefinite session")
            }
        default:
            startSession(mode, event: "Restored last session")
        }
    }

    // MARK: - Assertions (individually configurable)

    func enabledAssertionTypes() -> [String] {
        var types: [String] = []
        if prefs.keepDisplay { types += ["PreventUserIdleDisplaySleep", "UserIsActive"] }
        if prefs.keepSystem { types += ["PreventUserIdleSystemSleep", "PreventSystemSleep"] }
        if prefs.keepDisk { types += ["PreventDiskIdle"] }
        return types
    }

    func acquireAssertions() {
        guard assertionIDs.isEmpty else { return }
        for type in enabledAssertionTypes() {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Switch Everywhere" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                assertionIDs[type] = id
            } else {
                logEvent("Assertion failed: \(type)")
            }
        }
    }

    func releaseAssertions() {
        for (_, id) in assertionIDs { IOPMAssertionRelease(id) }
        assertionIDs.removeAll()
    }

    func reconfigureAssertions() {
        releaseAssertions()
        if state == .active { acquireAssertions() }
        savePreferences()
        logEvent("Assertion groups updated")
        updateUI()
    }

    // MARK: - Monitoring

    func tick() {
        checkLid()
        checkSession()
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
        let wasClosed = lidIsClosed
        let closed = isLidClosed()

        if closed != wasClosed {
            logEvent(closed ? "Lid closed (\(powerSource))" : "Lid opened")
        }

        // On AC power we intentionally ignore the lid and keep the Mac awake
        // (clamshell mode) so tasks keep running. On battery we pause.
        if closed && state == .active && powerSource != "AC Power" {
            transition(to: .lidPaused, event: "Lid closed on battery — assertions paused")
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
            if let end = sessionEndDate, Date() >= end { endSession(event: "Timer expired") }
        case .app:
            guard let bundle = sessionAppBundleID else {
                endSession(event: "App session lost its target")
                return
            }
            let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }
            if !running { endSession(event: "\(sessionAppName ?? "App") quit") }
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

    // MARK: - Downloads

    func downloadSnapshot() -> [String: Int64] {
        let fm = FileManager.default
        let dir = prefs.downloadFolder
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

    func downloadStatus() -> (active: Bool, source: String) {
        var active = false
        var browserReadable = false

        let safari = NSString(string: "~/Library/Safari/Downloads.plist").expandingTildeInPath
        if FileManager.default.fileExists(atPath: safari) {
            let out = shell("/usr/bin/plutil -convert json -o - \"\(safari)\" 2>/dev/null")
            if let data = out.data(using: .utf8), !out.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: data),
               let dict = json as? [String: Any],
               let items = dict["DownloadHistory"] as? [[String: Any]] {
                browserReadable = true
                for item in items {
                    if let state = item["DownloadEntryState"] as? Int, state == 0 { active = true }
                    if let soFar = item["DownloadEntryProgressBytesSoFar"] as? Int,
                       let total = item["DownloadEntryProgressTotalToLoad"] as? Int,
                       total > 0, soFar < total { active = true }
                }
            }
        }

        let command = """
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
        if shell(command).contains("ACTIVE") {
            active = true
            browserReadable = true
        }

        let snapshot = downloadSnapshot()
        let partials = [".download", ".crdownload", ".part", ".tmp"]
        for (name, size) in snapshot {
            if partials.contains(where: { name.lowercased().hasSuffix($0) }) { active = true }
            if let old = downloadBaseline[name], size > old { active = true }
        }
        downloadBaseline = snapshot

        return (active, browserReadable
            ? "Browser events + folder"
            : "Folder only (Full Disk Access for browser events)")
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
        if let raw = d.string(forKey: "sessionMode"), let mode = SessionMode(rawValue: raw) { sessionMode = mode }
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

    // MARK: - Descriptions

    func sessionDescription() -> String {
        switch sessionMode {
        case .indefinite: return "Runs until you end it"
        case .minutes, .hours, .until:
            guard let end = sessionEndDate else { return "Timed" }
            let seconds = Int(end.timeIntervalSinceNow)
            if seconds <= 0 { return "Ending now" }
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return "Ends in \(h > 0 ? "\(h)h \(m)m" : "\(m)m")"
        case .app: return "Ends when \(sessionAppName ?? "the app") quits"
        case .download: return "Ends 30s after downloads stop"
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
        let style = MenuBarStyle(rawValue: prefs.menuBarStyle) ?? .countdown
        switch state {
        case .off: return style == .icon ? "○" : "○ OFF"
        case .lidPaused: return "⏸"
        case .active:
            if style == .dot { return "● ON" }
            if style == .icon { return "⏱" }
            if [.minutes, .hours, .until].contains(sessionMode), let end = sessionEndDate {
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
        if date <= Date() { date = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date }
        return date
    }

    // MARK: - Actions

    @objc func toggleAction() {
        if state == .off {
            if prefs.defaultSession == "lastUsed" {
                restoreLastSession()
            } else {
                startSession(.indefinite, event: "Indefinite session started")
            }
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
        rebuildPopover() // only on explicit Refresh click
    }

    @objc func startIndefinite() { startSession(.indefinite, event: "Indefinite session started") }
    @objc func startDownloadSession() { startSession(.download, event: "Download session started") }

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

    @objc func settingToggle(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender.tag {
        case 1: prefs.keepDisplay = on
        case 2: prefs.keepSystem = on
        case 3: prefs.keepDisk = on
        case 4: sleepLogExpanded = on
        case 5: debugExpanded = on
        default: return
        }
        if sender.tag <= 3 {
            reconfigureAssertions()
        } else if sender.tag == 4 {
            sleepLogContainer?.isHidden = !on
        } else if sender.tag == 5 {
            debugLogContainer?.isHidden = !on
        }
    }

    @objc func settingChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem else { return }
        switch sender.tag {
        case 10: prefs.defaultSession = item.tag == 0 ? "indefinite" : "lastUsed"
        case 11: prefs.menuBarStyle = ["countdown", "dot", "icon"][min(max(item.tag, 0), 2)]
        default: return
        }
        savePreferences()
        logEvent("Settings updated")
        updateUI()
    }

    @objc func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.prefs.downloadFolder = url.path
            self?.savePreferences()
            self?.resetDownloadBaseline()
            self?.logEvent("Download folder: \(url.lastPathComponent)")
            self?.updateUI()
        }
    }

    func agentIsLoaded() -> Bool {
        !shell("/bin/launchctl print gui/\(getuid())/com.user.keepawakeapp 2>&1 | head -1").isEmpty
    }

    @objc func toggleLogin() {
        if loginEnabled {
            // Removing the plist prevents the next login from launching the agent.
            // Do not bootout here: that would kill this running process.
            try? FileManager.default.removeItem(atPath: loginAgentPath)
            logEvent("Login auto-launch disabled")
        } else {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>com.user.keepawakeapp</string>
            <key>ProgramArguments</key><array><string>\(Bundle.main.executablePath ?? "")</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
            <key>ProcessType</key><string>Interactive</string>
            </dict></plist>
            """
            try? plist.write(toFile: loginAgentPath, atomically: true, encoding: .utf8)
            if !agentIsLoaded() {
                _ = shell("/bin/launchctl bootstrap gui/\(getuid()) '\(loginAgentPath)' 2>&1")
            }
            logEvent("Login auto-launch enabled")
        }
        updateUI()
    }

    @objc func copyDiagnostics() {
        var lines = [
            "Switch Everywhere Diagnostics",
            "Version: 2.0.0",
            "State: \(state.rawValue)",
            "Session: \(sessionMode.rawValue) — \(sessionDescription())",
            "Last event: \(lastEvent)",
            "Assertions: \(assertionIDs.count)/\(Self.allAssertionTypes.count)",
            "Enabled groups: display=\(prefs.keepDisplay) system=\(prefs.keepSystem) disk=\(prefs.keepDisk)",
            "Power: \(powerSource), Battery: \(batteryLine), Lid: \(lidIsClosed ? "closed" : "open")",
            "Download folder: \(prefs.downloadFolder)",
            "Download source: \(downloadSource)",
            "Login at startup: \(loginEnabled ? "on" : "off")",
            "",
            "Event log (last 30):"
        ]
        lines += Array(eventLog.suffix(30))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        logEvent("Diagnostics copied to clipboard")
    }

    // MARK: - UI

    func stateColor() -> NSColor {
        switch state {
        case .off: return .secondaryLabelColor
        case .active: return .systemGreen
        case .lidPaused: return .systemOrange
        }
    }

    func updateButton() {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(string: menuBarTitle(), attributes: [
            .foregroundColor: stateColor(),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        ])
        updateLabels()
    }

    /// Updates the visible popover labels in place. Never replaces the content
    /// view controller — that is what caused the popup to flash on every click.
    func updateLabels() {
        headerLabel?.stringValue = "Switch Everywhere — \(state.rawValue)"
        headerLabel?.textColor = stateColor()
        powerSwitch?.isOn = state != .off
        sessionLabel?.stringValue = state == .off ? "" : "Session: \(sessionDescription())"
        lastEventLabel?.stringValue = "Last event: \(lastEvent)"
        assertionsLabel?.stringValue = "Assertions: \(assertionIDs.count)/\(Self.allAssertionTypes.count)"
    }

    func updateUI() {
        updateButton()
    }

    @objc func togglePopover(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggle = NSMenuItem(title: state == .off ? "Start Session" : "End Session",
                                    action: #selector(toggleAction), keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
            refresh.target = self
            menu.addItem(refresh)
            menu.addItem(NSMenuItem.separator())
            let diagnostics = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnostics), keyEquivalent: "d")
            diagnostics.target = self
            menu.addItem(diagnostics)
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

    /// Fixed size keeps the popover anchored — never re-fit from fittingSize.
    private let popoverSize = NSSize(width: 280, height: 460)

    func showPopover() {
        guard let popover else { return }
        let vc = makePopoverContent()
        vc.preferredContentSize = popoverSize
        popover.contentViewController = vc
        popover.contentSize = popoverSize
        if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func rebuildPopover() {
        guard let popover, popover.isShown else { return }
        let vc = makePopoverContent()
        vc.preferredContentSize = popoverSize
        popover.contentViewController = vc
        // Do not touch popover.contentSize here: fixed size prevents jumping.
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

    func popup(_ items: [(String, Int)], tag: Int, width: CGFloat, action: Selector) -> NSPopUpButton {
        let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 22), pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.tag = tag
        button.target = self
        button.action = action
        for (title, itemTag) in items {
            button.addItem(withTitle: title)
            button.lastItem?.tag = itemTag
        }
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    func checkbox(_ title: String, on: Bool, tag: Int) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingToggle(_:)))
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.state = on ? .on : .off
        button.tag = tag
        return button
    }

    func makePopoverContent() -> NSViewController {
        let vc = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 460))

        let scroll = NSScrollView(frame: view.bounds)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -18)
        ])

        // Builders -----------------------------------------------------------
        @discardableResult
        func label(_ text: String,
                   in target: NSStackView,
                   font: NSFont = .systemFont(ofSize: 11),
                   color: NSColor = .labelColor,
                   wrap: Bool = false) -> NSTextField {
            let field: NSTextField
            if wrap {
                field = NSTextField(wrappingLabelWithString: text)
                field.lineBreakMode = .byWordWrapping
                field.maximumNumberOfLines = 0
                field.preferredMaxLayoutWidth = 228
                field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            } else {
                field = NSTextField(labelWithString: text)
                field.lineBreakMode = .byTruncatingTail
                field.maximumNumberOfLines = 1
            }
            field.font = font
            field.textColor = color
            target.addArrangedSubview(field)
            return field
        }
        func rule(in target: NSStackView) {
            let box = NSBox()
            box.boxType = .separator
            target.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: target.widthAnchor, constant: -24).isActive = true
        }
        func sectionTitle(_ text: String, in target: NSStackView) {
            label(text, in: target, font: .systemFont(ofSize: 10, weight: .semibold), color: .secondaryLabelColor)
        }

        // Header -------------------------------------------------------------
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: 252).isActive = true

        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = stateColor().cgColor
        dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 9).isActive = true
        header.addArrangedSubview(dot)

        let title = NSTextField(labelWithString: "Switch Everywhere — \(state.rawValue)")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = stateColor()
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)
        headerLabel = title

        let pill = PillToggle(frame: NSRect(x: 0, y: 0, width: 42, height: 22))
        pill.isOn = state != .off
        pill.onToggle = { [weak self] in self?.toggleAction() }
        pill.widthAnchor.constraint(equalToConstant: 42).isActive = true
        pill.heightAnchor.constraint(equalToConstant: 22).isActive = true
        header.addArrangedSubview(pill)
        powerSwitch = pill
        stack.addArrangedSubview(header)

        sessionLabel = label(state == .off ? "No active session" : sessionDescription(), in: stack)
        lastEventLabel = label("Last event: \(lastEvent)", in: stack, color: .secondaryLabelColor)
        assertionsLabel = label("Assertions: \(assertionIDs.count)/\(Self.allAssertionTypes.count)",
                                in: stack, color: .secondaryLabelColor)
        rule(in: stack)

        // Start session ------------------------------------------------------
        sectionTitle("START NEW SESSION", in: stack)
        let indefinite = NSButton(title: "Indefinitely", target: self, action: #selector(startIndefinite))
        indefinite.bezelStyle = .rounded
        indefinite.controlSize = .small
        stack.addArrangedSubview(row(label: "", control: indefinite))
        stack.addArrangedSubview(row(label: "Minutes", control: popup([
            ("5 min", 5), ("10 min", 10), ("15 min", 15), ("30 min", 30), ("45 min", 45), ("60 min", 60)
        ], tag: 1, width: 100, action: #selector(sessionPreset(_:)))))
        stack.addArrangedSubview(row(label: "Hours", control: popup([
            ("1 hr", 1), ("2 hr", 2), ("3 hr", 3), ("4 hr", 4), ("6 hr", 6), ("8 hr", 8), ("12 hr", 12)
        ], tag: 2, width: 100, action: #selector(sessionPreset(_:)))))
        stack.addArrangedSubview(row(label: "Other/Until", control: popup([
            ("5:00 PM", 1), ("11:00 PM", 2), ("Midnight", 3), ("In 30 min", 4), ("In 2 hours", 5)
        ], tag: 3, width: 100, action: #selector(sessionPreset(_:)))))

        appChoices = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName,
                  let bundle = app.bundleIdentifier,
                  bundle != "com.user.keepawakeapp" else { return nil }
            return (name, bundle)
        }.sorted { $0.name < $1.name }
        let appItems: [(String, Int)] = appChoices.isEmpty
            ? [("No apps", -1)]
            : appChoices.prefix(20).enumerated().map { ($0.element.name, $0.offset) }
        stack.addArrangedSubview(row(label: "While app runs", control: popup(appItems, tag: 4, width: 100,
                                                                            action: #selector(sessionPreset(_:)))))
        let download = NSButton(title: "Start", target: self, action: #selector(startDownloadSession))
        download.bezelStyle = .rounded
        download.controlSize = .small
        stack.addArrangedSubview(row(label: "While downloading", control: download))
        rule(in: stack)

        // Settings -----------------------------------------------------------
        sectionTitle("SETTINGS", in: stack)
        let displayCheck = checkbox("Keep display awake", on: prefs.keepDisplay, tag: 1)
        displayCheck.toolTip = "Off lets the screen sleep while the Mac stays awake."
        let systemCheck = checkbox("Keep system awake", on: prefs.keepSystem, tag: 2)
        systemCheck.toolTip = "Blocks idle system sleep. PreventSystemSleep applies on AC power only."
        stack.addArrangedSubview(displayCheck)
        stack.addArrangedSubview(systemCheck)
        stack.addArrangedSubview(checkbox("Keep disks awake", on: prefs.keepDisk, tag: 3))
        let folderButton = NSButton(title: (prefs.downloadFolder as NSString).lastPathComponent + "…",
                                    target: self, action: #selector(chooseDownloadFolder))
        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small
        stack.addArrangedSubview(row(label: "Download folder", control: folderButton))
        stack.addArrangedSubview(row(label: "Default session", control: popup([
            ("Indefinite", 0), ("Last used", 1)
        ], tag: 10, width: 100, action: #selector(settingChanged(_:)))))
        stack.addArrangedSubview(row(label: "Menu bar", control: popup([
            ("Countdown", 0), ("Dot ● ON", 1), ("Icon ⏱", 2)
        ], tag: 11, width: 100, action: #selector(settingChanged(_:)))))
        let loginButton = NSButton(title: loginEnabled ? "On — click to disable" : "Off — click to enable",
                                   target: self, action: #selector(toggleLogin))
        loginButton.bezelStyle = .rounded
        loginButton.controlSize = .small
        stack.addArrangedSubview(row(label: "Login at startup", control: loginButton))
        rule(in: stack)

        // Live info ----------------------------------------------------------
        sectionTitle("LIVE INFO", in: stack)
        label("Power: \(powerSource)", in: stack)
        label("Battery: \(batteryLine)", in: stack)
        label("Lid: \(lidIsClosed ? "Closed" : "Open")", in: stack)
        label("Uptime: \(uptimeLine)", in: stack)
        label("Session age: \(sessionUptimeString())", in: stack)
        if [.minutes, .hours, .until].contains(sessionMode), sessionEndDate != nil {
            label("Ends at: \(sessionEndTimeString())", in: stack)
        }
        label("Download source: \(downloadSource)", in: stack, color: .secondaryLabelColor, wrap: true)
        rule(in: stack)

        // Sleep/Wake log — one container, collapses fully ---------------------
        let sleepBox = NSStackView()
        sleepBox.orientation = .vertical
        sleepBox.alignment = .left
        sleepBox.spacing = 4
        sleepBox.addArrangedSubview(checkbox("Sleep/Wake Log (\(sleepEvents.count))", on: sleepLogExpanded, tag: 4))
        if sleepEvents.isEmpty {
            label("  No recent events", in: sleepBox, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        } else {
            for event in sleepEvents {
                let eventRow = NSStackView()
                eventRow.orientation = .vertical
                eventRow.alignment = .left
                eventRow.spacing = 1
                label("\(event.time)  \(event.symbol)", in: eventRow,
                      font: .monospacedSystemFont(ofSize: 9, weight: .regular), color: .secondaryLabelColor)
                label(event.reason, in: eventRow, font: .systemFont(ofSize: 10), color: .labelColor, wrap: true)
                sleepBox.addArrangedSubview(eventRow)
            }
        }
        sleepBox.isHidden = !sleepLogExpanded
        sleepLogContainer = sleepBox
        stack.addArrangedSubview(sleepBox)

        // Debug log — one container, collapses fully -------------------------
        let debugBox = NSStackView()
        debugBox.orientation = .vertical
        debugBox.alignment = .left
        debugBox.spacing = 4
        debugBox.addArrangedSubview(checkbox("Debug Log", on: debugExpanded, tag: 5))
        for entry in eventLog.suffix(5) {
            label("  \(entry)", in: debugBox, font: .monospacedSystemFont(ofSize: 9, weight: .regular),
                  color: .secondaryLabelColor, wrap: true)
        }
        let copyButton = NSButton(title: "Copy Diagnostics", target: self, action: #selector(copyDiagnostics))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        debugBox.addArrangedSubview(copyButton)
        debugBox.isHidden = !debugExpanded
        debugLogContainer = debugBox
        stack.addArrangedSubview(debugBox)
        rule(in: stack)

        // Footer -------------------------------------------------------------
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY
        let toggle = NSButton(title: state == .off ? "Start Session" : "End Session",
                              target: self, action: #selector(toggleAction))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshAction))
        let quit = NSButton(title: "Quit", target: self, action: #selector(quitAction))
        for button in [toggle, refresh, quit] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            buttons.addArrangedSubview(button)
        }
        stack.addArrangedSubview(buttons)

        vc.view = view
        return vc
    }

    // MARK: - Stats

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
        if ps.contains("AC Power") { powerSource = "AC Power" }
        else if ps.contains("Battery Power") { powerSource = "Battery Power" }
        else { powerSource = "Unknown" }
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
            if let end = value.range(of: " user") { value = String(value[..<end.lowerBound]) }
            else if let end = value.range(of: " load") { value = String(value[..<end.lowerBound]) }
            uptimeLine = value.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }

        // Sleep/wake history from the power management ASL logs (today + yesterday).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let today = formatter.string(from: Date())
        let yesterday = formatter.string(from: Date().addingTimeInterval(-86400))
        let filter = "grep -iE 'Entering Sleep|Wake from|DarkWake'"
        let command = "syslog -f /var/log/powermanagement/\(yesterday).asl 2>/dev/null | \(filter); syslog -f /var/log/powermanagement/\(today).asl 2>/dev/null | \(filter)"
        let found = shell(command).components(separatedBy: "\n").compactMap { parseSleepEvent($0) }
        sleepEvents = Array(found.suffix(5))
    }

    func parseSleepEvent(_ line: String) -> SleepEvent? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return nil }
        let time = "\(parts[0]) \(parts[1]) \(parts[2])"

        let symbol: String
        var reason: String
        if text.contains("Entering Sleep") {
            symbol = "↓"
            reason = "Sleep"
            if let start = text.range(of: "due to '") {
                let rest = text[start.upperBound...]
                if let end = rest.range(of: "'") { reason = String(rest[..<end.lowerBound]) }
            }
        } else if text.contains("DarkWake") {
            symbol = "↕"
            reason = "Dark wake"
            if let start = text.range(of: "due to ") { reason = String(text[start.upperBound...]) }
        } else if text.contains("Wake from") {
            symbol = "↑"
            reason = "Wake"
            if let start = text.range(of: "due to ") { reason = String(text[start.upperBound...]) }
        } else {
            return nil
        }
        if let end = reason.range(of: " Using") { reason = String(reason[..<end.lowerBound]) }
        return SleepEvent(time: time, symbol: symbol, reason: reason)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
