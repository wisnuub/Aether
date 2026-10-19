import Foundation

@MainActor
final class BottleManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingWine
        case extractingWine
        case downloadingARM64Wine
        case extractingARM64Wine
        case creatingPrefix
        case downloadingSteam
        case installingSteam
        case steamLogin
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var log: [String] = []
    @Published var downloadProgress: Double = 0

    private let stableInstallDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether/Wine")
    }()

    // MARK: - Full setup

    func createBottleAndInstallSteam(at path: URL) async -> Bottle? {
        if !GPTKManager.isInstalled {
            guard await downloadStableWine() else { return nil }
        }

        let bottle = Bottle(path: path)
        do {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Could not create bottle directory: \(error.localizedDescription)")
            return nil
        }

        phase = .creatingPrefix
        append("Initialising Wine prefix...")
        do {
            try await WineProcess.runWineboot(bottle: bottle)
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
        append("Wine prefix ready.")

        phase = .downloadingSteam
        append("Downloading Steam installer...")
        let steamURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
        let tmpURL   = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SteamSetup.exe")

        do {
            let (data, _) = try await URLSession.shared.data(from: steamURL)
            try data.write(to: tmpURL)
        } catch {
            phase = .failed("Steam download failed: \(error.localizedDescription)")
            return nil
        }
        append("Download complete.")

        phase = .installingSteam
        append("Installing Steam (this may take a minute)...")
        guard let winePath = GPTKManager.winePath else {
            phase = .failed(WineError.wineBinaryNotFound.localizedDescription)
            return nil
        }

        let installer = Process()
        installer.executableURL = winePath
        installer.arguments     = [tmpURL.path, "/S"]
        installer.environment   = GPTKManager.baseEnvironment(for: bottle)
        do { try installer.run() } catch {
            phase = .failed("Failed to launch installer: \(error.localizedDescription)")
            return nil
        }
        await withCheckedContinuation { continuation in
            installer.terminationHandler = { _ in continuation.resume() }
        }

        append("Steam installed. Please sign in.")
        phase = .steamLogin
        try? await WineProcess.launchSteam(bottle: bottle, gameID: nil, config: GameConfig())
        return bottle
    }

    func completeSteamLogin() {
        phase = .done
    }

    // MARK: - ARM64 Wine download

    /// Download the latest ARM64-native Wine build from Gcenx's GitHub releases.
    /// If no ARM64 asset is found, the phase is set to .failed with a clear message.
    func downloadARM64Wine() async -> Bool {
        phase = .downloadingARM64Wine
        append("Fetching ARM64 Wine release info...")

        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]]
        else {
            phase = .failed("Could not reach GitHub API. Check your internet connection.")
            return false
        }

        // Look for an ARM64 / aarch64 asset in the release
        let arm64Asset = assets.first(where: { asset -> Bool in
            guard let name = asset["name"] as? String else { return false }
            let lower = name.lowercased()
            return (lower.contains("arm64") || lower.contains("aarch64")) && lower.hasSuffix(".tar.xz")
        })

        guard let asset = arm64Asset,
              let downloadURLStr = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLStr)
        else {
            phase = .failed(
                "No ARM64 Wine builds available yet from Gcenx.\n\n" +
                "Options:\n" +
                "• Install CrossOver 27 preview — Aether detects its ARM64 Wine automatically.\n" +
                "• Check back later; Gcenx ARM64 builds are in progress.\n" +
                "• Manually place an ARM64 Wine bundle in:\n  ~/Library/Application Support/Aether/Wine-ARM64/"
            )
            return false
        }

        let assetName = asset["name"] as? String ?? "wine-arm64"
        append("Downloading \(assetName)...")

        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(assetName)
        do {
            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
            try? FileManager.default.removeItem(at: tmpFile)
            try FileManager.default.moveItem(at: localURL, to: tmpFile)
        } catch {
            phase = .failed("ARM64 Wine download failed: \(error.localizedDescription)")
            return false
        }

        phase = .extractingARM64Wine
        append("Extracting ARM64 Wine...")
        try? FileManager.default.createDirectory(at: GPTKManager.arm64Root,
                                                 withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments     = ["-xJf", tmpFile.path, "-C", GPTKManager.arm64Root.path,
                             "--strip-components=1"]
        do { try tar.run() } catch {
            phase = .failed("ARM64 Wine extraction failed: \(error.localizedDescription)")
            return false
        }
        await withCheckedContinuation { continuation in
            tar.terminationHandler = { _ in continuation.resume() }
        }

        guard GPTKManager.isARM64WineInstalled else {
            phase = .failed("ARM64 Wine extracted but binary not found. The archive layout may differ.")
            return false
        }

        append("ARM64 Wine ready.")
        return true
    }

    // MARK: - Private helpers

    private func downloadStableWine() async -> Bool {
        phase = .downloadingWine
        append("Fetching Wine release info...")

        // Pinned release: the patched DLLs in WinePatches/ are built for this exact version.
        let tag = GPTKManager.stableWineVersion
        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/tags/\(tag)")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == "wine-devel-\(tag)-osx64.tar.xz" })
                  ?? assets.first(where: {
                      guard let name = $0["name"] as? String else { return false }
                      // x86_64 builds end with osx64.tar.xz; exclude any arm64/aarch64 assets
                      return name.hasSuffix("osx64.tar.xz")
                  }),
              let downloadURLStr = asset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLStr)
        else {
            phase = .failed("Could not find Wine download. Check your internet connection.")
            return false
        }

        let assetName = asset["name"] as? String ?? "wine"
        append("Downloading \(assetName)...")

        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(assetName)

        do {
            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
            try? FileManager.default.removeItem(at: tmpFile)
            try FileManager.default.moveItem(at: localURL, to: tmpFile)
        } catch {
            phase = .failed("Wine download failed: \(error.localizedDescription)")
            return false
        }

        phase = .extractingWine
        append("Extracting Wine...")
        try? FileManager.default.createDirectory(at: stableInstallDir,
                                                 withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments     = ["-xJf", tmpFile.path, "-C", stableInstallDir.path,
                             "--strip-components=1"]
        do { try tar.run() } catch {
            phase = .failed("Extraction failed: \(error.localizedDescription)")
            return false
        }
        await withCheckedContinuation { continuation in
            tar.terminationHandler = { _ in continuation.resume() }
        }

        guard GPTKManager.isInstalled else {
            phase = .failed("Wine extracted but binary not found. Try again.")
            return false
        }

        let patched = GPTKManager.applyWinePatches()
        if !patched.isEmpty { append("Applied \(patched.count) Wine patch file(s).") }

        append("Wine ready.")
        return true
    }

    private func append(_ msg: String) {
        log.append(msg)
    }
}
