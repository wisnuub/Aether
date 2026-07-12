import Foundation

enum GPTKManager {
    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/Wine")

    // Gcenx builds extract as an app bundle: Wine.app/Contents/Resources/wine/bin/wine
    private static let bundledWinePaths: [String] = [
        appSupport.appendingPathComponent("Contents/Resources/wine/bin/wine64").path,
        appSupport.appendingPathComponent("Contents/Resources/wine/bin/wine").path,
        appSupport.appendingPathComponent("bin/wine64").path,
        appSupport.appendingPathComponent("bin/wine").path,
    ]

    static let searchPaths: [String] = bundledWinePaths + [
        "/usr/local/bin/wine64",
        "/usr/local/bin/wine",
        "/opt/homebrew/bin/wine64",
        NSHomeDirectory() + "/.local/share/CrossOver/wine/bin/wine64",
    ]

    static var winePath: URL? {
        searchPaths.compactMap { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { winePath != nil }

    // MARK: - GPTK (Game Porting Toolkit / D3DMetal) build

    /// Root of the Gcenx GPTK bundle, extracted with the same layout as Wine/.
    private static let gptkRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/GPTK")

    /// GPTK ships wine64 only (no 32-bit loader).
    static var gptkWinePath: URL? {
        let p = gptkRoot.appendingPathComponent("Contents/Resources/wine/bin/wine64")
        return FileManager.default.isExecutableFile(atPath: p.path) ? p : nil
    }

    static var isGPTKInstalled: Bool { gptkWinePath != nil }

    /// Wine binary for the given per-game build choice. Falls back to the
    /// stable build if GPTK is selected but not installed.
    static func winePath(for build: GameConfig.WineBuild) -> URL? {
        build == .gptk ? (gptkWinePath ?? winePath) : winePath
    }

    static func baseEnvironment(for bottle: Bottle,
                                build: GameConfig.WineBuild = .stable) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = bottle.path.path
        env["WINEDEBUG"] = "-all"
        env["WINE_CROSSOVER_HACK"] = "1"
        env["WINEESYNC"] = "1"
        // Default to builtin D3D dlls. On stable Wine these are WineD3D; on the
        // GPTK build the same builtins are Apple's D3DMetal shims. Game launches
        // override this with per-config dllOverrides(); this default covers
        // wineboot, installers, and other utility processes.
        env["WINEDLLOVERRIDES"] = "steamservice=d;winemenubuilder.exe=d;dxgi=b;d3d11=b;d3d10core=b;d3d9=b;dcomp=n"
        env["STEAM_RUNTIME"] = "0"
        // MoltenVK debug logging to os_log, capture with:
        // sudo log stream --predicate 'subsystem contains "moltenVK"' --level debug
        // Stable build only: GPTK has no MoltenVK (D3DMetal talks to Metal directly).
        if build == .stable {
            env["MVK_CONFIG_LOG_LEVEL"] = "3"
        }

        // Each build must see its own lib dir: stable carries our patched
        // libMoltenVK wrapper; GPTK carries libd3dshared + D3DMetal.framework.
        // Mixing them loads the wrong dylibs and breaks rendering.
        let libRoot = build == .gptk ? gptkRoot : appSupport
        let libPath = libRoot.appendingPathComponent("Contents/Resources/wine/lib").path
        if FileManager.default.fileExists(atPath: libPath) {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
        }
        return env
    }
}
