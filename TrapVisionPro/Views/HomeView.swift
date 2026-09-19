//
//  HomeView.swift
//  TrapVisionPro
//
//  The only menu screen in the app. Two choices: Practice (unlimited,
//  helpful on-screen feedback, learn the controls) or Round (the real
//  25-bird ATA round, deliberately "pure" — no menus popping up while
//  you're shooting). Kicks off mic/speech/Muse discovery in the
//  background the moment this screen appears, so there's no extra wait
//  once you pick a mode.
//

import SwiftUI

struct HomeView: View {
    @ObservedObject var game: GameState
    @Binding var immersionStyle: ImmersionStyle
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Text("Trap Trainer")
                    .font(.system(size: 44, weight: .bold))

                HStack {
                    Circle()
                        .fill(game.museConnected ? .green : .orange)
                        .frame(width: 14, height: 14)
                    Text(game.museConnected ? "Muse: \(game.museDeviceName)" : "No Muse — look+tap fallback ready")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                // Previously silent — if mic/speech access was denied, voice
                // "pull"/"bang" would just do nothing with zero explanation.
                if game.voiceAuthorizationDenied {
                    Text("Microphone/Speech access denied — voice commands won't work. Enable them in Settings.")
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Live ground-truth for the Muse — there's no reliable way to
                // reach an Xcode console on this device yet, so every
                // TestFlight build has to show what's actually happening.
                if game.museConnected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aim: \(game.museAimStatus)")
                        Text(String(format: "Tip %.2f · Secondary %.2f · Primary %@ · Pulls %d",
                                    game.museTipPressure, game.museSecondaryPressure,
                                    game.musePrimaryPressed ? "YES" : "no", game.museTriggerPullCount))
                    }
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    // Manual safety net: the automatic check now runs the
                    // moment the Muse connects (not at cold launch, before any
                    // device existed for the OS to authorize), but this lets
                    // you force another attempt on demand without reconnecting
                    // — e.g. right after approving a permission prompt.
                    Button {
                        Task {
                            await game.museManager.retryAccessoryTracking()
                        }
                    } label: {
                        Text("Retry Muse Tracking Permission")
                            .font(.body)
                    }
                    .buttonStyle(.bordered)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.wave.2").font(.title3)
                        Slider(value: $game.gunVolume, in: 0...1)
                        Image(systemName: "speaker.wave.3").font(.title3)
                    }
                    Text("Gun Volume")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)

                VStack(spacing: 10) {
                    Picker("Immersion", selection: $game.isFullImmersion) {
                        Text("Mixed").tag(false)
                        Text("Full").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .onChange(of: game.isFullImmersion) { _, isFull in
                        immersionStyle = isFull ? .full : .mixed
                    }
                    Text(game.isFullImmersion
                         ? "Real world hidden — a virtual gun tracks the Muse."
                         : "See your real room and real gun through passthrough.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Picker("Difficulty", selection: $game.difficulty) {
                        ForEach(Difficulty.allCases) { difficulty in
                            Text(difficulty.displayName).tag(difficulty)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    Text("Widens the hit forgiveness — helps while aim runs on head-direction fallback.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 16) {
                    Button {
                        Task {
                            game.startPractice()
                            _ = await openImmersiveSpace(id: "TrapRange")
                            dismissWindow()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Practice Range").font(.title2.bold())
                            Text("Unlimited pulls, pick any station, on-screen help.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task {
                            game.startRound()
                            _ = await openImmersiveSpace(id: "TrapRange")
                            dismissWindow()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Start a Round (25)").font(.title2.bold())
                            Text("The real ATA round — clean screen, score only.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            game.startPatterning()
                            _ = await openImmersiveSpace(id: "TrapRange")
                            dismissWindow()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Patterning Range").font(.title2.bold())
                            Text("Stationary target at a chosen distance — see where the shot actually lands and adjust hold.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .buttonStyle(.bordered)

                    // A much simpler scene than the full trap range, just to
                    // prove the Muse itself works — connection, any-button
                    // trigger, and tilt-tracking — before trusting it inside
                    // the real game. Uses the exact same GameState.museManager,
                    // so nothing learned here needs porting later.
                    Button {
                        Task {
                            _ = await openImmersiveSpace(id: "MuseDebug")
                        }
                    } label: {
                        Text("Muse Debug (simple test)")
                            .font(.body)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Text("Exit anytime with the Exit button on the bottom bar, or long-press look+pinch. In Practice, aim at the trap house and fire to cycle warm-up angle (Straight → Slight Curve → Full).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
        // TrapVisionProApp uses .windowStyle(.plain), which drops visionOS's
        // standard frosted-glass window background entirely — without this,
        // the menu content just floats with nothing behind it, reading as
        // washed-out/see-through rather than an actual menu.
        .glassBackgroundEffect()
        .task {
            await game.prepareSession()
        }
    }
}
