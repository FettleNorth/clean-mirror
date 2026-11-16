import AppKit
import MirrorKit
import ServiceManagement

/// Clean Mirror's menu bar icon and menu. Turning the mirror on creates the Clean Mirror screen and
/// sends it to the UltraStudio; turning it off removes the screen and releases the box.
final class AppController: NSObject, NSApplicationDelegate {
    enum State {
        case off, starting, on, stopping
        case failed(String)
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Mirror is off", action: nil, keyEquivalent: "")
    private let detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var toggleItem: NSMenuItem!
    private var standardItem: NSMenuItem!
    private var retinaItem: NSMenuItem!
    private var fpsItems: [Int: NSMenuItem] = [:]
    private var lowDelayItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private var session: MirrorSession?
    private var state: State = .off { didSet { refresh() } }
    private var timer: Timer?
    private var lastSample = Date()
    private var screenFPS = 0.0
    private var restartAfterStop = false

    // MARK: Settings (remembered between launches)

    private let defaults = UserDefaults.standard
    private var fps: Int {
        get { let v = defaults.integer(forKey: "fps"); return [25, 30, 50, 60].contains(v) ? v : 60 }
        set { defaults.set(newValue, forKey: "fps") }
    }
    private var hidpi: Bool {
        get { defaults.bool(forKey: "hidpi") }
        set { defaults.set(newValue, forKey: "hidpi") }
    }
    private var lowDelay: Bool {
        get { defaults.object(forKey: "lowDelay") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lowDelay") }
    }
    /// Whether the mirror should be on: set when you turn it on, cleared when you turn it off,
    /// so it comes back the way you left it next time the app opens.
    private var wantOn: Bool {
        get { defaults.bool(forKey: "wantOn") }
        set { defaults.set(newValue, forKey: "wantOn") }
    }
    private var queuedFrames: Int { lowDelay ? 2 : 4 }

    // MARK: Launch and quit

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        refresh()
        if wantOn { startMirror() }
        // The very first time, show the menu where the pointer is, so it's obvious the app is running
        // even if the menu bar is too full to show the icon.
        if !defaults.bool(forKey: "launchedBefore") {
            defaults.set(true, forKey: "launchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showMenuAtPointer() }
        }
    }

    /// Opening the app again (double-click, or `open` in Terminal) shows its menu where the pointer is.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtPointer()
        return false
    }

    private func showMenuAtPointer() {
        NSApp.activate()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        session?.stopNow()
        session = nil
        return .terminateNow
    }

    // MARK: Menu

    private func buildMenu() {
        statusLine.isEnabled = false
        detailLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(detailLine)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Turn Mirror On", action: #selector(toggleMirror), keyEquivalent: "m")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Clean Mirror Screen"))
        standardItem = NSMenuItem(title: "Standard (sharpest text)", action: #selector(chooseStandard), keyEquivalent: "")
        standardItem.target = self
        retinaItem = NSMenuItem(title: "Retina (smoother text)", action: #selector(chooseRetina), keyEquivalent: "")
        retinaItem.target = self
        menu.addItem(standardItem)
        menu.addItem(retinaItem)

        let fpsMenu = NSMenu()
        for rate in [60, 50, 30, 25] {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(chooseFPS(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rate
            fpsItems[rate] = item
            fpsMenu.addItem(item)
        }
        let fpsItem = NSMenuItem(title: "Frame Rate", action: nil, keyEquivalent: "")
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)

        lowDelayItem = NSMenuItem(title: "Lowest Delay", action: #selector(toggleLowDelay), keyEquivalent: "")
        lowDelayItem.target = self
        menu.addItem(lowDelayItem)
        menu.addItem(.separator())

        permissionItem = NSMenuItem(title: "Open Screen Recording Settings…", action: #selector(openPermissionSettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Clean Mirror", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func refresh() {
        let delayMs = Int((Double(queuedFrames) * 1000 / Double(fps)).rounded())
        switch state {
        case .off:
            statusLine.title = "Mirror is off"
            detailLine.title = "The box is free for other apps"
            toggleItem.title = "Turn Mirror On"
        case .starting:
            statusLine.title = "Starting…"
            detailLine.title = ""
            toggleItem.title = "Turn Mirror Off"
        case .stopping:
            statusLine.title = "Stopping…"
            detailLine.title = ""
            toggleItem.title = "Turn Mirror On"
        case .on:
            let name = session?.deviceName ?? "UltraStudio"
            statusLine.title = "On: \(name)"
            let s = session?.boxStats() ?? BoxStats()
            detailLine.title = String(format: "1080p%d · screen %.0f fps · late %llu · dropped %llu · %d ms",
                                      fps, screenFPS, s.late, s.dropped, delayMs)
            toggleItem.title = "Turn Mirror Off"
        case .failed(let message):
            statusLine.title = "Not running"
            detailLine.title = message
            toggleItem.title = "Turn Mirror On"
        }
        detailLine.isHidden = detailLine.title.isEmpty

        standardItem.state = hidpi ? .off : .on
        retinaItem.state = hidpi ? .on : .off
        for (rate, item) in fpsItems { item.state = rate == fps ? .on : .off }
        lowDelayItem.state = lowDelay ? .on : .off
        lowDelayItem.title = lowDelay ? "Lowest Delay (\(delayMs) ms)" : "Lowest Delay"
        permissionItem.isHidden = screenRecordingAllowed()
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if let button = statusItem.button {
            // Outline TV when off, filled when on: full contrast either way, so it reads on e-ink.
            let symbol: String
            switch state {
            case .on: symbol = "tv.fill"
            case .failed: symbol = "display.trianglebadge.exclamationmark"
            default: symbol = "tv"
            }
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Clean Mirror")
            button.image?.isTemplate = true
            button.appearsDisabled = false
        }
    }

    // MARK: Turning the mirror on and off

    @objc private func toggleMirror() {
        switch state {
        case .on, .starting:
            wantOn = false
            stopMirror()
        case .off, .failed:
            wantOn = true
            startMirror()
        case .stopping:
            break
        }
    }

    private func startMirror() {
        if case .starting = state { return }
        guard screenRecordingAllowed() else {
            requestScreenRecording()
            state = .failed("Allow Clean Mirror in Screen Recording settings, then quit and reopen it")
            return
        }
        state = .starting
        let config = MirrorConfig(fps: fps, hidpi: hidpi, queuedFrames: queuedFrames, useMainDisplay: false)
        let newSession = MirrorSession(config: config)
        newSession.onCaptureStopped = { [weak self] error in
            DispatchQueue.main.async { self?.captureStopped(error) }
        }
        Task.detached { [weak self] in
            do {
                try await newSession.start()
                await MainActor.run { self?.didStart(newSession) }
            } catch {
                await MainActor.run { self?.didFail(error) }
            }
        }
    }

    private func didStart(_ newSession: MirrorSession) {
        guard case .starting = state else {
            // Turned off while it was starting.
            Task.detached { await newSession.stop() }
            return
        }
        session = newSession
        screenFPS = 0
        lastSample = Date()
        _ = newSession.sample()
        state = .on
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps updating while the menu is open
        timer = t
    }

    private func didFail(_ error: Error) {
        guard case .starting = state else { return }   // turned off while it was starting
        let message: String
        if let e = error as? MirrorError, e.isBoxBusy {
            message = "The box is in use by another app (Final Cut's A/V Output, or cleanmirror in Terminal?)"
        } else {
            message = error.localizedDescription
        }
        state = .failed(message)
    }

    private func stopMirror() {
        timer?.invalidate()
        timer = nil
        guard let running = session else {
            if case .starting = state { state = .off }   // didStart will clean up
            return
        }
        session = nil
        state = .stopping
        Task.detached { [weak self] in
            await running.stop()
            await MainActor.run {
                guard let self else { return }
                self.state = .off
                if self.restartAfterStop {
                    self.restartAfterStop = false
                    self.startMirror()
                }
            }
        }
    }

    private func captureStopped(_ error: Error) {
        guard let running = session else { return }
        timer?.invalidate()
        timer = nil
        session = nil
        running.stopNow()
        state = .failed("Screen capture stopped: \(error.localizedDescription)")
    }

    private func tick() {
        guard let s = session else { return }
        let now = Date()
        let sample = s.sample()
        screenFPS = Double(sample.newScreenFrames) / now.timeIntervalSince(lastSample)
        lastSample = now
        refresh()
    }

    /// Applies a changed setting: restarts the mirror if it's running.
    private func settingChanged() {
        if case .on = state {
            restartAfterStop = true
            stopMirror()
        } else {
            refresh()
        }
    }

    // MARK: Settings actions

    @objc private func chooseStandard() { guard hidpi else { return }; hidpi = false; settingChanged() }
    @objc private func chooseRetina() { guard !hidpi else { return }; hidpi = true; settingChanged() }

    @objc private func chooseFPS(_ sender: NSMenuItem) {
        guard sender.tag != fps else { return }
        fps = sender.tag
        settingChanged()
    }

    @objc private func toggleLowDelay() {
        lowDelay.toggle()
        settingChanged()
    }

    @objc private func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
