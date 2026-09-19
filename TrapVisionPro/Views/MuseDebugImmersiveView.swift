//
//  MuseDebugImmersiveView.swift
//  TrapVisionPro
//
//  A deliberately tiny scene with none of the trap game's complexity —
//  one red sphere, anchored to the Muse's "aim" location if accessory
//  tracking is actually working. Point the Muse around: if tracking works,
//  the sphere swings with it: if it doesn't, the sphere just sits there.
//  That's the whole test. HomeView's debug panel (still visible — this
//  scene doesn't dismiss the window) shows the rest: connection, aim
//  status, and whether button presses are registering at all.
//
//  Reuses GameState.museManager directly, so whatever gets fixed here
//  already applies to the real game — there's nothing to port over later.
//

import SwiftUI
import RealityKit

struct MuseDebugImmersiveView: View {
    @ObservedObject var game: GameState

    var body: some View {
        RealityView { content in
            content.add(game.museManager.accessoryRoot)

            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.03),
                materials: [SimpleMaterial(color: .red, isMetallic: false)]
            )
            game.museManager.attachAimVisual(sphere)
        }
    }
}
