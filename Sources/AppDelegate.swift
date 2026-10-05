import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let monitor = MediaMonitor()
    private let banner = BannerController()
    private var statusItem: NSStatusItem!

    /// Preview mode pins the banner on regardless of what the hardware is doing.
    private var previewing = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        setUpStatusItem()

        monitor.onChange = { [weak self] in self?.updateBanner() }
        monitor.onPoll = { [weak self] in
            self?.banner.refreshGeometry()
            self?.debugLog()
        }
        monitor.start()
        updateBanner()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        banner.hide()
    }

    // MARK: - Banner

    /// Apps start and stop the input stream constantly during a call — muting in Zoom
    /// or Teams genuinely releases the mic — so let the bar linger briefly before it
    /// comes down. Going on air is instant; coming off air waits.
    private static let hideDelay: TimeInterval = 2.0
    private var pendingHide: DispatchWorkItem?

    private func updateBanner() {
        let live = previewing || monitor.isLive

        if live {
            pendingHide?.cancel()
            pendingHide = nil
            let text = bannerText()
            if banner.isShowing { banner.update(text: text) } else { banner.show(text: text) }
        } else if banner.isShowing, pendingHide == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingHide = nil
                guard !(self.previewing || self.monitor.isLive) else { return }
                self.banner.hide()
                self.updateStatusIcon(live: false)
            }
            pendingHide = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
        }

        updateStatusIcon(live: live)
    }

    /// "LIVE ON AIR ● Camera & mic on ● Zoom"
    private func bannerText() -> String {
        var parts = [Prefs.text]

        if previewing && !monitor.isLive {
            parts.append("Preview")
        } else {
            switch (monitor.cameraIsLive, monitor.micIsLive) {
            case (true, true): parts.append("Camera & mic on")
            case (true, false): parts.append("Camera on")
            case (false, true): parts.append("Mic on")
            case (false, false): break
            }
            let apps = monitor.liveAppNames
            if !apps.isEmpty { parts.append(apps.joined(separator: " + ")) }
        }

        return parts.joined(separator: "   \u{25CF}   ")
    }

    private static let debugging = ProcessInfo.processInfo.environment["ONAIR_DEBUG"] == "1"

    /// Run with ONAIR_DEBUG=1 to trace what the detector sees, once a second.
    /// `read=` is how long the hardware read took, off the main thread.
    private func debugLog() {
        guard Self.debugging else { return }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        let fields = "watchCam=\(Prefs.watchCamera) watchMic=\(Prefs.watchMic)"
            + " cam=\(monitor.cameraIsLive) mic=\(monitor.micIsLive) live=\(monitor.isLive)"
            + " showing=\(banner.isShowing) apps=\(monitor.liveAppNames)"
            + String(format: " read=%.1fms", monitor.lastReadDuration * 1000)
        print("[\(stamp)] \(fields)")
        fflush(stdout)
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon(live: false)
    }

    private func updateStatusIcon(live: Bool) {
        guard let button = statusItem.button else { return }

        let symbol = live ? "record.circle.fill" : "record.circle"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: live ? "On air" : "Off air")?
            .withSymbolConfiguration(config)

        if live {
            // Tint red so a glance at the menu bar is enough.
            image?.isTemplate = false
            button.image = image?.tinted(with: .systemRed)
        } else {
            image?.isTemplate = true
            button.image = image
        }

        button.toolTip = live ? "On Air — camera or microphone is live" : "On Air — idle"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Built from the last reading, at most a second old. Re-reading here would
        // block the menu on coreaudiod, which is exactly what polling off the main
        // thread is for avoiding.
        menu.removeAllItems()

        // --- Status ---
        let cameras = monitor.activeCameras
        let mics = monitor.activeMicDevices
        let apps = monitor.activeInputApps

        menu.addItem(disabled(cameras.isEmpty
            ? "Camera: idle"
            : "Camera: \(cameras.map(\.name).joined(separator: ", "))"))

        if !apps.isEmpty {
            menu.addItem(disabled("Microphone: \(apps.map(\.name).joined(separator: ", "))"))
        } else if !mics.isEmpty {
            menu.addItem(disabled("Microphone: \(mics.map(\.name).joined(separator: ", "))"))
        } else {
            menu.addItem(disabled("Microphone: idle"))
        }

        menu.addItem(.separator())

        // --- What to watch ---
        menu.addItem(check("Watch camera", #selector(toggleWatchCamera), Prefs.watchCamera))
        menu.addItem(check("Watch microphone", #selector(toggleWatchMic), Prefs.watchMic))

        menu.addItem(.separator())

        // --- Appearance ---
        let positionItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu()
        positionMenu.addItem(check("Automatic", #selector(setPositionAuto), Prefs.position == .auto))
        positionMenu.addItem(check("Bottom edge (over the Dock)", #selector(setPositionBottom), Prefs.position == .bottomEdge))
        positionMenu.addItem(check("Above the Dock", #selector(setPositionAboveDock), Prefs.position == .aboveDock))
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)

        let sizeItem = NSMenuItem(title: "Height", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.addItem(check("Match the Dock", #selector(setHeightMatchDock), Prefs.matchDockHeight))
        sizeMenu.addItem(.separator())
        for (title, value) in [("Slim", 22.0), ("Medium", 28.0), ("Tall", 40.0)] {
            let on = !Prefs.matchDockHeight && abs(Prefs.height - value) < 0.5
            let item = check(title, #selector(setHeight(_:)), on)
            item.representedObject = value
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let speedItem = NSMenuItem(title: "Scroll speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for (title, value) in [("Slow", 40.0), ("Normal", 70.0), ("Fast", 120.0)] {
            let item = check(title, #selector(setSpeed(_:)), abs(Prefs.speed - value) < 0.5)
            item.representedObject = value
            speedMenu.addItem(item)
        }
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        menu.addItem(check("Scroll behind the Dock", #selector(toggleBehindDock), Prefs.behindDock))
        menu.addItem(check("Show on all displays", #selector(toggleAllScreens), Prefs.allScreens))

        menu.addItem(.separator())

        // --- Ignore list, for always-on virtual devices ---
        let ignoreItem = NSMenuItem(title: "Ignore", action: nil, keyEquivalent: "")
        let ignoreMenu = NSMenu()
        let ignored = Prefs.ignoredDeviceUIDs
        var added = false

        for device in monitor.devices.sorted(by: { $0.name < $1.name }) {
            let label = device.inUse ? "\(device.name) — live now" : device.name
            let item = check(label, #selector(toggleIgnored(_:)), ignored.contains(device.uid))
            item.representedObject = device.uid
            ignoreMenu.addItem(item)
            added = true
        }
        for app in monitor.inputApps.sorted(by: { $0.name < $1.name }) {
            let item = check("\(app.name) (app)", #selector(toggleIgnored(_:)), ignored.contains(app.uid))
            item.representedObject = app.uid
            ignoreMenu.addItem(item)
            added = true
        }
        if !added { ignoreMenu.addItem(disabled("No devices found")) }

        ignoreItem.submenu = ignoreMenu
        menu.addItem(ignoreItem)

        menu.addItem(.separator())

        // --- Actions ---
        menu.addItem(check("Preview banner", #selector(togglePreview), previewing))
        menu.addItem(check("Open at login", #selector(toggleLoginItem), isLoginItemEnabled))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit On Air", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func check(_ title: String, _ action: Selector, _ on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    // MARK: - Menu actions

    @objc private func toggleWatchCamera() {
        Prefs.watchCamera.toggle()
        monitor.refresh()
    }

    @objc private func toggleWatchMic() {
        Prefs.watchMic.toggle()
        monitor.refresh()
    }

    @objc private func setPositionAuto() { setPosition(.auto) }
    @objc private func setPositionBottom() { setPosition(.bottomEdge) }
    @objc private func setPositionAboveDock() { setPosition(.aboveDock) }

    private func setPosition(_ position: Prefs.Position) {
        Prefs.position = position
        banner.applyPreferences()
    }

    @objc private func setHeightMatchDock() {
        Prefs.matchDockHeight = true
        banner.applyPreferences()
    }

    @objc private func setHeight(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Prefs.matchDockHeight = false
        Prefs.height = CGFloat(value)
        banner.applyPreferences()
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        Prefs.speed = CGFloat(value)
        banner.applyPreferences()
    }

    @objc private func toggleBehindDock() {
        Prefs.behindDock.toggle()
        banner.applyPreferences()
    }

    @objc private func toggleAllScreens() {
        Prefs.allScreens.toggle()
        banner.applyPreferences()
    }

    @objc private func toggleIgnored(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        Prefs.toggleIgnored(uid)
        monitor.refresh()
    }

    @objc private func togglePreview() {
        previewing.toggle()
        updateBanner()
    }

    // MARK: - Login item

    private var isLoginItemEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if isLoginItemEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = """
                \(error.localizedDescription)

                macOS often refuses this for an app that is not code signed. \
                You can add On Air by hand in System Settings › General › Login Items.
                """
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

private extension NSImage {
    /// Flat-tint a symbol image, preserving its alpha.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
