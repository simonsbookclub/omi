// Who is speaking, decided on the phone.
//
// The worker used to send every voice clip to a GPU service to be turned into
// a vector, then match it there. The vector now arrives free with the speaker
// separation, so all that is left is the comparison, which is arithmetic.
//
// Thresholds come from measurement, not taste. On 140 slices the existing
// pipeline had already named (2026-09-15): two clips of the same person score
// 0.545 on average, two different people 0.137, and picking the nearer of two
// enrolled prints named the speaker correctly 138 times out of 140.
import Foundation

actor Voiceprints {
    static let shared = Voiceprints()
    static let wearerName = "Simon"

    /// Below this, nobody is claimed: an unknown guest must stay unknown
    /// rather than be forced onto the closest enrolled person.
    private static let floor: Float = 0.30
    /// And the winner must beat the runner-up by this, or it is a coin toss.
    private static let margin: Float = 0.05

    private struct Print: Codable { var name: String; var centroid: [Float]; var count: Int }
    private var prints: [String: Print] = [:]
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiceprints.json")
    }()

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: Print].self, from: data) else { return }
        prints = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prints) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    var enrolled: [String: Int] { prints.mapValues(\.count) }

    /// Fold one more example of a known voice into its running average.
    func enroll(name: String, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        if var p = prints[name], p.centroid.count == embedding.count {
            let n = Float(p.count)
            for i in 0..<p.centroid.count { p.centroid[i] = (p.centroid[i] * n + embedding[i]) / (n + 1) }
            p.count += 1
            prints[name] = p
        } else {
            prints[name] = Print(name: name, centroid: embedding, count: 1)
        }
        save()
    }

    /// Replace a print outright, for vectors handed down by the worker.
    func replace(name: String, centroid: [Float], count: Int) {
        guard !centroid.isEmpty else { return }
        prints[name] = Print(name: name, centroid: centroid, count: max(1, count))
        save()
    }

    func name(for embedding: [Float]) -> String? {
        guard !prints.isEmpty, !embedding.isEmpty else { return nil }
        var best: (name: String, score: Float)? = nil
        var runnerUp: Float = -1
        for (name, p) in prints {
            let s = Self.cosine(embedding, p.centroid)
            if best == nil || s > best!.score {
                if let b = best { runnerUp = max(runnerUp, b.score) }
                best = (name, s)
            } else if s > runnerUp { runnerUp = s }
        }
        guard let b = best, b.score >= Self.floor else { return nil }
        if prints.count > 1 && (b.score - runnerUp) < Self.margin { return nil }
        return b.name
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d > 0 ? dot / d : 0
    }
}
