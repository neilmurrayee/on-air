import AppKit

// A dependency-free test runner: the Command Line Tools ship neither XCTest nor
// Swift Testing, so this is compiled together with Sources/ (minus main.swift).
//
//   ./build.sh --test    logic tests, then the performance budgets
//   ./build.sh --bench   performance only, more iterations, more detail
//
// The performance checks read the real hardware. They never open a camera or mic.

let benchOnly = CommandLine.arguments.contains("--bench")
var failures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if !condition {
        failures += 1
        print("  FAIL line \(line): \(message())")
    }
}

func test(_ name: String, _ body: () -> Void) {
    // Fresh, throwaway settings for every test.
    let suite = "com.local.onair.tests"
    UserDefaults().removePersistentDomain(forName: suite)
    Prefs.d = UserDefaults(suiteName: suite)!
    Prefs.registerDefaults()
    let before = failures
    body()
    print(failures == before ? "ok    \(name)" : "FAILED \(name)")
}

// MARK: - Fixtures

func cam(_ uid: String, live: Bool = true) -> Device {
    Device(kind: .camera, uid: uid, name: uid, inUse: live)
}
func mic(_ uid: String, live: Bool = true) -> Device {
    Device(kind: .microphone, uid: uid, name: uid, inUse: live)
}
func app(_ uid: String, _ name: String, pid: pid_t = 1) -> AudioApp {
    AudioApp(pid: pid, uid: uid, name: name)
}
func snapshot(_ devices: [Device] = [], _ apps: [AudioApp] = []) -> HardwareReader.Snapshot {
    HardwareReader.Snapshot(devices: devices, inputApps: apps, duration: 0)
}

/// A monitor that counts its change notifications.
func countingMonitor() -> (MediaMonitor, () -> Int) {
    let m = MediaMonitor()
    var changes = 0
    m.onChange = { changes += 1 }
    return (m, { changes })
}

// MARK: - Logic

if !benchOnly {
    test("helper bundle ids walk up to their parent app") {
        check(HardwareReader.parentBundleIDs(of: "com.google.Chrome.helper")
              == ["com.google.Chrome.helper", "com.google.Chrome", "com.google"], "Chrome helper")
        check(HardwareReader.parentBundleIDs(of: "us.zoom.xos") == ["us.zoom.xos", "us.zoom"], "Zoom")
        check(HardwareReader.parentBundleIDs(of: "single").isEmpty, "no dots: nothing to try")
    }

    test("the same reading twice notifies once") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([cam("c1")]))
        m.apply(snapshot([cam("c1")]))
        check(changes() == 1, "got \(changes())")
        check(m.isLive && m.cameraIsLive && !m.micIsLive, "camera only")
    }

    test("idle devices are not live and do not notify") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([cam("c1", live: false), mic("m1", live: false)]))
        check(!m.isLive, "should be idle")
        check(changes() == 0, "got \(changes())")
    }

    test("going live and coming back off both notify") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([mic("m1")]))
        m.apply(snapshot([mic("m1", live: false)]))
        check(changes() == 2, "got \(changes())")
        check(!m.isLive, "should be idle again")
    }

    test("a new app joining the mic notifies, so the banner text updates") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([], [app("us.zoom.xos", "Zoom")]))
        m.apply(snapshot([], [app("us.zoom.xos", "Zoom"), app("com.google.Chrome", "Google Chrome", pid: 2)]))
        check(changes() == 2, "got \(changes())")
        check(m.liveAppNames == ["Zoom", "Google Chrome"], "\(m.liveAppNames)")
    }

    test("two helpers of one app are named once") {
        let (m, _) = countingMonitor()
        m.apply(snapshot([], [app("com.google.Chrome", "Google Chrome", pid: 1),
                              app("com.google.Chrome", "Google Chrome", pid: 2)]))
        check(m.liveAppNames == ["Google Chrome"], "\(m.liveAppNames)")
    }

    test("ignored devices and apps never make it live") {
        Prefs.toggleIgnored("virtual-mic")
        Prefs.toggleIgnored("com.example.Recorder")
        let (m, changes) = countingMonitor()
        m.apply(snapshot([mic("virtual-mic")], [app("com.example.Recorder", "Recorder")]))
        check(!m.isLive, "should be idle")
        check(changes() == 0, "got \(changes())")
    }

    test("unwatched camera is ignored; the mic still counts") {
        Prefs.watchCamera = false
        let (m, _) = countingMonitor()
        m.apply(snapshot([cam("c1"), mic("m1")]))
        check(!m.cameraIsLive && m.micIsLive, "cam=\(m.cameraIsLive) mic=\(m.micIsLive)")
    }

    test("a preference change is noticed on the next reading, not cancelled out") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([cam("c1")]))
        Prefs.watchCamera = false
        m.apply(snapshot([cam("c1")]))
        check(changes() == 2, "got \(changes())")
        check(!m.isLive, "camera is no longer watched")
    }

    test("refresh always notifies, without a new reading") {
        let (m, changes) = countingMonitor()
        m.apply(snapshot([cam("c1")]))
        m.refresh()
        check(changes() == 2, "got \(changes())")
    }

    // A 1000x800 screen whose Dock claims the bottom 60 points.
    let full = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let withDock = NSRect(x: 0, y: 60, width: 1000, height: 715)
    let dockHidden = NSRect(x: 0, y: 4, width: 1000, height: 771)   // auto-hide still reserves a sliver

    test("banner matches the Dock on the bottom edge by default") {
        check(BannerController.frame(full: full, visible: withDock) == NSRect(x: 0, y: 0, width: 1000, height: 60),
              "\(BannerController.frame(full: full, visible: withDock))")
    }

    test("hidden Dock falls back to the last height seen") {
        Prefs.lastDockHeight = 48
        check(BannerController.frame(full: full, visible: dockHidden).height == 48, "height")
    }

    test("fixed height overrides the Dock") {
        Prefs.matchDockHeight = false
        Prefs.height = 22
        check(BannerController.frame(full: full, visible: withDock).height == 22, "height")
    }

    test("above-the-Dock and automatic positions") {
        Prefs.position = .aboveDock
        check(BannerController.frame(full: full, visible: withDock).minY == 60, "above dock")
        Prefs.position = .auto
        check(BannerController.frame(full: full, visible: withDock).minY == 60, "auto, dock showing")
        check(BannerController.frame(full: full, visible: dockHidden).minY == 0, "auto, dock hidden")
    }

    test("the red frame hugs the screen edges without overlapping corners") {
        let screen = NSRect(x: 1000, y: -200, width: 1600, height: 900)
        let strips = BannerController.borderFrames(full: screen, width: 4)
        check(strips.count == 4, "four strips")
        let area = strips.reduce(0) { $0 + $1.width * $1.height }
        check(area == 2 * 1600 * 4 + 2 * 4 * (900 - 8), "strips overlap or leave gaps: area \(area)")
        check(strips.allSatisfy { screen.contains($0) }, "a strip leaves the screen")
    }

    test("the bar holds still by default, and scrolls when asked") {
        let view = MarqueeView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        view.layout()
        check(!view.isScrolling, "still bar should not animate")
        Prefs.scroll = true
        view.restart()
        check(view.isScrolling, "should scroll")
        Prefs.scroll = false
        view.restart()
        check(!view.isScrolling, "should stop again")
    }

    test("banner spans the screen it is on, not the main one") {
        let second = NSRect(x: 1000, y: -200, width: 1600, height: 900)
        let f = BannerController.frame(full: second, visible: second)
        check(f.minX == 1000 && f.minY == -200 && f.width == 1600, "\(f)")
    }
}

// MARK: - Performance

func percentiles(_ samples: [Double]) -> (p50: Double, p99: Double, max: Double) {
    let s = samples.sorted()
    return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.99))], s.last!)
}

func ms(_ seconds: Double) -> String { String(format: "%6.2f ms", seconds * 1000) }

let iterations = benchOnly ? 500 : 100

test("hardware read: cached reads stay within budget") {
    let reader = HardwareReader()
    let first = reader.read()           // cold: fills the caches
    var times: [Double] = []
    var last = first
    for _ in 0..<iterations {
        last = reader.read()
        times.append(last.duration)
    }
    let p = percentiles(times)
    print("      cold \(ms(first.duration))   warm p50 \(ms(p.p50))  p99 \(ms(p.p99))  max \(ms(p.max))")
    print("      \(last.devices.count) devices, \(last.inputApps.count) app(s) recording")
    // Off the main thread, so this guards the polling cost, not responsiveness.
    check(p.p50 < 0.025, "p50 \(ms(p.p50)) over 25 ms")
}

test("main thread: applying a reading is cheap") {
    let reader = HardwareReader()
    let reading = reader.read()
    let m = MediaMonitor()
    m.onChange = {}
    var times: [Double] = []
    for _ in 0..<iterations {
        let start = DispatchTime.now().uptimeNanoseconds
        m.apply(reading)
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }
    let p = percentiles(times)
    print("      p50 \(ms(p.p50))  p99 \(ms(p.p99))  max \(ms(p.max))")
    check(p.p99 < 0.002, "p99 \(ms(p.p99)) over 2 ms")
}

test("main thread: stays responsive while the monitor polls") {
    // Tick the main run loop every 5 ms and record how late each tick is. Before
    // polling moved off the main thread this saw ~11 ms stalls every second.
    let seconds = benchOnly ? 10.0 : 4.0
    let m = MediaMonitor()
    var polls = 0
    m.onPoll = { polls += 1 }
    m.start(interval: 0.25)            // four times the real rate, to make stalls likely

    var lateness: [Double] = []
    var expected = Date().addingTimeInterval(0.005)
    let ticker = Timer(timeInterval: 0.005, repeats: true) { _ in
        let now = Date()
        lateness.append(max(0, now.timeIntervalSince(expected)))
        expected = now.addingTimeInterval(0.005)
    }
    RunLoop.main.add(ticker, forMode: .common)
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    ticker.invalidate()
    m.stop()

    let p = percentiles(lateness)
    print("      \(polls) polls in \(Int(seconds)) s; tick lateness p50 \(ms(p.p50))  p99 \(ms(p.p99))  max \(ms(p.max))")
    check(polls >= Int(seconds * 4) - 2, "only \(polls) polls")
    // Idle noise is ~5 ms and the old on-main polling scored ~28 ms; 15 ms leaves
    // headroom for a busy machine (a video call, say) while still catching that.
    check(p.p99 < 0.015, "p99 lateness \(ms(p.p99)) over 15 ms")
}

UserDefaults().removePersistentDomain(forName: "com.local.onair.tests")
print(failures == 0 ? "\nall passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
