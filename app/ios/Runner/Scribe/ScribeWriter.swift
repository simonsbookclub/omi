// Titles, overviews and the read on a conversation, written by the phone.
//
// The worker does this today with Llama 70B on Cloudflare. Apple's on-device
// model is free, private and offline, and the probe confirmed it both available
// and actually generating on this hardware (2026-09-15). The guided-generation
// types below mirror exactly what omi-listen.ts and health.ts already store, so
// the worker keeps its shape and only stops paying for the words.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
enum ScribeWriter {

    #if canImport(FoundationModels)
    @Generable
    struct Structured {
        @Guide(description: "A short title, at most six words, in the language the conversation is in.")
        var title: String
        @Guide(description: "Two or three sentences saying what was actually discussed.")
        var overview: String
        @Guide(description: "One emoji that fits the conversation.")
        var emoji: String
        @Guide(description: "One of: personal, work, social, health, finance, education, other.")
        var category: String
    }

    @Generable
    struct Sentiment {
        @Guide(description: "How pleasant the speaker sounds, -1 unpleasant to 1 pleasant.")
        var valence: Double
        @Guide(description: "How activated the speaker sounds, 0 calm to 1 agitated.")
        var arousal: Double
        @Guide(description: "One word for the dominant emotion.")
        var emotion: String
        @Guide(description: "Quality of the exchange, 0 to 100.")
        var quality: Int
        @Guide(description: "How curious the speaker is about the other person, 0 to 1.")
        var curiosity: Double
    }

    /// The shape the Us panel already stores (us-analysis.ts, version 5). Every
    /// field it reads is here, so a conversation read on the phone renders the
    /// same as one the worker paid for.
    @Generable
    struct Relationship {
        @Guide(description: "Tension in the conversation, 0 none to 1 a row.")
        var tension: Double
        @Guide(description: "Escalation: does it get worse as it goes, 0 to 1.")
        var escalation: Double
        @Guide(description: "Repair: attempts to soften, apologise or reconnect, 0 to 1.")
        var repair: Double
        @Guide(description: "Taking responsibility rather than assigning it, 0 to 1.")
        var self_blame: Double
        @Guide(description: "True only if this was a genuinely hard conversation.")
        var hard: Bool
        @Guide(description: "One sentence, plain and specific, on what happened between them.")
        var summary: String
        @Guide(description: "Up to three short quotes, word for word, where someone softened or reconnected. Empty if there were none.")
        var repair_examples: [String]
    }
    #endif

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability {
            logModelOnce()
            return true
        }
        #endif
        return false
    }

    private static var logged = false

    /// Which model this phone actually runs. iOS 27 ships two on-device
    /// variants, core3 and coreAdvanced3, and there is no way to ask for one:
    /// `variant` is read-only and the system decides. So record what we got.
    private static func logModelOnce() {
        guard !logged else { return }
        logged = true
        #if canImport(FoundationModels)
        #if compiler(>=6.3)
        if #available(iOS 27.0, *) {
            NSLog("scribe: on-device model is %@", SystemLanguageModel.default.variant.displayName)
            return
        }
        #endif
        NSLog("scribe: on-device model available")
        #endif
    }

    /// The on-device window is 8,192 tokens, and Cyrillic spends far more of
    /// them per character than English does, so no character count is right for
    /// both. Rather than guess low and summarise everything twice, hand over
    /// the whole transcript and only fall back to pieces when the model refuses
    /// it — which is the one reliable signal of what actually fits.
    private static let chunkChars = 6000

    #if canImport(FoundationModels)
    private static func respond<T: Generable>(_ instructions: String, _ transcript: String, _ type: T.Type) async throws -> T {
        do {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: transcript, generating: type).content
        } catch {
            let short = try await condense(transcript)
            NSLog("scribe: transcript of %d chars did not fit; condensed to %d", transcript.count, short.count)
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: short, generating: type).content
        }
    }

    /// A long conversation summarised in pieces, and the pieces joined.
    private static func condense(_ transcript: String) async throws -> String {
        guard transcript.count > chunkChars else { return transcript }
        var parts: [String] = []
        var i = transcript.startIndex
        while i < transcript.endIndex {
            let j = transcript.index(i, offsetBy: chunkChars, limitedBy: transcript.endIndex) ?? transcript.endIndex
            parts.append(String(transcript[i..<j]))
            i = j
        }
        var notes: [String] = []
        for part in parts {
            let session = LanguageModelSession(instructions: "Summarise this part of a conversation in three sentences. Keep names, quotes and specifics.")
            notes.append(try await session.respond(to: part).content)
        }
        return notes.joined(separator: "\n")
    }
    #endif

    #if canImport(FoundationModels)
    static func structured(for transcript: String) async throws -> Structured {
        try await respond("You title and summarise a recorded conversation. Answer in the language the conversation is in. Be specific and plain; no preamble.", transcript, Structured.self)
    }

    static func sentiment(for transcript: String) async throws -> Sentiment {
        try await respond("You read how someone sounds in a conversation. Judge only from what is said. Be conservative: most conversations are unremarkable.", transcript, Sentiment.self)
    }

    static func relationship(for transcript: String) async throws -> Relationship {
        try await respond("You read what happened between two people in a conversation. Be conservative: score tension near zero unless there is real friction, and never invent events or quotes.", transcript, Relationship.self)
    }
    #endif
}
