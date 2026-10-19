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
    ]

    static var winePath: URL? {
        searchPaths.compactMap { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { winePath != nil }

    /// Gcenx release tag Aether installs for the stable build. Pinned so the
    /// patched DLLs in WinePatches/ always match the installed Wine.
    static let stableWineVersion = "11.10"

    /// CFBundleShortVersionString of the installed stable Wine bundle (e.g. "11.10").
    static var installedStableWineVersion: String? {
        let plist = appSupport.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    // MARK: - Wine patches

    /// Install the patched builtin DLLs from the app bundle's WinePatches/wine-<version>/
    /// into the stable Wine install, and into the bottle's system32 when given.
    ///
    /// Currently this is CW HACK 20760 (wow64cpu.dll): CrossOver's Rosetta 2 fix for the
    /// 32-to-64-bit mode switch. Without it, 32-bit games (e.g. Plants vs. Zombies) crash
    /// in wow64cpu shortly after start. See WinePatches/README.md.
    ///
    /// Idempotent: files are only copied when their contents differ. The first time a
    /// file is replaced, the original is kept next to it as <name>.orig.
    @discardableResult
    static func applyWinePatches(bottle: Bottle? = nil) -> [String] {
        guard let version = installedStableWineVersion,
              let patchRoot = Bundle.main.resourceURL?
                .appendingPathComponent("WinePatches/wine-\(version)"),
              FileManager.default.fileExists(atPath: patchRoot.path)
        else { return [] }

        let fm = FileManager.default
        let wineLib = appSupport.appendingPathComponent("Contents/Resources/wine/lib/wine")
        var applied: [String] = []

        // wine-<version>/<arch-dir>/<file>, mirroring lib/wine/<arch-dir>/<file>.
        let archDirs = (try? fm.contentsOfDirectory(atPath: patchRoot.path)) ?? []
        for arch in archDirs {
            let srcDir = patchRoot.appendingPathComponent(arch)
            let files = (try? fm.contentsOfDirectory(atPath: srcDir.path)) ?? []
            for name in files where name.lowercased().hasSuffix(".dll") {
                let src = srcDir.appendingPathComponent(name)
                var targets = [wineLib.appendingPathComponent(arch).appendingPathComponent(name)]
                // Prefix copies of 64-bit builtins live in system32.
                if let bottle, arch == "x86_64-windows" {
                    targets.append(bottle.driveCPath
                        .appendingPathComponent("windows/system32").appendingPathComponent(name))
                }
                for dst in targets where fm.fileExists(atPath: dst.path) {
                    if fm.contentsEqual(atPath: src.path, andPath: dst.path) { continue }
                    let orig = dst.appendingPathExtension("orig")
                    if !fm.fileExists(atPath: orig.path) { try? fm.copyItem(at: dst, to: orig) }
                    try? fm.removeItem(at: dst)
                    if (try? fm.copyItem(at: src, to: dst)) != nil { applied.append(dst.path) }
                }
            }
        }
        return applied
    }

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

    /// Root for Aether's own ARM64-native Wine install.
    /// Downloaded and managed entirely by Aether — no external dependency.
    static let arm64Root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Aether/Wine-ARM64")

    /// ARM64 Wine binary from Aether's own managed install directory.
    /// Returns nil if not yet downloaded — call BottleManager.downloadARM64Wine() to install.
    static var arm64WinePath: URL? {
        let candidates = [
            arm64Root.appendingPathComponent("Contents/Resources/wine/bin/wine64"),
            arm64Root.appendingPathComponent("bin/wine64"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
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
