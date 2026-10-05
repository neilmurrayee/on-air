import AppKit

/// A borderless, click-through panel that floats above everything, including the
/// Dock and full-screen apps, and is captured by screen sharing and screenshots
/// like any ordinary window.
final class BannerWindow: NSPanel {

    let marquee = MarqueeView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        // The bar is solid red edge to edge. Saying so lets WindowServer skip
        // blending it with whatever is underneath.
        isOpaque = true
        backgroundColor = MarqueeView.barColor
        hasShadow = false
        ignoresMouseEvents = true          // clicks pass straight through to whatever is beneath
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none

        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        applyLevel()

        // .readOnly is the default, but be explicit: this window MUST be picked up by
        // screen sharing and recording — that is the whole point of the app.
        sharingType = .readOnly

        contentView = marquee
    }

    /// Two levels to choose between:
    ///
    ///  - behind the Dock: one below `kCGDockWindowLevel`, so the Dock draws on top and
    ///    the marquee scrolls out of sight behind it, while still floating above every
    ///    ordinary app window.
    ///  - in front: `.screenSaver`, above the Dock, the menu bar and full-screen apps.
    func applyLevel() {
        if Prefs.behindDock {
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
        } else {
            level = .screenSaver
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One edge of the red frame around a screen: a thin, solid, click-through strip.
///
/// The frame is four opaque strips rather than one transparent screen-sized window
/// with a red outline, because WindowServer would have to blend a screen-sized
/// window into every frame of whatever moves beneath it, video calls included.
/// Strips that never change cost nothing once drawn.
final class BorderWindow: NSPanel {

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isOpaque = true
        backgroundColor = MarqueeView.barColor
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Above the menu bar and full-screen apps, so the frame is never broken.
        level = .screenSaver
        sharingType = .readOnly
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns one banner window per screen, plus the red frame around each screen, and
/// keeps their text, size and position current.
final class BannerController {

    private var windows: [BannerWindow] = []
    private var borders: [BorderWindow] = []
    private(set) var isShowing = false

    /// Text currently displayed, so we can skip redundant updates.
    private var currentText = ""

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func screensChanged() {
        guard isShowing else { return }
        rebuildWindows()
    }

    // MARK: - Showing and hiding

    func show(text: String) {
        currentText = text
        isShowing = true
        rebuildWindows()
    }

    func update(text: String) {
        guard isShowing, text != currentText else { return }
        currentText = text
        windows.forEach { $0.marquee.text = text }
    }

    func hide() {
        isShowing = false
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        borders.forEach { $0.orderOut(nil) }
        borders.removeAll()
    }

    /// Cheap tick: reposition only if the target geometry actually moved, so a
    /// resized Dock or a Dock that changed edge is picked up without rebuilding the
    /// marquee (and restarting its scroll) every second.
    func refreshGeometry() {
        guard isShowing else { return }
        rememberDockHeight()

        let screens = targetScreens
        guard screens.count == windows.count else { return rebuildWindows() }
        let moved = zip(windows, screens).contains { $0.frame != frame(for: $1) }
        if moved { rebuildWindows() }
    }

    /// Persist the Dock height currently visible, so an auto-hidden or side-mounted
    /// Dock still gets a sensible match later.
    ///
    /// Deliberately separate from `frame(for:)`: that runs on every tick and for every
    /// screen, and a function that computes a rectangle has no business writing to
    /// `UserDefaults` each time it is asked.
    private func rememberDockHeight() {
        guard Prefs.matchDockHeight else { return }
        for screen in targetScreens {
            let claimed = screen.visibleFrame.minY - screen.frame.minY
            if claimed > 20, abs(claimed - Prefs.lastDockHeight) > 0.5 {
                Prefs.lastDockHeight = claimed
                return
            }
        }
    }

    /// Re-read the preferences that affect appearance and apply them live.
    func applyPreferences() {
        guard isShowing else { return }
        rebuildWindows()
        windows.forEach { $0.marquee.restart() }
    }

    // MARK: - Geometry

    private var targetScreens: [NSScreen] {
        if Prefs.allScreens { return NSScreen.screens }
        return [NSScreen.main ?? NSScreen.screens.first].compactMap { $0 }
    }

    private func rebuildWindows() {
        rememberDockHeight()
        let screens = targetScreens

        // Grow or shrink the pool to one window per screen.
        while windows.count < screens.count { windows.append(BannerWindow()) }
        while windows.count > screens.count { windows.removeLast().orderOut(nil) }

        for (window, screen) in zip(windows, screens) {
            window.applyLevel()
            window.setFrame(frame(for: screen), display: true)
            window.marquee.text = currentText
            window.marquee.needsLayout = true
            window.orderFrontRegardless()
        }

        // The frame changes only with the screens or the preference, so simply
        // replace it rather than reconcile it.
        borders.forEach { $0.orderOut(nil) }
        borders = Prefs.showBorder
            ? screens.flatMap { Self.borderFrames(full: $0.frame, width: Prefs.borderWidth) }.map(BorderWindow.init)
            : []
        borders.forEach { $0.orderFrontRegardless() }
    }

    /// Four strips just inside the edges of a screen: top and bottom full width,
    /// left and right filling the gap between them so the corners do not overlap.
    static func borderFrames(full: NSRect, width: CGFloat) -> [NSRect] {
        [
            NSRect(x: full.minX, y: full.maxY - width, width: full.width, height: width),
            NSRect(x: full.minX, y: full.minY, width: full.width, height: width),
            NSRect(x: full.minX, y: full.minY + width, width: width, height: full.height - 2 * width),
            NSRect(x: full.maxX - width, y: full.minY + width, width: width, height: full.height - 2 * width),
        ]
    }

    private func frame(for screen: NSScreen) -> NSRect {
        Self.frame(full: screen.frame, visible: screen.visibleFrame)
    }

    /// The strip along the bottom of a screen that the banner should occupy, given
    /// the screen's full frame and the part of it not claimed by the Dock or menu bar.
    static func frame(full: NSRect, visible: NSRect) -> NSRect {
        // How much space something (almost always the Dock) is claiming at the bottom.
        // An auto-hidden Dock still reserves a few points, hence the threshold.
        let claimedAtBottom = visible.minY - full.minY
        let dockIsShowing = claimedAtBottom > 20

        // Matching the Dock means matching the space it reserves, which is exactly
        // what `visibleFrame` tells us — and it tracks the user resizing the Dock for
        // free. When the Dock is hidden or on a side edge there is nothing to measure,
        // so fall back to the last height we saw (see `rememberDockHeight`).
        let height: CGFloat
        if Prefs.matchDockHeight {
            height = dockIsShowing ? claimedAtBottom : Prefs.lastDockHeight
        } else {
            height = Prefs.height
        }

        let y: CGFloat
        switch Prefs.position {
        case .bottomEdge:
            y = full.minY
        case .aboveDock:
            y = visible.minY
        case .auto:
            y = dockIsShowing ? visible.minY : full.minY
        }

        return NSRect(x: full.minX, y: y, width: full.width, height: height)
    }
}
