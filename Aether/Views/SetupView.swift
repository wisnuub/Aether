import SwiftUI

struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var bottleManager = BottleManager()
    @State private var step: Step = .welcome

    enum Step { case welcome, installing, login, done }

    var body: some View {
        ZStack {
            backgroundGradient
            VStack(spacing: 0) {
                Spacer()
                switch step {
                case .welcome:    WelcomeStep(onStart: beginSetup)
                case .installing: InstallingStep(manager: bottleManager)
                case .login:      SteamLoginStep(onContinue: {
                                    bottleManager.completeSteamLogin()
                                  })
                case .done:       DoneStep(onContinue: finish)
                }
                Spacer()
            }
            .padding(48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: bottleManager.phase) { phase in
            switch phase {
            case .steamLogin: step = .login
            case .done:       step = .done
            default: break
            }
        }
    }

    private func beginSetup() {
        step = .installing
        Task {
            _ = await bottleManager.createBottleAndInstallSteam(at: Bottle.defaultLocation())
        }
    }

    private func finish() {
        appState.completeSetup(bottle: Bottle(path: Bottle.defaultLocation()))
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.08, blue: 0.15), Color(red: 0.05, green: 0.05, blue: 0.10)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct WelcomeStep: View {
    var onStart: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("Welcome to Aether")
                    .font(.largeTitle.bold())
                Text("Run Windows Steam games on your Mac, for free, no CrossOver required.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                Label("Downloads Wine automatically", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Installs Steam in an isolated bottle", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("Per-game graphics configuration", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .font(.callout)

            Button(action: onStart) {
                Label("Set Up Aether", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

private struct InstallingStep: View {
    @ObservedObject var manager: BottleManager

    var body: some View {
        VStack(spacing: 24) {
            if case .failed(let msg) = manager.phase {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("Setup Failed").font(.title2.bold())
                Text(msg).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                ProgressView().scaleEffect(1.5)
                Text(phaseLabel).font(.title3.bold())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(manager.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .frame(height: 160)
            .background(.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var phaseLabel: String {
        switch manager.phase {
        case .idle:              "Preparing..."
        case .downloadingWine:   "Downloading Wine..."
        case .extractingWine:    "Extracting Wine..."
        case .downloadingARM64Wine: "Downloading ARM64 Wine..."
        case .extractingARM64Wine:  "Extracting ARM64 Wine..."
        case .creatingPrefix:    "Creating Wine prefix..."
        case .downloadingSteam:  "Downloading Steam..."
        case .installingSteam:   "Installing Steam..."
        case .steamLogin:        "Waiting for Steam login..."
        case .done:              "Done!"
        case .failed:            "Failed"
        }
    }
}

private struct SteamLoginStep: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)

            VStack(spacing: 8) {
                Text("Sign in to Steam")
                    .font(.largeTitle.bold())
                Text("Steam is open. Sign in with your account, then come back here and click Continue.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Continue to Library", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct DoneStep: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green.gradient)

            VStack(spacing: 8) {
                Text("Ready to play").font(.largeTitle.bold())
                Text("Steam is installed. Sign in when it opens, then install your games.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Button("Open Library", action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}
