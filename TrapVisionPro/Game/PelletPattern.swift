//
//  PelletPattern.swift
//  TrapVisionPro
//
//  Real pellet-level shot simulation. Replaces the old single-ray/forgiving-
//  cone hit test with several hundred individually-simulated pellets, spread
//  the way a real shot charge actually spreads (a 2D Gaussian cloud whose
//  width is set by choke, not guessed), each tested against the clay
//  individually. This is still a simplification — real pellets deform,
//  jostle each other on the way out of the barrel, and drop at very slightly
//  different rates by size — but the part that actually matters for
//  "did I hit it and how well" (the pattern's density and spread) is modeled
//  from real ballistics numbers, not eyeballed.
//

import Foundation
import simd

struct PelletPattern {

    /// A trap/target load's typical pellet count for the shot size commonly
    /// used at the 16-yard line (#7.5 or #8 shot in a 1 oz / 28g load).
    /// Real shells run roughly 350 (#7.5) to 450+ (#8) pellets — 400 is a
    /// reasonable middle value.
    static let pelletCount = 400

    /// Choke constriction sets how tightly the pellets stay together.
    /// Chokes are conventionally rated by what percentage of the pattern
    /// lands inside a 30-inch circle at 40 yards. Modeling the pattern as a
    /// 2D Gaussian cloud (a standard, reasonable approximation for shot
    /// dispersion — real patterns are dense in the middle and sparse at the
    /// edges, not a uniform disc), that rated percentage implies a
    /// characteristic angular spread (σ). Deriving σ from
    /// P(within r) = 1 - exp(-r²/2σ²) for a 30" circle (0.381 m radius) at
    /// 40 yd (36.576 m):
    ///   Cylinder        ~40% in circle -> σ ≈ 0.336 m -> angular σ ≈ 0.527°
    ///   Improved Cyl.    ~50%          -> σ ≈ 0.275 m -> angular σ ≈ 0.431°
    ///   Modified         ~60%          -> σ ≈ 0.245 m -> angular σ ≈ 0.384°
    ///   Improved Mod.    ~65%          -> σ ≈ 0.231 m -> angular σ ≈ 0.362°
    ///   Full             ~75%          -> σ ≈ 0.204 m -> angular σ ≈ 0.320°
    /// Trap's 16-yard line is conventionally shot Modified or Improved
    /// Modified — this defaults to Modified.
    static let angularSigmaDegrees: Float = 0.384

    /// Real clay-target radius (matches the disc mesh in ClayTarget) — a
    /// pellet "connects" if its individual ray passes within this distance
    /// of the clay's center.
    static let clayRadius: Float = 0.055

    /// Minimum number of connecting pellets to count as a scored hit. ATA
    /// rules require a visible piece broken off — one stray pellet grazing
    /// the very edge of the pattern wouldn't realistically chip visible
    /// material off a clay, so a handful of pellets need to connect.
    static let minPelletsToScore = 3

    /// Average pellet velocity for a typical 1200 ft/s target load, in m/s
    /// (pellets decelerate over their flight, but a flat average speed is
    /// accurate enough here — it's only used to get a flight TIME, which
    /// sets how much the pattern sags under gravity, not to model energy
    /// or knockdown power).
    static let averagePelletSpeed: Float = 370

    /// Standard gravity, m/s². Applied as real drop over the pellets'
    /// flight time — this is what makes a 40-yard shot need to be held
    /// slightly higher than a 16-yard one, same as a real shotgun: pellets
    /// in the air longer sag further below a dead-straight line from the
    /// muzzle.
    static let gravity: Float = 9.81
}

/// Result of firing one full simulated pellet pattern at a clay.
struct PelletShotResult {
    let hit: Bool
    let pelletsConnected: Int
    let totalPellets: Int
    let hitFraction: Float          // pelletsConnected / totalPellets, 0...1
    let centerMissDistance: Float   // meters, dead-center aim ray vs. clay — for HUD text
    let leadTime: Float             // how long the clay had been flying
}

/// Simulates a full pellet pattern fired from `aimOrigin` toward
/// `aimForward` (both WORLD space — already true for both the Muse's
/// tracked aim and the fallback head-forward ray) against the clay's
/// position at the instant the trigger was pulled.
///
/// This does NOT auto-lead the shot for you — the pattern is evaluated
/// against the clay's actual position at the moment you fire, not some
/// predicted future position. If you don't physically aim ahead of a
/// moving clay, you'll shoot behind it, same as a real shotgun; the only
/// "lead" happening is whatever you (or your tracked aim) actually did.
///
/// Each pellet also sags below a dead-straight line from the muzzle the
/// longer it's in the air — real gravity drop, computed from that
/// pellet's own flight time (distance / average pellet speed). This is
/// what makes a 40-yard shot need to be held a bit higher than a 16-yard
/// one: the farther out the clay is, the longer the pellets take to get
/// there, and the more they've dropped by the time they arrive. It's a
/// flat-average-speed approximation (real pellets decelerate, so the drop
/// is slightly understated at long range) but it's the right shape of
/// effect and scales correctly with distance.
func simulatePelletShot(aimOrigin: SIMD3<Float>, aimForward: SIMD3<Float>, clay: ClayTarget,
                         hitRadiusMultiplier: Float = 1.0) -> PelletShotResult {
    let forward = normalize(aimForward)
    let clayPos = clay.worldPosition

    // Stable right/up basis around the aim direction to scatter individual
    // pellets in a cone around it.
    let worldUp = SIMD3<Float>(0, 1, 0)
    let right = length(cross(forward, worldUp)) > 0.001
        ? normalize(cross(worldUp, forward))
        : SIMD3<Float>(1, 0, 0)
    let up = normalize(cross(forward, right))

    let toClay = clayPos - aimOrigin
    let distanceAlongAim = dot(toClay, forward)

    // Gravity drop for a straight-line flight of `distance` meters at the
    // pattern's average pellet speed: d = ½gt², t = distance / speed.
    func gravityDrop(overDistance distance: Float) -> Float {
        guard distance > 0 else { return 0 }
        let flightTime = distance / PelletPattern.averagePelletSpeed
        return 0.5 * PelletPattern.gravity * flightTime * flightTime
    }

    let centerMissDistance: Float
    if distanceAlongAim > 0 {
        let drop = gravityDrop(overDistance: distanceAlongAim)
        let closestPoint = aimOrigin + forward * distanceAlongAim - SIMD3<Float>(0, drop, 0)
        centerMissDistance = length(clayPos - closestPoint)
    } else {
        centerMissDistance = .greatestFiniteMagnitude
    }

    guard distanceAlongAim > 0 else {
        return PelletShotResult(
            hit: false,
            pelletsConnected: 0,
            totalPellets: PelletPattern.pelletCount,
            hitFraction: 0,
            centerMissDistance: centerMissDistance,
            leadTime: clay.timeAloft
        )
    }

    let sigma = PelletPattern.angularSigmaDegrees * .pi / 180
    var connected = 0

    for _ in 0..<PelletPattern.pelletCount {
        // Box-Muller transform for a proper 2D Gaussian scatter (dense at
        // center, sparse at the edges) rather than a uniform random cone,
        // which would make edge hits unrealistically common.
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        let radius = sqrt(-2 * log(u1))
        let angleX = radius * cos(2 * .pi * u2) * sigma
        let angleY = radius * sin(2 * .pi * u2) * sigma

        let pelletDirection = normalize(forward + right * tan(angleX) + up * tan(angleY))

        let alongPellet = dot(toClay, pelletDirection)
        guard alongPellet > 0 else { continue }
        let drop = gravityDrop(overDistance: alongPellet)
        let closest = aimOrigin + pelletDirection * alongPellet - SIMD3<Float>(0, drop, 0)
        let missDistance = length(clayPos - closest)
        if missDistance <= PelletPattern.clayRadius * hitRadiusMultiplier {
            connected += 1
        }
    }

    let fraction = Float(connected) / Float(PelletPattern.pelletCount)
    let hit = connected >= PelletPattern.minPelletsToScore

    return PelletShotResult(
        hit: hit,
        pelletsConnected: connected,
        totalPellets: PelletPattern.pelletCount,
        hitFraction: fraction,
        centerMissDistance: centerMissDistance,
        leadTime: clay.timeAloft
    )
}

/// Fires a full pellet pattern at a fixed distance against an imaginary
/// flat target board, and returns each pellet's (right, up) offset in
/// meters from the dead-straight, no-drop aim point at that distance —
/// real gravity drop already baked into the up component. This is for
/// on-target patterning (see a real pattern spread and adjust hold-point),
/// not clay hit/miss scoring — same scatter model as `simulatePelletShot`,
/// just measured against a plane instead of a clay's position. Treats
/// aim-relative right/up as equal to the board's own fixed right/up,
/// which holds as long as you're aiming roughly at the board — the same
/// approximation `simulatePelletShot` already makes for clays.
func simulatePatterningShot(distanceMeters: Float) -> [SIMD2<Float>] {
    let flightTime = distanceMeters / PelletPattern.averagePelletSpeed
    let drop = 0.5 * PelletPattern.gravity * flightTime * flightTime
    let sigma = PelletPattern.angularSigmaDegrees * .pi / 180

    var impacts: [SIMD2<Float>] = []
    impacts.reserveCapacity(PelletPattern.pelletCount)

    for _ in 0..<PelletPattern.pelletCount {
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        let radius = sqrt(-2 * log(u1))
        let angleX = radius * cos(2 * .pi * u2) * sigma
        let angleY = radius * sin(2 * .pi * u2) * sigma
        let rightOffset = tan(angleX) * distanceMeters
        let upOffset = tan(angleY) * distanceMeters - drop
        impacts.append(SIMD2<Float>(rightOffset, upOffset))
    }

    return impacts
}

/// Fires a pattern at an actual world-space target board. Each pellet is
/// intersected with the board plane and returned in that board's local
/// right/up coordinates. This matters when the player is off center or
/// pitching/yawing the gun: a closest-point projection onto the aim ray
/// looks plausible near the center but is not where pellets hit the board.
func simulatePatterningShot(
    aimOrigin: SIMD3<Float>,
    aimForward: SIMD3<Float>,
    boardCenter: SIMD3<Float>,
    boardNormal: SIMD3<Float>,
    boardRight: SIMD3<Float>,
    boardUp: SIMD3<Float>
) -> [SIMD2<Float>] {
    let forward = normalize(aimForward)
    let normal = normalize(boardNormal)
    let right = length(cross(forward, SIMD3<Float>(0, 1, 0))) > 0.001
        ? normalize(cross(SIMD3<Float>(0, 1, 0), forward))
        : SIMD3<Float>(1, 0, 0)
    let up = normalize(cross(forward, right))
    let sigma = PelletPattern.angularSigmaDegrees * .pi / 180

    var impacts: [SIMD2<Float>] = []
    impacts.reserveCapacity(PelletPattern.pelletCount)

    for _ in 0..<PelletPattern.pelletCount {
        let u1 = Float.random(in: 0.0001...1)
        let u2 = Float.random(in: 0...1)
        let radius = sqrt(-2 * log(u1))
        let angleX = radius * cos(2 * .pi * u2) * sigma
        let angleY = radius * sin(2 * .pi * u2) * sigma
        let pelletDirection = normalize(forward + right * tan(angleX) + up * tan(angleY))

        let denominator = dot(pelletDirection, normal)
        guard abs(denominator) > 0.0001 else { continue }
        let distance = dot(boardCenter - aimOrigin, normal) / denominator
        guard distance > 0 else { continue }

        let flightTime = distance / PelletPattern.averagePelletSpeed
        let drop = 0.5 * PelletPattern.gravity * flightTime * flightTime
        let impact = aimOrigin + pelletDirection * distance - SIMD3<Float>(0, drop, 0)
        let offset = impact - boardCenter
        impacts.append(SIMD2<Float>(dot(offset, boardRight), dot(offset, boardUp)))
    }

    return impacts
}
