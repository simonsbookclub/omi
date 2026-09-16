// Apple's own transcriber, as an alternative to Parakeet.
//
// Both recover 95% of Deepgram's words on the one recording whose reference
// provably matches its audio, and they agree with each other on 92-94% of the
// words in the clean recordings. Neither invents text the way Whisper does:
// handed a minute it could not make out, Apple wrote nothing at all.
//
// Apple's costs nothing to ship — no 600 MB download to arrive corrupted, no
// third-party framework, no CoreML compute-unit to get wrong — and it is the
// system's own service. The single reason Parakeet was chosen over it was
// Russian, which SpeechTranscriber does not support in any of its 45 locales.
// Simon and Masha speak English to each other, so that reason is gone.
import Foundation
import AVFoundation
#if canImport(Speech)
import Speech
#endif

/// A run of words with the time it was said, relative to the audio handed in.
struct TimedPiece {
    var text: String
    var start: Double
    var end: Double
}

@available(iOS 26.0, *)
actor AppleTranscriber {
    static let shared = AppleTranscriber()

    #if canImport(Speech)
    private var locale: Locale?
    private var format: AVAudioFormat?
    #endif
    private var ready = false

    /// Whether the system can transcribe this locale at all, assets and all.
    static func isSupported(_ localeID: String = "en-US") async -> Bool {
        #if canImport(Speech)
        let wanted = Locale(identifier: localeID)
        return await SpeechTranscriber.supportedLocale(equivalentTo: wanted) != nil
        #else
        return false
        #endif
    }

    func prepare(localeID: String = "en-US") async throws {
        #if canImport(Speech)
        guard !ready else { return }
        let wanted = Locale(identifier: localeID)
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? wanted
        let t = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        // The voice model is an OS asset, downloaded once and shared by every
        // app on the phone rather than bundled into this one.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            NSLog("scribe: installing Apple speech assets for %@", locale.identifier(.bcp47))
            try await request.downloadAndInstall()
        }
        self.locale = locale
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
        ready = true
        NSLog("scribe: Apple transcriber ready (%@)", locale.identifier(.bcp47))
        #endif
    }

    /// One buffer of 16 kHz mono samples in, the words out.
    ///
    /// A fresh analyzer per call: these are already whole utterances cut by the
    /// speech detector, and a per-call analyzer cannot carry state from one
    /// person's turn into the next.
    func transcribe(_ samples: [Float]) async throws -> [TimedPiece] {
        #if canImport(Speech)
        try await prepare()
        guard let locale, !samples.isEmpty else { return [] }
        // A transcriber belongs to one analyzer. Handing the same one to a
        // second analyzer traps inside SpeechAnalyzer.prepareModulesIfNeeded,
        // which is what crashed the app on launch (2026-09-15). Both are made
        // fresh for each utterance; the expensive part, the voice model, is an
        // OS asset that stays loaded between them.
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)

        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 1, interleaved: false)
        guard let source,
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        // Convert only when the analyzer wants something other than what we have.
        var input = buffer
        if let want = format, want.sampleRate != source.sampleRate || want.commonFormat != source.commonFormat {
            guard let converter = AVAudioConverter(from: source, to: want) else { return [] }
            let ratio = want.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: want, frameCapacity: capacity) else { return [] }
            var done = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if done { status.pointee = .noDataNow; return nil }
                done = true
                status.pointee = .haveData
                return buffer
            }
            if err != nil { return [] }
            input = out
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Timed pieces, not one string. Without word times there is no way to
        // tell which half of a run of speech belonged to whom, and a quarter of
        // all segments came out holding both people's words under one name.
        let collector = Task { () -> [TimedPiece] in
            var parts: [TimedPiece] = []
            for try await r in transcriber.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let a = r.range.start.seconds, b = r.range.end.seconds
                parts.append(TimedPiece(text: text,
                                        start: a.isFinite ? a : 0,
                                        end: b.isFinite ? b : (a.isFinite ? a : 0)))
            }
            return parts
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: input))
        continuation.finish()
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
        #else
        return []
        #endif
    }
}
