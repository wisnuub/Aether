import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var steamMonitor = SteamMonitor()
    @State private var searchText = ""
    @State private var selectedGame: SteamGame?
    @State private var showRendererTest = false
    @State private var showSoftware = false
    @State private var filter: LibraryFilter = .all
    @State private var showAddGame = false
    @State private var pendingExePath: String = ""
    @State private var pendingGameName: String = ""

    enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case steam = "Steam"
        case custom = "Custom"
    }

    private var filtered: [SteamGame] {
        let source: [SteamGame]
        switch filter {
        case .all:    source = appState.games
        case .steam:  source = appState.games.filter { !$0.isCustom }
        case .custom: source = appState.games.filter {  $0.isCustom }
        }
        if searchText.isEmpty { return source }
        return source.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .frame(minWidth: 220)
        } detail: {
            if showRendererTest {
                RendererTestView()
            } else if showSoftware {
                SoftwareView()
            } else if let game = selectedGame {
                GameDetailView(game: bindingFor(game))
            } else {
                emptyDetail
            }
        }
        .background(backgroundGradient)
        .onAppear { steamMonitor.start() }
        .onDisappear { steamMonitor.stop() }
        .sheet(isPresented: $showAddGame) {
            AddGameSheet(
                name: $pendingGameName,
                exePath: pendingExePath,
                onAdd: { name in
                    appState.addCustomGame(name: name, exePath: pendingExePath)
                    showAddGame = false
                },
                onCancel: { showAddGame = false }
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "gamecontroller.fill")
                    .foregroundStyle(.blue)
                Text("Aether")
                    .font(.headline)
                Spacer()
                Button {
                    pickExeAndAdd()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add non-Steam game")

                Button {
                    Task { await appState.refreshGames() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh library")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if appState.isLoadingGames {
                ProgressView("Loading games...")
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Filter tabs – only show when both Steam and custom games exist
                let hasCustom = appState.games.contains(where: { $0.isCustom })
                if hasCustom {
                    Picker("Filter", selection: $filter) {
                        ForEach(LibraryFilter.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }

                SearchBar(text: $searchText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                if filtered.isEmpty && !appState.games.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("No matches")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appState.games.isEmpty {
                    noGamesView
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { game in
                                GameRow(game: game, isSelected: selectedGame?.id == game.id)
                                    .onTapGesture {
                                        selectedGame = game
                                        showRendererTest = false
                                        showSoftware = false
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()

            // Tools section
            VStack(spacing: 0) {
                Button {
                    selectedGame = nil
                    showRendererTest = true
                    showSoftware = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu")
                            .foregroundStyle(showRendererTest ? .blue : .secondary)
                            .frame(width: 16)
                        Text("Renderer Test")
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(showRendererTest ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

                Button {
                    selectedGame = nil
                    showSoftware = true
                    showRendererTest = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(showSoftware ? .blue : .secondary)
                            .frame(width: 16)
                        Text("Software")
                            .font(.subheadline)
                        Spacer()
                        if !appState.installedApps.isEmpty {
                            Text("\(appState.installedApps.count)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(showSoftware ? Color.accentColor.opacity(0.2) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            }

            Divider()

            steamFooter
        }
        .background(.ultraThinMaterial)
    }

    private var steamFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(steamMonitor.isRunning ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 7, height: 7)
                .shadow(color: steamMonitor.isRunning ? .green.opacity(0.8) : .clear, radius: 4)

            Text(steamMonitor.isRunning ? "Steam is running" : "Steam is not running")
                .font(.caption)
                .foregroundStyle(steamMonitor.isRunning ? .primary : .secondary)

            Spacer()

            if steamMonitor.isRunning {
                Button("Focus") {
                    let script = "tell application \"System Events\" to set frontmost of (first process whose name contains \"wine\") to true"
                    NSAppleScript(source: script)?.executeAndReturnError(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)

                Button("Kill") {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                    task.arguments = ["-f", "Steam.exe"]
                    try? task.run()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
            } else {
                Button("Launch") {
                    guard let bottle = appState.bottle else { return }
                    try? WineProcess.launchSteam(bottle: bottle, gameID: nil, config: GameConfig())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.3), value: steamMonitor.isRunning)
    }

    private var emptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("Select a game")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundGradient)
    }

    private var noGamesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No games found")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Launch Steam and install some games, then refresh.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.08, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.08)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func pickExeAndAdd() {
        let panel = NSOpenPanel()
        panel.title = "Select Windows Executable"
        panel.allowedContentTypes = [.init(filenameExtension: "exe")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingExePath = url.path
        pendingGameName = url.deletingPathExtension().lastPathComponent
        showAddGame = true
    }

    private func bindingFor(_ game: SteamGame) -> Binding<SteamGame> {
        Binding(
            get: { appState.games.first(where: { $0.id == game.id }) ?? game },
            set: { updated in
                if let idx = appState.games.firstIndex(where: { $0.id == updated.id }) {
                    appState.games[idx] = updated
                }
            }
        )
    }
}

private struct GameRow: View {
    let game: SteamGame
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if game.isCustom {
                Image(systemName: "doc.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange.opacity(0.8))
                    .frame(width: 36, height: 24)
            } else {
                AsyncImage(url: game.artworkURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.white.opacity(0.05)
                }
                .frame(width: 36, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(game.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

private struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search games...", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Renderer Test

private struct RendererTestView: View {
    @EnvironmentObject var appState: AppState

    @State private var wineBuild: GameConfig.WineBuild = .stable
    @State private var renderer: GameConfig.Renderer  = .auto
    @State private var dxVersion: GameConfig.DXVersion = .dx11
    @State private var status: TestStatus = .idle
    @State private var testProcess: Process?

    private var toolsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Aether/Tools")
    }
    private var hasVKD3D: Bool {
        FileManager.default.fileExists(atPath: toolsDir.appendingPathComponent("d3d12.dll").path)
    }
    // VKD3D is only needed on the stable build's DXVK path; GPTK's D3DMetal
    // translates DX12 natively.
    private var needsVKD3D: Bool {
        wineBuild == .stable && renderer == .dxvk && dxVersion == .dx12
    }

    enum TestStatus: Equatable {
        case idle, running, passed, failed(String)
        var label: String {
            switch self {
            case .idle:         return "Ready"
            case .running:      return "Running..."
            case .passed:       return "Window opened"
            case .failed(let e): return "Failed: \(e)"
            }
        }
        var color: Color {
            switch self {
            case .idle:    return .secondary
            case .running: return .blue
            case .passed:  return .green
            case .failed:  return .red
            }
        }
        var icon: String {
            switch self {
            case .idle:    return "circle"
            case .running: return "circle.dotted"
            case .passed:  return "checkmark.circle.fill"
            case .failed:  return "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Renderer Test")
                        .font(.title.bold())
                    Text("Launch a spinning-triangle benchmark to verify each rendering path works.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Wine build picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Wine Build").font(.headline).foregroundStyle(.secondary)
                    Picker("Wine Build", selection: $wineBuild) {
                        ForEach(GameConfig.WineBuild.allCases) { b in
                            Text(b.rawValue).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    if wineBuild == .gptk {
                        if GPTKManager.isGPTKInstalled {
                            Text("Runs in an isolated test prefix, not your Steam bottle. First run takes about 30 seconds extra while the prefix is created.")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Label("GPTK not installed. The test will fall back to Stable.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }

                // Renderer picker (GPTK has no Vulkan driver: D3DMetal only)
                if wineBuild == .gptk {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Renderer").font(.headline).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill").font(.caption)
                            Text("D3DMetal (fixed by GPTK build)")
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Renderer").font(.headline).foregroundStyle(.secondary)
                        Picker("Renderer", selection: $renderer) {
                            ForEach(GameConfig.Renderer.allCases) { r in
                                Text(r == .auto ? "Auto (WineD3D)" : r.rawValue).tag(r)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // DX version picker (hidden for MoltenVK, which is Vulkan-native)
                if wineBuild == .gptk || renderer != .moltenVK {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("DirectX Version").font(.headline).foregroundStyle(.secondary)
                            if wineBuild == .gptk {
                                Text("D3DMetal translates all versions")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        Picker("DX Version", selection: $dxVersion) {
                            ForEach(GameConfig.DXVersion.allCases) { v in
                                Text(v.rawValue).tag(v)
                            }
                        }
                        .pickerStyle(.segmented)

                        if wineBuild == .stable && renderer == .auto
                            && (dxVersion == .dx10 || dxVersion == .dx11) {
                            Label("WineD3D DX10/DX11 cannot be tested standalone.",
                                  systemImage: "info.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                            Text("WineD3D's D3D11 adapter needs Steam's display context. Games work fine via Steam, or switch to the GPTK build to test with D3DMetal.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if needsVKD3D {
                            if hasVKD3D {
                                Label("VKD3D-Proton d3d12.dll found in Tools.",
                                      systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label("d3d12.dll not found in Tools folder.",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                    Text("Download vkd3d-proton from github.com/HansKristian-Work/vkd3d-proton → Releases, extract the x86_64 .dll files, and copy d3d12.dll to:\n~/Library/Application Support/Aether/Tools/")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }

                Divider()

                // What this test will use
                VStack(alignment: .leading, spacing: 6) {
                    Text("Test configuration").font(.headline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle").foregroundStyle(.blue)
                        Text(configSummary).font(.system(.body, design: .monospaced))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Run button + status
                HStack(spacing: 16) {
                    Button {
                        runTest()
                    } label: {
                        Label(status == .running ? "Running..." : "Launch Test",
                              systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(status == .running || appState.bottle == nil || (needsVKD3D && !hasVKD3D))

                    if appState.bottle == nil {
                        Text("No bottle configured").font(.caption).foregroundStyle(.red)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: status.icon)
                            .foregroundStyle(status.color)
                        Text(status.label)
                            .foregroundStyle(status.color)
                    }
                    .font(.subheadline)
                }
            }
            .padding(28)
        }
        .background(
            LinearGradient(
                colors: [Color(red:0.08,green:0.08,blue:0.15), Color(red:0.04,green:0.04,blue:0.08)],
                startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
    }

    private var configSummary: String {
        let effectiveRenderer: GameConfig.Renderer = wineBuild == .gptk ? .auto : renderer
        let dll = WineProcess.dllOverrides(renderer: effectiveRenderer, dxVersion: dxVersion)
        let api: String
        if wineBuild == .gptk {
            api = "\(dxVersion.rawValue) via D3DMetal (GPTK)"
        } else if renderer == .moltenVK {
            api = "Vulkan (native)"
        } else {
            api = "\(dxVersion.rawValue) via \(renderer == .auto ? "WineD3D" : renderer.rawValue)"
        }
        return "API: \(api)\nWINEDLLOVERRIDES: \(dll)"
    }

    private func runTest() {
        guard let bottle = appState.bottle else { return }
        status = .running
        testProcess?.terminate()

        do {
            let process = try WineProcess.launchRendererTest(
                bottle: bottle, renderer: renderer, dxVersion: dxVersion, build: wineBuild)
            testProcess = process
            DispatchQueue.global().async {
                process.waitUntilExit()
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        status = .passed
                    } else if process.terminationStatus == 99 {
                        // Graceful WineD3D DX10/DX11 limitation (VEH guard fired)
                        status = .failed("WineD3D DX10/DX11 not supported standalone, use DXVK or GPTK")
                    } else if process.terminationReason == .exit && process.terminationStatus != 0 {
                        status = .failed("Exit code \(process.terminationStatus)")
                    } else {
                        status = .passed  // closed by user = success
                    }
                    testProcess = nil
                }
            }
            // Give it 2 s to launch; if still running, consider it passed (window is open)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if case .running = status { status = .passed }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Add Game Sheet

private struct AddGameSheet: View {
    @Binding var name: String
    let exePath: String
    let onAdd: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Game")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Executable").font(.caption).foregroundStyle(.secondary)
                Text(exePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Game Name").font(.caption).foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Add Game") { onAdd(name) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
