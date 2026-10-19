import AppKit
import Foundation

/// A native Apple Silicon runtime that replaces Wine for one Steam game.
///
/// The runtime is built from NativePorts/<name> at Xcode build time and shipped in
/// Aether.app/Contents/Resources/NativePorts/<name>. It is launched through macOS
/// Steam (the game's Mac entry, with Launch Options pointing at the runtime), so
/// Steam handles Cloud saves, achievements and playtime exactly like a Mac game.
struct NativePort {
    let steamAppID: Int
    /// Folder name under Resources/NativePorts and ~/Library/Application Support/Aether/Native.
    let name: String
    let executable: String
    /// Files and folders copied from the game's Steam install folder in the bottle.
    let assets: [String]
}

enum NativePortError: LocalizedError {
    case notBundled
    case steamNotInstalled
    case assetsMissing(String)
    case finishSteamInstall
    case steamConfig(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "This build of Aether does not include the native runtime."
        case .steamNotInstalled:
            return "The native version runs through Steam for macOS. Install Steam from store.steampowered.com, sign in, then press Play again."
        case .assetsMissing(let path):
            return "Game files not found at \(path). Install the game in Aether's Steam first."
        case .finishSteamInstall:
            return "Steam for macOS is installing the game's Mac entry (small download). When it finishes, press Play again."
        case .steamConfig(let why):
            return "Could not configure Steam for the native version: \(why)"
        }
    }
}

enum NativePortManager {
    static let ports: [Int: NativePort] = [
        3590: NativePort(steamAppID: 3590, name: "PvZ", executable: "pvz-native",
                         assets: ["main.pak", "properties"]),
    ]

    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether")

    /// The native port for a Steam app, if this Aether build ships one.
    static func port(for appID: Int) -> NativePort? {
        guard let port = ports[appID], bundledDir(port) != nil else { return nil }
        return port
    }

    static func bundledDir(_ port: NativePort) -> URL? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("NativePorts/\(port.name)") else { return nil }
        let exe = dir.appendingPathComponent(port.executable)
        return FileManager.default.isExecutableFile(atPath: exe.path) ? dir : nil
    }

    static func installDir(_ port: NativePort) -> URL {
        appSupport.appendingPathComponent("Native/\(port.name)")
    }

    // MARK: - Install

    /// Copy the runtime and the game's data into place. Returns the launch wrapper.
    @discardableResult
    static func install(_ port: NativePort, bottle: Bottle, gameInstallDir: String) throws -> URL {
        guard let src = bundledDir(port) else { throw NativePortError.notBundled }
        let fm = FileManager.default
        let dst = installDir(port)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)

        // Runtime files: refresh whenever the bundled build changes.
        let stamp = { (dir: URL) in try? String(contentsOf: dir.appendingPathComponent(".build-stamp"), encoding: .utf8) }
        if stamp(src) == nil || stamp(src) != stamp(dst) {
            for item in try fm.contentsOfDirectory(atPath: src.path) {
                let target = dst.appendingPathComponent(item)
                try? fm.removeItem(at: target)
                try fm.copyItem(at: src.appendingPathComponent(item), to: target)
            }
        }
        // A steam_appid.txt would stop the runtime from relaunching through Steam.
        try? fm.removeItem(at: dst.appendingPathComponent("steam_appid.txt"))

        // Game data from the user's own Windows install.
        let gameDir = bottle.steamLibraryPath.appendingPathComponent("common/\(gameInstallDir)")
        for asset in port.assets where !fm.fileExists(atPath: dst.appendingPathComponent(asset).path) {
            let from = gameDir.appendingPathComponent(asset)
            guard fm.fileExists(atPath: from.path) else { throw NativePortError.assetsMissing(from.path) }
            try fm.copyItem(at: from, to: dst.appendingPathComponent(asset))
        }

        // Text overrides for the Steam 1.2.0.1096 strings (cosmetic; skipped without python3).
        let overrides = dst.appendingPathComponent("properties/aether-overrides.xml")
        let generator = dst.appendingPathComponent("make-compat-overrides.py")
        if !fm.fileExists(atPath: overrides.path), fm.fileExists(atPath: generator.path) {
            let py = Process()
            py.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            py.arguments = ["python3", generator.path, dst.appendingPathComponent("main.pak").path]
            py.standardOutput = FileHandle.nullDevice
            py.standardError = FileHandle.nullDevice
            try? py.run()
            py.waitUntilExit()
        }

        // Launch wrapper used as the game's Steam Launch Options.
        let wrapper = dst.appendingPathComponent("aether-launch.sh")
        let script = """
        #!/bin/sh
        # Started by Steam for macOS (Launch Options: "<this file>" %command%).
        # Steam passes the game's original Mac binary as "$@"; run Aether's native runtime instead.
        DIR="$(cd "$(dirname "$0")" && pwd)"
        cd "$DIR" || exit 1
        unset DYLD_INSERT_LIBRARIES
        exec "$DIR/\(port.executable)" >> "$DIR/last-run.log" 2>&1

        """
        if (try? String(contentsOf: wrapper, encoding: .utf8)) != script {
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        }
        return wrapper
    }

    // MARK: - Launch

    static func launch(_ port: NativePort, bottle: Bottle, gameInstallDir: String) async throws {
        let wrapper = try install(port, bottle: bottle, gameInstallDir: gameInstallDir)
        guard NativeSteam.isInstalled else { throw NativePortError.steamNotInstalled }

        let appID = port.steamAppID
        guard NativeSteam.isAppInstalled(appID) else {
            if !NativeSteam.isRunning { NativeSteam.start() }
            NativeSteam.open("steam://install/\(appID)")
            throw NativePortError.finishSteamInstall
        }

        let launchOptions = "\"\(wrapper.path)\" %command%"
        let configs = NativeSteam.userConfigs()
        guard !configs.isEmpty else {
            throw NativePortError.steamConfig("sign in to Steam for macOS once, then press Play again")
        }
        let stale = configs.filter { NativeSteam.launchOptions(appID, in: $0) != launchOptions }

        if !stale.isEmpty {
            // Steam rewrites localconfig.vdf on exit, so it must be closed while editing.
            if NativeSteam.isRunning {
                guard await NativeSteam.exit() else {
                    throw NativePortError.steamConfig("Steam did not quit; quit Steam and press Play again")
                }
            }
            for config in stale {
                guard NativeSteam.setLaunchOptions(appID, value: launchOptions, in: config) else {
                    throw NativePortError.steamConfig("could not update \(config.path)")
                }
            }
        }
        if !NativeSteam.isRunning {
            let offset = NativeSteam.connectionLogSize()
            NativeSteam.start()
            await NativeSteam.waitForLogin(since: offset, timeout: 120)
        }
        guard await NativeSteam.runGame(appID) else {
            throw NativePortError.steamConfig("Steam did not accept the launch; press Play again")
        }
    }

    /// True while the native runtime for this port is running.
    static func isRunning(_ port: NativePort) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", installDir(port).appendingPathComponent(port.executable).path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}

// MARK: - Steam for macOS

enum NativeSteam {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")

    static var appURL: URL? {
        ["/Applications/Steam.app", NSHomeDirectory() + "/Applications/Steam.app"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isInstalled: Bool { appURL != nil }

    static var isRunning: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "MacOS/steam_osx"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func start() {
        guard let app = appURL else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Ask Steam to quit and wait for it.
    static func exit(timeout: TimeInterval = 60) async -> Bool {
        open("steam://exit")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isRunning { return true }
            try? await Task.sleep(for: .seconds(1))
        }
        return !isRunning
    }

    static func connectionLogSize() -> UInt64 {
        let log = root.appendingPathComponent("logs/connection_log.txt")
        return (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
    }

    static func waitForLogin(since offset: UInt64, timeout: TimeInterval) async {
        let log = root.appendingPathComponent("logs/connection_log.txt")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let handle = try? FileHandle(forReadingFrom: log) {
                let size = (try? handle.seekToEnd()) ?? 0
                try? handle.seek(toOffset: size < offset ? 0 : offset)
                let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                try? handle.close()
                if text.contains("RecvMsgClientLogOnResponse() : processing complete") { return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Ask Steam to launch an app, retrying while Steam is still starting up
    /// ("rungameid : not allowed yet"). True once Steam starts the launch.
    static func runGame(_ appID: Int, timeout: TimeInterval = 90) async -> Bool {
        let log = root.appendingPathComponent("logs/console_log.txt")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let offset = (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
            open("steam://rungameid/\(appID)")
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let handle = try? FileHandle(forReadingFrom: log) else { continue }
                try? handle.seek(toOffset: offset)
                let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
                try? handle.close()
                if text.contains("GameAction [AppID \(appID)") || text.contains("Game process added : AppID \(appID) ") {
                    return true
                }
                if text.contains("not allowed yet") { break }
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    /// Steam library folders (the default one plus any added in Steam settings).
    static func libraryFolders() -> [URL] {
        var folders = [root]
        let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let regex = try? NSRegularExpression(pattern: #""path"\s+"([^"]+)""#) {
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) {
                    let url = URL(fileURLWithPath: String(text[r]))
                    if !folders.contains(url) { folders.append(url) }
                }
            }
        }
        return folders
    }

    static func isAppInstalled(_ appID: Int) -> Bool {
        libraryFolders().contains { lib in
            let manifest = lib.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
            guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return false }
            return text.range(of: #""StateFlags"\s+"4""#, options: .regularExpression) != nil
        }
    }

    /// localconfig.vdf of every account that has signed in to Steam for macOS.
    static func userConfigs() -> [URL] {
        let userdata = root.appendingPathComponent("userdata")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: userdata.path)) ?? []
        return ids.compactMap { id in
            let url = userdata.appendingPathComponent("\(id)/config/localconfig.vdf")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    static func launchOptions(_ appID: Int, in config: URL) -> String? {
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let block = VDFText.appBlock(in: text, appID: String(appID)) else { return nil }
        return VDFText.value(of: "LaunchOptions", inBlock: text[block])
    }

    static func setLaunchOptions(_ appID: Int, value: String, in config: URL) -> Bool {
        guard let text = try? String(contentsOf: config, encoding: .utf8),
              let updated = VDFText.settingLaunchOptions(in: text, appID: String(appID), value: value) else { return false }
        let backup = config.appendingPathExtension("aether-backup")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: config, to: backup)
        }
        return (try? updated.write(to: config, atomically: true, encoding: .utf8)) != nil
    }
}

// MARK: - Minimal text VDF editing (Steam's localconfig.vdf)

enum VDFText {
    private enum Token { case string(String, Range<String.Index>), open(String.Index), close(String.Index) }

    private static func tokens(_ text: String, from start: String.Index) -> AnyIterator<Token> {
        var i = start
        return AnyIterator {
            while i < text.endIndex {
                let c = text[i]
                if c == "{" { defer { i = text.index(after: i) }; return .open(i) }
                if c == "}" { defer { i = text.index(after: i) }; return .close(i) }
                if c == "\"" {
                    let s = i
                    var j = text.index(after: i)
                    var value = ""
                    while j < text.endIndex, text[j] != "\"" {
                        if text[j] == "\\", text.index(after: j) < text.endIndex {
                            j = text.index(after: j)
                        }
                        value.append(text[j])
                        j = text.index(after: j)
                    }
                    let end = j < text.endIndex ? text.index(after: j) : j
                    i = end
                    return .string(value, s..<end)
                }
                i = text.index(after: i)
            }
            return nil
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Range of the body (between the braces) of apps/<appID> in the first "apps" block.
    static func appBlock(in text: String, appID: String) -> Range<String.Index>? {
        guard let appsBody = body(after: "apps", in: text, from: text.startIndex) else { return nil }
        return childBody(named: appID, in: text, within: appsBody)
    }

    /// Body range of the first block keyed `name` anywhere in text.
    private static func body(after name: String, in text: String, from start: String.Index) -> Range<String.Index>? {
        var expectOpenAfterKey = false
        var bodyStart: String.Index?
        var depth = 0
        for t in tokens(text, from: start) {
            switch t {
            case .string(let v, _):
                if bodyStart == nil { expectOpenAfterKey = (v == name) }
            case .open(let idx):
                if bodyStart == nil {
                    if expectOpenAfterKey { bodyStart = text.index(after: idx); depth = 1 }
                    expectOpenAfterKey = false
                } else { depth += 1 }
            case .close(let idx):
                if bodyStart != nil {
                    depth -= 1
                    if depth == 0 { return bodyStart!..<idx }
                }
                expectOpenAfterKey = false
            }
        }
        return nil
    }

    /// Body range of the direct child block `name` inside `parent`.
    private static func childBody(named name: String, in text: String, within parent: Range<String.Index>) -> Range<String.Index>? {
        var depth = 0
        var lastKeyAtDepth0: String?
        var bodyStart: String.Index?
        for t in tokens(text, from: parent.lowerBound) {
            switch t {
            case .string(let v, let r):
                if r.lowerBound >= parent.upperBound { return nil }
                if depth == 0 { lastKeyAtDepth0 = v }
            case .open(let idx):
                if idx >= parent.upperBound { return nil }
                if depth == 0, lastKeyAtDepth0 == name { bodyStart = text.index(after: idx) }
                depth += 1
            case .close(let idx):
                if idx >= parent.upperBound { return nil }
                depth -= 1
                if depth == 0, let s = bodyStart { return s..<idx }
                lastKeyAtDepth0 = nil
            }
        }
        return nil
    }

    /// Value of a direct key/value pair inside a block body.
    static func value(of key: String, inBlock block: Substring) -> String? {
        let text = String(block)
        var depth = 0
        var pendingKey: String?
        for t in tokens(text, from: text.startIndex) {
            switch t {
            case .string(let v, _):
                guard depth == 0 else { continue }
                if let k = pendingKey { if k == key { return v }; pendingKey = nil } else { pendingKey = v }
            case .open: depth += 1; pendingKey = nil
            case .close: depth -= 1
            }
        }
        return nil
    }

    /// Returns text with apps/<appID>/LaunchOptions set to value (block created if needed).
    static func settingLaunchOptions(in text: String, appID: String, value: String) -> String? {
        let line = "\"LaunchOptions\"\t\t\"\(escape(value))\""
        guard let appsBody = body(after: "apps", in: text, from: text.startIndex) else { return nil }
        var result = text
        if let app = childBody(named: appID, in: text, within: appsBody) {
            // Replace an existing direct LaunchOptions pair, else insert at the top.
            var depth = 0
            var pending: (String, Range<String.Index>)?
            scan: for t in tokens(text, from: app.lowerBound) {
                switch t {
                case .string(let v, let r):
                    if r.lowerBound >= app.upperBound { break scan }
                    guard depth == 0 else { continue }
                    if let p = pending {
                        if p.0 == "LaunchOptions" {
                            result.replaceSubrange(p.1.lowerBound..<r.upperBound, with: line)
                            return result
                        }
                        pending = nil
                    } else {
                        pending = (v, r)
                    }
                case .open(let idx):
                    if idx >= app.upperBound { break scan }
                    depth += 1
                    pending = nil
                case .close(let idx):
                    if idx >= app.upperBound { break scan }
                    depth -= 1
                }
            }
            result.insert(contentsOf: "\n\t\t\t\t\t\t" + line, at: app.lowerBound)
        } else {
            result.insert(contentsOf: "\n\t\t\t\t\t\"\(appID)\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\(line)\n\t\t\t\t\t}", at: appsBody.lowerBound)
        }
        return result
    }
}
