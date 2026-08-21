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

    var errorDescription: String? {
        switch self {
        case .wineBinaryNotFound:
            return "Wine binary not found. Please complete setup or install Wine via Homebrew."
        case .processFailed(let code):
            return "Wine process exited with code \(code)"
        case .arm64WineNotFound:
            return "ARM64 Wine not found. Download it in Setup, or install CrossOver 27 preview — Aether will detect it automatically."
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

    static func launchSteam(
        bottle: Bottle,
        gameID: Int? = nil,
        config: GameConfig,
        installDir: String? = nil
    ) async throws {
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

        // When launching a specific game, kill any running Steam/Wine processes first.
        // The auto-launched Steam has a generic WINEDLLOVERRIDES; if we reuse it via
        // Steam's single-instance IPC, the game inherits the wrong env and per-game
        // DLL overrides (e.g. ddraw=n,b for cnc-ddraw) never apply.
        if gameID != nil && steamIsAlreadyRunning() {
            killWineProcesses()
            try await Task.sleep(for: .seconds(1.5))
        }

        guard let winePath = GPTKManager.winePath(for: config.wineBuild) else {
            throw config.wineBuild == .arm64 ? WineError.arm64WineNotFound : WineError.wineBinaryNotFound
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
                bgSteam.arguments     = [bottle.steamExePath.path,
                                         "-no-cef-sandbox", "-noverifyfiles"]
                bgSteam.environment   = env
                try bgSteam.run()
                // steamwebhelper args contain "-steamid=0" until Steam finishes login.
                // A non-zero steamid means the IPC pipe is live and SteamAPI_Init will succeed.
                await waitForSteamLogin(timeout: 60)
            } else {
                try await Task.sleep(for: .seconds(1.0))
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
            game.executableURL       = winePath
            game.arguments           = [exeURL.path] + extraArgs
            game.environment         = env
            game.currentDirectoryURL = exeURL.deletingLastPathComponent()
            try game.run()
            return
        }

        let process = Process()
        process.executableURL = winePath

        // Always use Steam.exe -applaunch: Steam handles single-instance IPC itself.
        // wine explorer.exe steam://rungameid/<id> fails in Wine (explorer can't route
        // the steam:// protocol -- produces "Failed to create PIDL" and game never starts).
        var args = [bottle.steamExePath.path,
                    "-no-cef-sandbox", "-forcedesktopscaling", "1", "-noverifyfiles"]
        if let gameID { args += ["-applaunch", "\(gameID)"] }
        if !config.launchArgs.isEmpty {
            args += config.launchArgs.split(separator: " ").map(String.init)
        }

        process.arguments   = args
        process.environment = env

        try process.run()
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

    /// Kill all Wine and Steam processes. Scoped to generic infrastructure names
    /// only — game-specific process names belong in per-game config, not here.
    @discardableResult
    static func killWineProcesses() {
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

    /// Polls steamwebhelper until the steamid is non-zero (login complete) or timeout.
    /// Uses cooperative Task.sleep — safe to call from async context without blocking.
    private static func waitForSteamLogin(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments     = ["-a", "-f", "steamwebhelper"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError  = Pipe()
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            // steamwebhelper args contain "-steamid=0" until login completes
            if output.contains("steamid=") && !output.contains("steamid=0") { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
