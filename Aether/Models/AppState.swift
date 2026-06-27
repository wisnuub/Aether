import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isSetupComplete: Bool = false
    @Published var bottle: Bottle?
    @Published var isLoadingGames: Bool = false

    /// Steam-discovered games.
    @Published private var steamGames: [SteamGame] = []
    /// Manually added non-Steam games.
    @Published private(set) var customGames: [SteamGame] = []
    /// Software installed via the installer runner.
    @Published private(set) var installedApps: [InstalledApp] = []

    /// Unified list for the library: Steam games first, then custom entries.
    var games: [SteamGame] {
        get { steamGames + customGames }
        set {
            // LibraryView writes back via binding; route updates to the right bucket.
            let customIDs = Set(customGames.map(\.id))
            steamGames  = newValue.filter { !customIDs.contains($0.id) }
            customGames = newValue.filter {  customIDs.contains($0.id) }
        }
    }

    private let defaults = UserDefaults.standard
    private let customGamesKey = "aether.customGames"
    private let installedAppsKey = "aether.installedApps"

    init() {
        loadCustomGames()
        loadInstalledApps()
        if let bottlePath = defaults.string(forKey: "aether.bottlePath"),
           FileManager.default.fileExists(atPath: bottlePath) {
            let b = Bottle(path: URL(fileURLWithPath: bottlePath))
            bottle = b
            isSetupComplete = true
            Task { await refreshGames() }
        }
    }

    func completeSetup(bottle: Bottle) {
        self.bottle = bottle
        defaults.set(bottle.path.path, forKey: "aether.bottlePath")
        isSetupComplete = true
        Task { await refreshGames() }
    }

    func refreshGames() async {
        guard let bottle else { return }
        isLoadingGames = true
        var discovered = await SteamManager.shared.discoverGames(in: bottle)
        let saved = loadAllConfigs()
        for i in discovered.indices {
            if let config = saved[discovered[i].id] {
                discovered[i].config = config
            }
        }
        steamGames = discovered
        isLoadingGames = false
    }

    func saveConfig(_ config: GameConfig, for gameID: Int) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: "aether.game.\(gameID).config")
        }
        // Persist into custom game entry if applicable.
        if let idx = customGames.firstIndex(where: { $0.id == gameID }) {
            customGames[idx].config = config
            persistCustomGames()
        }
    }

    // MARK: - Custom game management

    func addCustomGame(name: String, exePath: String) {
        let entry = CustomGameEntry(name: name, exePath: exePath, config: GameConfig())
        customGames.append(SteamGame.from(entry: entry))
        persistCustomGames()
    }

    func removeCustomGame(id: Int) {
        customGames.removeAll { $0.id == id }
        persistCustomGames()
    }

    // MARK: - Installed apps management

    func addInstalledApp(name: String, installerPath: String) {
        let app = InstalledApp(name: name, installerPath: installerPath)
        installedApps.append(app)
        persistInstalledApps()
    }

    func removeInstalledApp(id: String) {
        installedApps.removeAll { $0.id == id }
        persistInstalledApps()
    }

    func renameInstalledApp(id: String, name: String) {
        if let idx = installedApps.firstIndex(where: { $0.id == id }) {
            installedApps[idx].name = name
            persistInstalledApps()
        }
    }

    private func loadInstalledApps() {
        guard let data = defaults.data(forKey: installedAppsKey),
              let apps = try? JSONDecoder().decode([InstalledApp].self, from: data)
        else { return }
        installedApps = apps
    }

    private func persistInstalledApps() {
        if let data = try? JSONEncoder().encode(installedApps) {
            defaults.set(data, forKey: installedAppsKey)
        }
    }

    // MARK: - Private

    private func loadAllConfigs() -> [Int: GameConfig] {
        var result: [Int: GameConfig] = [:]
        for key in defaults.dictionaryRepresentation().keys {
            guard key.hasPrefix("aether.game."), key.hasSuffix(".config") else { continue }
            let middle = key.dropFirst("aether.game.".count).dropLast(".config".count)
            guard let id = Int(middle),
                  let data = defaults.data(forKey: key),
                  let config = try? JSONDecoder().decode(GameConfig.self, from: data)
            else { continue }
            result[id] = config
        }
        return result
    }

    private func loadCustomGames() {
        guard let data = defaults.data(forKey: customGamesKey),
              let entries = try? JSONDecoder().decode([CustomGameEntry].self, from: data)
        else { return }
        customGames = entries.map { SteamGame.from(entry: $0) }
    }

    private func persistCustomGames() {
        let entries: [CustomGameEntry] = customGames.map { game in
            CustomGameEntry(name: game.name, exePath: game.customExeFullPath, config: game.config)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: customGamesKey)
        }
    }
}
