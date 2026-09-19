//
//  ShotAudioPlayer.swift
//  TrapVisionPro
//
//  Generic one-shot audio cue player. Used for two real recorded sounds
//  pulled from Chares's own range footage:
//    - shotgun_blast.wav — plays on every trigger pull (the bang)
//    - pump_rack.wav     — plays the moment you step onto a station,
//                          signaling the gun is loaded and hot
//

import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioCuePlayer {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var buffer: AVAudioPCMBuffer?
    private var cancellable: AnyCancellable?
    private let resourceName: String

    /// User-facing volume multiplier (0...1), independent of the small
    /// per-play random variation below — set from GameState so a single
    /// Home-screen slider controls both the blast and the pump-rack cue.
    var volume: Float = 1.0

    init(resourceName: String) {
        self.resourceName = resourceName
        loadBuffer()
        engine.attach(playerNode)
        if let buffer {
            engine.connect(playerNode, to: engine.mainMixerNode, format: buffer.format)
        }
        try? engine.start()
    }

    /// Subscribe to a publisher (e.g. GameState's `shotFired` or
    /// `stationReady`) to play this cue automatically whenever it fires.
    func bind(to publisher: PassthroughSubject<Void, Never>) {
        cancellable = publisher.sink { [weak self] in self?.play() }
    }

    private func loadBuffer() {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "wav") else {
            print("TrapVisionPro: \(resourceName).wav not found in bundle — add Resources/Audio/ to the Xcode target.")
            return
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                              frameCapacity: AVAudioFrameCount(file.length)) else { return }
            try file.read(into: buf)
            self.buffer = buf
        } catch {
            print("TrapVisionPro: failed to load audio cue '\(resourceName)': \(error)")
        }
    }

    func play() {
        guard let buffer else { return }
        playerNode.stop()
        playerNode.volume = Float.random(in: 0.92...1.0) * volume
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts)
        playerNode.play()
    }
}
