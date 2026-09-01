import AppKit

/// Everything the user can tweak, persisted in UserDefaults.
/// Anything not exposed in the menu can be set with `defaults write com.local.onair <key> <value>`.
enum Prefs {
    private static let d = UserDefaults.standard

    static func registerDefaults() {
        d.register(defaults: [
            Key.watchCamera: true,
            Key.watchMic: true,
            Key.text: "LIVE ON AIR",
            Key.height: 28.0,
            Key.matchDockHeight: true,
            Key.lastDockHeight: 52.0,
            Key.speed: 70.0,           // points per second
            Key.allScreens: true,
            Key.position: Position.bottomEdge.rawValue,
            Key.behindDock: true,
            Key.ignoredDeviceUIDs: [String](),
        ])
    }

    enum Key {
        static let watchCamera = "watchCamera"
        static let watchMic = "watchMic"
        static let text = "bannerText"
        static let height = "bannerHeight"
        static let speed = "scrollSpeed"
        static let allScreens = "allScreens"
        static let position = "bannerPosition"
        static let matchDockHeight = "matchDockHeight"
        static let lastDockHeight = "lastDockHeight"
        static let behindDock = "behindDock"
        static let ignoredDeviceUIDs = "ignoredDeviceUIDs"
    }

    enum Position: String {
        case auto           // sit above the Dock if it is showing, otherwise on the screen's bottom edge
        case bottomEdge     // always the very bottom edge, drawn over the Dock
        case aboveDock      // always above the Dock / anything else claiming screen space
    }

    static var watchCamera: Bool {
        get { d.bool(forKey: Key.watchCamera) }
        set { d.set(newValue, forKey: Key.watchCamera) }
    }

    static var watchMic: Bool {
        get { d.bool(forKey: Key.watchMic) }
        set { d.set(newValue, forKey: Key.watchMic) }
    }

    static var text: String {
        get { d.string(forKey: Key.text) ?? "LIVE ON AIR" }
        set { d.set(newValue, forKey: Key.text) }
    }

    static var height: CGFloat {
        get { max(14, min(120, CGFloat(d.double(forKey: Key.height)))) }
        set { d.set(Double(newValue), forKey: Key.height) }
    }

    static var speed: CGFloat {
        get { max(10, min(400, CGFloat(d.double(forKey: Key.speed)))) }
        set { d.set(Double(newValue), forKey: Key.speed) }
    }

    static var allScreens: Bool {
        get { d.bool(forKey: Key.allScreens) }
        set { d.set(newValue, forKey: Key.allScreens) }
    }

    static var position: Position {
        get { Position(rawValue: d.string(forKey: Key.position) ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: Key.position) }
    }

    /// Size the banner to whatever height the Dock is currently claiming.
    static var matchDockHeight: Bool {
        get { d.bool(forKey: Key.matchDockHeight) }
        set { d.set(newValue, forKey: Key.matchDockHeight) }
    }

    /// Last Dock height we actually observed, so an auto-hidden Dock still gets a
    /// sensible match instead of collapsing to nothing.
    static var lastDockHeight: CGFloat {
        get { max(16, min(160, CGFloat(d.double(forKey: Key.lastDockHeight)))) }
        set { d.set(Double(newValue), forKey: Key.lastDockHeight) }
    }

    /// Sit below the Dock so the marquee scrolls behind it, rather than over it.
    static var behindDock: Bool {
        get { d.bool(forKey: Key.behindDock) }
        set { d.set(newValue, forKey: Key.behindDock) }
    }

    static var ignoredDeviceUIDs: Set<String> {
        get { Set(d.stringArray(forKey: Key.ignoredDeviceUIDs) ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: Key.ignoredDeviceUIDs) }
    }

    static func toggleIgnored(_ uid: String) {
        var set = ignoredDeviceUIDs
        if set.contains(uid) { set.remove(uid) } else { set.insert(uid) }
        ignoredDeviceUIDs = set
    }
}
