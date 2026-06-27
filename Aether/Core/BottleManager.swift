import Foundation

@MainActor
final class BottleManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingWine
        case extractingWine
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

    private let wineInstallDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aether/Wine")
    }()

    func createBottleAndInstallSteam(at path: URL) async -> Bottle? {
        if !GPTKManager.isInstalled {
            guard await downloadWine() else { return nil }
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
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SteamSetup.exe")

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
        installer.arguments = [tmpURL.path, "/S"]
        installer.environment = GPTKManager.baseEnvironment(for: bottle)
        do { try installer.run() } catch {
            phase = .failed("Failed to launch installer: \(error.localizedDescription)")
            return nil
        }
        await withCheckedContinuation { continuation in
            installer.terminationHandler = { _ in continuation.resume() }
        }

        append("Steam installed. Please sign in.")
        phase = .steamLogin
        try? WineProcess.launchSteam(bottle: bottle, gameID: nil, config: GameConfig())
        return bottle
    }

    func completeSteamLogin() {
        phase = .done
    }

    private func downloadWine() async -> Bool {
        phase = .downloadingWine
        append("Fetching Wine release info...")

        let apiURL = URL(string: "https://api.github.com/repos/Gcenx/macOS_Wine_builds/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: {
                  ($0["name"] as? String)?.hasSuffix("osx64.tar.xz") == true
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
        try? FileManager.default.createDirectory(at: wineInstallDir, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xJf", tmpFile.path, "-C", wineInstallDir.path, "--strip-components=1"]
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

        append("Wine ready.")
        return true
    }

    private func append(_ msg: String) {
        log.append(msg)
    }
}
