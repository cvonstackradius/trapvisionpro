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
    // Mirrors `game.isFullImmersion` (set by the Home screen's picker) into
    // the actual system value `.immersionStyle(selection:)` needs.
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup(id: "Home") {
            HomeView(game: game, immersionStyle: $immersionStyle)
        }
        .windowStyle(.plain)
        .defaultSize(width: 620, height: 620)

        ImmersiveSpace(id: "TrapRange") {
            TrapRangeImmersiveView(game: game)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed, .full)

        // A minimal scene just to prove the Muse itself works, isolated
        // from the trap game's complexity — see MuseDebugImmersiveView.
        ImmersiveSpace(id: "MuseDebug") {
            MuseDebugImmersiveView(game: game)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
