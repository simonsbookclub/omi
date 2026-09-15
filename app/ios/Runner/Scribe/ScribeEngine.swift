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
    /// How much audio to gather before reading it.
    ///
    /// The first version gated the stream chunk by chunk with a hand-rolled
    /// threshold and threw away everything it judged silent. Measured against
    /// real pendant audio it kept 1.3 seconds of a 641-second recording, so
    /// almost the whole conversation was destroyed before the transcriber ever
    /// saw it (2026-09-15). This does what the file reader does instead, which
    /// works: gather a window, ask the library where the speech is, and read
    /// those parts. Thirty seconds of delay is nothing for a day's record.
    private static let windowS: Double = 30
    /// Speech still running at the edge of a window is held back for the next
    /// one rather than cut mid-word.
    private static let edgeGuardS: Double = 0.75
    /// The transcriber's own floor is 0.3 s; anything above that is worth
    /// keeping. At 0.4 it dropped "Yes.", "No." and "Mhmm" — the turns that
    /// carry agreement.
    private static let minSpeechS: Double = 0.3
    private static let sampleRate: Double = 16_000
    /// Audio kept while the models are still loading: ten minutes.
    private static let backlogCapBytes = 10 * 60 * 16_000 * 2

    private var ready = false
    private var backlog: [Data] = []
    private var backlogBytes = 0

    /// The audio waiting to be read, and where it starts on the session clock.
    private var window: [Float] = []
    private var windowStartS: Double = 0
    /// drain() suspends on three model calls. Without this, every packet that
    /// arrived meanwhile started another drain over the same audio.
    private var draining = false
    /// Each window is its own stream, so the backend anchors it on arrival
    /// rather than carrying one drifting clock — and cannot glue this window's
    /// SPEAKER_00 onto the last window's, who is a different person.
    private var windowIndex = 0
    /// Everything received so far, in seconds.
    private var clockS: Double = 0

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
        // Deliberately still not `ready`: feed() keeps queueing while this
        // replays, so live packets cannot interleave with the backlog and
        // splice two different moments into one window.
        while !backlog.isEmpty {
            let batch = backlog
            backlog.removeAll(keepingCapacity: true)
            backlogBytes = 0
            for d in batch { await ingest(d) }
        }
        ready = true
        NSLog("scribe: session %@ live", String(sessionId.prefix(8)))
    }

    /// The session is over; read whatever is left.
    func finish() async {
        // An open media window would otherwise mark everything after it as
        // the phone's own audio for the rest of the session.
        setMedia(playing: false)
        guard ready, !window.isEmpty, !draining else { return }
        await drain(force: true)
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
        window += samples
        clockS += Double(samples.count) / Self.sampleRate
        if !draining, Double(window.count) / Self.sampleRate >= Self.windowS {
            await drain(force: false)
        }
    }

    /// Read the window: find the speech, transcribe each run of it, say who spoke.
    private func drain(force: Bool) async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        let buffer = window
        let bufferS = Double(buffer.count) / Self.sampleRate
        guard buffer.count > Int(Self.sampleRate * Self.minSpeechS) else { return }
        let index = windowIndex
        windowIndex += 1

        var runs: [(start: Double, end: Double)] = []
        var gateFailed = false
        do {
            runs = try await ScribeModels.shared.speech(in: buffer)
        } catch {
            NSLog("scribe: could not find the speech in %.0fs: %@", bufferS, "\(error)")
            // Read the whole window rather than lose it — and do not hold any
            // of it back, or a repeated failure pins the same audio for ever.
            runs = [(start: 0, end: bufferS)]
            gateFailed = true
        }
        runs = runs.filter { $0.end - $0.start >= Self.minSpeechS }

        // Speech still going at the edge waits for the next window, so a word
        // is not cut in half. Never when the gate failed, and never the whole
        // window, or nothing would ever be read.
        var carryFromS: Double? = nil
        if !force, !gateFailed, let last = runs.last,
           bufferS - last.end < Self.edgeGuardS, last.start > Self.edgeGuardS {
            carryFromS = last.start
            runs.removeLast()
        }

        // How much of the buffer this pass consumes. Everything after it stays,
        // INCLUDING audio that arrived while the models were working — which is
        // why this is a removeFirst on the live window rather than a write-back
        // of the snapshot.
        let consumedS = carryFromS ?? bufferS
        defer {
            let consumed = min(window.count, Int(consumedS * Self.sampleRate))
            if consumed > 0 { window.removeFirst(consumed) }
            windowStartS += consumedS
        }

        guard !runs.isEmpty else { return }

        // One diarization for the whole window: speakers stay consistent
        // across it, which a per-utterance pass could never manage.
        var turns: [Turn] = []
        do {
            turns = try await ScribeModels.shared.diarize(buffer).segments.map {
                Turn(speakerId: $0.speakerId, embedding: $0.embedding,
                     start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        } catch {
            NSLog("scribe: no speakers in this %.0fs window: %@", bufferS, "\(error)")
        }

        var out: [ScribeSegment] = []
        for run in runs {
            let a = max(0, Int(run.start * Self.sampleRate))
            let b = min(buffer.count, Int(run.end * Self.sampleRate))
            guard b - a > Int(Self.sampleRate * Self.minSpeechS) else { continue }
            var text = ""
            do {
                text = try await ScribeModels.shared.transcribe(Array(buffer[a..<b]))
                    .text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                NSLog("scribe: lost %.1fs of speech: %@", run.end - run.start, "\(error)")
                continue
            }
            guard !text.isEmpty, !Self.isGibberish(text) else { continue }

            // The speaker holding most of this run.
            let turn = turns
                .map { t -> (Turn, Double) in (t, max(0, min(t.end, run.end) - max(t.start, run.start))) }
                .filter { $0.1 > 0 }
                .max { $0.1 < $1.1 }?.0
            var person: String? = nil
            if let e = turn?.embedding {
                let m = await Voiceprints.shared.match(e)
                person = m.name
                NSLog("scribe: %.1fs \"%@\" → %@ (%.2f, next %.2f)",
                      run.end - run.start, String(text.prefix(40)), m.name ?? "unknown", m.score, m.runnerUp)
            } else {
                NSLog("scribe: %.1fs \"%@\" → no voice vector", run.end - run.start, String(text.prefix(40)))
            }
            // Times are relative to THIS window, which the backend anchors when
            // it arrives. One session-long clock counted audio rather than time,
            // so a dropped link shifted everything after it.
            let from = windowStartS + run.start
            let to = windowStartS + run.end
            let media = person == nil && mediaShare(from, to) >= 0.5
            let sp = Int(turn?.speakerId.filter(\.isNumber) ?? "") ?? 0
            out.append(ScribeSegment(
                text: text, start: run.start, end: run.end,
                speaker: String(format: "SPEAKER_%02d", sp), speaker_id: sp,
                is_user: person == Voiceprints.wearerName,
                person_id: person == Voiceprints.wearerName ? nil : person,
                stream: "device:\(sessionId):\(index)",
                media: media ? true : nil, language: nil))
        }
        if !out.isEmpty { emit?(out) }
    }

    /// A transcriber that has lost its footing repeats itself: "5-5-5-5-5…" for
    /// a whole minute, or a line of bullets. It is never speech, and once it is
    /// in the record there is no telling it from something that was said.
    static func isGibberish(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if words.count >= 12 {
            let unique = Double(Set(words).count) / Double(words.count)
            if unique < 0.15 { return true }
            // One token over and over, even spelled differently each time.
            if let top = Dictionary(grouping: words, by: { $0 }).values.map(\.count).max(),
               Double(top) / Double(words.count) > 0.5 { return true }
        }
        // Long, but almost none of it is a word: a run of punctuation or symbols.
        if text.count > 40 && words.count * 20 < text.count { return true }
        return false
    }

    /// A speaker turn on the window's clock.
    private struct Turn {
        var speakerId: String
        var embedding: [Float]
        var start: Double
        var end: Double
    }
}
