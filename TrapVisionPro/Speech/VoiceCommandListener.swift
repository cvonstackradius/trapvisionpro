//
//  VoiceCommandListener.swift
//  TrapVisionPro
//
//  On-device speech recognition listening continuously for two keywords:
//    "pull"  -> launch a clay from the trap house
//    "bang"  -> counts as pulling the trigger (backup for people not using
//               the Muse's own trigger control)
//
//  Uses SFSpeechRecognizer with requiresOnDeviceRecognition = true so audio
//  never leaves the headset, and doesn't need network access. No camera or
//  raw audio access beyond the standard microphone permission is required.
//
//  This used to also do audio-amplitude-based "trigger click" detection for
//  the real Nerf gun's mechanical click. Removed: the Muse's own physical
//  trigger control does the job of "bang" directly and reliably (see
//  GameState.handleMuseTrigger), and the audio-based detector had a real
//  bug — its amplitude check fired from installTap's callback, which runs
//  on Core Audio's real-time render thread rather than the main thread,
//  and sending straight into GameState/AVAudioPlayerNode calls from there
//  crashed (confirmed via a symbolicated TestFlight crash log). Simpler and
//  safer to just not do audio-transient detection at all.
//

import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class VoiceCommandListener: ObservableObject {

    enum Command {
        case pull
        case bang
    }

    @Published var isListening = false
    @Published var authorizationDenied = false
    @Published var lastHeardPhrase: String = ""

    /// Fires once per detected command, debounced so a single utterance
    /// (which the recognizer may report as several partial results while
    /// it refines its guess) doesn't fire twice.
    let commandDetected = PassthroughSubject<Command, Never>()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // Debounce window so rapid partial-result updates for the same word
    // don't re-fire the command multiple times.
    private var lastPullFire: Date = .distantPast
    private var lastBangFire: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.6

    func requestAuthorizationAndStart() async {
        let speechStatus = await requestSpeechAuthorization()
        let micStatus = await requestMicAuthorization()

        guard speechStatus, micStatus else {
            authorizationDenied = true
            return
        }
        start()
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            print("TrapVisionPro: speech recognizer unavailable.")
            return
        }
        guard !audioEngine.isRunning else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep everything on-device: no audio leaves the headset, and it
        // works without network access at the range.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
        } catch {
            print("TrapVisionPro: audio engine failed to start: \(error)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.handleTranscript(result.bestTranscription.formattedString)
                }
                if error != nil || (result?.isFinal ?? false) {
                    // Restart continuously — a single recognition task has a
                    // limited duration, so we chain a fresh one to keep
                    // listening throughout a shooting session.
                    self.restartRecognitionTask()
                }
            }
        }
    }

    private func restartRecognitionTask() {
        request?.endAudio()
        task?.cancel()
        guard let recognizer, recognizer.isAvailable, audioEngine.isRunning else { return }

        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        self.request = newRequest

        task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.handleTranscript(result.bestTranscription.formattedString)
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.restartRecognitionTask()
                }
            }
        }
    }

    private func handleTranscript(_ text: String) {
        lastHeardPhrase = text
        let lowered = text.lowercased()
        let now = Date()

        if lowered.contains("pull"), now.timeIntervalSince(lastPullFire) > debounceInterval {
            lastPullFire = now
            commandDetected.send(.pull)
        }
        // "bang" (and the common transcription "bank"/"bam" the recognizer
        // sometimes substitutes for a shouted plosive) triggers a shot.
        if (lowered.contains("bang") || lowered.contains("bam")),
           now.timeIntervalSince(lastBangFire) > debounceInterval {
            lastBangFire = now
            commandDetected.send(.bang)
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        request?.endAudio()
        task?.cancel()
        isListening = false
    }
}
