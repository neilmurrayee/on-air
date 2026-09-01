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
/// listeners that never fire), so this polls on a timer instead of subscribing.
///
/// None of these reads requires TCC permission and none of them opens a device, so
/// this app never lights the orange/green indicator itself.
final class MediaMonitor {
    private(set) var devices: [Device] = []
    private(set) var inputApps: [AudioApp] = []

    private var timer: Timer?

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

    func start(interval: TimeInterval = 1.0) {
        poll()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        // .common so polling continues while a menu is open or a window is being dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read everything. Fires `onChange` only when the visible state actually
    /// changed, so the banner is not torn down and rebuilt once a second.
    ///
    /// The comparison is against the last fingerprint we *emitted*, not one recomputed
    /// on the spot. Recomputing reads the current preferences, so a preference change
    /// would cancel itself out — the "before" snapshot would already reflect the new
    /// setting and nothing would ever be reported as changed.
    func poll() {
        devices = readCameras() + readMicrophones()
        inputApps = readInputApps()

        let current = fingerprint
        if current != lastEmitted {
            lastEmitted = current
            onChange?()
        }
        onPoll?()
    }

    /// Force a change notification, e.g. after the user toggles what is watched.
    func refresh() {
        devices = readCameras() + readMicrophones()
        inputApps = readInputApps()
        lastEmitted = fingerprint
        onChange?()
    }

    // MARK: - Signal 3: audio processes (macOS 14+)

    private func readInputApps() -> [AudioApp] {
        guard #available(macOS 14.0, *) else { return [] }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard boolProperty(id, kAudioProcessPropertyIsRunningInput) else { return nil }

            let pid = pidProperty(id)

            // Our own process never counts — belt and braces, we never open a device.
            guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }

            let bundleID = audioString(id, kAudioProcessPropertyBundleID)
            let (uid, name) = identify(pid: pid, bundleID: bundleID)
            return AudioApp(pid: pid, uid: uid, name: name)
        }
    }

    /// Turn a recording process into something worth showing a human.
    ///
    /// Chrome, Electron and Teams all record audio from a helper process whose own
    /// name is the useless "Helper", so walk the bundle id up towards its parent
    /// ("com.google.Chrome.helper" -> "com.google.Chrome") until we find a real
    /// foreground app. The resolved id doubles as the ignore-list key, so ignoring
    /// Chrome ignores every one of its helpers.
    private func identify(pid: pid_t, bundleID: String?) -> (uid: String, name: String) {
        if let bundleID {
            var parts = bundleID.components(separatedBy: ".")
            while parts.count > 1 {
                let candidate = parts.joined(separator: ".")
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: candidate)
                    .first(where: { $0.activationPolicy == .regular }),
                   let name = app.localizedName {
                    return (candidate, name)
                }
                parts.removeLast()
            }
        }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return (bundleID ?? "pid-\(pid)", name)
        }
        return (bundleID ?? "pid-\(pid)", bundleID?.components(separatedBy: ".").last?.capitalized ?? "an app")
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
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard audioInputChannels(id) > 0 else { return nil }   // skip output-only devices
            let uid = audioString(id, kAudioDevicePropertyDeviceUID) ?? "audio-\(id)"
            let name = audioString(id, kAudioObjectPropertyName) ?? "Microphone"
            let live = boolProperty(id, kAudioDevicePropertyDeviceIsRunningSomewhere)
            return Device(kind: .microphone, uid: uid, name: name, inUse: live)
        }
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

        return ids.map { id in
            let uid = cmioString(id, kCMIODevicePropertyDeviceUID) ?? "video-\(id)"
            let name = cmioString(id, kCMIOObjectPropertyName) ?? "Camera"
            return Device(kind: .camera, uid: uid, name: name, inUse: cmioIsRunning(id))
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
