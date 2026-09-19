//
//  TrapRangeImmersiveView.swift
//  TrapVisionPro
//
//  Full-space RealityView hosting the trap field. Draws a simple grey box
//  for the trap house (with a real idle oscillation matching how an actual
//  trap machine swings before throwing) and 5 station markers, all under
//  `game.fieldRoot` — which repositions itself under the player whenever
//  the selected station changes, so switching stations feels like walking
//  the line without actually having to move around your room. Anchors the
//  Muse's virtual aim tracking, and — when no Muse is connected — shows a
//  head-locked virtual shotgun + reticle with look-and-tap firing.
//
//  HUD differs by mode: Practice keeps a helpful head-locked readout;
//  Round keeps the screen clean — score lives on a small world-anchored
//  sign near the trap house instead of a menu that follows your gaze. A
//  long-press look+pinch fallback opens a minimal pause/exit overlay in
//  either mode (every Muse control fires the shooting trigger, so none is
//  free for pause).
//

import SwiftUI
import RealityKit
import Combine
import simd

struct TrapRangeImmersiveView: View {
    @ObservedObject var game: GameState
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow

    @State private var fallbackGunAnchor: AnchorEntity?
    @State private var fallbackGunGroup: Entity?
    @State private var museGunOverlay: Entity?
    @State private var practiceHudAnchor: Entity?
    @State private var pauseMenuAnchor: Entity?
    @State private var recenterBarAnchor: Entity?
    @State private var headAnchorRef: AnchorEntity?
    @State private var trapModeGroup: Entity?
    @State private var patterningBoard: Entity?
    @State private var patterningImpactsContainer: Entity?
    @State private var lastRenderedPatterningDistance: PatterningDistance?
    @State private var lastRenderedImpacts: [SIMD2<Float>] = []
    @State private var shotSubscription: AnyCancellable?
    @State private var recoilTask: Task<Void, Never>?
    @State private var shakeTask: Task<Void, Never>?

    var body: some View {
        RealityView { content, attachments in
            content.add(game.sceneRoot)
            buildScenery(into: game.fieldRoot)

            // Trap house + station markers live under their own group so
            // they can be hidden together in patterning mode, which shows
            // a stationary target board instead.
            let trapGroup = Entity()
            game.fieldRoot.addChild(trapGroup)
            buildFieldGeometry(into: trapGroup)
            trapModeGroup = trapGroup
            // Oscillation disabled — read as a bug ("rotating black box")
            // rather than the intended pre-throw wobble. Simpler and
            // clearer to keep the trap house stationary for now.

            let board = buildPatterningBoard()
            game.fieldRoot.addChild(board)
            patterningBoard = board
            let impactsContainer = Entity()
            board.addChild(impactsContainer)
            patterningImpactsContainer = impactsContainer

            // World-anchored scoreboard: a physical sign standing to the
            // side of the trap house, showing score + MISS flash. It does
            // NOT move with your gaze — you glance at it the way you'd
            // glance at a real scoreboard, keeping Round mode's screen
            // otherwise completely clean.
            if let scoreboard = attachments.entity(for: "scoreboard") {
                scoreboard.position = TrapField.trapHousePosition + SIMD3<Float>(2.0, 0.6, 0)
                game.fieldRoot.addChild(scoreboard)
            }

            let headAnchor = AnchorEntity(.head)
            let gunGroup = buildFallbackGunOverlay()
            headAnchor.addChild(gunGroup)
            content.add(headAnchor)
            fallbackGunAnchor = headAnchor
            fallbackGunGroup = gunGroup
            headAnchorRef = headAnchor

            // Full immersion's stand-in for the real gun (which passthrough
            // would otherwise show) — tracks the Muse's real-world aim
            // point instead of the head.
            let museOverlay = buildMuseTrackedGunOverlay()
            game.museManager.attachAimVisual(museOverlay)
            museGunOverlay = museOverlay

            let museMuzzleFlash = buildMuzzleFlash()
            museMuzzleFlash.position = SIMD3<Float>(0, 0.017, 0)
            museOverlay.addChild(museMuzzleFlash)

            // Same model as the muse-tracked overlay, so the muzzle sits at
            // the same local point (0, 0.017, 0) — the bead's position.
            let fallbackMuzzleFlash = buildMuzzleFlash()
            fallbackMuzzleFlash.position = SIMD3<Float>(0, 0.017, 0)
            gunGroup.addChild(fallbackMuzzleFlash)

            // Practice-only head-locked HUD (hidden entirely in Round mode).
            if let practiceHud = attachments.entity(for: "practiceHud") {
                practiceHud.position = SIMD3<Float>(0.22, -0.18, -0.6)
                headAnchor.addChild(practiceHud)
                practiceHudAnchor = practiceHud
            }

            // Pause/exit overlay — hidden unless game.isPaused.
            if let pauseMenu = attachments.entity(for: "pauseMenu") {
                pauseMenu.position = SIMD3<Float>(0, 0, -0.8)
                headAnchor.addChild(pauseMenu)
                pauseMenuAnchor = pauseMenu
            }

            // Bottom-of-view control bar — visible in both modes. Aim runs
            // on head-direction fallback right now (no real Muse tilt
            // tracking yet), so being able to re-anchor the field to
            // wherever you're actually standing/facing matters more than
            // it otherwise would.
            if let recenterBar = attachments.entity(for: "recenterBar") {
                recenterBar.position = SIMD3<Float>(0, -0.35, -0.6)
                headAnchor.addChild(recenterBar)
                recenterBarAnchor = recenterBar
            }

            shotSubscription = game.shotFired.sink { [weak gunGroup, weak museMuzzleFlash, weak fallbackMuzzleFlash] in
                Task { @MainActor in
                    if let gunGroup { performRecoil(on: gunGroup) }
                    performSceneShake(on: game.sceneRoot)
                    if let museMuzzleFlash { performMuzzleFlash(on: museMuzzleFlash) }
                    if let fallbackMuzzleFlash { performMuzzleFlash(on: fallbackMuzzleFlash) }
                }
            }

            game.fallbackAimProvider = { [weak headAnchor] in
                guard let headAnchor, headAnchor.isAnchored else {
                    return (SIMD3<Float>(0, 1.6, 0), SIMD3<Float>(0, 0, -1))
                }
                let transform = headAnchor.transformMatrix(relativeTo: nil)
                let origin = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                return (origin, forward)
            }
        } update: { content, attachments in
            // Fallback stays on unconditionally for now — real Muse-tilt
            // tracking's authorization check was just fixed but isn't yet
            // confirmed working on-device, so don't hide the only gun
            // visual that's guaranteed to render. The rod (museGunOverlay)
            // also shows whenever a Muse is connected + Full immersion is
            // picked, so if real tracking IS working now, you'll see it —
            // as a thin rod with a red tip, distinct from the flat photo —
            // moving independently of the photo behind it.
            fallbackGunAnchor?.isEnabled = true
            museGunOverlay?.isEnabled = game.museConnected && game.isFullImmersion
            practiceHudAnchor?.isEnabled = (game.mode == .practice)
            pauseMenuAnchor?.isEnabled = game.isPaused

            let isPatterning = (game.mode == .patterning)
            trapModeGroup?.isEnabled = !isPatterning
            patterningBoard?.isEnabled = isPatterning
            if isPatterning {
                if lastRenderedPatterningDistance != game.patterningDistance {
                    patterningBoard?.position = SIMD3<Float>(0, 1.4, -game.patterningDistance.meters)
                    lastRenderedPatterningDistance = game.patterningDistance
                }
                refreshPatterningImpacts()
            }
        } attachments: {
            Attachment(id: "scoreboard") {
                ScoreboardView(game: game)
            }
            Attachment(id: "practiceHud") {
                PracticeHUDView(game: game)
            }
            Attachment(id: "pauseMenu") {
                PauseMenuView(game: game)
            }
            Attachment(id: "recenterBar") {
                RecenterBarView(game: game, action: recenterField)
            }
        }
        .gesture(
            // Always available, regardless of `museConnected` — that flag
            // has proven unreliable in practice (a Muse can register as
            // "connected" while its button/pressure input isn't actually
            // getting through), so gating pinch-to-fire behind it left
            // people with no working input at all. Look+pinch now works
            // unconditionally as a guaranteed fallback alongside the Muse
            // and voice commands, never blocked by them.
            SpatialTapGesture()
                .onEnded { _ in
                    if game.isPaused { return }
                    game.manualTrigger()
                }
        )
        .simultaneousGesture(
            // Same reasoning — long-press-to-toggle-menu always available,
            // not gated behind museConnected.
            LongPressGesture(minimumDuration: 0.8)
                .onEnded { _ in
                    game.toggleMenu()
                }
        )
        .task {
            while !Task.isCancelled {
                game.tick(dt: 1.0 / 60.0)
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 60)
            }
        }
        .onChange(of: game.exitRequested) { _, requested in
            guard requested else { return }
            Task {
                await dismissImmersiveSpace()
                openWindow(id: "Home")
            }
        }
    }

    // MARK: Recenter

    /// Re-anchors the field to wherever you're currently standing and
    /// facing. See GameState.recenterField's doc comment for why this
    /// matters more than usual right now (head-direction aim fallback).
    private func recenterField() {
        guard let headAnchor = headAnchorRef, headAnchor.isAnchored else { return }
        let transform = headAnchor.transformMatrix(relativeTo: nil)
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        game.recenterField(headPosition: position, headForward: forward)
    }

    // MARK: Patterning range

    /// A stationary target board: white square, a small red aim-point dot
    /// dead center (what you hold the bead on), and a printed distance
    /// label. Repositioned along the field's local -Z by the update
    /// closure whenever `game.patterningDistance` changes.
    private func buildPatterningBoard() -> Entity {
        let board = Entity()

        let boardMaterial = SimpleMaterial(color: .init(white: 0.92, alpha: 1.0), roughness: 0.9, isMetallic: false)
        let boardFace = ModelEntity(mesh: .generatePlane(width: 1.2, height: 1.2), materials: [boardMaterial])
        boardFace.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        board.addChild(boardFace)

        // Thin crosshair lines through center — makes it much easier to
        // read exactly how far off (and which direction) the pattern's
        // center lands, not just "somewhere on the board."
        let lineMaterial = UnlitMaterial(color: .init(white: 0.6, alpha: 1.0))
        let horizontalLine = ModelEntity(mesh: .generateBox(width: 1.2, height: 0.006, depth: 0.002), materials: [lineMaterial])
        horizontalLine.position = SIMD3<Float>(0, 0, -0.002)
        board.addChild(horizontalLine)
        let verticalLine = ModelEntity(mesh: .generateBox(width: 0.006, height: 1.2, depth: 0.002), materials: [lineMaterial])
        verticalLine.position = SIMD3<Float>(0, 0, -0.002)
        board.addChild(verticalLine)

        // Aim-point dot — hold the bead here.
        let aimDot = ModelEntity(mesh: .generateSphere(radius: 0.02), materials: [UnlitMaterial(color: .systemRed)])
        aimDot.position = SIMD3<Float>(0, 0, -0.003)
        board.addChild(aimDot)

        return board
    }

    /// Rebuilds the pellet-impact dots on the patterning board from
    /// `game.lastPatternImpacts`, but only when that array has actually
    /// changed — `update` re-runs on every published-state change (e.g.
    /// live tip-pressure readouts while a button is held), and rebuilding
    /// ~400 tiny entities on every one of those would be wasteful.
    private func refreshPatterningImpacts() {
        guard game.lastPatternImpacts != lastRenderedImpacts else { return }
        lastRenderedImpacts = game.lastPatternImpacts
        guard let container = patterningImpactsContainer else { return }
        container.children.removeAll()

        let impactMaterial = UnlitMaterial(color: .init(white: 0.05, alpha: 1.0))
        for impact in game.lastPatternImpacts {
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [impactMaterial])
            dot.position = SIMD3<Float>(impact.x, impact.y, -0.001)
            container.addChild(dot)
        }
    }

    // MARK: Scenery — procedural, no image asset required
    //
    // The old version of this loaded a "trap_house_backdrop.jpg" from the
    // bundle — that file was never actually added to the Xcode target in
    // any build, so this was a silent no-op every single time (confirmed:
    // no Resources/Backdrop folder, no reference in the project file).
    // Mixed immersion was left with nothing but a distant grey box and a
    // few thin markers — everything close in front of you was just empty
    // passthrough. This replaces it with simple procedural scenery (sky,
    // ground, a few trees) that can't silently fail to load, giving both
    // immersion modes something to actually look at.

    private func buildScenery(into root: Entity) {
        let skyWidth: Float = 60
        let skyHeight: Float = 24
        var skyMaterial = UnlitMaterial()
        skyMaterial.color = .init(tint: .init(red: 0.55, green: 0.75, blue: 0.95, alpha: 1.0))
        let sky = ModelEntity(mesh: .generatePlane(width: skyWidth, height: skyHeight), materials: [skyMaterial])
        sky.position = SIMD3<Float>(
            TrapField.trapHousePosition.x,
            skyHeight / 2 - 1.5,
            TrapField.trapHousePosition.z - 6
        )
        sky.orientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0))
        root.addChild(sky)

        var groundMaterial = SimpleMaterial()
        groundMaterial.color = .init(tint: .init(red: 0.30, green: 0.45, blue: 0.22, alpha: 1.0))
        let ground = ModelEntity(mesh: .generatePlane(width: 70, depth: 70), materials: [groundMaterial])
        ground.position = SIMD3<Float>(TrapField.trapHousePosition.x, 0, TrapField.trapHousePosition.z + 10)
        root.addChild(ground)

        // A handful of simple trees (cone + cylinder) lining both sides of
        // the field, between the stations and the house — enough visual
        // reference to judge distance/depth without pretending to be a
        // real tree line.
        let treeXOffsets: [Float] = [-11, -8, 8, 11]
        let treeZOffsets: [Float] = [-11, -4, 3]
        for xOffset in treeXOffsets {
            for zOffset in treeZOffsets {
                let tree = buildTree()
                tree.position = SIMD3<Float>(
                    TrapField.trapHousePosition.x + xOffset,
                    0,
                    TrapField.trapHousePosition.z + zOffset
                )
                root.addChild(tree)
            }
        }
    }

    private func buildTree() -> Entity {
        let tree = Entity()

        var trunkMaterial = SimpleMaterial()
        trunkMaterial.color = .init(tint: .init(red: 0.36, green: 0.25, blue: 0.16, alpha: 1.0))
        let trunk = ModelEntity(mesh: .generateCylinder(height: 2.2, radius: 0.15), materials: [trunkMaterial])
        trunk.position = SIMD3<Float>(0, 1.1, 0)
        tree.addChild(trunk)

        var canopyMaterial = SimpleMaterial()
        canopyMaterial.color = .init(tint: .init(red: 0.20, green: 0.42, blue: 0.20, alpha: 1.0))
        let canopy = ModelEntity(mesh: .generateCone(height: 3.0, radius: 1.1), materials: [canopyMaterial])
        canopy.position = SIMD3<Float>(0, 3.2, 0)
        tree.addChild(canopy)

        return tree
    }

    // MARK: Field geometry — stupid simple grey boxes, real-world positions

    private func buildFieldGeometry(into root: Entity) {
        let houseMesh = MeshResource.generateBox(width: 1.2, height: 1.0, depth: 1.2)
        var houseMaterial = SimpleMaterial()
        houseMaterial.color = .init(tint: .init(white: 0.35, alpha: 1.0))
        let house = ModelEntity(mesh: houseMesh, materials: [houseMaterial])
        house.position = TrapField.trapHousePosition
        root.addChild(house)

        for station in TrapField.stations {
            let markerMesh = MeshResource.generateCylinder(height: 0.02, radius: 0.35)
            var markerMaterial = SimpleMaterial()
            markerMaterial.color = .init(tint: .init(white: station.id == game.currentStationNumber ? 0.9 : 0.6, alpha: 1.0))
            let marker = ModelEntity(mesh: markerMesh, materials: [markerMaterial])
            marker.position = station.shooterPosition
            root.addChild(marker)
        }
    }

    // MARK: Recoil & shake feedback

    private func performRecoil(on gunGroup: Entity) {
        recoilTask?.cancel()
        let restPosition = gunGroup.position
        let restOrientation = gunGroup.orientation

        let kickPosition = restPosition + SIMD3<Float>(0, 0.02, 0.06)
        let kickOrientation = restOrientation * simd_quatf(angle: -0.18, axis: SIMD3<Float>(1, 0, 0))

        recoilTask = Task { @MainActor in
            let kickSteps = 3
            let kickDuration: UInt64 = 12_000_000
            for step in 1...kickSteps {
                let t = Float(step) / Float(kickSteps)
                gunGroup.position = lerp(restPosition, kickPosition, t)
                gunGroup.orientation = simd_slerp(restOrientation, kickOrientation, t)
                try? await Task.sleep(nanoseconds: kickDuration)
                if Task.isCancelled { return }
            }
            let returnSteps = 8
            let returnDuration: UInt64 = 18_000_000
            for step in 1...returnSteps {
                let t = Float(step) / Float(returnSteps)
                gunGroup.position = lerp(kickPosition, restPosition, easeOut(t))
                gunGroup.orientation = simd_slerp(kickOrientation, restOrientation, easeOut(t))
                try? await Task.sleep(nanoseconds: returnDuration)
                if Task.isCancelled { return }
            }
            gunGroup.position = restPosition
            gunGroup.orientation = restOrientation
        }
    }

    private func performSceneShake(on root: Entity) {
        shakeTask?.cancel()
        let restPosition = root.position
        let restOrientation = root.orientation

        shakeTask = Task { @MainActor in
            let shakeSteps = 5
            let stepDuration: UInt64 = 14_000_000
            for step in 0..<shakeSteps {
                let decay = 1.0 - Float(step) / Float(shakeSteps)
                let jitter = SIMD3<Float>(
                    Float.random(in: -1...1),
                    Float.random(in: -1...1),
                    0
                ) * 0.015 * decay
                root.position = restPosition + jitter
                root.orientation = restOrientation * simd_quatf(
                    angle: Float.random(in: -0.01...0.01) * decay,
                    axis: SIMD3<Float>(0, 0, 1)
                )
                try? await Task.sleep(nanoseconds: stepDuration)
                if Task.isCancelled { return }
            }
            root.position = restPosition
            root.orientation = restOrientation
        }
    }

    private func easeOut(_ t: Float) -> Float { 1 - (1 - t) * (1 - t) }
    private func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }

    // MARK: Muzzle flash

    /// A bright core plus radiating spikes, scaled to zero until fired — a
    /// classic muzzle-flash star shape when viewed roughly down the
    /// barrel, which is exactly the angle you're at right after firing.
    private func buildMuzzleFlash() -> Entity {
        let flash = Entity()

        let core = ModelEntity(mesh: .generateSphere(radius: 0.03), materials: [UnlitMaterial(color: .white)])
        flash.addChild(core)

        let spikeMaterial = UnlitMaterial(color: .init(red: 1.0, green: 0.7, blue: 0.2, alpha: 1.0))
        let spikeCount = 8
        let spikeLength: Float = 0.1
        for i in 0..<spikeCount {
            let angle = (Float(i) / Float(spikeCount)) * 2 * .pi
            let spike = ModelEntity(mesh: .generateCone(height: spikeLength, radius: 0.014), materials: [spikeMaterial])
            // Cones point along local +Y by default — rotate each to point
            // outward along its own spoke direction in the X/Y plane
            // (perpendicular to the barrel), then slide it out along that
            // same direction so its base sits at the core instead of its
            // center.
            let direction = SIMD3<Float>(cos(angle), sin(angle), 0)
            spike.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: direction)
            spike.position = direction * (spikeLength / 2)
            flash.addChild(spike)
        }

        flash.scale = .zero
        return flash
    }

    /// Quick pop-and-fade via scale alone (no material/opacity animation
    /// needed) — up in ~40% of the duration, back to nothing over the rest.
    private func performMuzzleFlash(on flash: Entity) {
        let steps = 6
        let stepDuration: UInt64 = 12_000_000
        Task { @MainActor in
            for step in 0...steps {
                if Task.isCancelled { return }
                let t = Float(step) / Float(steps)
                let scale = t < 0.4 ? (t / 0.4) : max(0, 1 - (t - 0.4) / 0.6)
                flash.scale = SIMD3<Float>(repeating: scale)
                try? await Task.sleep(nanoseconds: stepDuration)
            }
            flash.scale = .zero
        }
    }

    // MARK: Virtual shotgun overlay
    //
    // Two placements share the same 3D model (buildMuseTrackedGunOverlay):
    //   - Head-locked (below): shown when no Muse is connected, or as the
    //     visible gun in Mixed immersion. A flat photo used to stand in
    //     here, but a 2D image pinned close to the eye reads as too steep/
    //     distorted and can't be "shouldered" properly. A real 3D gun,
    //     fixed at a static shouldered-on-the-right pose, looks right from
    //     any head angle and sits at a natural distance instead.
    //   - Muse-tracked: shown in Full immersion when a Muse IS connected,
    //     standing in for the real gun that passthrough would otherwise
    //     show, tracking the Muse's actual position/orientation.
    // Position below is a starting guess (a real shouldered gun's barrel
    // runs parallel to your sightline, offset a few inches to the side and
    // down, not angled toward your face) — expect to nudge after trying it
    // on-device.

    /// Static "shouldered on the right shoulder" pose: offset right and
    /// down from the eye, barrel parallel to head-forward (matching how a
    /// real shouldered gun's barrel points exactly where your eye is
    /// looking, just offset from it) — not angled in from the side, which
    /// would point the barrel somewhere other than your actual sightline.
    private func buildFallbackGunOverlay() -> Entity {
        let gun = buildMuseTrackedGunOverlay()
        gun.position = SIMD3<Float>(0.10, -0.16, -0.85)
        return gun
    }

    /// Anchored under the Muse's aim point. Local -Z is the aim/fire
    /// direction (per `MuseAccessoryManager.aimWorldMatrix`'s convention),
    /// so +Z runs back from the muzzle toward the shooter.
    ///
    /// A real (if simplified) shotgun silhouette rather than a bare rod —
    /// barrel + sighting rib + front bead + receiver + stock, so it reads
    /// as an actual gun you can look down the sight of, and — since it's a
    /// real 3D shape rather than a flat plane — tilting/twisting/rolling
    /// the physical Muse (however it ends up mounted, e.g. inside a real
    /// Nerf-style housing) reads correctly from any angle you view it from,
    /// which a flat photo plane can't do.
    private func buildMuseTrackedGunOverlay() -> Entity {
        let group = Entity()

        // Blued-steel look: dark, low roughness, metallic — catches light
        // like real gun metal instead of reading as flat grey plastic.
        let bluedSteel = SimpleMaterial(color: .init(white: 0.08, alpha: 1.0), roughness: 0.28, isMetallic: true)
        // The rib is deliberately matte, not metallic — real sighting ribs
        // are finished rough/matte on top specifically to kill glare that
        // would otherwise wash out your sight picture.
        let matteRib = SimpleMaterial(color: .init(white: 0.05, alpha: 1.0), roughness: 0.9, isMetallic: false)
        let walnut = SimpleMaterial(color: .init(red: 0.33, green: 0.19, blue: 0.10, alpha: 1.0), roughness: 0.45, isMetallic: false)
        let recoilPadRubber = SimpleMaterial(color: .init(white: 0.04, alpha: 1.0), roughness: 0.95, isMetallic: false)

        // Barrel: two segments so it visibly tapers — thicker where it
        // meets the receiver, thinner toward the muzzle, the way a real
        // barrel profile does, instead of one perfectly uniform tube.
        let barrelLength: Float = 0.5
        let muzzleHalf = ModelEntity(mesh: .generateCylinder(height: barrelLength * 0.55, radius: 0.010), materials: [bluedSteel])
        muzzleHalf.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        muzzleHalf.position = SIMD3<Float>(0, 0, barrelLength * 0.275)
        group.addChild(muzzleHalf)

        let breechHalf = ModelEntity(mesh: .generateCylinder(height: barrelLength * 0.45, radius: 0.014), materials: [bluedSteel])
        breechHalf.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        breechHalf.position = SIMD3<Float>(0, 0, barrelLength * 0.55 + barrelLength * 0.225)
        group.addChild(breechHalf)

        // Sighting rib: the raised strip along the top of a real trap gun's
        // barrel that you look down, running the barrel's full length.
        let rib = ModelEntity(mesh: .generateBox(width: 0.007, height: 0.005, depth: barrelLength), materials: [matteRib])
        rib.position = SIMD3<Float>(0, 0.015, barrelLength / 2)
        group.addChild(rib)

        // Front sight bead — unlit so it stays bright and easy to pick out
        // against the rib regardless of scene lighting, like a real
        // fiber-optic bead.
        let bead = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [UnlitMaterial(color: .systemRed)])
        bead.position = SIMD3<Float>(0, 0.017, 0.02)
        group.addChild(bead)

        // Forend: the wood/synthetic sleeve your leading hand grips, just
        // ahead of the receiver — without it the barrel-to-receiver
        // transition reads as a bare pipe.
        let forendLength: Float = 0.14
        let forend = ModelEntity(mesh: .generateCylinder(height: forendLength, radius: 0.028), materials: [walnut])
        forend.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        forend.position = SIMD3<Float>(0, -0.006, barrelLength - forendLength / 2 - 0.01)
        group.addChild(forend)

        let receiverLength: Float = 0.16
        let receiver = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.06, depth: receiverLength), materials: [bluedSteel])
        receiver.position = SIMD3<Float>(0, -0.005, barrelLength + receiverLength / 2)
        group.addChild(receiver)

        let stockLength: Float = 0.26
        let stock = ModelEntity(mesh: .generateBox(width: 0.045, height: 0.055, depth: stockLength), materials: [walnut])
        // Real stocks angle down slightly from the receiver toward the
        // shoulder — a small downward tilt reads better than a dead-straight
        // box butted on the back.
        stock.orientation = simd_quatf(angle: -0.12, axis: SIMD3<Float>(1, 0, 0))
        stock.position = SIMD3<Float>(0, -0.03, barrelLength + receiverLength + stockLength / 2 - 0.02)
        group.addChild(stock)

        // Recoil pad: the black rubber cap on the very end of the stock —
        // a small detail, but its dark matte cap against the wood is what
        // actually reads as "gun" rather than "wooden block" from behind.
        let recoilPad = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.06, depth: 0.02), materials: [recoilPadRubber])
        recoilPad.orientation = stock.orientation
        let stockBackLocal = SIMD3<Float>(0, 0, stockLength / 2 + 0.01)
        recoilPad.position = stock.position + stock.orientation.act(stockBackLocal)
        group.addChild(recoilPad)

        return group
    }
}

/// World-anchored scoreboard standing next to the trap house — used in
/// Round mode so the score is glance-able like a real sign, never
/// following your gaze around the field.
private struct ScoreboardView: View {
    @ObservedObject var game: GameState

    var body: some View {
        VStack(spacing: 8) {
            if let roundScoreText = game.roundScoreText {
                Text(roundScoreText)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.yellow)
            } else {
                Text("\(game.hits)/\(game.shotsInRound)")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                Text("Station \(game.currentStationNumber)")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if game.missFlashVisible {
                Text("MISS")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .opacity(game.mode == .round ? 1 : 0)
    }
}

/// Head-locked HUD shown only in Practice mode.
private struct PracticeHUDView: View {
    @ObservedObject var game: GameState

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if game.missFlashVisible {
                Text("MISS")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(.red)
            }
            Text("\(game.hits)/\(game.attempts) · Station \(game.currentStationNumber)")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text("Warm-up: \(game.warmupLevel.displayName)")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Minimal pause/exit overlay, opened by a long-press look+pinch fallback,
/// so leaving Round mode never requires a menu flashing into view
/// unprompted.
private struct PauseMenuView: View {
    @ObservedObject var game: GameState

    var body: some View {
        VStack(spacing: 16) {
            Text("Paused").font(.title2.bold())
            Button("Resume") { game.resumeFromMenu() }
                .buttonStyle(.borderedProminent)
            Button("Exit to Home") { game.exitToHome() }
                .buttonStyle(.bordered)
        }
        .padding(28)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
        .opacity(game.isPaused ? 1 : 0)
    }
}

/// Bottom-of-view control bar, always visible in every mode. Recenter and
/// Exit are always available — every mode needs a guaranteed, discoverable
/// way out, not just a long-press gesture someone might never find. In
/// patterning mode a distance stepper also shows up so you can test
/// several distances without leaving the scene.
private struct RecenterBarView: View {
    @ObservedObject var game: GameState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: action) {
                Label("Recenter", systemImage: "scope")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)

            if game.mode == .patterning {
                HStack(spacing: 10) {
                    Button {
                        stepDistance(by: -1)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    Text(game.patterningDistance.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 44)
                    Button {
                        stepDistance(by: 1)
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                }
            }

            Button {
                game.exitToHome()
            } label: {
                Label("Exit", systemImage: "xmark.circle")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.black.opacity(0.25), in: Capsule())
    }

    private func stepDistance(by delta: Int) {
        let all = PatterningDistance.allCases
        guard let index = all.firstIndex(of: game.patterningDistance) else { return }
        let newIndex = min(max(index + delta, 0), all.count - 1)
        game.patterningDistance = all[newIndex]
    }
}
