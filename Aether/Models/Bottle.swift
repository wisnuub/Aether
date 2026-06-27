import Foundation

struct Bottle: Identifiable, Equatable {
    let id = UUID()
    let path: URL

    var name: String { path.lastPathComponent }
    var driveCPath: URL { path.appendingPathComponent("drive_c") }
    var steamPath: URL { driveCPath.appendingPathComponent("Program Files (x86)/Steam") }
    var steamExePath: URL { steamPath.appendingPathComponent("Steam.exe") }
    var steamLibraryPath: URL { steamPath.appendingPathComponent("steamapps") }

    var isSteamInstalled: Bool {
        FileManager.default.fileExists(atPath: steamExePath.path)
    }

    static func defaultLocation() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Aether/Bottles/Steam")
    }
}
