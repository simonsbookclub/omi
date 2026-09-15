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

    @Generable
    struct Relationship {
        @Guide(description: "Tension in the conversation, 0 none to 1 a row.")
        var tension: Double
        @Guide(description: "Escalation: does it get worse as it goes, 0 to 1.")
        var escalation: Double
        @Guide(description: "Repair: attempts to soften, apologise or reconnect, 0 to 1.")
        var repair: Double
        @Guide(description: "True only if this was a genuinely hard conversation.")
        var hard: Bool
        @Guide(description: "One sentence, plain and specific, on what happened between them.")
        var summary: String
    }
    #endif

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// The on-device context is small, so a long conversation is summarised in
    /// pieces and the pieces summarised again, rather than truncated.
    private static func condense(_ transcript: String, limit: Int = 6000) async throws -> String {
        guard transcript.count > limit else { return transcript }
        #if canImport(FoundationModels)
        var parts: [String] = []
        var i = transcript.startIndex
        while i < transcript.endIndex {
            let j = transcript.index(i, offsetBy: limit, limitedBy: transcript.endIndex) ?? transcript.endIndex
            parts.append(String(transcript[i..<j]))
            i = j
        }
        var notes: [String] = []
        for part in parts {
            let session = LanguageModelSession(instructions: "Summarise this part of a conversation in three sentences. Keep names and specifics.")
            notes.append(try await session.respond(to: part).content)
        }
        return notes.joined(separator: "\n")
        #else
        return String(transcript.prefix(limit))
        #endif
    }

    #if canImport(FoundationModels)
    static func structured(for transcript: String) async throws -> Structured {
        let text = try await condense(transcript)
        let session = LanguageModelSession(instructions:
            "You title and summarise a recorded conversation. Answer in the language the conversation is in. Be specific and plain; no preamble.")
        return try await session.respond(to: text, generating: Structured.self).content
    }

    static func sentiment(for transcript: String) async throws -> Sentiment {
        let text = try await condense(transcript, limit: 4000)
        let session = LanguageModelSession(instructions:
            "You read how someone sounds in a conversation. Judge only from what is said. Be conservative: most conversations are unremarkable.")
        return try await session.respond(to: text, generating: Sentiment.self).content
    }

    static func relationship(for transcript: String) async throws -> Relationship {
        let text = try await condense(transcript, limit: 6000)
        let session = LanguageModelSession(instructions:
            "You read what happened between two people in a conversation. Be conservative: score tension near zero unless there is real friction, and never invent events.")
        return try await session.respond(to: text, generating: Relationship.self).content
    }
    #endif
}
