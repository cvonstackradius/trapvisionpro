//
//  ClayBreak.swift
//  TrapVisionPro
//
//  Clay break effect: three hand-picked visual outcomes chosen from the
//  REAL simulated pellet pattern (see PelletPattern.swift) — how many of
//  the ~400 individually-simulated pellets actually connected with the
//  clay. A dense core hit dusts the clay into a fine cloud, a solid chunk
//  of the pattern breaks it into several chunks, and just a few pellets
//  grazing the edge only chips a small piece off it — all built from
//  simple primitive meshes with a short randomized outward burst + gravity,
//  no fade, no real fracture simulation (the visual side is deliberately
//  kept simple; the pellet physics behind the classification is not).
//

import Foundation
import RealityKit
import simd
import UIKit

enum ClayBreakKind {
    case dusted   // dead center — fine particle cloud
    case broken   // solid hit — several chunks
    case chipped  // grazing edge hit — one or two small pieces

    /// Classifies a hit from how many of the simulated pellets in the shot
    /// pattern actually connected (see PelletPattern.swift) — a dense core
    /// hit dusts the clay, a solid chunk of the pattern breaks it, and just
    /// a few pellets grazing the edge only chips it. This reads directly
    /// off the simulated pattern rather than a single ray's miss distance.
    static func classify(pelletsConnected: Int, totalPellets: Int) -> ClayBreakKind {
        let fraction = totalPellets > 0 ? Float(pelletsConnected) / Float(totalPellets) : 0
        if fraction >= 0.35 {
            return .dusted
        } else if fraction >= 0.12 {
            return .broken
        } else {
            return .chipped
        }
    }

    /// How many fragment pieces to spawn.
    fileprivate var fragmentCount: Int {
        switch self {
        case .dusted: return 14
        case .broken: return 6
        case .chipped: return 2
        }
    }

    /// Roughly how big each fragment piece is, in meters.
    fileprivate var fragmentSize: Float {
        switch self {
        case .dusted: return 0.012
        case .broken: return 0.028
        case .chipped: return 0.02
        }
    }

    /// How hard fragments burst outward from the hit point.
    fileprivate var burstSpeed: ClosedRange<Float> {
        switch self {
        case .dusted: return 3.0...6.0
        case .broken: return 1.5...3.5
        case .chipped: return 0.8...2.0
        }
    }

    /// How long fragments stay in the scene before being cleaned up.
    fileprivate var lifetime: TimeInterval {
        switch self {
        case .dusted: return 0.9
        case .broken: return 1.3
        case .chipped: return 1.1
        }
    }
}

/// Spawns a short-lived cloud of fragment pieces standing in for the clay
/// shattering, at `position` (field-local — pass `fieldRoot` as `root` so
/// this lines up with where the clay entity itself was rendered), biased to
/// inherit some of the clay's own travel direction (`incomingVelocity`,
/// also field-local) so the debris doesn't look like it burst from a clay
/// standing still. Fire-and-forget: each fragment removes itself from the
/// scene after its lifetime via a detached Task, no caller bookkeeping
/// needed.
@MainActor
func spawnClayBreak(kind: ClayBreakKind, at position: SIMD3<Float>, incomingVelocity: SIMD3<Float>, into root: Entity) {
    var material = SimpleMaterial()
    material.color = .init(tint: .orange.withAlphaComponent(0.95))

    let travelDirection = length(incomingVelocity) > 0.01
        ? normalize(incomingVelocity)
        : SIMD3<Float>(0, 0, -1)

    for _ in 0..<kind.fragmentCount {
        let size = kind.fragmentSize * Float.random(in: 0.7...1.3)
        let mesh: MeshResource = kind == .dusted
            ? .generateSphere(radius: size)
            : .generateBox(size: size)
        let fragment = ModelEntity(mesh: mesh, materials: [material])
        fragment.position = position
        root.addChild(fragment)

        // Burst mostly outward in a random direction, biased toward the
        // clay's own direction of travel so it reads as "the hit knocked
        // this piece forward/along," not as an explosion centered on
        // nothing.
        let randomDirection = SIMD3<Float>(
            Float.random(in: -1...1),
            Float.random(in: -0.2...1),
            Float.random(in: -1...1)
        )
        let normalizedRandom = length(randomDirection) > 0.01 ? normalize(randomDirection) : SIMD3<Float>(0, 1, 0)
        let burstDirection = normalize(normalizedRandom + travelDirection * 0.6)
        let speed = Float.random(in: kind.burstSpeed)
        var fragmentVelocity = burstDirection * speed + incomingVelocity * 0.25

        let spinAxis = normalize(SIMD3<Float>(
            Float.random(in: -1...1),
            Float.random(in: -1...1),
            Float.random(in: -1...1)
        ))
        let spinSpeed = Float.random(in: 4...10)

        let lifetime = kind.lifetime
        let startTime = Date()
        let gravity: Float = -9.81

        Task { @MainActor in
            // Simple fixed-step animation loop — this is cosmetic debris,
            // not physics that needs to match the clay's own simulation.
            let step: Float = 1.0 / 60.0
            while Date().timeIntervalSince(startTime) < lifetime {
                fragmentVelocity.y += gravity * step
                fragment.position += fragmentVelocity * step
                fragment.orientation *= simd_quatf(angle: spinSpeed * step, axis: spinAxis)
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
            fragment.removeFromParent()
        }
    }
}
