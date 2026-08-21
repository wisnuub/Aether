import Foundation

enum GPTKManager {
    private static let appSupport = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/Wine")

    // MARK: - Stable (Gcenx x86_64 + Rosetta) build

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
    static let gptkRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/GPTK")

    /// GPTK ships wine64 only (no 32-bit loader).
    static var gptkWinePath: URL? {
        let p = gptkRoot.appendingPathComponent("Contents/Resources/wine/bin/wine64")
        return FileManager.default.isExecutableFile(atPath: p.path) ? p : nil
    }

    static var isGPTKInstalled: Bool { gptkWinePath != nil }

    // MARK: - ARM64 + FEX build

    /// Root for ARM64-native Wine (Gcenx ARM64 builds or CrossOver 27 Wine extracted here).
    static let arm64Root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/Wine-ARM64")

    /// CrossOver 27 ships ARM64-native Wine at these paths.
    private static let crossOver27Candidates: [String] = [
        NSHomeDirectory() + "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/wine/bin/wine64",
        "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/wine/bin/wine64",
    ]

    /// Returns true if the Mach-O binary at `path` is ARM64-native (not x86_64 / Rosetta).
    static func isARM64Binary(at path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        task.arguments     = [path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // ARM64-native binary: "arm64" appears and "x86_64" does not
        return out.contains("arm64") && !out.contains("x86_64")
    }

    /// Bundled ARM64 Wine from the Aether/Wine-ARM64 directory (manual install or future auto-download).
    private static var arm64BundledPath: URL? {
        let candidates = [
            arm64Root.appendingPathComponent("Contents/Resources/wine/bin/wine64"),
            arm64Root.appendingPathComponent("bin/wine64"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// ARM64 Wine binary: bundled install first, then CrossOver 27 if its binary is ARM64-native.
    /// Falls back to nil if nothing ARM64 is found (caller should fall back to stable).
    static var arm64WinePath: URL? {
        // 1. Prefer our own managed install directory
        if let bundled = arm64BundledPath { return bundled }
        // 2. CrossOver 27 ARM64 preview, detected by checking the binary architecture
        for path in crossOver27Candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if isARM64Binary(at: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var isARM64WineInstalled: Bool { arm64WinePath != nil }

    // MARK: - Dispatch

    /// Wine binary for the given per-game build choice.
    /// Falls back to stable if the requested build is not installed.
    static func winePath(for build: GameConfig.WineBuild) -> URL? {
        switch build {
        case .stable: return winePath
        case .gptk:   return gptkWinePath ?? winePath
        case .arm64:  return arm64WinePath ?? winePath
        }
    }

    // MARK: - Environment

    static func baseEnvironment(for bottle: Bottle,
                                build: GameConfig.WineBuild = .stable) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"]          = bottle.path.path
        env["WINEDEBUG"]           = "-all"
        env["WINE_CROSSOVER_HACK"] = "1"
        env["WINEESYNC"]           = "1"
        env["STEAM_RUNTIME"]       = "0"

        // Default WINEDLLOVERRIDES used for wineboot, installers, and other utility
        // processes. launchSteam() overrides this per-game via dllOverrides().
        let baseOverrides = "steamservice=d;winemenubuilder.exe=d;dxgi=b;d3d11=b;d3d10core=b;d3d9=b;dcomp=n"
        env["WINEDLLOVERRIDES"] = baseOverrides

        // Each build ships a different lib directory. Mixing them loads the wrong
        // dylibs (e.g. stable's libMoltenVK wrapper vs GPTK's D3DMetal shims).
        switch build {
        case .arm64:
            // ARM64-native Wine + FEX: D3DMetal handles all DX versions via DXMT.
            // No MoltenVK layer is present or needed in this build.
            // FEX is an internal Wine component; FEX_DISABLEAVXI disables AVX
            // emulation because Apple Silicon has no SVE2 for 256-bit ASIMD vectors.
            env["FEX_DISABLEAVXI"] = "1"
            let libPath = arm64Root.appendingPathComponent("Contents/Resources/wine/lib").path
            if FileManager.default.fileExists(atPath: libPath) {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
            }

        case .gptk:
            // GPTK: D3DMetal via Apple's shims. No MoltenVK.
            let libPath = gptkRoot.appendingPathComponent("Contents/Resources/wine/lib").path
            if FileManager.default.fileExists(atPath: libPath) {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
            }

        case .stable:
            // Stable: WineD3D or DXVK with MoltenVK wrapper.
            // MoltenVK debug logging captured via:
            //   sudo log stream --predicate 'subsystem contains "moltenVK"' --level debug
            env["MVK_CONFIG_LOG_LEVEL"] = "3"
            let libPath = appSupport.appendingPathComponent("Contents/Resources/wine/lib").path
            if FileManager.default.fileExists(atPath: libPath) {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = libPath
            }
        }

        return env
    }
}
