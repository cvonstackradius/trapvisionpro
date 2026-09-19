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

@MainActor
final class MuseAccessoryManager: ObservableObject {

    // MARK: Published state the UI / game logic can observe

    @Published var isConnected: Bool = false
    @Published var deviceName: String = "No accessory connected"
    @Published var lastTipPressure: Float = 0
    @Published var lastSecondaryPressure: Float = 0
    @Published var isPrimaryButtonPressed: Bool = false

    /// Plain-English state of accessory aim-tracking, meant to be shown
    /// directly on-screen (HomeView) since we have no reliable way to reach
    /// an Xcode console on this device yet. Every branch that decides
    /// whether the tilt-tracked gun will work updates this.
    @Published var aimStatus: String = "Not started"

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
        aimVisual = entity
        aimAnchor?.addChild(entity)
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
            Task { @MainActor in self?.handleStylusDisconnected(stylus) }
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
        } else if let controller {
            await setupAiming(device: controller)
        }
    }

    private func handleStylusDisconnected(_ stylus: GCStylus) {
        guard self.stylus === stylus else { return }
        self.stylus = nil
        isConnected = false
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
                anchor.addChild(aimVisual)
            }
            aimStatus = "Aim anchor created — tracking live"
        } catch {
            aimStatus = "Anchor source failed: \(error.localizedDescription)"
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
    /// `device.input` can briefly be nil right at connect time — the old
    /// code silently gave up forever if that happened (no retry, no
    /// visible error), which would look identical to "button does
    /// nothing." One retry after a beat covers that window.
    private func observeInputs(device: GCStylus, attempt: Int = 0) {
        guard let input = device.input else {
            if attempt == 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self?.observeInputs(device: device, attempt: 1)
                }
            } else {
                aimStatus += " (also: stylus has no input profile — buttons can't work)"
            }
            return
        }

        input.buttons[.stylusPrimaryButton]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: true) }
        }
        input.buttons[.stylusSecondaryButton]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: false) }
        }
        input.buttons[.stylusTip]?.pressedInput.pressedDidChangeHandler = { [weak self] _, _, pressed in
            Task { @MainActor [weak self] in self?.handleDiscreteControl(pressed: pressed, isPrimary: false) }
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

    /// Any of the three stylus controls firing a press (not release) counts
    /// as a trigger pull — see the type-level comment on `triggerPulled`.
    private func handleDiscreteControl(pressed: Bool, isPrimary: Bool) {
        if isPrimary { isPrimaryButtonPressed = pressed }
        guard pressed else { return }
        triggerPulled.send()
        playShotHaptic()
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
            triggerPulled.send()
            playShotHaptic()
        }
        wasControllerButtonPressed[name] = isPressed
    }

    /// Kept as a no-op for source compatibility — `GameState.tick(dt:)`
    /// still calls this once per frame, but actual stylus readings now
    /// arrive via `observeInputs`'s queued handler above, which is the
    /// correct/documented way to read a GCStylus's input.
    func pollOnce() {}

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

    /// The Muse's current world-space aim transform, if connected & tracked.
    /// Explicitly resolved relative to nil (the scene root) so it stays
    /// correct regardless of any transform applied higher up the hierarchy
    /// (e.g. the field repositioning itself under the player per station,
    /// or the recoil/shake animations) — those must never affect where the
    /// Muse itself is actually aiming.
    var aimWorldMatrix: float4x4? {
        guard let aimAnchor, aimAnchor.isAnchored else { return nil }
        return aimAnchor.transformMatrix(relativeTo: nil)
    }
}
