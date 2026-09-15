// The pendant's flash recordings, understood on the phone.
//
// While the Bluetooth link is down the pendant keeps recording to its own
// storage, and the phone later uploads those files. They used to go to a paid
// transcriber; now they are read here. Offline rather than streaming, because
// a whole file at once gives the diarizer the context to tell voices apart
// properly — which is exactly what the drained hours have been missing since
// the live path stopped using a diarizer.
import Foundation
import AVFoundation
import FluidAudio

@available(iOS 17.0, *)
actor ScribeFile {
    static let shared = ScribeFile()

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var ready = false

    func prepare() async throws {
        guard !ready else { return }
        let a = AsrManager(config: .default)
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        } catch {
            // Same repair as the live engine: a half-finished download cannot
            // be retried into working order, only thrown away.
            ModelHub.clearAllCaches()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        }
        asr = a
        let d = OfflineDiarizerManager()
        do { try await d.prepareModels() } catch { try await d.prepareModels(forceRedownload: true) }
        diarizer = d
        ready = true
    }

    /// A 16 kHz mono WAV (Dart decodes the pendant's Opus with the decoder it
    /// already ships) becomes named, timed segments.
    func process(wavPath: String, stream: String) async throws -> [ScribeSegment] {
        try await prepare()
        guard let asr, let diarizer else { return [] }
        let url = URL(fileURLWithPath: wavPath)
        let samples = try AudioConverter().resampleAudioFile(url)
        guard samples.count > 16_000 else { return [] }   // under a second: nothing to say

        let turns = (try? await diarizer.process(audio: samples))?.segments ?? []
        var out: [ScribeSegment] = []

        // No turns at all means the diarizer heard no speech; fall back to one
        // pass over the file rather than silently dropping a recording.
        if turns.isEmpty {
            var state = try TdtDecoderState()
            let r = try await asr.transcribe(samples, decoderState: &state)
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                out.append(ScribeSegment(text: text, start: 0, end: Double(samples.count) / 16_000,
                                         speaker: "SPEAKER_00", speaker_id: 0, is_user: false,
                                         person_id: nil, stream: stream, media: nil, language: nil))
            }
            return out
        }

        for t in turns {
            let a = max(0, Int(t.startTimeSeconds * 16_000))
            let b = min(samples.count, Int(t.endTimeSeconds * 16_000))
            guard b - a > 8_000 else { continue }          // half a second
            let slice = Array(samples[a..<b])
            var state = try TdtDecoderState()
            guard let r = try? await asr.transcribe(slice, decoderState: &state) else { continue }
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let person = await Voiceprints.shared.name(for: t.embedding)
            let n = Int(t.speakerId.filter(\.isNumber)) ?? 0
            out.append(ScribeSegment(
                text: text, start: Double(t.startTimeSeconds), end: Double(t.endTimeSeconds),
                speaker: "SPEAKER_\(String(format: "%02d", n))", speaker_id: n,
                is_user: person == Voiceprints.wearerName,
                person_id: person == Voiceprints.wearerName ? nil : person,
                stream: stream, media: nil, language: nil))
        }
        return out
    }
}
