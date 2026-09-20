//
//  MuseAccessoryManager.swift
//  TrapVisionPro
//
//  Connects to a Logitech Muse (or any GC spatial accessory) via the
//  GameController framework, anchors virtual content to its "aim" location
//  using RealityKit, and exposes button/tip pressure plus haptics.
//
//  Reference: WWDC25 "Explore spatial accessory input on visionOS"
//  https://developer.apple.com/videos/play/wwdc2025/289/
//

import Foundation
import GameController
import RealityKit
import ARKit
import CoreHaptics
import Combine
import simd

/// Which physical control fires the shot during normal play. Defaults to
/// "any" (the behavior since Build 13) since not everyone has identified
/// their specific hardware's mapping yet — but once you've watched
/// `lastInputEvent` and know which one is real, picking it here stops the
/// other two controls from also firing (e.g. brushing the tip while
/// gripping the housing shouldn't count as a shot).
enum MuseTriggerSource: String, CaseIterable, Identifiable {
    case any, primaryButton, secondaryButton, tip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: return "Any Control"
        case .primaryButton: return "Primary Button"
        case .secondaryButton: return "Secondary Button"
        case .tip: return "Tip"
        }
    }
}

@MainActor
final class MuseAccessoryManager: ObservableObject {

    // MARK: Published state the UI / game logic can observe

    @Published var isConnected: Bool = false
    @Published var deviceName: String = "No accessory connected"
    @Published var lastTipPressure: Float = 0
    @Published var lastSecondaryPressure: Float = 0
    @Published var isPrimaryButtonPressed: Bool = false

    /// The most recent physical control that actually reached the Game
    /// Controller framework, by name (e.g. "Primary button pressed") —
    /// visible on-screen since we have no reliable Xcode console access on
    /// this device, and it directly answers "which control does the Muse
    /// actually report" without guessing.
    @Published var lastInputEvent: String = "No input yet"

    /// Plain-English state of accessory aim-tracking, meant to be shown
    /// directly on-screen (HomeView) since we have no reliable way to reach
    /// an Xcode console on this device yet. Every branch that decides
    /// whether the tilt-tracked gun will work updates this.
    @Published var aimStatus: String = "Not started"

    /// True only while a real aim anchor exists and is actively tracking —
    /// distinct from `aimStatus`'s free-text (meant for humans to read),
    /// this is what view code should actually branch on to decide whether
    /// to show the tracked gun or the head-locked fallback.
    @Published private(set) var isAimTrackingLive: Bool = false

    /// Which control fires the shot — see the type's doc comment.
    /// Persisted so a choice survives app relaunches (not necessarily full
    /// reinstalls, same caveat as every other permission/preference this
    /// app has hit this session).
    @Published var triggerSource: MuseTriggerSource {
        didSet { UserDefaults.standard.set(triggerSource.rawValue, forKey: Self.triggerSourceDefaultsKey) }
    }

    /// User-calibrated rotation applied to every raw aim reading. Together
    /// with `muzzleOffset`, this defines the real barrel pose relative to
    /// the Muse inside a gun-shaped housing.
    @Published private(set) var aimCorrection: simd_quatf = simd_quatf(real: 1, imag: .zero) {
        didSet { applyAimVisualCorrection() }
    }

    /// Local-space translation from the Muse's reported aim origin to the
    /// real muzzle. Rotation-only calibration still leaves a close-range
    /// parallax error whenever the Muse sits behind or below the muzzle.
    /// Starts at a small backward guess (not zero) — on-device testing
    /// found the uncalibrated gun rendering with its whole body sitting
    /// right at the tracked tip, poking out further than it should.
    /// Overwritten the moment real calibration runs (`updateMuzzleOffset`)
    /// or a previously-saved value loads, so this only matters before that.
    @Published private(set) var muzzleOffset: SIMD3<Float> = SIMD3<Float>(0, 0, 0.12) {
        didSet { applyAimVisualCorrection() }
    }

    /// The "aim" accessory location's own reported "up" doesn't match a
    /// person's actual up while gripping the housing like a gun —
    /// on-device testing found the rendered gun upside down (bead at the
    /// bottom) even with `aimCorrection` at identity. This is a fixed 180°
    /// roll about the anchor's own forward axis, applied ONLY to the
    /// visual: rotating about the forward axis itself never changes the
    /// forward direction, so `aimOriginAndForward`'s hit-ray math is
    /// completely unaffected by this. Kept separate from user calibration
    /// on purpose — solving `aimCorrection` from "rotate this vector to
    /// that vector" leaves the roll around the resulting axis completely
    /// unconstrained, so no amount of calibration samples could ever have
    /// fixed this on their own.
    private static let visualRollBaseline = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
    private var visualOrientation: simd_quatf { aimCorrection * Self.visualRollBaseline }

    private struct CalibrationSample {
        let rawTransform: float4x4
        let targetWorldPosition: SIMD3<Float>
    }

    private var calibrationSamples: [CalibrationSample] = []
    private var calibrationSampleCount = 0

    private static let triggerSourceDefaultsKey = "MuseTriggerSource"
    // "V2" because addCalibrationSample/aimOriginAndForward changed how
    // this value is solved for and applied (local-space composition,
    // matching the visual gun, instead of a world-space rotation that
    // silently disagreed with it) — a value saved under the old math means
    // something different now, so this intentionally starts everyone at a
    // clean identity/zero instead of loading a stale, wrong correction.
    private static let calibrationDefaultsKeyPrefix = "MuseAimCorrectionV2"
    private static let muzzleOffsetDefaultsKeyPrefix = "MuseMuzzleOffsetV2"

    private func loadPreferences() {
        if let raw = UserDefaults.standard.string(forKey: Self.triggerSourceDefaultsKey),
           let saved = MuseTriggerSource(rawValue: raw) {
            triggerSource = saved
        }
        let defaults = UserDefaults.standard
        let xKey = Self.calibrationDefaultsKeyPrefix + "X"
        if defaults.object(forKey: xKey) != nil {
            let x = defaults.float(forKey: xKey)
            let y = defaults.float(forKey: Self.calibrationDefaultsKeyPrefix + "Y")
            let z = defaults.float(forKey: Self.calibrationDefaultsKeyPrefix + "Z")
            let w = defaults.float(forKey: Self.calibrationDefaultsKeyPrefix + "W")
            aimCorrection = simd_quatf(ix: x, iy: y, iz: z, r: w)
        }
        let offsetXKey = Self.muzzleOffsetDefaultsKeyPrefix + "X"
        if defaults.object(forKey: offsetXKey) != nil {
            muzzleOffset = SIMD3<Float>(
                defaults.float(forKey: offsetXKey),
                defaults.float(forKey: Self.muzzleOffsetDefaultsKeyPrefix + "Y"),
                defaults.float(forKey: Self.muzzleOffsetDefaultsKeyPrefix + "Z")
            )
        }
    }

    private func saveCalibration() {
        let defaults = UserDefaults.standard
        defaults.set(aimCorrection.imag.x, forKey: Self.calibrationDefaultsKeyPrefix + "X")
        defaults.set(aimCorrection.imag.y, forKey: Self.calibrationDefaultsKeyPrefix + "Y")
        defaults.set(aimCorrection.imag.z, forKey: Self.calibrationDefaultsKeyPrefix + "Z")
        defaults.set(aimCorrection.real, forKey: Self.calibrationDefaultsKeyPrefix + "W")
        defaults.set(muzzleOffset.x, forKey: Self.muzzleOffsetDefaultsKeyPrefix + "X")
        defaults.set(muzzleOffset.y, forKey: Self.muzzleOffsetDefaultsKeyPrefix + "Y")
        defaults.set(muzzleOffset.z, forKey: Self.muzzleOffsetDefaultsKeyPrefix + "Z")
    }

    /// Records one calibration sample and estimates the complete muzzle
    /// pose: a rotation plus local translation from the Muse to the muzzle.
    /// The translation is solved as the least-squares point closest to the
    /// calibrated aim rays across all samples, which removes the most
    /// noticeable close-range parallax from an off-center mounting.
    /// Call `resetCalibration()` first if you want to start over rather
    /// than refine the existing correction.
    func addCalibrationSample(targetWorldPosition: SIMD3<Float>) -> Bool {
        guard let anchor = aimAnchor, anchor.isAnchored else { return false }
        let matrix = anchor.transformMatrix(relativeTo: nil)
        let origin = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        let rotation = simd_float3x3(
            SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        )
        let desiredForwardWorld = targetWorldPosition - origin
        guard length(desiredForwardWorld) > 0.01 else { return false }
        // Solve for the correction in the anchor's LOCAL frame (undo its
        // current world rotation with `rotation.transpose` first) so the
        // result is a fixed mounting offset — the same convention
        // `aimOriginAndForward` and the rendered gun both use — rather than
        // a world-space rotation that would only happen to match this one
        // sample's device orientation.
        let localDesiredForward = normalize(rotation.transpose * desiredForwardWorld)
        let sampleCorrection = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: localDesiredForward)

        calibrationSampleCount += 1
        if calibrationSampleCount == 1 {
            aimCorrection = sampleCorrection
        } else {
            aimCorrection = simd_slerp(aimCorrection, sampleCorrection, 1.0 / Float(calibrationSampleCount))
        }
        calibrationSamples.append(CalibrationSample(rawTransform: matrix, targetWorldPosition: targetWorldPosition))
        updateMuzzleOffset()
        saveCalibration()
        return true
    }

    /// Finds the local point that lies closest to every calibrated target
    /// ray. Each sample constrains the muzzle to a line; the accumulated
    /// normal equations find their best common point in Muse-local space.
    private func updateMuzzleOffset() {
        guard calibrationSamples.count >= 2 else { return }

        var normalMatrix = simd_float3x3(.zero, .zero, .zero)
        var rightHandSide = SIMD3<Float>.zero

        for sample in calibrationSamples {
            let transform = sample.rawTransform
            let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let rotation = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )
            // Same local-space composition as aimOriginAndForward — see
            // that property's comment.
            let direction = normalize(rotation * aimCorrection.act(SIMD3<Float>(0, 0, -1)))
            let projection = matrix_identity_float3x3 - simd_float3x3(
                direction * direction.x,
                direction * direction.y,
                direction * direction.z
            )
            let inverseRotation = rotation.transpose
            normalMatrix += inverseRotation * projection * rotation
            rightHandSide += inverseRotation * projection * (sample.targetWorldPosition - origin)
        }

        guard abs(simd_determinant(normalMatrix)) > 0.0001 else { return }
        let estimatedOffset = simd_inverse(normalMatrix) * rightHandSide
        // An unstable calibration should never put the virtual muzzle many
        // meters from the tracked accessory. Keep a bad sample set from
        // creating an unusable saved pose.
        guard length(estimatedOffset) < 1.5 else { return }
        muzzleOffset = estimatedOffset
    }

    func resetCalibration() {
        aimCorrection = simd_quatf(real: 1, imag: .zero)
        muzzleOffset = SIMD3<Float>(0, 0, 0.12)
        calibrationSampleCount = 0
        calibrationSamples.removeAll()
        let defaults = UserDefaults.standard
        for suffix in ["X", "Y", "Z", "W"] {
            defaults.removeObject(forKey: Self.calibrationDefaultsKeyPrefix + suffix)
        }
        for suffix in ["X", "Y", "Z"] {
            defaults.removeObject(forKey: Self.muzzleOffsetDefaultsKeyPrefix + suffix)
        }
    }

    /// Fires once per discrete press of ANY control on the device (tip,
    /// primary button, or secondary button — debounced per-control, never
    /// repeatedly while held). GameState decides whether a given press means
    /// "pull" (no clay airborne yet) or "bang" (one already is). Voice
    /// "pull"/"bang" remain as a backup; the old amplitude-based audio click
    /// detector was removed entirely after it caused a real crash.
    let triggerPulled = PassthroughSubject<Void, Never>()

    /// Currently unused — there's no control left to dedicate to a separate
    /// menu button once every control fires `triggerPulled` (see that
    /// property's comment). Pause/exit goes through
    /// TrapRangeImmersiveView's fallback gesture instead. Kept so GameState
    /// doesn't need to change if a real menu control shows up later.
    let menuButtonPressed = PassthroughSubject<Void, Never>()

    init() {
        self.triggerSource = .any
        loadPreferences()
    }

    /// The RealityKit anchor tracking the Muse's "aim" pose. Attach your
    /// virtual barrel/sight/reticle entity as a child of this anchor.
    private(set) var aimAnchor: AnchorEntity?

    /// An entity that should always live under the current `aimAnchor`
    /// (e.g. Full immersion's virtual gun). Re-parented automatically
    /// whenever `setupAiming` (re)creates the anchor, so callers don't need
    /// to know about connect/reconnect timing.
    private var aimVisual: Entity?

    /// Registers (or replaces) the entity that should track the Muse's aim
    /// point for as long as it's connected. Safe to call before a device is
    /// connected — it attaches the moment `aimAnchor` exists.
    func attachAimVisual(_ entity: Entity) {
        aimVisual?.removeFromParent()
        // Apply the current calibration immediately — without this, a
        // freshly (re)attached visual would render at the RAW orientation
        // until the next time `aimCorrection` happens to change, which may
        // be never in a session where calibration was already done earlier.
        entity.orientation = visualOrientation
        entity.position = muzzleOffset
        aimVisual = entity
        aimAnchor?.addChild(entity)
    }

    private func applyAimVisualCorrection() {
        aimVisual?.orientation = visualOrientation
        aimVisual?.position = muzzleOffset
    }

    /// Root entity you should add to your RealityKit scene once available.
    /// It stays empty (no children) until an accessory connects and the
    /// aim anchor is created; the game view just adds this once at startup.
    let accessoryRoot = Entity()

    private var stylus: GCStylus?
    private var controller: GCController?
    private var hapticsEngine: CHHapticEngine?
    // Build 8 confirmed the single-designated-button approach doesn't work:
    // isConnected was true but the physical click did nothing, and nobody
    // could say for certain which named element (tip / primary / secondary)
    // the click the user meant actually corresponds to. Rather than keep
    // guessing which element Muse populates, every control independently
    // fires the trigger via its own pressedDidChangeHandler — whichever one
    // is physically real on this hardware just works, no naming/mapping
    // required, and no manual edge-detection since each handler already
    // fires once per discrete press/release.
    private var spatialTrackingSession: SpatialTrackingSession?
    private var cancellables = Set<AnyCancellable>()

    /// Whether RealityKit actually reports accessory anchor tracking as
    /// available — checked from `run(_:)`'s return value, which we used to
    /// silently discard. That omission is the real bug behind a crash that
    /// hit every single connection attempt (confirmed across 6+
    /// symbolicated TestFlight crash logs): `AnchorEntity(.accessory(...))`
    /// was being constructed unconditionally, including in the moment
    /// right after launch when the OS's own accessory-tracking
    /// authorization hadn't necessarily settled yet. `run(_:)` returns
    /// `UnavailableCapabilities?` precisely so callers can check this
    /// before touching the anchor API — see
    /// https://developer.apple.com/documentation/realitykit/spatialtrackingsession/run(_:)
    private var accessoryTrackingAvailable = false

    // MARK: Setup

    func start() async {
        // Run a SpatialTrackingSession configured for accessory tracking so
        // any accessory AnchorEntity we create actually gets live transforms.
        let session = SpatialTrackingSession()
        let configuration = SpatialTrackingSession.Configuration(tracking: [.accessory])
        self.spatialTrackingSession = session
        // Deliberately NOT checking `session.run()`'s result here — at cold
        // launch there's no accessory connected yet, so the OS has nothing
        // to authorize and would just report "unavailable" regardless of
        // real capability, permanently poisoning `accessoryTrackingAvailable`
        // before the Muse even shows up. The real check happens in
        // `refreshAccessoryAvailability()`, called once a device is
        // actually connected (and manually via `retryAccessoryTracking()`).
        _ = await session.run(configuration)

        // Listen for styli (Muse reports as a GCStylus with product category
        // "Spatial Stylus") connecting/disconnecting.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCStylusDidConnect,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let stylus = notification.object as? GCStylus else { return }
            Task { @MainActor in await self?.handleStylusConnected(stylus) }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCStylusDidDisconnect,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let stylus = notification.object as? GCStylus else { return }
            Task { @MainActor [weak self] in self?.handleStylusDisconnected(stylus) }
        }

        // Some accessories may enumerate as a full GCController with product
        // category "Spatial Controller" instead of a GCStylus. Handle both.
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let controller = notification.object as? GCController,
                  controller.productCategory == GCProductCategorySpatialController
            else { return }
            Task { @MainActor in await self?.handleControllerConnected(controller) }
        }

        // Pick up anything already connected before we started observing.
        for stylus in GCStylus.styli where stylus.productCategory == GCProductCategorySpatialStylus {
            await handleStylusConnected(stylus)
            break
        }
        for controller in GCController.controllers() where controller.productCategory == GCProductCategorySpatialController {
            await handleControllerConnected(controller)
            break
        }
    }

    // MARK: Connection handling

    private func handleStylusConnected(_ stylus: GCStylus) async {
        guard stylus.productCategory == GCProductCategorySpatialStylus else { return }
        self.stylus = stylus
        self.deviceName = stylus.vendorName ?? "Logitech Muse"
        // Checked NOW, with a real device present, not at cold launch — see
        // refreshAccessoryAvailability's comment for why that ordering
        // mattered.
        await refreshAccessoryAvailability()
        // REVERTED an unconditional call here (matching a third-party
        // reference implementation) after Build 12 crashed on launch,
        // before any permission prompt — exactly the symptom of the
        // original confirmed AnchorEntity crash this gate exists to
        // prevent. Whatever's different about our setup, unconditional
        // clearly isn't safe here even if it is elsewhere.
        if accessoryTrackingAvailable {
            await setupAiming(device: stylus)
        }
        setupHaptics(stylus: stylus)
        observeInputs(device: stylus)
        isConnected = true
        startAutoRetryLoop()
    }

    private func handleControllerConnected(_ controller: GCController) async {
        self.controller = controller
        self.deviceName = controller.vendorName ?? "Spatial Controller"
        await refreshAccessoryAvailability()
        if accessoryTrackingAvailable {
            await setupAiming(device: controller)
        }
        // This path previously never wired up button observation at all —
        // if Muse enumerates as a plain GCController instead of a GCStylus,
        // every button press was silently going nowhere no matter what
        // triggerSource was set to. Mirrors the "any control fires"
        // behavior from the stylus path.
        observeInputs(device: controller)
        isConnected = true
        startAutoRetryLoop()
    }

    private var autoRetryTask: Task<Void, Never>?

    /// The whole reason a manual "Retry Tracking" button exists at all:
    /// accessory-tracking authorization frequently doesn't settle on the
    /// very first connection attempt, but DOES succeed a few seconds later
    /// with no user action other than pressing that button again. Requiring
    /// someone to know that button exists, find it (previously only on the
    /// Home screen, then also added in-range after Home's retry didn't
    /// survive the Home→Range transition), and press it — possibly more
    /// than once — is exactly the "how do I even get this working" dead end
    /// reported this session. This automates the same retry the button
    /// performs: every 1.5s for the first ~15s after connecting, unless/
    /// until real tracking is confirmed live (`isAimTrackingLive`, which
    /// only flips true from an actual per-frame anchor check — see
    /// `pollOnce()` — not just from an anchor merely being created). The
    /// manual button stays too, both as a way to force an immediate retry
    /// without waiting, and as a safety net if this loop's window closes
    /// before tracking happens to settle.
    private func startAutoRetryLoop() {
        autoRetryTask?.cancel()
        autoRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self, !Task.isCancelled else { return }
                if self.isAimTrackingLive { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                await self.retryAccessoryTracking()
            }
        }
    }

    /// Re-runs the SpatialTrackingSession check for accessory-anchor
    /// authorization/support. Called the moment a device actually connects
    /// (see the comment in `start()` on why checking any earlier — before
    /// any accessory existed for the OS to authorize — permanently poisoned
    /// this to "unavailable"), and again from `retryAccessoryTracking()` as
    /// a manual safety net if that still isn't enough.
    private func refreshAccessoryAvailability() async {
        guard let session = spatialTrackingSession else { return }
        let configuration = SpatialTrackingSession.Configuration(tracking: [.accessory])
        let unavailable = await session.run(configuration)
        accessoryTrackingAvailable = !(unavailable?.anchor.contains(.accessory) ?? false)
        if !accessoryTrackingAvailable {
            aimStatus = "Accessory tracking UNAVAILABLE (auth/hardware) — fixed gun"
            print("TrapVisionPro: accessory anchor tracking unavailable (hardware or authorization) — aim will fall back to head-tracking.")
        }
    }

    /// Manual retry button in the UI — lets the user force another
    /// anchoring attempt without reconnecting the device (e.g. right after
    /// a Bluetooth/Muse power-cycle). Safe to call repeatedly. Re-gated on
    /// `accessoryTrackingAvailable` after Build 12's launch crash — see
    /// setupAiming's call sites.
    func retryAccessoryTracking() async {
        await refreshAccessoryAvailability()
        guard accessoryTrackingAvailable else { return }
        if let stylus {
            await setupAiming(device: stylus)
            // The stylus can be discovered before its input profile is
            // populated. Re-wiring here is safe (it replaces handlers) and
            // lets a tracking retry recover a trigger handler too.
            observeInputs(device: stylus)
        } else if let controller {
            await setupAiming(device: controller)
            observeInputs(device: controller)
        }
    }

    /// Called as the actual immersive range becomes active. A Muse can
    /// connect while the Home window is frontmost, when accessory poses
    /// aren't yet available. The old retry window then expires before the
    /// range opens, making the manual Retry Tracking button appear to be a
    /// required startup step. Repeat that safe, availability-gated setup
    /// automatically here instead.
    func activateForImmersiveRange() async {
        guard stylus != nil || controller != nil else {
            aimStatus = "Waiting for Logitech Muse connection"
            return
        }
        await retryAccessoryTracking()
        if !isAimTrackingLive {
            startAutoRetryLoop()
        }
    }

    private func handleStylusDisconnected(_ stylus: GCStylus) {
        guard self.stylus === stylus else { return }
        autoRetryTask?.cancel()
        self.stylus = nil
        isConnected = false
        isAimTrackingLive = false
        deviceName = "No accessory connected"
        aimAnchor?.removeFromParent()
        aimAnchor = nil
    }

    /// Creates a RealityKit AnchorEntity tracking the accessory's "aim"
    /// location. Only called when `accessoryTrackingAvailable` is true —
    /// this exact call used to crash RealityKit's `HasAnchoring.anchoring`
    /// setter every single time early on (6+ symbolicated TestFlight crash
    /// logs, all identical). Briefly tried calling this unconditionally
    /// (matching a third-party reference implementation that apparently
    /// gets away with it) in Build 12 — it reintroduced the exact same
    /// launch crash, before any permission prompt, so the gate is back.
    /// Whatever's different about our setup, unconditional isn't safe here.
    private func setupAiming(device: GCDevice) async {
        do {
            let source = try await AnchoringComponent.AccessoryAnchoringSource(device: device)
            print("TrapVisionPro: accessory locations available: \(source.accessoryLocations)")
            guard let location = source.locationName(named: "aim") else {
                aimStatus = "Device has no 'aim' location — fixed gun"
                isAimTrackingLive = false
                print("TrapVisionPro: accessory has no 'aim' location, cannot anchor.")
                return
            }
            let anchor = AnchorEntity(
                .accessory(from: source, location: location),
                trackingMode: .continuous
            )
            self.aimAnchor?.removeFromParent()
            accessoryRoot.addChild(anchor)
            self.aimAnchor = anchor
            if let aimVisual {
                aimVisual.orientation = visualOrientation
                aimVisual.position = muzzleOffset
                anchor.addChild(aimVisual)
            }
            aimStatus = "Aim anchor created — tracking live"
            // Creating an anchor is not the same as receiving a valid pose.
            // `pollOnce()` publishes the actual isAnchored state each frame.
            isAimTrackingLive = false
        } catch {
            aimStatus = "Anchor source failed: \(error.localizedDescription)"
            isAimTrackingLive = false
            print("TrapVisionPro: failed to create accessory anchoring source: \(error)")
        }
    }

    // MARK: Input handling (buttons / pressure)

    /// Switched from a speculative queue-based `inputStateAvailableHandler`/
    /// `nextInputState()` pattern (which never produced a single working
    /// button press across every build so far) to the per-button
    /// `pressedDidChangeHandler`/`valueDidChangeHandler` pattern confirmed
    /// working in a real published Logitech Muse + visionOS integration
    /// (https://medium.com/@igor.tarantino/how-to-integrate-a-logitech-muse-pen-inputs-into-your-visionos-xcode-project-0e14741eaa9d).
    /// Each handler already fires once per discrete state change (press AND
    /// release), so no extra edge-detection bookkeeping is needed here —
    /// `pressedDidChangeHandler`'s `pressed` argument already tells us
    /// exactly that.
    ///
    /// `device.input` can briefly be nil right at connect time. Keep trying
    /// through the normal connection-settling window rather than giving up
    /// after a single half-second retry.
    private func observeInputs(device: GCStylus, attempt: Int = 0) {
        guard let input = device.input else {
            if attempt < 10 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    self?.observeInputs(device: device, attempt: attempt + 1)
                }
            } else {
                aimStatus += " (also: stylus has no input profile — buttons can't work)"
            }
            return
        }

        input.buttons[.stylusPrimaryButton]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: true, source: "Primary button") }
        }
        input.buttons[.stylusSecondaryButton]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: false, source: "Secondary button") }
        }
        input.buttons[.stylusTip]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: false, source: "Tip") }
        }
        // Continuous pressure values, purely for the on-screen debug
        // readout — not used for trigger edge-detection anymore.
        input.buttons[.stylusTip]?.pressedInput.valueDidChangeHandler = { [weak self] _, _, value in
            Task { @MainActor [weak self] in self?.lastTipPressure = value }
        }
        input.buttons[.stylusSecondaryButton]?.pressedInput.valueDidChangeHandler = { [weak self] _, _, value in
            Task { @MainActor [weak self] in self?.lastSecondaryPressure = value }
        }
    }

    /// Which control(s) fire the trigger depends on `triggerSource` — see
    /// that type's doc comment. `.any` (the default, and the only option
    /// that behaved this way before trigger mapping existed) still lets
    /// every control fire.
    private func handleDiscreteControl(pressed: Bool, isPrimary: Bool, source: String) {
        if isPrimary { isPrimaryButtonPressed = pressed }
        guard pressed else { return }
        lastInputEvent = "\(source) pressed"
        guard matchesTriggerSource(source) else { return }
        triggerPulled.send()
        playShotHaptic()
    }

    private func matchesTriggerSource(_ source: String) -> Bool {
        switch triggerSource {
        case .any: return true
        case .primaryButton: return source == "Primary button"
        case .secondaryButton: return source == "Secondary button"
        case .tip: return source == "Tip"
        }
    }

    /// Tracks the pressed state of every button on a plain GCController's
    /// physical input profile, by name — there's no fixed "tip/primary/
    /// secondary" naming here the way GCStylus has, and no way to know in
    /// advance which named element(s) Muse actually populates on this path.
    private var wasControllerButtonPressed: [String: Bool] = [:]

    /// GCController delivers input via a per-button value-changed callback
    /// rather than GCStylus's state queue. Every button on the physical
    /// input profile gets its own handler, so any of them firing counts as
    /// a trigger pull — matching the "every control works" behavior on the
    /// stylus path.
    private func observeInputs(device: GCController) {
        for button in device.physicalInputProfile.allButtons {
            let name = button.localizedName ?? button.aliases.first ?? "unknown"
            button.valueChangedHandler = { [weak self] _, _, isPressed in
                Task { @MainActor [weak self] in
                    self?.processControllerButton(name: name, isPressed: isPressed)
                }
            }
        }
    }

    private func processControllerButton(name: String, isPressed: Bool) {
        isPrimaryButtonPressed = isPressed
        let wasPressed = wasControllerButtonPressed[name] ?? false
        if isPressed && !wasPressed {
            lastInputEvent = "\(name) pressed"
            // GCController button names are arbitrary strings (no fixed
            // "primary/secondary/tip" the way GCStylus has), so a specific
            // triggerSource selection is matched loosely by name rather
            // than exactly — `.any` always fires regardless.
            let matches: Bool
            switch triggerSource {
            case .any: matches = true
            case .primaryButton: matches = name.localizedCaseInsensitiveContains("primary")
            case .secondaryButton: matches = name.localizedCaseInsensitiveContains("secondary")
            case .tip: matches = name.localizedCaseInsensitiveContains("tip")
            }
            if matches {
                triggerPulled.send()
                playShotHaptic()
            }
        }
        wasControllerButtonPressed[name] = isPressed
    }

    /// Publishes real accessory-anchor availability for the view. Input is
    /// event-driven, but anchoring can change independently when tracking
    /// resolves or drops, so this small per-frame check prevents the HUD
    /// from claiming the Muse gun is live before it has a valid transform.
    func pollOnce() {
        let live = aimAnchor?.isAnchored ?? false
        if isAimTrackingLive != live {
            isAimTrackingLive = live
            if live {
                aimStatus = "Aim anchor tracking live"
            } else if aimAnchor != nil {
                aimStatus = "Aim anchor waiting for tracking"
            }
        }
    }

    // MARK: Haptics

    private func setupHaptics(stylus: GCStylus) {
        guard let haptics = stylus.haptics else { return }
        guard let engine = haptics.createEngine(withLocality: .default) else { return }
        hapticsEngine = engine
        try? engine.start()
    }

    /// A two-part "recoil" haptic: a very sharp, intense transient for the
    /// initial kick, immediately followed by a short decaying continuous
    /// rumble for the follow-through — closer to a real shotgun's recoil
    /// feel than a single flat click.
    private func playShotHaptic() {
        guard let engine = hapticsEngine else { return }
        do {
            let kickSharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
            let kickIntense = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let kick = CHHapticEvent(eventType: .hapticTransient,
                                      parameters: [kickSharp, kickIntense],
                                      relativeTime: 0)

            let rumbleSharp = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            let rumbleIntenseStart = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.75)
            let rumble = CHHapticEvent(eventType: .hapticContinuous,
                                        parameters: [rumbleSharp, rumbleIntenseStart],
                                        relativeTime: 0.01,
                                        duration: 0.18)

            // Decay the rumble's intensity over its short life for a
            // punch-then-fade feel rather than a flat buzz.
            let decayCurve = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1.0),
                    CHHapticParameterCurve.ControlPoint(relativeTime: 0.18, value: 0.0)
                ],
                relativeTime: 0.01
            )

            let pattern = try CHHapticPattern(events: [kick, rumble], parameterCurves: [decayCurve])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("TrapVisionPro: haptic playback failed: \(error)")
        }
    }

    /// Fallback for people without a Muse: manually trigger a shot (e.g. from
    /// an air-tap gesture or a look-and-tap on the reticle).
    func fireManualTrigger() {
        triggerPulled.send()
    }

    /// The Muse's RAW current world-space aim transform (no calibration
    /// applied), if connected & tracked. Explicitly resolved relative to
    /// nil (the scene root) so it stays correct regardless of any
    /// transform applied higher up the hierarchy (e.g. the field
    /// repositioning itself under the player per station, or the
    /// recoil/shake animations) — those must never affect where the Muse
    /// itself is actually aiming. Used directly only by calibration
    /// sampling; gameplay should use `aimOriginAndForward` instead, which
    /// applies the calibration correction.
    var aimWorldMatrix: float4x4? {
        guard let aimAnchor, aimAnchor.isAnchored else { return nil }
        return aimAnchor.transformMatrix(relativeTo: nil)
    }

    /// The Muse's current world-space aim origin/forward, WITH calibration
    /// applied (identity rotation if never calibrated, so this is safe to
    /// use unconditionally). This is what actual gameplay (hit-testing,
    /// "am I aiming at the trap house") should read — `aimWorldMatrix` is
    /// the uncorrected raw reading, kept around only for calibration
    /// sampling itself.
    var aimOriginAndForward: (origin: SIMD3<Float>, forward: SIMD3<Float>)? {
        guard let matrix = aimWorldMatrix else { return nil }
        let origin = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        let rotation = simd_float3x3(
            SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        )
        // aimCorrection is a fixed LOCAL-space offset — how the barrel sits
        // inside the housing relative to the Muse's own frame, independent
        // of whichever way the whole device currently points. It must
        // compose the same way the rendered gun does (the anchor's world
        // rotation, THEN the local correction, i.e. `rotation * correction`
        // acting on local -Z) — not as a plain world-space rotation of the
        // raw forward vector. Those two only ever agreed while aimCorrection
        // was still identity (before calibration did anything); the moment
        // a real correction existed, the visual gun and this hit-ray pointed
        // in different directions, which is exactly the "looks aimed right,
        // nothing breaks" bug reported after the first real calibration.
        let localForward = aimCorrection.act(SIMD3<Float>(0, 0, -1))
        let forward = rotation * localForward
        return (origin + rotation * muzzleOffset, forward)
    }
}
