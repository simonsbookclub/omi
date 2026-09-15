// The models, loaded once per process and shared by every session.
//
// The first version gave each session its own copy. A session starts on every
// pendant reconnect; each start read 600 MB from disk and compiled it, which
// pinned the CPU right as the link was coming back up, so the link timed out,
// reconnected, and started another load. Chronicle went from 1.6 GB to 3.4 GB
// in six minutes and iOS killed it, four times (2026-09-15). One copy, ever.
import CoreML
import Foundation
import FluidAudio

enum ScribeError: Error { case notReady }

actor ScribeModels {
    static let shared = ScribeModels()

    private var asr: AsrManager?
    private var vad: VadManager?
    private var diarizer: OfflineDiarizerManager?
    private var loading = false

    /// Ready means the speech detector and the speaker separator are up, and a
    /// transcriber has been chosen. Parakeet's half-gigabyte is not part of
    /// that unless it is the one doing the writing.
    var isReady: Bool { vad != nil && diarizer != nil && (useApple || asr != nil) }

    /// Loads everything, once. Callers that arrive mid-load wait for that load.
    func prepare() async throws {
        if isReady { return }
        while loading { try await Task.sleep(nanoseconds: 200_000_000) }
        if isReady { return }
        loading = true
        defer { loading = false }
        try await loadAll()
    }

    /// CPU and Neural Engine, never the GPU.
    ///
    /// iOS refuses GPU work from a backgrounded app
    /// (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted), and
    /// Chronicle spends its whole life in the background listening to the
    /// pendant. Left to choose, CoreML picks the GPU and every prediction
    /// fails the moment the app leaves the screen — 45 such errors in ten
    /// minutes on 2026-09-15, with no transcript to show for them. The Neural
    /// Engine has no such restriction and is the right unit for these models
    /// anyway.
    private static var background: MLModelConfiguration {
        let c = MLModelConfiguration()
        c.computeUnits = .cpuAndNeuralEngine
        return c
    }

    /// Parakeet, loaded only if it is going to write something down.
    ///
    /// Half a gigabyte of model resident for a fallback that never runs: the
    /// app sat at 259 MB in the background and was killed under memory
    /// pressure with nothing captured (2026-09-15). Apple's transcriber is a
    /// system service and costs this process almost nothing.
    private func loadParakeet() async throws {
        if asr != nil { return }
        let a = AsrManager(config: .default)
        do {
            let models = try await AsrModels.downloadAndLoad(configuration: Self.background, version: .v3)
            try await a.loadModels(models)
        } catch {
            // A download interrupted mid-flight leaves truncated files that no
            // retry repairs; the library says so in its log and retries anyway.
            NSLog("scribe: model load failed (\(error)); clearing the cache and downloading again")
            ModelHub.clearAllCaches()
            let models = try await AsrModels.downloadAndLoad(configuration: Self.background, version: .v3)
            try await a.loadModels(models)
        }
        NSLog("scribe: Parakeet ready")
        asr = a
    }

    private func loadAll() async throws {
        await chooseTranscriber()
        if !useApple { try await loadParakeet() }
        let v = try await VadManager(config: .default)
        let d = OfflineDiarizerManager()
        do {
            try await d.prepareModels(configuration: Self.background)
        } catch {
            NSLog("scribe: diarizer models failed (\(error)); retrying once")
            try await d.prepareModels(configuration: Self.background, forceRedownload: true)
        }
        vad = v; diarizer = d
        NSLog("scribe: models ready — transcribing on this phone")
    }

    // Everything below runs through the actor, so the live engine and the
    // file reader take turns rather than driving one CoreML model from two
    // tasks at once.

    /// Which transcriber writes the words down. Apple's is the system's own
    /// service: nothing to download into this app, nothing to keep working.
    /// Parakeet stays for anything Apple has no language for.
    private var useApple = false

    func chooseTranscriber() async {
        // A switch that needs no rebuild. Apple's analyzer has already trapped
        // the app once; if it does so again this can be turned off by writing
        // the preference and restarting, rather than by another build-sign-
        // install round trip while Simon has no working app.
        if UserDefaults.standard.string(forKey: "flutter.scribeEngine") == "parakeet" {
            useApple = false
            NSLog("scribe: transcribing with Parakeet (Apple turned off by preference)")
            return
        }
        if #available(iOS 26.0, *) {
            useApple = await AppleTranscriber.isSupported("en-US")
            NSLog("scribe: transcribing with %@", useApple ? "Apple" : "Parakeet")
        }
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        if useApple, #available(iOS 26.0, *) {
            do {
                // Empty is an answer: Apple heard nothing worth writing down.
                // Handing that audio to Parakeet instead is precisely how a
                // stretch of noise becomes "5-5-5-5-5…" — the second engine
                // is asked to transcribe exactly what the first judged
                // unintelligible, which is where a decoder loops.
                let text = try await AppleTranscriber.shared.transcribe(samples)
                return ASRResult(text: text, confidence: 1, duration: Double(samples.count) / 16_000,
                                 processingTime: 0, tokenTimings: nil)
            } catch {
                NSLog("scribe: Apple could not transcribe (%@); using Parakeet", "\(error)")
                try? await loadParakeet()
            }
        }
        guard let asr else { throw ScribeError.notReady }
        var state = try TdtDecoderState()
        return try await asr.transcribe(samples, decoderState: &state)
    }

    func diarize(_ samples: [Float]) async throws -> DiarizationResult {
        guard let diarizer else { throw ScribeError.notReady }
        return try await diarizer.process(audio: samples)
    }

    /// Where the speech is in a buffer, decided by the library's own
    /// segmentation — hysteresis, padding and a minimum speech duration.
    ///
    /// Measured on 79 minutes of real pendant audio (2026-09-15): thresholding
    /// the raw per-chunk probability at 0.75, which is what Scribe shipped,
    /// kept 1.3 seconds of a 641-second recording. This keeps 583.
    func speech(in samples: [Float]) async throws -> [(start: Double, end: Double)] {
        guard let vad else { throw ScribeError.notReady }
        return try await vad.segmentSpeech(samples).map {
            (start: Double($0.startTime), end: Double($0.endTime))
        }
    }
}
