import Foundation
import AppKit
import CoreAudio
import CoreMediaIO

/// One camera or microphone, as reported by the system.
struct Device: Equatable {
    enum Kind { case camera, microphone }
    let kind: Kind
    let uid: String
    let name: String
    let inUse: Bool
}

/// An app currently recording from an audio input (macOS 14+ only).
struct AudioApp: Equatable {
    let pid: pid_t
    let uid: String        // bundle id where we have one, else "pid-123"
    let name: String
}

/// Polls the system for "is any camera / microphone actually running right now".
///
/// Three signals, unioned — any one of them is enough to go live:
///
///  1. `kCMIODevicePropertyDeviceIsRunningSomewhere` per camera.
///  2. `kAudioDevicePropertyDeviceIsRunningSomewhere` per audio input device.
///  3. `kAudioProcessPropertyIsRunningInput` per audio process (macOS 14+).
///
/// Signal 2 alone is the classic approach, but it reports Bluetooth mics as idle
/// even while they are recording, so signal 3 backs it up — and as a bonus it names
/// the app doing the recording. Apple's own listeners for these properties are
/// documented as unreliable (spurious camera callbacks on macOS 12+, input-running
/// listeners that never fire), so this polls on a timer.
///
/// The one listener that does work is an audio device's "running somewhere": it
/// fired within the same second as polling for every change we saw. So an input
/// device starting or stopping triggers a read straight away, and the timer only
/// needs to run every few seconds to catch everything else — cameras, and apps
/// on Bluetooth mics, which their device does not report.
///
/// None of these reads requires TCC permission and none of them opens a device, so
/// this app never lights the orange/green indicator itself.
///
/// Every CoreAudio read is a synchronous round trip to coreaudiod — about 0.3 ms
/// each, one per audio process per poll, and far longer while coreaudiod is busy
/// switching devices — so the reading happens on a background queue and only the
/// result is handed to the main thread. Everything on this class is main-thread only.
final class MediaMonitor {
    private(set) var devices: [Device] = []
    private(set) var inputApps: [AudioApp] = []

    /// How long the last hardware read took, for the debug trace.
    private(set) var lastReadDuration: TimeInterval = 0

    private let queue: DispatchQueue
    private let reader: HardwareReader      // only ever touched on `queue`
    private var timer: DispatchSourceTimer?
    private var readPending = false         // only ever touched on `queue`

    init() {
        let queue = DispatchQueue(label: "com.local.onair.monitor", qos: .utility)
        self.queue = queue
        reader = HardwareReader(listeningOn: queue)
    }

    /// The last fingerprint handed to `onChange`.
    private var lastEmitted: [String] = []

    /// Called whenever the live/not-live state changes.
    var onChange: (() -> Void)?

    /// Called on every poll, changed or not. Somewhere to hang cheap upkeep.
    var onPoll: (() -> Void)?

    // MARK: - Derived state

    /// Cameras that are live, watched, and not ignored.
    var activeCameras: [Device] {
        guard Prefs.watchCamera else { return [] }
        let ignored = Prefs.ignoredDeviceUIDs
        return devices.filter { $0.kind == .camera && $0.inUse && !ignored.contains($0.uid) }
    }

    /// Mic *devices* that are live, watched, and not ignored.
    var activeMicDevices: [Device] {
        guard Prefs.watchMic else { return [] }
        let ignored = Prefs.ignoredDeviceUIDs
        return devices.filter { $0.kind == .microphone && $0.inUse && !ignored.contains($0.uid) }
    }

    /// Apps recording input that are watched and not ignored.
    var activeInputApps: [AudioApp] {
        guard Prefs.watchMic else { return [] }
        let ignored = Prefs.ignoredDeviceUIDs
        return inputApps.filter { !ignored.contains($0.uid) }
    }

    var cameraIsLive: Bool { !activeCameras.isEmpty }
    var micIsLive: Bool { !activeMicDevices.isEmpty || !activeInputApps.isEmpty }
    var isLive: Bool { cameraIsLive || micIsLive }

    /// Distinct app names currently on the mic, for the banner text.
    var liveAppNames: [String] {
        var seen = Set<String>()
        return activeInputApps.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    /// A stable fingerprint of everything that would change what the banner shows.
    private var fingerprint: [String] {
        (activeCameras.map { "cam:\($0.uid)" }
            + activeMicDevices.map { "mic:\($0.uid)" }
            + activeInputApps.map { "app:\($0.uid)" }).sorted()
    }

    // MARK: - Polling

    /// Every read costs coreaudiod one request per audio process, ~35 here, so the
    /// timer is the slow safety net and device listeners provide the speed.
    func start(interval: TimeInterval = 3.0) {
        queue.async { [weak self] in
            self?.reader.onDeviceChange = { [weak self] in self?.readSoon() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets the system batch our wakeups with others.
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.read() }
        t.resume()
        timer = t
    }

    /// On `queue`: read now and hand the result to the main thread.
    private func read() {
        let snapshot = reader.read()
        DispatchQueue.main.async { [weak self] in self?.apply(snapshot) }
    }

    /// On `queue`: read shortly, folding a burst of device notifications (a call
    /// starting several devices at once, say) into a single read.
    private func readSoon() {
        guard !readPending else { return }
        readPending = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.readPending = false
            self?.read()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Take in a fresh reading. Fires `onChange` only when the visible state actually
    /// changed, so the banner is not torn down and rebuilt once a second.
    ///
    /// The comparison is against the last fingerprint we *emitted*, not one recomputed
    /// on the spot. Recomputing reads the current preferences, so a preference change
    /// would cancel itself out — the "before" snapshot would already reflect the new
    /// setting and nothing would ever be reported as changed.
    func apply(_ snapshot: HardwareReader.Snapshot) {
        devices = snapshot.devices
        inputApps = snapshot.inputApps
        lastReadDuration = snapshot.duration

        let current = fingerprint
        if current != lastEmitted {
            lastEmitted = current
            onChange?()
        }
        onPoll?()
    }

    /// Force a change notification, e.g. after the user toggles what is watched.
    /// Only preferences changed, so the last reading is still good.
    func refresh() {
        lastEmitted = fingerprint
        onChange?()
    }
}

/// Reads cameras, mics and recording apps from the system.
///
/// Not thread-safe: `MediaMonitor` uses it only from its own serial queue, which is
/// also where its device listeners are delivered. A device's
/// UID, name and channel layout, and a process's pid and app, never change for the
/// life of its object ID, so those are read once and cached. Each poll then costs
/// one read per device and per audio process for the live flag, plus the lists.
final class HardwareReader {
    struct Snapshot {
        var devices: [Device]
        var inputApps: [AudioApp]
        var duration: TimeInterval
    }

    private struct DeviceInfo { let uid: String; let name: String }

    private var micInfo: [AudioObjectID: DeviceInfo?] = [:]      // nil: output-only, skip
    private var cameraInfo: [CMIOObjectID: DeviceInfo] = [:]
    private var processInfo: [AudioObjectID: AudioApp?] = [:]    // nil: ourselves, skip

    /// Called on the listening queue when devices come or go, or an input device
    /// starts or stops.
    var onDeviceChange: (() -> Void)?
    private let listenQueue: DispatchQueue?
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceListListener: AudioObjectPropertyListenerBlock?

    /// With a queue, listen for device changes on it; without one (tests), only read.
    init(listeningOn queue: DispatchQueue? = nil) {
        listenQueue = queue
        guard let queue else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceChange?() }
        var addr = Self.address(kAudioHardwarePropertyDevices)
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr {
            deviceListListener = block
        }
    }

    deinit {
        guard let listenQueue else { return }
        var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for (id, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(id, &running, listenQueue, block)
        }
        if let deviceListListener {
            var list = Self.address(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &list, listenQueue, deviceListListener)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Follow each input device's "running somewhere", and stop following devices
    /// that have gone. A device that has gone takes its listener with it, so a
    /// failed removal there is expected and harmless.
    private func updateListeners(inputs: Set<AudioObjectID>) {
        guard let listenQueue else { return }
        var addr = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        for (id, block) in listeners where !inputs.contains(id) {
            AudioObjectRemovePropertyListenerBlock(id, &addr, listenQueue, block)
            listeners[id] = nil
        }
        for id in inputs where listeners[id] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onDeviceChange?() }
            if AudioObjectAddPropertyListenerBlock(id, &addr, listenQueue, block) == noErr {
                listeners[id] = block
            }
        }
    }

    func read() -> Snapshot {
        let start = DispatchTime.now().uptimeNanoseconds
        let devices = readCameras() + readMicrophones()
        let apps = readInputApps()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        return Snapshot(devices: devices, inputApps: apps, duration: elapsed)
    }

    // MARK: - Signal 3: audio processes (macOS 14+)

    private func readInputApps() -> [AudioApp] {
        guard #available(macOS 14.0, *) else { return [] }

        let ids = audioObjectList(kAudioHardwarePropertyProcessObjectList)
        processInfo = processInfo.filter { ids.contains($0.key) }

        return ids.compactMap { id in
            guard boolProperty(id, kAudioProcessPropertyIsRunningInput) else { return nil }
            if let cached = processInfo[id] { return cached }

            let pid = pidProperty(id)
            // Our own process never counts — belt and braces, we never open a device.
            let app = pid == ProcessInfo.processInfo.processIdentifier
                ? nil
                : Self.identify(pid: pid, bundleID: audioString(id, kAudioProcessPropertyBundleID))
            processInfo[id] = app
            return app
        }
    }

    /// Turn a recording process into something worth showing a human.
    ///
    /// Chrome, Electron and Teams all record audio from a helper process whose own
    /// name is the useless "Helper", so walk the bundle id up towards its parent
    /// ("com.google.Chrome.helper" -> "com.google.Chrome") until we find a real
    /// foreground app. The resolved id doubles as the ignore-list key, so ignoring
    /// Chrome ignores every one of its helpers.
    private static func identify(pid: pid_t, bundleID: String?) -> AudioApp {
        // Command-line tools report an empty bundle id rather than none.
        let bundleID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        if let bundleID {
            for candidate in parentBundleIDs(of: bundleID) {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate)
                    .first(where: { $0.activationPolicy == .regular }),
                   let name = app.localizedName, !name.isEmpty {
                    return AudioApp(pid: pid, uid: candidate, name: name)
                }
            }
        }
        if let bundleID {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName.flatMap { $0.isEmpty ? nil : $0 }
            return AudioApp(pid: pid, uid: bundleID,
                            name: name ?? bundleID.components(separatedBy: ".").last!.capitalized)
        }
        // No bundle at all, e.g. ffmpeg in a terminal: go by the executable's name,
        // which also keeps the ignore-list key stable from one run to the next.
        if let name = processName(pid) {
            return AudioApp(pid: pid, uid: "process:\(name)", name: name)
        }
        return AudioApp(pid: pid, uid: "pid-\(pid)", name: "an app")
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// "a.b.c.d" -> ["a.b.c.d", "a.b.c", "a.b"]: the bundle id and its ancestors,
    /// nearest first, stopping short of the bare top-level domain.
    static func parentBundleIDs(of bundleID: String) -> [String] {
        var parts = bundleID.components(separatedBy: ".")
        var result: [String] = []
        while parts.count > 1 {
            result.append(parts.joined(separator: "."))
            parts.removeLast()
        }
        return result
    }

    @available(macOS 14.0, *)
    private func pidProperty(_ id: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &pid) == noErr else { return -1 }
        return pid
    }

    // MARK: - Signal 2: audio input devices

    private func readMicrophones() -> [Device] {
        let ids = audioObjectList(kAudioHardwarePropertyDevices)
        micInfo = micInfo.filter { ids.contains($0.key) }
        defer { updateListeners(inputs: Set(micInfo.compactMap { $0.value == nil ? nil : $0.key })) }

        return ids.compactMap { id in
            let info: DeviceInfo?
            if let cached = micInfo[id] {
                info = cached
            } else {
                info = audioInputChannels(id) > 0   // skip output-only devices
                    ? DeviceInfo(
                        uid: audioString(id, kAudioDevicePropertyDeviceUID) ?? "audio-\(id)",
                        name: audioString(id, kAudioObjectPropertyName) ?? "Microphone")
                    : nil
                micInfo[id] = info
            }
            guard let info else { return nil }
            let live = boolProperty(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
            return Device(kind: .microphone, uid: info.uid, name: info.name, inUse: live)
        }
    }

    private func audioObjectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func audioInputChannels(_ id: AudioObjectID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let buf = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func boolProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private func audioString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    // MARK: - Signal 1: cameras (CoreMediaIO)

    private func readCameras() -> [Device] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0))

        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr
        else { return [] }
        ids = Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
        cameraInfo = cameraInfo.filter { ids.contains($0.key) }

        return ids.map { id in
            let info = cameraInfo[id] ?? DeviceInfo(
                uid: cmioString(id, kCMIODevicePropertyDeviceUID) ?? "video-\(id)",
                name: cmioString(id, kCMIOObjectPropertyName) ?? "Camera")
            cameraInfo[id] = info
            return Device(kind: .camera, uid: info.uid, name: info.name, inUse: cmioIsRunning(id))
        }
    }

    private func cmioIsRunning(_ id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0))
        var running: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, &running) == noErr else { return false }
        return running != 0
    }

    private func cmioString(_ id: CMIOObjectID, _ selector: Int) -> String? {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(0))
        var value: CFString? = nil
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &used, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
