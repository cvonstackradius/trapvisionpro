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
                        Text("Last input: \(game.museLastInputEvent)")
                        // Only refreshes once you've entered a range at
                        // least once this session (it's updated from the
                        // per-frame loop that only runs there) — the
                        // in-range debug readout is the one to actually
                        // watch live while testing different holds.
                        Text(game.museRawAimDebugText)
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

                    // Item 2 of the premium-sim brief: watch "Last input"
                    // above to see which physical control actually reaches
                    // the app, then pick that one here so brushing the
                    // other controls (e.g. gripping the housing) doesn't
                    // also fire a shot during normal play.
                    VStack(spacing: 6) {
                        Picker("Trigger", selection: Binding(
                            get: { game.museManager.triggerSource },
                            set: { game.museManager.triggerSource = $0 }
                        )) {
                            ForEach(MuseTriggerSource.allCases) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                        Text("Fires from any control by default — once you know which one is real from \"Last input\" above, pick it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
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
                        Text("Range (Crown)").tag(false)
                        Text("Full").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    .onChange(of: game.isFullImmersion) { _, isFull in
                        immersionStyle = isFull
                            ? .full
                            : .progressive(0.15...0.9, initialAmount: 0.6)
                    }
                    Text(game.isFullImmersion
                         ? "Real world hidden — a virtual gun tracks the Muse."
                         : "A virtual range starts about 60% immersive. Turn the Digital Crown to reveal more of your real room and Muse.")
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

                    // Requested directly as a way to isolate whether aim
                    // tracking itself works, separate from trap timing/lead
                    // — 5 big, fully stationary discs close in, no flight,
                    // no clock. If this can't be hit either, the problem is
                    // aim/calibration, not difficulty.
                    Button {
                        Task {
                            game.startCrazyEasy()
                            _ = await openImmersiveSpace(id: "TrapRange")
                            dismissWindow()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Crazy Easy").font(.title2.bold())
                            Text("5 big stationary targets, close range — no timing, no lead, just aim.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                    .buttonStyle(.bordered)

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

                    // Item 1 of the premium-sim brief: aim the mounted Muse
                    // at a few real targets and save the offset so the
                    // virtual barrel/scoring ray actually lines up with
                    // wherever the physical housing points. Needs live Muse
                    // tracking to record a sample — if tracking isn't live,
                    // firing here just shows a message saying so instead of
                    // silently doing nothing.
                    Button {
                        Task {
                            game.startCalibration()
                            _ = await openImmersiveSpace(id: "TrapRange")
                            dismissWindow()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Calibrate Muse Aim").font(.title2.bold())
                            Text("Aim at an apple, pumpkin, and watermelon to align the virtual barrel with your real one.")
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

                Text("Exit anytime with the Exit button on the bottom bar, or long-press look+pinch. In Practice, the first Muse press calls a clay and the second fires.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // CC-BY 4.0 requires attribution wherever the work is used
                // — this is a demo placeholder gun, not the final art, so
                // credit stays visible until it's replaced.
                Text("Shotgun model: \"Mossberg 940 Pro Tactical Shotgun\" by Sayooj Sasikumar, licensed CC-BY 4.0.")
                    .font(.caption2)
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
