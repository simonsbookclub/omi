// The models, loaded once per process and shared by every session.
//
// The first version gave each session its own copy. A session starts on every
// pendant reconnect; each start read 600 MB from disk and compiled it, which
// pinned the CPU right as the link was coming back up, so the link timed out,
// reconnected, and started another load. Chronicle went from 1.6 GB to 3.4 GB
// in six minutes and iOS killed it, four times (2026-09-15). One copy, ever.
import Foundation
import FluidAudio

enum ScribeError: Error { case notReady }

actor ScribeModels {
    static let shared = ScribeModels()

    private var asr: AsrManager?
    private var vad: VadManager?
    private var diarizer: OfflineDiarizerManager?
    private var loading = false

    var isReady: Bool { asr != nil && vad != nil && diarizer != nil }

    /// Loads everything, once. Callers that arrive mid-load wait for that load.
    func prepare() async throws {
        if isReady { return }
        while loading { try await Task.sleep(nanoseconds: 200_000_000) }
        if isReady { return }
        loading = true
        defer { loading = false }
        try await loadAll()
    }

    private func loadAll() async throws {
        let a = AsrManager(config: .default)
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        } catch {
            // A download interrupted mid-flight leaves truncated files that no
            // retry repairs; the library says so in its log and retries anyway.
            NSLog("scribe: model load failed (\(error)); clearing the cache and downloading again")
            ModelHub.clearAllCaches()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        }
        NSLog("scribe: Parakeet ready")
        let v = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
        let d = OfflineDiarizerManager()
        do {
            try await d.prepareModels()
        } catch {
            NSLog("scribe: diarizer models failed (\(error)); retrying once")
            try await d.prepareModels(forceRedownload: true)
        }
        asr = a; vad = v; diarizer = d
        NSLog("scribe: models ready — transcribing on this phone")
    }

    // Everything below runs through the actor, so the live engine and the
    // file reader take turns rather than driving one CoreML model from two
    // tasks at once.

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        guard let asr else { throw ScribeError.notReady }
        var state = try TdtDecoderState()
        return try await asr.transcribe(samples, decoderState: &state)
    }

    func diarize(_ samples: [Float]) async throws -> DiarizationResult {
        guard let diarizer else { throw ScribeError.notReady }
        return try await diarizer.process(audio: samples)
    }

    func makeVadState() async throws -> VadStreamState {
        guard let vad else { throw ScribeError.notReady }
        return await vad.makeStreamState()
    }

    func vadStep(_ chunk: [Float], state: VadStreamState) async throws -> VadStreamResult {
        guard let vad else { throw ScribeError.notReady }
        return try await vad.processStreamingChunk(chunk, state: state, config: .default, returnSeconds: false)
    }
}
