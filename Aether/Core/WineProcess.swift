import Foundation

enum ProcessOutput {
    case stdout(String)
    case stderr(String)
    case exit(Int32)
}

enum WineError: Error, LocalizedError {
    case wineBinaryNotFound
    case processFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .wineBinaryNotFound:
            return "GPTK Wine binary not found. Please install Game Porting Toolkit via Homebrew."
        case .processFailed(let code):
            return "Wine process exited with code \(code)"
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
        process.standardError = stderrPipe

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

    // Build WINEDLLOVERRIDES from renderer + DX version so per-game config is
    // automatic, no manual env var hacks needed in Extra Env Vars.
    static func dllOverrides(renderer: GameConfig.Renderer,
                             dxVersion: GameConfig.DXVersion,
                             useDDrawWrapper: Bool = false,
                             enableDComp: Bool = false) -> String {
        let dcomp = enableDComp ? "" : ";dcomp=n"
        let fixed = "steamservice=d;winemenubuilder.exe=d\(dcomp)"
        // Steam's GameOverlayRenderer.dll/.dll64 are replaced with no-op stubs directly
        // in the bottle's Steam directory. Wine's =b builtin override doesn't work for
        // MinGW-compiled DLLs (Wine rejects them as "not a builtin"). Replacing the file
        // directly ensures the stub is always loaded regardless of WINEDLLOVERRIDES.
        let ddraw = useDDrawWrapper ? ";ddraw=n,b" : ""
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

    static func launchSteam(
        bottle: Bottle,
        gameID: Int? = nil,
        config: GameConfig,
        installDir: String? = nil
    ) throws {
        // GPTK has no Vulkan driver (winevulkan.dll but no libMoltenVK), so DXVK
        // and MoltenVK renderers cannot work under it. Coerce to D3DMetal builtins.
        let renderer: GameConfig.Renderer =
            config.wineBuild == .gptk ? .auto : config.renderer
        var env = GPTKManager.baseEnvironment(for: bottle, build: config.wineBuild)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: renderer,
                                               dxVersion: config.dxVersion,
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
        // own GPU compositor thread (which runs inline under single-process)
        // fighting the Vulkan/Metal path used by actual games. This only
        // affects Steam's own UI smoothness, games launch in their own
        // separate Wine process untouched by this.
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

        // When launching a specific game, kill any running Steam/Wine processes first.
        // The auto-launched Steam has a generic WINEDLLOVERRIDES; if we reuse it via
        // Steam's single-instance IPC, the game inherits the wrong env and per-game
        // DLL overrides (e.g. ddraw=n,b for cnc-ddraw) never apply.
        if gameID != nil && steamIsAlreadyRunning() {
            killWineProcesses()
            Thread.sleep(forTimeInterval: 1.5)
        }

        guard let winePath = GPTKManager.winePath(for: config.wineBuild) else {
            throw WineError.wineBinaryNotFound
        }

        // Direct-exe path: bypasses Steam's launcher (which silently fails for some games).
        // Steam is started in the background first so steam_api.dll DRM can connect.
        if let installDir, !config.customExePath.isEmpty {
            let exeURL = bottle.steamLibraryPath
                .appendingPathComponent("common/\(installDir)/\(config.customExePath)")
            let extraArgs = config.launchArgs.isEmpty
                ? []
                : config.launchArgs.split(separator: " ").map(String.init)

            if !steamIsAlreadyRunning() {
                let bgSteam = Process()
                bgSteam.executableURL = winePath
                bgSteam.arguments    = [bottle.steamExePath.path,
                                        "-no-cef-sandbox", "-noverifyfiles"]
                bgSteam.environment  = env
                try bgSteam.run()
                // steamwebhelper args contain "-steamid=0" until Steam finishes login.
                // A non-zero steamid means the IPC pipe is live and SteamAPI_Init will succeed.
                waitForSteamLogin(timeout: 60)
            } else {
                Thread.sleep(forTimeInterval: 1.0)
            }

            // Prevent SteamAPI_RestartAppIfNecessary from requesting a Steam relaunch.
            // Without these env vars, old Steamworks SDKs see Steam running + no SteamAppId,
            // assume they weren't launched by Steam, and exit to ask Steam to relaunch them --
            // which shows "Stop" in Steam but no window, since Steam's own launch fails too.
            if let gameID {
                env["SteamAppId"]  = "\(gameID)"
                env["SteamGameId"] = "\(gameID)"
            }

            let game = Process()
            game.executableURL    = winePath
            game.arguments        = [exeURL.path] + extraArgs
            game.environment      = env
            game.currentDirectoryURL = exeURL.deletingLastPathComponent()
            try game.run()
            return
        }

        let process = Process()
        process.executableURL = winePath

        // Always use Steam.exe -applaunch: Steam handles single-instance IPC itself.
        // wine explorer.exe steam://rungameid/<id> fails in Wine (explorer can't route
        // the steam:// protocol -- produces "Failed to create PIDL" and game never starts).
        var args = [bottle.steamExePath.path, "-no-cef-sandbox", "-forcedesktopscaling", "1", "-noverifyfiles"]
        if let gameID { args += ["-applaunch", "\(gameID)"] }
        if !config.launchArgs.isEmpty {
            args += config.launchArgs.split(separator: " ").map(String.init)
        }

        process.arguments = args
        process.environment = env

        try process.run()
    }

    /// Open a Wine desktop environment (Wine explorer).
    static func launchDesktop(bottle: Bottle) throws {
        guard let winePath = GPTKManager.winePath else { throw WineError.wineBinaryNotFound }
        var env = GPTKManager.baseEnvironment(for: bottle)
        env["WINEDLLOVERRIDES"] = "steamservice=d;winemenubuilder.exe=d"
        let process = Process()
        process.executableURL = winePath
        process.arguments = ["explorer.exe", "/desktop=Wine,1280x800"]
        process.environment = env
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
        process.environment = env
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
            throw WineError.wineBinaryNotFound
        }
        // Same coercion as launchSteam: GPTK has no Vulkan driver.
        let renderer: GameConfig.Renderer =
            config.wineBuild == .gptk ? .auto : config.renderer
        var env = GPTKManager.baseEnvironment(for: bottle, build: config.wineBuild)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: renderer,
                                               dxVersion: config.dxVersion,
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
        process.executableURL    = winePath
        process.arguments        = args
        process.environment      = env
        process.currentDirectoryURL = exeURL.deletingLastPathComponent()
        try process.run()
    }

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

        // GPTK tests run in their own throwaway prefix: pointing an older Wine
        // (GPTK base) at the main bottle would downgrade its prefix version.
        // Wine auto-creates the prefix on first run (adds ~30s once).
        let testBottle: Bottle
        if build == .gptk {
            let prefix = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Aether/TestPrefixes/gptk")
            try? FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            testBottle = Bottle(path: prefix)
        } else {
            testBottle = bottle
        }

        // GPTK has no Vulkan driver, so only the D3DMetal builtins are testable.
        let effectiveRenderer: GameConfig.Renderer = build == .gptk ? .auto : renderer

        var env = GPTKManager.baseEnvironment(for: testBottle, build: build)
        env["WINEDLLOVERRIDES"] = dllOverrides(renderer: effectiveRenderer, dxVersion: dxVersion)
        env["DXVK_LOG_LEVEL"]   = "none"

        let process = Process()
        process.executableURL    = winePath
        process.arguments        = [exePath.path, effectiveRenderer.rawValue, dxVersion.apiArg]
        process.environment      = env
        process.currentDirectoryURL = toolsDir
        try process.run()
        return process
    }

    static func killWineProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c",
            "ps aux | grep -E 'wine|[Ss]team|wineserver|popcap|PlantsVs' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null; true"
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    private static func steamIsAlreadyRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "Steam.exe"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func waitForSteamLogin(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-a", "-f", "steamwebhelper"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            // steamwebhelper args contain "-steamid=0" until login completes
            if output.contains("steamid=") && !output.contains("steamid=0") { return }
            Thread.sleep(forTimeInterval: 2.0)
        }
    }
}
