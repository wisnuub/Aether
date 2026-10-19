import Foundation

enum ProcessOutput {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

enum WineError: Error, LocalizedError {
    case wineBinaryNotFound
    case processFailed(Int32)
    case arm64WineNotFound
    case steamLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .wineBinaryNotFound:
            return "Wine binary not found. Please complete setup or install Wine via Homebrew."
        case .processFailed(let code):
            return "Wine process exited with code \(code)"
        case .arm64WineNotFound:
            return "ARM64 Wine not found. Download it in Setup, or install CrossOver 27 preview — Aether will detect it automatically."
        case .steamLaunchFailed(let reason):
            return "Steam could not start the game: \(reason)"
        }
    }
}

struct WineProcess {
    static func run(
        args: [String],
        environment: [String: String],
        workingDirectory: URL? = nil
    ) throws -> AsyncStream<ProcessOutput> {
        guard let winePath = GPTKManager.winePath else {
            throw WineError.wineBinaryNotFound
        }

        let process = Process()
        process.executableURL = winePath
        process.arguments = args
        process.environment = environment
        if let wd = workingDirectory { process.currentDirectoryURL = wd }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        try process.run()

        return AsyncStream { continuation in
            Task {
                async let readStdout: Void = {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        continuation.yield(.stdout(line))
                    }
                }()
                async let readStderr: Void = {
                    for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                        continuation.yield(.stderr(line))
                    }
                }()
                _ = try? await (readStdout, readStderr)
                continuation.yield(.exit(process.terminationStatus))
                continuation.finish()
            }
        }
    }

    static func runWineboot(bottle: Bottle) async throws {
        let env = GPTKManager.baseEnvironment(for: bottle)
        let stream = try WineProcess.run(args: ["wineboot", "--init"], environment: env)
        for await event in stream {
            if case .exit(let code) = event, code != 0 {
                throw WineError.processFailed(code)
            }
        }
    }

    // MARK: - DLL Overrides

    // Build WINEDLLOVERRIDES from renderer + DX version so per-game config is
    // automatic. ARM64 and GPTK both use D3DMetal builtins — DXVK and MoltenVK
    // have no Vulkan driver to back them in those builds.
    static func dllOverrides(renderer: GameConfig.Renderer,
                             dxVersion: GameConfig.DXVersion,
                             build: GameConfig.WineBuild = .stable,
                             useDDrawWrapper: Bool = false,
                             enableDComp: Bool = false) -> String {
        let dcomp  = enableDComp ? "" : ";dcomp=n"
        let fixed  = "steamservice=d;winemenubuilder.exe=d\(dcomp)"
        // Steam's GameOverlayRenderer.dll/.dll64 are replaced with no-op stubs
        // directly in the bottle's Steam directory. Wine's =b builtin override
        // doesn't work for MinGW-compiled DLLs (Wine rejects them as "not a
        // builtin"). Replacing the file directly ensures the stub is always
        // loaded regardless of WINEDLLOVERRIDES.
        let ddraw  = useDDrawWrapper ? ";ddraw=n,b" : ""

        // ARM64 and GPTK: D3DMetal builtins handle all DX versions. DXVK and
        // MoltenVK cannot be used (no Vulkan driver in either build).
        if build.usesD3DMetal {
            return "\(fixed);dxgi=b;d3d11=b;d3d10core=b;d3d9=b\(ddraw)"
        }

        // Stable Wine: respect the per-game renderer choice.
        switch renderer {
        case .auto, .moltenVK:
            return "\(fixed);dxgi=b;d3d11=b;d3d10core=b;d3d9=b\(ddraw)"
        case .dxvk:
            switch dxVersion {
            case .dx9:
                return "\(fixed);dxgi=n,b;d3d9=n,b;d3d11=b;d3d10core=b\(ddraw)"
            case .dx10:
                return "\(fixed);dxgi=n,b;d3d10core=n,b;d3d11=n,b;d3d9=b\(ddraw)"
            case .dx11:
                return "\(fixed);dxgi=n,b;d3d11=n,b;d3d10core=n,b;d3d9=b\(ddraw)"
            case .dx12:
                return "\(fixed);dxgi=n,b;d3d12=n,b;d3d11=b;d3d10core=b;d3d9=b\(ddraw)"
            }
        }
    }

    // MARK: - Steam launch

    /// Identifies the environment the Aether-started Steam is running with. Games are
    /// child processes of Steam and inherit its environment, so a game whose per-game
    /// settings (DLL overrides, HUD, extra env) differ needs Steam restarted first.
    private static var runningSteamEnvKey: String?

    private static func steamEnvKey(_ env: [String: String], winePath: URL) -> String {
        let keys = ["WINEDLLOVERRIDES", "DXVK_HUD", "MTL_HUD_ENABLED", "WINEESYNC", "AETHER_CEF_FLAGS"]
        var parts = [winePath.path] + keys.map { "\($0)=\(env[$0] ?? "")" }
        let base = ProcessInfo.processInfo.environment
        parts += env.filter { base[$0.key] != $0.value && !keys.contains($0.key) }
                    .map { "\($0.key)=\($0.value)" }.sorted()
        return parts.joined(separator: "\n")
    }

    static func launchSteam(
        bottle: Bottle,
        gameID: Int? = nil,
        config: GameConfig,
        installDir: String? = nil
    ) async throws {
        // CW HACK 20760 and any other version-matched Wine fixes. Cheap no-op when current.
        GPTKManager.applyWinePatches(bottle: bottle)

        // ARM64 and GPTK both use D3DMetal builtins; DXVK/MoltenVK cannot work
        // in either build (no Vulkan driver). Coerce renderer to .auto so
        // dllOverrides() emits the right builtin set.
        let renderer: GameConfig.Renderer = config.wineBuild.usesD3DMetal ? .auto : config.renderer

        var env = GPTKManager.baseEnvironment(for: bottle, build: config.wineBuild)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: renderer,
                                               dxVersion: config.dxVersion,
                                               build: config.wineBuild,
                                               useDDrawWrapper: config.useDDrawWrapper,
                                               enableDComp: config.enableDComp)

        // Steam's CEF spawns separate renderer/GPU/utility OS processes, each
        // owning native windows that Wine's macOS driver has to composite
        // together. That cross-process window handoff is where a hide/show
        // race lives: macOS window-server occlusion notifications get
        // translated back into WM_SHOWWINDOW messages that Steam's own UI
        // reacts to by re-hiding, producing rapid visible flicker. Folding
        // everything into one process (--single-process) removes the
        // cross-process window state entirely; --disable-gpu avoids Steam's
        // own GPU compositor thread fighting the Vulkan/Metal path used by
        // actual games. This only affects Steam's own UI smoothness; games
        // launch in their own separate Wine process untouched by this.
        env["AETHER_CEF_FLAGS"] = "--disable-gpu --single-process"

        if config.metalHUD {
            switch renderer {
            case .dxvk:
                env["DXVK_HUD"] = "fps,frametimes,gpuload"
            default:
                env["MTL_HUD_ENABLED"] = "1"
            }
        }
        if config.esync { env["WINEESYNC"] = "1" }
        for (k, v) in config.extraEnvVars { env[k] = v }

        guard let winePath = GPTKManager.winePath(for: config.wineBuild) else {
            throw config.wineBuild == .arm64 ? WineError.arm64WineNotFound : WineError.wineBinaryNotFound
        }

        // 1. Make sure Steam is running with this game's environment.
        //
        // Steam is never cold-started with -applaunch: Steam fails the first launch
        // of a session with AppError_49 ("Corrupt file signature") under Wine, and a
        // cold start makes that first launch the game's. Instead Steam starts plain,
        // logs in, and the game is sent over Steam's single-instance IPC below.
        let envKey = steamEnvKey(env, winePath: winePath)
        if gameID != nil && steamIsAlreadyRunning() && runningSteamEnvKey != envKey {
            killWineProcesses(bottle: bottle)
            try await Task.sleep(for: .seconds(1.5))
        }
        if !steamIsAlreadyRunning() {
            let loginLogOffset = fileSize(steamLog(bottle, "connection_log.txt"))
            try runSteamExe(bottle: bottle, winePath: winePath, env: env,
                            args: ["-no-cef-sandbox", "-forcedesktopscaling", "1", "-noverifyfiles"])
            runningSteamEnvKey = envKey
            guard gameID != nil else { return }
            await waitForSteamLogin(bottle: bottle, since: loginLogOffset, timeout: 120)
        } else if gameID == nil {
            // Already running: Steam.exe forwards to the running instance and shows its window.
            try runSteamExe(bottle: bottle, winePath: winePath, env: env, args: [])
            return
        }
        guard let gameID else { return }

        // Direct-exe path: bypasses Steam's launcher (which silently fails for some games).
        // Steam is already running and logged in, so steam_api.dll DRM can connect.
        if let installDir, !config.customExePath.isEmpty {
            let exeURL = bottle.steamLibraryPath
                .appendingPathComponent("common/\(installDir)/\(config.customExePath)")
            let extraArgs = config.launchArgs.isEmpty
                ? []
                : config.launchArgs.split(separator: " ").map(String.init)

            // Prevent SteamAPI_RestartAppIfNecessary from requesting a Steam relaunch.
            // Without these env vars, old Steamworks SDKs see Steam running + no SteamAppId,
            // assume they weren't launched by Steam, and exit to ask Steam to relaunch them --
            // which shows "Stop" in Steam but no window, since Steam's own launch fails too.
            env["SteamAppId"]  = "\(gameID)"
            env["SteamGameId"] = "\(gameID)"

            let game = Process()
            game.executableURL       = winePath
            game.arguments           = [exeURL.path] + extraArgs
            game.environment         = env
            game.currentDirectoryURL = exeURL.deletingLastPathComponent()
            try game.run()
            return
        }

        // 2. Ask the running Steam to launch the game, retrying the signature error.
        //
        // Always Steam.exe -applaunch: wine explorer.exe steam://rungameid/<id> fails in
        // Wine (explorer can't route the steam:// protocol -- produces "Failed to create
        // PIDL" and the game never starts).
        var args = ["-applaunch", "\(gameID)"]
        if !config.launchArgs.isEmpty {
            args += config.launchArgs.split(separator: " ").map(String.init)
        }

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let consoleOffset = fileSize(steamLog(bottle, "console_log.txt"))
            try runSteamExe(bottle: bottle, winePath: winePath, env: env, args: args)
            switch await waitForLaunchResult(bottle: bottle, gameID: gameID,
                                             since: consoleOffset, timeout: 90) {
            case .started, .timedOut:
                return
            case .signatureError where attempt < maxAttempts:
                try await Task.sleep(for: .seconds(2))
                continue
            case .signatureError:
                throw WineError.steamLaunchFailed("AppError_49 (corrupt file signature)")
            case .failed(let reason):
                throw WineError.steamLaunchFailed(reason)
            }
        }
    }

    private static func runSteamExe(bottle: Bottle, winePath: URL,
                                    env: [String: String], args: [String]) throws {
        let process = Process()
        process.executableURL = winePath
        process.arguments     = [bottle.steamExePath.path] + args
        process.environment   = env
        try process.run()
    }

    // MARK: - Steam log watching

    private enum LaunchResult { case started, signatureError, failed(String), timedOut }

    private static func steamLog(_ bottle: Bottle, _ name: String) -> URL {
        bottle.steamPath.appendingPathComponent("logs/\(name)")
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// Text appended to a log since `offset`. Restarts from 0 if Steam rotated the file.
    private static func appendedText(_ url: URL, since offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let start = fileSize(url) < offset ? 0 : offset
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads Steam's console_log.txt for the outcome of the -applaunch just sent.
    private static func waitForLaunchResult(bottle: Bottle, gameID: Int,
                                            since offset: UInt64,
                                            timeout: TimeInterval) async -> LaunchResult {
        let log = steamLog(bottle, "console_log.txt")
        let tag = "[AppID \(gameID), ActionID"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for line in appendedText(log, since: offset).split(separator: "\n") {
                if line.contains("Game process added : AppID \(gameID) ") { return .started }
                guard line.contains(tag) else { continue }
                if line.contains("LaunchApp failed with AppError_49") { return .signatureError }
                if let r = line.range(of: "LaunchApp failed with ") {
                    return .failed(String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
                if line.contains("LaunchApp changed task to Completed") { return .started }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .timedOut
    }

    // MARK: - Desktop / installer / custom exe

    /// Open a Wine desktop environment (Wine explorer).
    static func launchDesktop(bottle: Bottle) throws {
        guard let winePath = GPTKManager.winePath else { throw WineError.wineBinaryNotFound }
        var env = GPTKManager.baseEnvironment(for: bottle)
        env["WINEDLLOVERRIDES"] = "steamservice=d;winemenubuilder.exe=d"
        let process = Process()
        process.executableURL = winePath
        process.arguments     = ["explorer.exe", "/desktop=Wine,1280x800"]
        process.environment   = env
        try process.run()
    }

    /// Run a Windows installer (.exe or .msi) via Wine.
    static func launchInstaller(bottle: Bottle, path: String) throws {
        guard let winePath = GPTKManager.winePath else { throw WineError.wineBinaryNotFound }
        var env = GPTKManager.baseEnvironment(for: bottle)
        env["WINEDLLOVERRIDES"] = "steamservice=d;winemenubuilder.exe=d"
        let exeURL = URL(fileURLWithPath: path)
        let process = Process()
        process.executableURL = winePath
        if exeURL.pathExtension.lowercased() == "msi" {
            process.arguments = ["msiexec", "/i", exeURL.path]
        } else {
            process.arguments = [exeURL.path]
        }
        process.environment      = env
        process.currentDirectoryURL = exeURL.deletingLastPathComponent()
        try process.run()
    }

    /// Launch a non-Steam Windows EXE directly under Wine (no Steam required).
    static func launchCustomExe(
        bottle: Bottle,
        exePath: String,
        config: GameConfig
    ) throws {
        guard let winePath = GPTKManager.winePath(for: config.wineBuild) else {
            throw config.wineBuild == .arm64 ? WineError.arm64WineNotFound : WineError.wineBinaryNotFound
        }
        let renderer: GameConfig.Renderer = config.wineBuild.usesD3DMetal ? .auto : config.renderer
        var env = GPTKManager.baseEnvironment(for: bottle, build: config.wineBuild)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: renderer,
                                               dxVersion: config.dxVersion,
                                               build: config.wineBuild,
                                               useDDrawWrapper: config.useDDrawWrapper,
                                               enableDComp: config.enableDComp)
        if config.metalHUD {
            switch renderer {
            case .dxvk: env["DXVK_HUD"] = "fps,frametimes,gpuload"
            default:    env["MTL_HUD_ENABLED"] = "1"
            }
        }
        if config.esync { env["WINEESYNC"] = "1" }
        for (k, v) in config.extraEnvVars { env[k] = v }

        let exeURL = URL(fileURLWithPath: exePath)
        var args = [exeURL.path]
        if !config.launchArgs.isEmpty {
            args += config.launchArgs.split(separator: " ").map(String.init)
        }

        let process = Process()
        process.executableURL       = winePath
        process.arguments           = args
        process.environment         = env
        process.currentDirectoryURL = exeURL.deletingLastPathComponent()
        try process.run()
    }

    // MARK: - Renderer test

    @discardableResult
    static func launchRendererTest(
        bottle: Bottle,
        renderer: GameConfig.Renderer,
        dxVersion: GameConfig.DXVersion,
        build: GameConfig.WineBuild = .stable
    ) throws -> Process {
        guard let winePath = GPTKManager.winePath(for: build) else {
            throw WineError.wineBinaryNotFound
        }

        let toolsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aether/Tools")
        let exePath = toolsDir.appendingPathComponent("AetherDXTest.exe")

        // GPTK and ARM64 tests run in their own throwaway prefix: pointing an older
        // Wine (GPTK base) at the main bottle would downgrade its prefix version.
        let testBottle: Bottle
        if build.usesD3DMetal {
            let prefix = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Aether/TestPrefixes/\(build.rawValue)")
            try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            testBottle = Bottle(path: prefix)
        } else {
            testBottle = bottle
        }

        // D3DMetal builds have no Vulkan driver; only the builtins are testable.
        let effectiveRenderer: GameConfig.Renderer = build.usesD3DMetal ? .auto : renderer

        var env = GPTKManager.baseEnvironment(for: testBottle, build: build)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: effectiveRenderer,
                                               dxVersion: dxVersion,
                                               build: build)
        env["DXVK_LOG_LEVEL"]   = "none"

        let process = Process()
        process.executableURL       = winePath
        process.arguments           = [exePath.path, effectiveRenderer.rawValue, dxVersion.apiArg]
        process.environment         = env
        process.currentDirectoryURL = toolsDir
        try process.run()
        return process
    }

    // MARK: - Process management

    /// Kill all Wine and Steam processes. With a bottle, first asks that prefix's
    /// wineserver to terminate every process in the session (games included, whatever
    /// their exe name). The name-based pass then catches leftovers and orphans.
    @discardableResult
    static func killWineProcesses(bottle: Bottle? = nil) {
        if let bottle {
            // Only the wineserver matching the running Wine version will accept -k;
            // the others fail with a protocol mismatch, which is harmless.
            let servers = [GPTKManager.winePath, GPTKManager.gptkWinePath, GPTKManager.arm64WinePath]
                .compactMap { $0?.deletingLastPathComponent().appendingPathComponent("wineserver") }
                .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
            for server in servers {
                let k = Process()
                k.executableURL  = server
                k.arguments      = ["-k"]
                k.environment    = ["WINEPREFIX": bottle.path.path]
                k.standardOutput = FileHandle.nullDevice
                k.standardError  = FileHandle.nullDevice
                try? k.run()
                k.waitUntilExit()
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "ps aux | grep -E 'wine(64|server|device|boot)?|[Ss]team\\.exe|steamwebhelper|pluginhost' " +
            "| grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null; true"
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    static func steamIsAlreadyRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments     = ["-f", "Steam.exe"]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// Waits until Steam logs a completed logon in connection_log.txt after `offset`,
    /// or until timeout (e.g. the user still has to sign in). Cooperative Task.sleep.
    private static func waitForSteamLogin(bottle: Bottle, since offset: UInt64,
                                          timeout: TimeInterval) async {
        let log = steamLog(bottle, "connection_log.txt")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if appendedText(log, since: offset).contains("RecvMsgClientLogOnResponse() : processing complete") {
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
