import AppKit
import Foundation
import ServiceManagement

// Login-item management, driven from the command line so it can be scripted:
//   "On Air.app/Contents/MacOS/OnAir" --register-login-item
// SMAppService always acts on the bundle it is running from, so this has to be the
// real binary inside the installed .app, not a copy.
let arguments = Set(CommandLine.arguments.dropFirst())
let loginItemFlags: Set<String> = ["--register-login-item", "--unregister-login-item", "--login-item-status"]

if !arguments.isDisjoint(with: loginItemFlags) {
    guard #available(macOS 13.0, *) else {
        FileHandle.standardError.write(Data("error: needs macOS 13 or later\n".utf8))
        exit(1)
    }

    let service = SMAppService.mainApp
    do {
        if arguments.contains("--register-login-item") { try service.register() }
        if arguments.contains("--unregister-login-item") { try service.unregister() }
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    let description: String
    switch service.status {
    case .enabled: description = "enabled"
    case .notRegistered: description = "not registered"
    case .requiresApproval: description = "requires approval in System Settings > General > Login Items"
    case .notFound: description = "not found"
    @unknown default: description = "unknown (\(service.status.rawValue))"
    }
    print("login item: \(description)")
    print("bundle: \(Bundle.main.bundleURL.path)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory: menu bar item only, no Dock icon, never takes focus from your call.
app.setActivationPolicy(.accessory)
app.run()
