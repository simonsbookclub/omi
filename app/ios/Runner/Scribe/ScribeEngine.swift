// Scribe: the pendant's audio understood on this phone, not in a data centre.
//
// The relay used to receive every frame, pay Deepgram by the minute and send
// back `{segments:[…]}`. This does the same work here: a voice-activity gate
// cuts the stream into utterances, Parakeet writes each one down, the
// diarizer says who spoke, and a voiceprint match puts a name to them. What
// leaves the phone is text, times and a 256-number voice vector; the audio
// itself is discarded as soon as it has been read.
//
// Phase 0 measured all three parts on this hardware (2026-09-15): Parakeet at
// 216x realtime and 545 MB peak on an A19 Pro, and speaker vectors that name
// Simon or Masha correctly 138 times out of 140.
import Foundation
import AVFoundation
import FluidAudio

/// One finished utterance, in the shape the backend's listen socket already accepts.
struct ScribeSegment: Codable {
    var text: String
    var start: Double
    var end: Double
    var speaker: String
    var speaker_id: Int
    var is_user: Bool
    var person_id: String?
    var stream: String
    var media: Bool?
    var language: String?
}

actor ScribeEngine {
    // MARK: tuning
    /// Deepgram's endpointing and the relay's whisper gate both settled on 1.5 s;
    /// a shorter pause splits a sentence and, worse, splits a spoken command.
    private static let silenceClosesUtteranceMs: Double = 1500
    /// Below this much speech an "utterance" is a cough or a door.
    private static let minSpeechMs: Double = 500
    /// Above this, close it anyway: a monologue should not wait for a pause.
    private static let maxUtteranceS: Double = 30
    /// Keep a little audio before the gate opened, or the first word is clipped.
    private static let preRollS: Double = 0.25
    private static let sampleRate: Double = 16_000

    private var asr: AsrManager?
    private var vad: VadManager?
    /// The gate keeps state between chunks (Silero-style hysteresis), so it has
    /// to be carried forward rather than made fresh each time.
    private var vadState: VadStreamState?
    private var diarizer: OfflineDiarizerManager?
    private var ready = false

    /// Audio waiting to be closed into an utterance, and where it sits on the session clock.
    private var pending: [Float] = []
    private var pendingStartS: Double = 0
    private var lastVoiceAtS: Double = 0
    private var sawSpeech = false
    /// Everything received so far, in seconds, so segment times match the session.
    private var clockS: Double = 0
    private var carry: [Float] = []

    private let sessionId: String
    private var emit: (@Sendable ([ScribeSegment]) -> Void)?
    /// Windows the phone was playing audio out loud, which must not become "someone said".
    private var mediaWindows: [(start: Double, end: Double?)] = []

    init(sessionId: String) { self.sessionId = sessionId }

    func onSegments(_ cb: @escaping @Sendable ([ScribeSegment]) -> Void) { self.emit = cb }

    /// Models load once and stay loaded; the first call downloads about 600 MB.
    ///
    /// A download interrupted mid-flight leaves truncated or empty files that
    /// no amount of retrying repairs — the library says so itself in the log
    /// and then keeps trying anyway. So: one clean attempt, and if that fails,
    /// throw the cache away and start again from nothing.
    func prepare() async throws {
        guard !ready else { return }
        let a = AsrManager(config: .default)
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        } catch {
            NSLog("scribe: model load failed (\(error)); clearing the cache and downloading again")
            ModelHub.clearAllCaches()
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            try await a.loadModels(models)
        }
        NSLog("scribe: Parakeet ready")
        self.asr = a
        let v = try await VadManager(config: VadConfig(defaultThreshold: 0.75))
        self.vad = v
        self.vadState = await v.makeStreamState()
        let d = OfflineDiarizerManager()
        do {
            try await d.prepareModels()
        } catch {
            NSLog("scribe: diarizer models failed (\(error)); retrying once")
            try await d.prepareModels(forceRedownload: true)
        }
        self.diarizer = d
        ready = true
        NSLog("scribe: engine ready — transcribing on this phone")
    }

    func setMedia(playing: Bool) {
        if playing {
            if mediaWindows.last?.end != nil || mediaWindows.isEmpty { mediaWindows.append((clockS, nil)) }
        } else if var last = mediaWindows.last, last.end == nil {
            last.end = clockS
            mediaWindows[mediaWindows.count - 1] = last
        }
        if mediaWindows.count > 200 { mediaWindows.removeFirst(mediaWindows.count - 200) }
    }

    private func mediaShare(_ from: Double, _ to: Double) -> Double {
        guard to > from else { return 0 }
        var covered = 0.0
        for w in mediaWindows {
            let a = max(from, w.start), b = min(to, w.end ?? clockS)
            if b > a { covered += b - a }
        }
        return covered / (to - from)
    }

    /// 16-bit little-endian mono PCM straight off the pendant, exactly what the
    /// app already decodes for the relay.
    func feed(pcm16: Data) async {
        guard ready else { return }
        var samples = [Float]()
        samples.reserveCapacity(pcm16.count / 2)
        pcm16.withUnsafeBytes { raw in
            let n = raw.count / 2
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<n { samples.append(Float(Int16(littleEndian: p[i])) / 32768.0) }
        }
        carry += samples
        // The gate works on whole chunks; 512 samples is 32 ms at 16 kHz.
        let chunk = 512
        while carry.count >= chunk {
            let slice = Array(carry.prefix(chunk))
            carry.removeFirst(chunk)
            await step(slice)
        }
    }

    private func step(_ chunk: [Float]) async {
        let durS = Double(chunk.count) / Self.sampleRate
        let atS = clockS
        clockS += durS

        var voiced = false
        if let vad, let state = vadState {
            if let r = try? await vad.processStreamingChunk(chunk, state: state, config: .default, returnSeconds: false) {
                vadState = r.state
                voiced = r.probability >= 0.75
            }
        }

        if voiced {
            if !sawSpeech {
                sawSpeech = true
                pendingStartS = max(0, atS - Self.preRollS)
            }
            lastVoiceAtS = clockS
        }
        pending += chunk

        let quietFor = (clockS - lastVoiceAtS) * 1000
        let longEnough = (clockS - pendingStartS) >= Self.maxUtteranceS
        if sawSpeech && (quietFor >= Self.silenceClosesUtteranceMs || longEnough) {
            await close()
        } else if !sawSpeech && pending.count > Int(Self.sampleRate * 2) {
            // Nothing but room tone: drop all but the pre-roll.
            let keep = Int(Self.sampleRate * Self.preRollS)
            pending = Array(pending.suffix(keep))
            pendingStartS = clockS - Double(keep) / Self.sampleRate
        }
    }

    /// Finish the buffered utterance: transcribe it, name the voice, emit it, forget the audio.
    private func close() async {
        let audio = pending
        let startS = pendingStartS
        let endS = clockS
        pending = []; sawSpeech = false
        guard audio.count >= Int(Self.sampleRate * Self.minSpeechMs / 1000), let asr else { return }

        do {
            var state = try TdtDecoderState()
            let r = try await asr.transcribe(audio, decoderState: &state)
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            var speakerId = 0
            var person: String? = nil
            var embedding: [Float]? = nil
            if let diarizer, let d = try? await diarizer.process(audio: audio),
               let best = d.segments.max(by: { $0.durationSeconds < $1.durationSeconds }) {
                embedding = best.embedding
                speakerId = Int(best.speakerId.filter(\.isNumber)) ?? 0
            }
            if let embedding { person = await Voiceprints.shared.name(for: embedding) }

            let media = person == nil && mediaShare(startS, endS) >= 0.5
            let seg = ScribeSegment(
                text: text, start: startS, end: endS,
                speaker: "SPEAKER_\(String(format: "%02d", speakerId))",
                speaker_id: speakerId,
                is_user: person == Voiceprints.wearerName,
                person_id: person == Voiceprints.wearerName ? nil : person,
                stream: "device:\(sessionId)",
                media: media ? true : nil,
                language: nil)
            emit?([seg])
        } catch {
            NSLog("scribe: utterance failed: \(error)")
        }
    }
}
