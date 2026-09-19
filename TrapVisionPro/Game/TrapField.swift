//
//  TrapField.swift
//  TrapVisionPro
//
//  Geometry and physics for a trap range: 5 shooting stations arranged in an
//  arc behind a single trap house, which launches a clay disc on "pull."
//
//  Dimensions and behavior are calibrated against the official ATA (Amateur
//  Trapshooting Association) field spec:
//    - Stations sit on the "16-yard line": 16 yards (≈14.63 m) from the trap
//      house, spaced 3 yards (≈2.74 m) apart, station 3 on the centerline.
//      https://filestore.scouting.org/filestore/designdevelop/pdf/d-312shotgunranges.pdf
//    - The trap oscillates ±17.14° off centerline (targets thrown outside
//      that are ruled illegal past a 27° tolerance).
//      https://www.shootata.com/portals/0/pdf/grand_training_materials.pdf
//    - A single target should reach 8-10 ft of height at 10 yards downrange
//      and land 48-52 yards from the house.
//
//  All coordinates are meters, RealityKit's right-handed coordinate system
//  (+X right, +Y up, -Z forward). Station 3 sits on the centerline directly
//  in front of the trap house.
//

import Foundation
import RealityKit
import simd
import UIKit

struct TrapStation: Identifiable {
    let id: Int                 // 1...5
    /// Position of the shooter's standing spot, relative to the field root.
    let shooterPosition: SIMD3<Float>
    let horizontalSpreadDegrees: ClosedRange<Float>
    let launchElevationDegrees: ClosedRange<Float>
}

struct TrapField {

    /// 16 yards = 14.6304 m. House sits centered on station 3, at roughly
    /// waist height where the target actually leaves the throwing arm —
    /// the house itself is set into a pit so its roof sits low to the
    /// ground; we render just the throwing point, not the full pit/roof.
    static let trapHousePosition = SIMD3<Float>(0, 0.9, -14.6304)

    /// 3 yards = 2.7432 m between adjacent stations.
    static let stationSpacing: Float = 2.7432

    /// ATA-legal oscillation: targets are thrown within ±17.14° of the
    /// centerline (beyond ~27° off centerline is an illegal throw).
    static let legalOscillationDegrees: Float = 17.14

    static let stations: [TrapStation] = (1...5).map { number in
        let offsetFromCenter = Float(number - 3) * stationSpacing
        return TrapStation(
            id: number,
            shooterPosition: SIMD3<Float>(offsetFromCenter, 0, 0),
            horizontalSpreadDegrees: -legalOscillationDegrees...legalOscillationDegrees,
            // Vertical launch angle isn't tightly specified by the rulebook;
            // this range is calibrated (see launchClay) so the simulated
            // flight matches the official 8-10ft-at-10yd / 48-52yd-landing
            // spec across the paired speed range below.
            launchElevationDegrees: 12...15
        )
    }

    static func station(_ number: Int) -> TrapStation {
        stations.first(where: { $0.id == number }) ?? stations[2]
    }
}

/// A single clay disc's flight, launched from the trap house.
final class ClayTarget {

    let entity: ModelEntity
    private var velocity: SIMD3<Float>
    private var position: SIMD3<Float>
    private let gravity: Float = -9.81

    /// Real clay targets are gyroscopically spin-stabilized — they fly
    /// edge-first through the air like a tiny frisbee, not tumbling
    /// face-first. That gives them a much smaller effective frontal area
    /// than their full face, which is why they can travel 48-52 yards
    /// instead of dropping after a few meters. Drag coefficient here is
    /// k = 0.5·ρ_air·Cd·A_frontal/mass, using the disc's edge-on area
    /// (diameter × thickness) rather than its full face:
    ///   ρ=1.225 kg/m³, Cd≈1.1 (blunt edge), A=0.11m×0.025m, mass=0.105kg
    ///   → k ≈ 0.0176
    /// This was calibrated by simulation against the ATA's official
    /// height/distance spec — see TrapField's doc comment for sources.
    private let dragCoefficient: Float = 0.0176
    private(set) var isFlying = true
    private(set) var timeAloft: Float = 0

    init(startPosition: SIMD3<Float>, launchSpeed: Float, headingDegrees: Float, elevationDegrees: Float) {
        let heading = headingDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        let direction = SIMD3<Float>(
            sin(heading) * cos(elevation),
            sin(elevation),
            -cos(heading) * cos(elevation)
        )
        self.velocity = direction * launchSpeed
        self.position = startPosition

        // Simple flat disc mesh standing in for a clay pigeon until a real
        // clay-target USDZ asset is dropped into Resources/.
        let mesh = MeshResource.generateCylinder(height: 0.025, radius: 0.055)
        var material = SimpleMaterial()
        material.color = .init(tint: .orange.withAlphaComponent(0.95))
        self.entity = ModelEntity(mesh: mesh, materials: [material])
        self.entity.position = startPosition
        self.entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normalize(direction))
    }

    /// Advance the flight by `dt` seconds. Call from your render loop.
    /// Returns false once the clay has landed (isFlying becomes false).
    @discardableResult
    func step(dt: Float) -> Bool {
        guard isFlying else { return false }
        timeAloft += dt

        // Per-component quadratic drag: a = -k * |v| * v (edge-on model).
        let speed = length(velocity)
        let dragAccel = -velocity * dragCoefficient * speed
        velocity += (SIMD3<Float>(0, gravity, 0) + dragAccel) * dt
        position += velocity * dt

        entity.position = position
        // Gentle spin for visual realism — real targets spin fast around
        // their own vertical axis, not tumbling end-over-end.
        entity.orientation *= simd_quatf(angle: dt * 10, axis: SIMD3<Float>(0, 1, 0))

        if position.y <= 0 {
            isFlying = false
        }
        return isFlying
    }

    /// Field-local position (unaffected by the field root's own transform).
    /// Physics stepping happens in this space; use `worldPosition` for
    /// hit-testing against a world-space aim ray.
    var currentPosition: SIMD3<Float> { position }

    /// Field-local velocity at the moment of query — used to give break
    /// fragments a believable inherited direction (the clay's own travel
    /// direction) rather than spawning them with zero momentum.
    var currentVelocity: SIMD3<Float> { velocity }

    /// The clay's actual position in world space — accounts for wherever
    /// the field root has been translated to (e.g. when you've selected a
    /// different station and the whole environment shifted to put you on
    /// that station's spot). Always use this for hit-testing.
    var worldPosition: SIMD3<Float> {
        entity.position(relativeTo: nil)
    }
}

/// Spawns a clay for a given station, with per-throw randomization within
/// that station's configured spread — matches the "you never know exactly
/// where it'll go" feel of a real trap house. `horizontalSpreadDegrees`
/// overrides the station's own spread when given (used for warm-up modes
/// that throw straighter than a real trap house would).
func launchClay(for station: TrapStation, from root: Entity, horizontalSpreadDegrees: ClosedRange<Float>? = nil) -> ClayTarget {
    let heading = Float.random(in: horizontalSpreadDegrees ?? station.horizontalSpreadDegrees)
    let elevation = Float.random(in: station.launchElevationDegrees)
    // Calibrated against the official 8-10ft-at-10yd / 48-52yd-landing spec
    // (see TrapField's doc comment) using this drag model — NOT a literal
    // claim about real muzzle velocity, just what makes the simulated arc
    // match the rulebook's numbers.
    let speed = Float.random(in: 39...42)

    let clay = ClayTarget(
        startPosition: TrapField.trapHousePosition,
        launchSpeed: speed,
        headingDegrees: heading,
        elevationDegrees: elevation
    )
    root.addChild(clay.entity)
    return clay
}

// Hit-testing a shot is now real pellet-pattern simulation rather than a
// single forgiving-cone ray — see PelletPattern.swift for
// `simulatePelletShot` / `PelletShotResult`, which replace the old
// `evaluateShot` / `ShotResult` single-ray approach.
