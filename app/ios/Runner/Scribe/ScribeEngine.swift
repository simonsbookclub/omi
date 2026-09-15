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
//
// The models themselves live in ScribeModels, loaded once per process. This
// object is one session's state only, so a pendant reconnect costs nothing.
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
    /// Audio kept while the models are still loading: ten minutes. The first
    /// launch downloads 600 MB and the opening of a conversation should not
    /// be lost to it (the way an interview was on 2026-09-15).
    private static let backlogCapBytes = 10 * 60 * 16_000 * 2

    /// The gate keeps state between chunks (Silero-style hysteresis), so it has
    /// to be carried forward rather than made fresh each time.
    private var vadState: VadStreamState?
    private var ready = false
    private var backlog: [Data] = []
    private var backlogBytes = 0
    /// The last 20 seconds of everything, speech or not.
    ///
    /// The diarizer works on ~10-second windows and finds nothing in less, so
    /// a short utterance handed to it on its own returns no speakers at all —
    /// which is why every live segment came out SPEAKER_00 and unnamed on the
    /// first day. A short utterance is diarized inside this window instead.
    private static let recentCapS: Double = 20
    private static let diarizeMinS: Double = 10
    private var recent: [Float] = []

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

    /// Ready as soon as the shared models are; then everything that arrived
    /// while waiting goes through, in order, before anything new.
    func prepare() async throws {
        guard !ready else { return }
        try await ScribeModels.shared.prepare()
        vadState = try await ScribeModels.shared.makeVadState()
        ready = true
        while !backlog.isEmpty {
            let batch = backlog
            backlog.removeAll(keepingCapacity: true)
            backlogBytes = 0
            for d in batch { await ingest(d) }
        }
        NSLog("scribe: session %@ live", String(sessionId.prefix(8)))
    }

    /// The session is over; whatever is still buffered is an utterance too.
    func finish() async {
        guard ready, sawSpeech else { return }
        await close()
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

    /// 16-bit little-endian mono PCM, exactly what the app already decodes for the relay.
    func feed(pcm16: Data) async {
        // Not ready, or still working through what arrived while not ready:
        // queue it, so nothing is dropped and nothing goes out of order.
        if !ready || !backlog.isEmpty {
            if backlogBytes < Self.backlogCapBytes {
                backlog.append(pcm16)
                backlogBytes += pcm16.count
            }
            return
        }
        await ingest(pcm16)
    }

    private func ingest(_ pcm16: Data) async {
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
        if let state = vadState, let r = try? await ScribeModels.shared.vadStep(chunk, state: state) {
            vadState = r.state
            voiced = r.probability >= 0.75
        }

        if voiced {
            if !sawSpeech {
                sawSpeech = true
                pendingStartS = max(0, atS - Self.preRollS)
            }
            lastVoiceAtS = clockS
        }
        pending += chunk
        recent += chunk
        let cap = Int(Self.sampleRate * Self.recentCapS)
        if recent.count > cap { recent.removeFirst(recent.count - cap) }

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

    private struct Piece {
        var text: String
        var from: Double
        var to: Double
        var speaker: Int
        var embedding: [Float]?
    }

    /// A speaker turn on the utterance's own clock. The library's own type is
    /// immutable and measured against whatever buffer it was given, which is
    /// not the utterance when a short one is diarized inside a wider window.
    private struct Turn {
        var speakerId: String
        var embedding: [Float]
        var start: Double
        var end: Double
        var duration: Double { end - start }
    }

    /// Finish the buffered utterance: transcribe it, split it by speaker, name each voice, emit, forget the audio.
    private func close() async {
        let audio = pending
        let startS = pendingStartS
        let endS = clockS
        pending = []; sawSpeech = false
        guard audio.count >= Int(Self.sampleRate * Self.minSpeechMs / 1000) else { return }

        do {
            let r = try await ScribeModels.shared.transcribe(audio)
            let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            // Who spoke, and where they changed over. One utterance often holds
            // a question and its answer — the gate only hears the pause between
            // them if it lasts 1.5 s — so the diarizer's turns split it.
            //
            // A short utterance is diarized inside the surrounding ten seconds
            // and the turns moved back onto its own clock: the diarizer works
            // in ~10 s windows and returns nothing at all for less, which is
            // why every live segment came out SPEAKER_00 and unnamed on the
            // first day (2026-09-15).
            let utterS = endS - startS
            var window = audio
            var offsetIntoWindow = 0.0
            if utterS < Self.diarizeMinS {
                let take = min(Int(Self.sampleRate * Self.diarizeMinS), recent.count)
                if take > audio.count {
                    window = Array(recent.suffix(take))
                    offsetIntoWindow = Double(take - audio.count) / Self.sampleRate
                }
            }
            var turns: [Turn] = []
            do {
                turns = try await ScribeModels.shared.diarize(window).segments.map {
                    Turn(speakerId: $0.speakerId, embedding: $0.embedding,
                         start: Double($0.startTimeSeconds) - offsetIntoWindow,
                         end: Double($0.endTimeSeconds) - offsetIntoWindow)
                }
            } catch {
                NSLog("scribe: no speakers in %.1fs (window %.1fs): %@",
                      utterS, Double(window.count) / Self.sampleRate, "\(error)")
            }
            turns = turns
                .compactMap { t -> Turn? in
                    // Keep only what overlaps the utterance itself.
                    guard t.end > 0, t.start < utterS else { return nil }
                    var c = t
                    c.start = max(0, t.start); c.end = min(utterS, t.end)
                    return c.duration >= 0.5 ? c : nil
                }
                .sorted { $0.start < $1.start }

            let timings = r.tokenTimings ?? []
            var pieces: [Piece] = []
            if turns.count >= 2, !timings.isEmpty, Set(turns.map(\.speakerId)).count >= 2 {
                // Each token goes to the turn holding its midpoint, else the nearest.
                var byTurn = [[TokenTiming]](repeating: [], count: turns.count)
                for t in timings {
                    let mid = (t.startTime + t.endTime) / 2
                    let inside = turns.firstIndex { $0.start <= mid && mid <= $0.end }
                    let idx = inside ?? turns.indices.min { Self.distance(mid, turns[$0]) < Self.distance(mid, turns[$1]) }
                    if let idx { byTurn[idx].append(t) }
                }
                for (i, turn) in turns.enumerated() {
                    let words = Self.join(byTurn[i])
                    guard !words.isEmpty else { continue }
                    let sp = Int(turn.speakerId.filter(\.isNumber)) ?? i
                    let to = startS + turn.end
                    if let last = pieces.last, last.speaker == sp {
                        // The same person kept talking; one piece, not two.
                        pieces[pieces.count - 1].text += " " + words
                        pieces[pieces.count - 1].to = to
                    } else {
                        pieces.append(Piece(text: words, from: startS + turn.start, to: to,
                                            speaker: sp, embedding: turn.embedding))
                    }
                }
            }
            if pieces.isEmpty {
                let best = turns.max { $0.duration < $1.duration }
                pieces = [Piece(text: text, from: startS, to: endS,
                                speaker: Int(best?.speakerId.filter(\.isNumber) ?? "") ?? 0,
                                embedding: best?.embedding)]
            }

            var out: [ScribeSegment] = []
            for p in pieces {
                var person: String? = nil
                if let e = p.embedding {
                    let m = await Voiceprints.shared.match(e)
                    person = m.name
                    NSLog("scribe: %.1fs \"%@\" → %@ (%.2f, next %.2f)",
                          p.to - p.from, String(p.text.prefix(40)), m.name ?? "unknown", m.score, m.runnerUp)
                } else {
                    NSLog("scribe: %.1fs \"%@\" → no voice vector", p.to - p.from, String(p.text.prefix(40)))
                }
                let media = person == nil && mediaShare(p.from, p.to) >= 0.5
                out.append(ScribeSegment(
                    text: p.text, start: p.from, end: p.to,
                    speaker: String(format: "SPEAKER_%02d", p.speaker),
                    speaker_id: p.speaker,
                    is_user: person == Voiceprints.wearerName,
                    person_id: person == Voiceprints.wearerName ? nil : person,
                    stream: "device:\(sessionId)",
                    media: media ? true : nil,
                    language: nil))
            }
            emit?(out)
        } catch {
            NSLog("scribe: utterance failed: \(error)")
        }
    }

    private static func distance(_ t: Double, _ turn: Turn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// Parakeet's pieces back into words. Word starts carry "▁" in the
    /// vocabulary; if the library has already turned those into spaces this is
    /// a no-op.
    private static func join(_ tokens: [TokenTiming]) -> String {
        tokens.map(\.token).joined()
            .replacingOccurrences(of: "▁", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
