//
//  GameState.swift
//  TrapVisionPro
//
//  Central game state: mode (Practice vs Round), current station, round
//  scoring, and wiring between voice commands, the Muse trigger, and the
//  trap field physics.
//
//  Practice mode: unlimited pulls, no round cap, pick any station freely —
//  meant for first-timers learning the controls, so its HUD stays visible
//  and helpful.
//
//  Round mode: the real ATA round — 25 targets, 5 per station, auto-
//  rotating through stations 1-5. Deliberately "pure": no head-locked
//  menus flashing around as you look — score lives on a small
//  world-anchored sign near the trap house instead. A long-press
//  look+pinch fallback opens a minimal pause/exit menu (every Muse
//  control fires the shooting trigger, so none is free for pause).
//

import Foundation
import RealityKit
import Combine
import simd

enum AppMode {
    case practice
    case round
    /// Stationary target board at a chosen distance — no clays, every
    /// trigger pull is an immediate shot. For seeing your actual pellet
    /// pattern and adjusting hold-point (including how much lower to hold
    /// at longer distances to compensate for real drop), the way you'd
    /// pattern a real shotgun on paper.
    case patterning
    /// Guided Muse calibration — see CalibrationTarget's doc comment.
    case calibration
}

/// One calibration step: aim the physical Muse (however it ends up
/// mounted) at this target and fire. Three targets at different positions
/// so the resulting correction isn't just fit to one direction. Made fun
/// on purpose (see MuseAccessoryManager.addCalibrationSample) rather than
/// a dry settings screen — you're aiming and shooting things either way,
/// might as well be a little game.
enum CalibrationTarget: Int, CaseIterable {
    case apple = 0, pumpkin, watermelon

    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .pumpkin: return "Pumpkin"
        case .watermelon: return "Watermelon"
        }
    }

    /// Position in fieldRoot-local space — matches how the patterning
    /// board and trap house are positioned, so recentering carries these
    /// along correctly too.
    var localPosition: SIMD3<Float> {
        switch self {
        case .apple: return SIMD3<Float>(0, 1.5, -3)
        case .pumpkin: return SIMD3<Float>(-1.1, 1.4, -3)
        case .watermelon: return SIMD3<Float>(1.1, 1.3, -3)
        }
    }
}

/// Distances offered on the patterning range, in yards — spanning inside
/// the 16-yard line out past the ATA's 27-yard max, so you can see how
/// hold-point needs to change (mostly for drop) across that whole range.
enum PatterningDistance: Int, CaseIterable, Identifiable {
    case yards10 = 10
    case yards16 = 16
    case yards20 = 20
    case yards25 = 25
    case yards30 = 30
    case yards40 = 40

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) yd" }
    var meters: Float { Float(rawValue) * 0.9144 }

    /// Height (meters, in fieldRoot's local space) the board is rendered
    /// at — shared with TrapRangeImmersiveView.buildPatterningBoard's
    /// positioning so GameState's aim-error math and the View's actual
    /// board placement can never drift apart.
    static let boardHeight: Float = 1.4
}

/// How much horizontal angle a pulled clay can fly at — narrower than the
/// real ATA spread for warming up, so early throws are easy to track and
/// hit while you're still getting a feel for the gun and controls. Cycled
/// by aiming at the trap house and firing (see `cycleWarmupLevel`).
/// Ignored in Round mode, which always uses the real spread.
enum WarmupLevel: String, CaseIterable, Identifiable {
    case straight, gentle, full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .straight: return "Straight"
        case .gentle: return "Slight Curve"
        case .full: return "Full Angle"
        }
    }

    var spreadDegrees: ClosedRange<Float> {
        switch self {
        case .straight: return -1...1
        case .gentle: return -6...6
        case .full: return -TrapField.legalOscillationDegrees...TrapField.legalOscillationDegrees
        }
    }
}

/// Widens the effective hit radius on a miss-forgiving curve — a fudge
/// factor, not a claim about real clay/pellet size. Matters more than it
/// otherwise would right now because aim runs on head-direction fallback
/// (no real Muse tilt tracking yet), which is much less precise than
/// actually pointing the pen.
enum Difficulty: String, CaseIterable, Identifiable {
    case normal, easy, superEasy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .easy: return "Easy"
        case .superEasy: return "Super Easy"
        }
    }

    var hitRadiusMultiplier: Float {
        switch self {
        case .normal: return 1.0
        case .easy: return 2.5
        case .superEasy: return 5.0
        }
    }
}

@MainActor
final class GameState: ObservableObject {

    static let roundSize = 25
    static let shotsPerStation = 5

    @Published var mode: AppMode = .practice
    /// Starts easy — see WarmupLevel's doc comment. Cycled via the trap
    /// house; forced to `.full` in Round mode regardless of this value.
    @Published var warmupLevel: WarmupLevel = .straight
    @Published var currentStationNumber: Int = 1
    @Published var hits: Int = 0
    @Published var attempts: Int = 0
    @Published var shotsInRound: Int = 0
    @Published var lastResultText: String = ""
    @Published var museConnected: Bool = false
    @Published var museDeviceName: String = "No accessory connected"

    /// Home-screen / in-scene picker for patterning mode.
    @Published var patterningDistance: PatterningDistance = .yards16

    /// Latest shot's pellet impacts, as (right, up) meter offsets from the
    /// straight-line aim point at `patterningDistance` — real drop already
    /// included. Replaced (not appended) on every shot, so the target board
    /// always shows just the most recent pattern.
    @Published var lastPatternImpacts: [SIMD2<Float>] = []

    /// Which of the three calibration targets is current — see
    /// CalibrationTarget's doc comment.
    @Published var calibrationTargetIndex: Int = 0
    @Published var calibrationComplete: Bool = false
    /// Set true for a brief moment whenever a sample is recorded, so the
    /// view can trigger the "blast apart" effect on the current target —
    /// cleared again immediately after the view consumes it.
    @Published var calibrationTargetJustHit: Bool = false

    /// Live diagnostics mirrored straight from MuseAccessoryManager so
    /// HomeView (and the simple Muse Debug scene) can show ground truth
    /// on-screen — there's no reliable way to reach an Xcode console on
    /// this device yet, so every TestFlight build has to be self-diagnosing.
    @Published var museAimStatus: String = "Not started"
    @Published var museTipPressure: Float = 0
    @Published var museSecondaryPressure: Float = 0
    @Published var musePrimaryPressed: Bool = false
    @Published var museLastInputEvent: String = "No input yet"
    @Published var museTriggerPullCount: Int = 0
    /// True only while a real Muse aim anchor is live-tracking — the View
    /// uses this (not just `museConnected`) to decide whether to show the
    /// head-locked fallback gun or the Muse-tracked one, per
    /// MuseAccessoryManager.isAimTrackingLive's doc comment.
    @Published var museIsTrackingLive: Bool = false

    /// Mirrors voiceListener.authorizationDenied so HomeView can show it —
    /// previously read directly off the nested VoiceCommandListener, which
    /// doesn't trigger a SwiftUI re-render on its own (nested
    /// ObservableObject changes don't propagate through the parent).
    @Published var voiceAuthorizationDenied: Bool = false

    /// Home-screen slider — controls both the shotgun blast and the
    /// pump-rack cue together, since they're the same "gun sound" identity.
    @Published var gunVolume: Double = 1.0 {
        didSet {
            shotAudioPlayer.volume = Float(gunVolume)
            rackAudioPlayer.volume = Float(gunVolume)
        }
    }

    /// Chosen on the Home screen before entering either mode. Range is a
    /// progressive, Crown-adjustable blend of the virtual range and
    /// passthrough; Full replaces everything with the virtual field, so the
    /// virtual gun overlay (tracking the Muse) has to stand in for the real one.
    @Published var isFullImmersion: Bool = false

    /// Home-screen picker. Widens hit forgiveness — see Difficulty's doc
    /// comment for why this matters more than usual right now.
    @Published var difficulty: Difficulty = .normal

    /// Transient "MISS" flash — set true on a miss, cleared a couple
    /// seconds later. Shown on the head-locked HUD in Practice, and on the
    /// world-anchored sign in Round.
    @Published var missFlashVisible: Bool = false

    /// Set once a round of 25 completes (e.g. "22/25" or "25 STRAIGHT!").
    @Published var roundScoreText: String? = nil

    /// True while the pause/exit overlay is showing (Round mode only,
    /// toggled by TrapRangeImmersiveView's fallback gesture — every Muse
    /// control now fires the shooting trigger, so there's no button left
    /// free to dedicate to pause).
    @Published var isPaused: Bool = false

    /// Set true when the player chooses "Exit to Home" from the pause
    /// menu — the immersive view watches this to dismiss itself.
    @Published var exitRequested: Bool = false

    let museManager = MuseAccessoryManager()
    let voiceListener = VoiceCommandListener()
    private let shotAudioPlayer = AudioCuePlayer(resourceName: "shotgun_blast")
    private let rackAudioPlayer = AudioCuePlayer(resourceName: "pump_rack")

    /// Fires every time the trigger is pulled (Muse button or "bang"),
    /// whether or not a clay happens to be in the air.
    let shotFired = PassthroughSubject<Void, Never>()

    /// Fires the moment you step onto a station and the gun goes hot —
    /// plays the pump-rack sound. Fires on every station change (including
    /// auto-advancing through a round), and once when you first enter.
    let stationReady = PassthroughSubject<Void, Never>()

    let sceneRoot = Entity()
    let fieldRoot = Entity()

    private var activeClay: ClayTarget?
    /// Clays that have already been shot at and missed — kept flying and
    /// falling naturally (like a real missed bird actually would) instead
    /// of vanishing the instant you miss. Purely visual from here: no
    /// further scoring happens to them, they're just cleaned up once they
    /// land.
    private var fallingClays: [ClayTarget] = []
    private var cancellables = Set<AnyCancellable>()
    private var sessionStarted = false

    init() {
        sceneRoot.addChild(museManager.accessoryRoot)
        sceneRoot.addChild(fieldRoot)
        repositionField()

        voiceListener.commandDetected
            .sink { [weak self] command in
                guard let self else { return }
                switch command {
                case .pull: self.pullCalled()
                case .bang: self.triggerFired()
                }
            }
            .store(in: &cancellables)

        // The Muse's one physical trigger control does double duty: pull if
        // no clay's airborne yet, fire if one already is — one button,
        // dead simple, no separate "pull" control to find on the pen.
        museManager.triggerPulled
            .sink { [weak self] in
                self?.museTriggerPullCount += 1
                self?.handleMuseTrigger()
            }
            .store(in: &cancellables)

        museManager.menuButtonPressed
            .sink { [weak self] in self?.toggleMenu() }
            .store(in: &cancellables)

        museManager.$isConnected.sink { [weak self] in self?.museConnected = $0 }.store(in: &cancellables)
        museManager.$deviceName.sink { [weak self] in self?.museDeviceName = $0 }.store(in: &cancellables)
        museManager.$aimStatus.sink { [weak self] in self?.museAimStatus = $0 }.store(in: &cancellables)
        museManager.$lastTipPressure.sink { [weak self] in self?.museTipPressure = $0 }.store(in: &cancellables)
        museManager.$lastSecondaryPressure.sink { [weak self] in self?.museSecondaryPressure = $0 }.store(in: &cancellables)
        museManager.$isPrimaryButtonPressed.sink { [weak self] in self?.musePrimaryPressed = $0 }.store(in: &cancellables)
        museManager.$lastInputEvent.sink { [weak self] in self?.museLastInputEvent = $0 }.store(in: &cancellables)
        museManager.$isAimTrackingLive.sink { [weak self] in self?.museIsTrackingLive = $0 }.store(in: &cancellables)
        voiceListener.$authorizationDenied.sink { [weak self] in self?.voiceAuthorizationDenied = $0 }.store(in: &cancellables)

        shotAudioPlayer.bind(to: shotFired)
        rackAudioPlayer.bind(to: stationReady)
    }

    /// Starts mic/speech/Muse discovery. Safe to call multiple times —
    /// only actually runs once per app launch (called from the Home
    /// screen before either mode opens the immersive space).
    func prepareSession() async {
        guard !sessionStarted else { return }
        sessionStarted = true
        await museManager.start()
        await voiceListener.requestAuthorizationAndStart()
    }

    /// Enter Practice mode: unlimited pulls, free station selection.
    func startPractice() {
        mode = .practice
        resetScoreState()
        selectStation(1, force: true)
    }

    /// Enter Round mode: the structured 25-bird ATA round.
    func startRound() {
        mode = .round
        resetScoreState()
        selectStation(1, force: true)
    }

    /// Enter the patterning range: a stationary target board at
    /// `patterningDistance`, no clays — every trigger pull is an immediate
    /// shot, showing where the pattern actually lands.
    func startPatterning() {
        mode = .patterning
        resetScoreState()
        lastPatternImpacts = []
    }

    /// Enter guided calibration — see CalibrationTarget's doc comment.
    /// Clears any previous calibration first, since walking through all
    /// three targets again is meant to replace it, not refine it further
    /// (refining an old, possibly-wrong correction could make things
    /// worse instead of better).
    func startCalibration() {
        mode = .calibration
        resetScoreState()
        calibrationTargetIndex = 0
        calibrationComplete = false
        museManager.resetCalibration()
    }

    private func resetScoreState() {
        hits = 0
        attempts = 0
        shotsInRound = 0
        roundScoreText = nil
        missFlashVisible = false
        isPaused = false
        exitRequested = false
    }

    /// Advance the render loop. Call once per frame from the immersive
    /// view's RealityKit scene update subscription.
    func tick(dt: Float) {
        guard !isPaused else { return }
        museManager.pollOnce()
        if let clay = activeClay {
            let stillFlying = clay.step(dt: dt)
            if !stillFlying {
                activeClay = nil
                recordAttempt(hit: false, resultText: "Lost — no shot")
            }
        }
        // Already-resolved misses just keep falling until they land —
        // no more scoring, just letting physics finish naturally.
        fallingClays.removeAll { clay in
            let stillFlying = clay.step(dt: dt)
            if !stillFlying {
                clay.entity.removeFromParent()
            }
            return !stillFlying
        }
    }

    func selectStation(_ number: Int, force: Bool = false) {
        guard force || number != currentStationNumber else { return }
        currentStationNumber = number
        repositionField()
        stationReady.send()
    }

    /// The world point the current station's shooterPosition should land
    /// on — defaults to the origin (matching the original behavior before
    /// `recenterField` existed: identity rotation + this at zero reduces
    /// to the old `fieldRoot.position = -station.shooterPosition`).
    /// Updated by `recenterField` so a later station change (manual pick,
    /// or auto-advance mid-round) keeps the field anchored where you
    /// actually recentered it, instead of snapping back to world origin.
    private var shooterWorldTarget: SIMD3<Float> = .zero

    /// Shifts (and rotates) the field root so the currently selected
    /// station's shooting spot lands on `shooterWorldTarget`, facing
    /// whatever direction `fieldRoot.orientation` currently holds.
    private func repositionField() {
        let station = TrapField.station(currentStationNumber)
        fieldRoot.position = shooterWorldTarget - fieldRoot.orientation.act(station.shooterPosition)
    }

    /// Re-anchors the whole field to wherever you're currently standing and
    /// facing — useful since aim currently falls back to head-direction
    /// (no real Muse tilt tracking yet), so standing/facing consistently
    /// relative to the virtual field matters more than it otherwise would.
    /// `headForward` is the current head-forward direction in world space
    /// (need not be flattened or normalized — only its horizontal component
    /// is used). Built with `simd_quatf(from:to:)` rather than a
    /// hand-derived yaw angle so there's no axis-rotation sign convention
    /// to get backwards.
    func recenterField(headPosition: SIMD3<Float>, headForward: SIMD3<Float>) {
        let flatForward = SIMD3<Float>(headForward.x, 0, headForward.z)
        if length(flatForward) > 0.0001 {
            fieldRoot.orientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: normalize(flatForward))
        }
        shooterWorldTarget = SIMD3<Float>(headPosition.x, 0, headPosition.z)
        repositionField()
    }

    func pullCalled() {
        guard !isPaused, activeClay == nil else { return }
        let station = TrapField.station(currentStationNumber)
        let effectiveSpread = (mode == .round) ? WarmupLevel.full.spreadDegrees : warmupLevel.spreadDegrees
        activeClay = launchClay(for: station, from: fieldRoot, horizontalSpreadDegrees: effectiveSpread)
        lastResultText = "Pulled — Station \(station.id)"
    }

    /// The Muse's single trigger control is deliberately unambiguous:
    /// first press calls for a clay; second press fires at it. Earlier
    /// builds overloaded "aim at the trap house + press" to alter warm-up
    /// spread, which is exactly where a new player naturally points when
    /// calling for a bird — it looked as though the Muse did nothing.
    private func handleMuseTrigger() {
        if mode == .calibration {
            fireCalibrationShot()
            return
        }
        if mode == .patterning {
            firePatterningShot()
            return
        }
        if activeClay == nil {
            pullCalled()
        } else {
            triggerFired()
        }
    }

    /// Cycles Straight → Slight Curve → Full Angle → Straight. Only
    /// meaningful in Practice (Round always forces full angle), but
    /// harmless to call any time.
    private func cycleWarmupLevel() {
        let all = WarmupLevel.allCases
        guard let index = all.firstIndex(of: warmupLevel) else { return }
        warmupLevel = all[(index + 1) % all.count]
        lastResultText = "Warm-up angle: \(warmupLevel.displayName)"
    }

    /// Fires one full pellet pattern at the stationary patterning target —
    /// no pull step, no clay, just "where did that shot actually land."
    /// Previously ignored your actual aim entirely (always simulated a
    /// dead-center shot plus scatter), which made patterning useless for
    /// its whole purpose — it couldn't show bad aim because it never
    /// looked at your aim. Now computes exactly how far off dead-center
    /// your real aim ray is at the board's distance, and offsets the whole
    /// scatter pattern by that — the same aim direction Practice/Round
    /// shots already use (Muse if tracking, otherwise fallback).
    private func firePatterningShot() {
        guard !isPaused else { return }
        shotFired.send()

        let aim = museManager.aimOriginAndForward ?? fallbackAimProvider?()

        let boardCenter = fieldRoot.position
            + fieldRoot.orientation.act(SIMD3<Float>(0, PatterningDistance.boardHeight, -patterningDistance.meters))
        let boardRight = fieldRoot.orientation.act(SIMD3<Float>(1, 0, 0))
        let boardUp = fieldRoot.orientation.act(SIMD3<Float>(0, 1, 0))
        let boardNormal = fieldRoot.orientation.act(SIMD3<Float>(0, 0, 1))

        if let aim {
            lastPatternImpacts = simulatePatterningShot(
                aimOrigin: aim.origin,
                aimForward: aim.forward,
                boardCenter: boardCenter,
                boardNormal: boardNormal,
                boardRight: boardRight,
                boardUp: boardUp
            )
        } else {
            // Keep a useful, centered fallback if the scene has not yet
            // supplied a head/Muse aim source.
            lastPatternImpacts = simulatePatterningShot(distanceMeters: patterningDistance.meters)
        }
        lastResultText = "Pattern at \(patterningDistance.displayName)"
    }

    /// Current calibration target's actual world position — field-local
    /// per `CalibrationTarget.localPosition`, transformed the same way the
    /// trap house and patterning board are, so recentering carries it
    /// along correctly.
    var calibrationTargetWorldPosition: SIMD3<Float> {
        let target = CalibrationTarget.allCases[min(calibrationTargetIndex, CalibrationTarget.allCases.count - 1)]
        return fieldRoot.position + fieldRoot.orientation.act(target.localPosition)
    }

    /// Records one calibration sample against the CURRENT target, then
    /// advances — three targets total (see CalibrationTarget), each from a
    /// meaningfully different direction so the resulting correction isn't
    /// just fit to a single line of sight.
    private func fireCalibrationShot() {
        guard !isPaused, !calibrationComplete else { return }
        let recorded = museManager.addCalibrationSample(targetWorldPosition: calibrationTargetWorldPosition)
        guard recorded else {
            lastResultText = "Calibration needs live Muse tracking to record a sample."
            return
        }
        shotFired.send()
        calibrationTargetJustHit = true

        let nextIndex = calibrationTargetIndex + 1
        if nextIndex >= CalibrationTarget.allCases.count {
            calibrationComplete = true
            lastResultText = "Calibration complete!"
        } else {
            calibrationTargetIndex = nextIndex
        }
    }

    /// Manual fallback trigger for people without a Muse.
    func manualTrigger() {
        guard !isPaused else { return }
        museManager.fireManualTrigger()
    }

    /// Toggle the pause/exit overlay — wired to the Muse's secondary
    /// button and available as a fallback gesture too. Only meaningful
    /// mid-session; harmless to call any time.
    func toggleMenu() {
        isPaused.toggle()
    }

    func resumeFromMenu() {
        isPaused = false
    }

    func exitToHome() {
        isPaused = false
        exitRequested = true
    }

    private func triggerFired() {
        guard !isPaused else { return }
        shotFired.send()
        guard let clay = activeClay else { return }
        guard let aim = museManager.aimOriginAndForward else {
            evaluateAndScore(clayFromFallback: clay)
            return
        }
        let result = simulatePelletShot(aimOrigin: aim.origin, aimForward: aim.forward, clay: clay,
                                         hitRadiusMultiplier: effectiveHitRadiusMultiplier)
        resolveShot(result: result, clay: clay)
    }

    var fallbackAimProvider: (() -> (origin: SIMD3<Float>, forward: SIMD3<Float>))?

    private func evaluateAndScore(clayFromFallback clay: ClayTarget) {
        guard let provider = fallbackAimProvider else {
            activeClay?.entity.removeFromParent()
            activeClay = nil
            recordAttempt(hit: false, resultText: "No aim source available")
            return
        }
        let (origin, forward) = provider()
        let result = simulatePelletShot(aimOrigin: origin, aimForward: forward, clay: clay,
                                         hitRadiusMultiplier: effectiveHitRadiusMultiplier)
        resolveShot(result: result, clay: clay)
    }

    /// Practice is a learning space, not a scorecard. Until the player has
    /// tuned their physical Muse mount, a perfectly reasonable sight picture
    /// can be a few centimetres off at the clay. Give Practice a modest,
    /// explicit training allowance; Round retains the selected difficulty's
    /// normal simulation so scores stay meaningful.
    private var effectiveHitRadiusMultiplier: Float {
        mode == .practice
            ? max(difficulty.hitRadiusMultiplier, 3.0)
            : difficulty.hitRadiusMultiplier
    }

    /// Common tail end of every real shot attempt: on a hit, break the clay
    /// (dusted/broken/chipped, classified from how much of the simulated
    /// pellet pattern actually connected) and remove the original disc —
    /// it shattered. On a miss, the clay keeps flying and falling exactly
    /// like a real missed bird would, moved to `fallingClays` so `tick`
    /// keeps stepping it until it lands naturally — it's already scored,
    /// so no further shot at it counts for anything. Either way clears
    /// `activeClay` so the next pull can happen.
    private func resolveShot(result: PelletShotResult, clay: ClayTarget) {
        if result.hit {
            let kind = ClayBreakKind.classify(pelletsConnected: result.pelletsConnected, totalPellets: result.totalPellets)
            spawnClayBreak(kind: kind, at: clay.currentPosition, incomingVelocity: clay.currentVelocity, into: fieldRoot)
            clay.entity.removeFromParent()
        } else {
            fallingClays.append(clay)
        }
        activeClay = nil
        recordAttempt(hit: result.hit, resultText: result.hit
            ? String(format: "HIT! %d/%d pellets connected (%.2fs aloft)", result.pelletsConnected, result.totalPellets, result.leadTime)
            : String(format: "Miss — off by %.2fm", result.centerMissDistance))
    }

    /// Single place every shot (hit, miss, or lost bird) funnels through.
    /// In Round mode this also drives the 25-bird structure (auto station
    /// advance every 5, final score at 25); Practice mode just tallies.
    private func recordAttempt(hit: Bool, resultText: String) {
        attempts += 1
        shotsInRound += 1
        lastResultText = resultText

        if hit {
            hits += 1
        } else {
            flashMiss()
        }

        guard mode == .round else { return }

        if shotsInRound >= Self.roundSize {
            finishRound()
        } else if shotsInRound % Self.shotsPerStation == 0 {
            let next = currentStationNumber == 5 ? 1 : currentStationNumber + 1
            selectStation(next)
        }
    }

    private func flashMiss() {
        missFlashVisible = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            missFlashVisible = false
        }
    }

    private func finishRound() {
        let finalHits = hits
        roundScoreText = finalHits == Self.roundSize
            ? "\(finalHits) STRAIGHT!"
            : "\(finalHits) / \(Self.roundSize)"

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            roundScoreText = nil
        }

        hits = 0
        attempts = 0
        shotsInRound = 0
        selectStation(1, force: true)
    }

    var battingAverage: Double {
        attempts == 0 ? 0 : Double(hits) / Double(attempts)
    }
}
