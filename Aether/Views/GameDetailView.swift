import SwiftUI

struct GameDetailView: View {
    @Binding var game: SteamGame
    @EnvironmentObject var appState: AppState
    @StateObject private var gameMonitor = GameMonitor()
    @State private var isLaunching = false
    @State private var launchError: String?
    @State private var confirmRemove = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                configSection
            }
        }
        .background(backgroundGradient)
        .onAppear { gameMonitor.start() }
        .onDisappear { gameMonitor.stop() }
        .onChange(of: game.config) { _, newConfig in
            appState.saveConfig(newConfig, for: game.id)
        }
        .alert("Launch Error", isPresented: .constant(launchError != nil)) {
            Button("OK") { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
        .confirmationDialog("Remove \(game.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { appState.removeCustomGame(id: game.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it from Aether only. The files on disk are not deleted.")
        }
    }

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            if game.isCustom {
                Rectangle().fill(Color.white.opacity(0.04))
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .overlay {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 64))
                            .foregroundStyle(.white.opacity(0.08))
                    }
            } else {
                AsyncImage(url: game.heroURL) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.04))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .clipped()
            }

            LinearGradient(
                colors: [.clear, Color(red: 0.04, green: 0.04, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 240)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if game.isCustom {
                            Label("Custom", systemImage: "doc.badge.plus")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Text(game.name)
                            .font(.title.bold())
                            .shadow(radius: 8)
                        if runsNative {
                            Label("Native", systemImage: "apple.logo")
                                .font(.caption2)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    if game.isCustom {
                        Text(game.customExeFullPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("App ID \(game.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        let dir: URL
                        if game.isCustom {
                            dir = URL(fileURLWithPath: game.customExeFullPath)
                                .deletingLastPathComponent()
                        } else if let bottle = appState.bottle {
                            dir = bottle.steamLibraryPath
                                .appendingPathComponent("common/\(game.installDir)")
                        } else { return }
                        NSWorkspace.shared.open(dir)
                    } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!game.isCustom && appState.bottle == nil)

                    if game.isCustom {
                        Button {
                            confirmRemove = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.large)
                    }

                    Button {
                        if gameMonitor.isRunning {
                            gameMonitor.killRunningGame()
                        } else {
                            launch()
                        }
                    } label: {
                        if isLaunching {
                            HStack {
                                ProgressView().scaleEffect(0.7)
                                Text("Launching...")
                            }
                        } else if gameMonitor.isRunning {
                            Label("Stop", systemImage: "stop.fill")
                        } else {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(gameMonitor.isRunning ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(isLaunching || appState.bottle == nil)
                }
            }
            .padding(20)
        }
    }

    /// Native port for this game, if this Aether build ships one.
    private var nativePort: NativePort? {
        game.isCustom ? nil : NativePortManager.port(for: game.id)
    }

    private var runsNative: Bool {
        nativePort != nil && game.config.runtime == .native
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Runtime")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Runtime", selection: $game.config.runtime) {
                    ForEach(GameConfig.Runtime.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            if game.config.runtime == .native {
                Text("Runs as a native Apple Silicon app through Steam for macOS, with no Wine. Progress syncs with Steam Cloud in both directions, achievements unlock on your account, and Steam counts the playtime. The first launch copies the game files and sets the game up in Steam for macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Runs the Windows version through Wine and Aether's Steam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var configSection: some View {
        if nativePort != nil {
            VStack(alignment: .leading, spacing: 24) {
                runtimeSection
                if !runsNative {
                    Divider()
                    wineConfigSection
                }
            }
            .padding(24)
        } else {
            wineConfigSection.padding(24)
        }
    }

    private var wineConfigSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Graphics")
                .font(.headline)
                .foregroundStyle(.secondary)

            // Wine build picker + per-build status hint
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Wine Build")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Wine Build", selection: $game.config.wineBuild) {
                        ForEach(GameConfig.WineBuild.allCases) { b in
                            Text(b.rawValue).tag(b)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)
                }

                switch game.config.wineBuild {
                case .gptk:
                    if GPTKManager.isGPTKInstalled {
                        Text("Apple D3DMetal handles DX9 through DX12. 32-bit games run via wow64. First launch may take longer while the prefix updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("GPTK not installed. Falls back to Stable.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                case .arm64:
                    if GPTKManager.isARM64WineInstalled {
                        Text("ARM64-native Wine with FEX x86 emulation — no Rosetta needed. D3DMetal handles all DX versions. Requires macOS 26.5+. 64-bit bottles only.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("ARM64 Wine not installed. Falls back to Stable.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("Download ARM64 Wine from Setup to enable this build.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                case .stable:
                    EmptyView()
                }
            }

            // Renderer picker — locked to D3DMetal for builds that have no Vulkan driver
            if game.config.wineBuild.usesD3DMetal {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.caption)
                    Text("Renderer: D3DMetal (fixed for \(game.config.wineBuild == .arm64 ? "ARM64" : "GPTK") build)")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            } else {
                Picker("Renderer", selection: $game.config.renderer) {
                    ForEach(GameConfig.Renderer.allCases) { r in
                        Text(rendererLabel(r)).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }

            if game.config.wineBuild == .stable, game.config.renderer == .dxvk {
                HStack {
                    Text("DX Version")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("DX Version", selection: $game.config.dxVersion) {
                        ForEach(GameConfig.DXVersion.allCases) { v in
                            Text(v.rawValue).tag(v)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }
                if game.config.dxVersion == .dx12 {
                    Text("DX12 via DXVK requires VKD3D-Proton (d3d12.dll) in the game folder.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            Text("Options")
                .font(.headline)
                .foregroundStyle(.secondary)

            Toggle("ESync (better CPU performance)", isOn: $game.config.esync)
            Toggle("Performance HUD", isOn: $game.config.metalHUD)
            Toggle("DirectDraw Wrapper (cnc-ddraw)", isOn: $game.config.useDDrawWrapper)
            Toggle("DirectComposition (window transparency)", isOn: $game.config.enableDComp)

            Divider()

            Text("Launch Arguments")
                .font(.headline)
                .foregroundStyle(.secondary)

            TextField("e.g. -windowed -noborder", text: $game.config.launchArgs)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Custom Executable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !game.config.customExePath.isEmpty {
                        Label("Direct launch active", systemImage: "bolt.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                TextField("e.g. PlantsVsZombies.exe", text: $game.config.customExePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Bypasses Steam's launcher and runs this exe directly (Steam still starts for DRM). Use when Steam's applaunch silently fails.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            EnvVarEditor(vars: $game.config.extraEnvVars)
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.08, blue: 0.15), Color(red: 0.04, green: 0.04, blue: 0.08)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // Display-only relabel: the stored rawValue "Auto (D3DMetal)" predates the
    // GPTK build and is misleading on stable Wine, where auto means WineD3D.
    private func rendererLabel(_ r: GameConfig.Renderer) -> String {
        r == .auto ? "Auto (WineD3D)" : r.rawValue
    }

    private func launch() {
        guard let bottle = appState.bottle else { return }
        isLaunching = true
        launchError = nil
        let snapshot = game
        Task.detached(priority: .userInitiated) {
            var err: String?
            do {
                if !snapshot.isCustom,
                   snapshot.config.runtime == .native,
                   let port = NativePortManager.port(for: snapshot.id) {
                    try await NativePortManager.launch(port, bottle: bottle,
                                                       gameInstallDir: snapshot.installDir)
                } else if snapshot.isCustom {
                    try WineProcess.launchCustomExe(
                        bottle: bottle,
                        exePath: snapshot.customExeFullPath,
                        config: snapshot.config
                    )
                } else {
                    try await WineProcess.launchSteam(
                        bottle: bottle,
                        gameID: snapshot.id,
                        config: snapshot.config,
                        installDir: snapshot.installDir
                    )
                }
            } catch {
                err = error.localizedDescription
            }
            await MainActor.run {
                self.launchError = err
                self.isLaunching = false
            }
        }
    }
}

private struct EnvVarEditor: View {
    @Binding var vars: [String: String]
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Environment Variables")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(vars.keys.sorted(), id: \.self) { key in
                HStack {
                    Text(key).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("=").foregroundStyle(.tertiary)
                    Text(vars[key] ?? "").font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button { vars.removeValue(forKey: key) } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                    }.buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("KEY", text: $newKey)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Text("=").foregroundStyle(.secondary)
                TextField("value", text: $newValue)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button {
                    guard !newKey.isEmpty else { return }
                    vars[newKey] = newValue
                    newKey = ""; newValue = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.green)
                .disabled(newKey.isEmpty)
            }
        }
    }
}
