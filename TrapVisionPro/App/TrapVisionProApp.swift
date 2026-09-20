//
//  TrapVisionProApp.swift
//  TrapVisionPro
//
//  App entry point. One Home window (Practice vs Round) plus the
//  ImmersiveSpace that hosts the trap field and clay flight.
//

import SwiftUI

@main
struct TrapVisionProApp: App {

    @StateObject private var game = GameState()
    // The normal range option is a 60% progressive portal: the virtual
    // range fills most of the view, while the Digital Crown can reveal more
    // of the real room (and the physical Muse) when the player wants it.
    // Full remains available as the separate, no-passthrough option.
    @State private var immersionStyle: ImmersionStyle = .progressive(0.15...0.9, initialAmount: 0.6)

    var body: some Scene {
        WindowGroup(id: "Home") {
            HomeView(game: game, immersionStyle: $immersionStyle)
        }
        .windowStyle(.plain)
        .defaultSize(width: 620, height: 620)

        ImmersiveSpace(id: "TrapRange") {
            TrapRangeImmersiveView(game: game)
        }
        .immersionStyle(selection: $immersionStyle, in: .progressive, .full)

        // A minimal scene just to prove the Muse itself works, isolated
        // from the trap game's complexity — see MuseDebugImmersiveView.
        ImmersiveSpace(id: "MuseDebug") {
            MuseDebugImmersiveView(game: game)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
