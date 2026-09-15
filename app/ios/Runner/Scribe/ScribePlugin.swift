// The bridge between Dart and Scribe.
//
// Dart speaks to this exactly the way it spoke to the relay socket: it sends
// PCM frames and the odd control message, and gets `{"segments":[…]}` back.
// That symmetry is deliberate — the composite socket upstream forwards those
// replies to the backend untouched, so nothing above this line has to change.
import Foundation
import Flutter

final class ScribePlugin: NSObject, FlutterStreamHandler {
    static let shared = ScribePlugin()
    private var engine: ScribeEngine?
    private var sink: FlutterEventSink?
    private let queue = DispatchQueue(label: "scribe.plugin")

    /// Attached from AppDelegate with the Flutter messenger, the way every other
    /// native service in this app is wired.
    func attach(messenger: FlutterBinaryMessenger) {
        let method = FlutterMethodChannel(name: "com.simonsbookclub.scribe",
                                          binaryMessenger: messenger)
        let events = FlutterEventChannel(name: "com.simonsbookclub.scribe/segments",
                                         binaryMessenger: messenger)
        events.setStreamHandler(self)
        method.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result)
        }
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            let args = call.arguments as? [String: Any] ?? [:]
            let sessionId = args["sessionId"] as? String ?? UUID().uuidString
            let e = ScribeEngine(sessionId: sessionId)
            engine = e
            Task {
                await e.onSegments { [weak self] segs in self?.send(segs) }
                do {
                    try await e.prepare()
                    result(true)
                } catch {
                    result(FlutterError(code: "prepare_failed", message: "\(error)", details: nil))
                }
            }

        case "audio":
            guard let data = (call.arguments as? FlutterStandardTypedData)?.data, let e = engine else {
                result(false); return
            }
            Task { await e.feed(pcm16: data) }
            result(true)

        case "media":
            let on = (call.arguments as? [String: Any])?["playing"] as? Bool ?? false
            if let e = engine { Task { await e.setMedia(playing: on) } }
            result(true)

        case "stop":
            engine = nil
            result(true)

        // Phase 2: the worker hands down the enrolled voices so the phone can
        // name people without asking anything.
        case "setVoiceprints":
            let list = (call.arguments as? [String: Any])?["prints"] as? [[String: Any]] ?? []
            Task {
                for p in list {
                    guard let name = p["name"] as? String,
                          let vec = p["centroid"] as? [NSNumber] else { continue }
                    await Voiceprints.shared.replace(name: name,
                                                     centroid: vec.map { $0.floatValue },
                                                     count: (p["count"] as? Int) ?? 1)
                }
                result(true)
            }

        // Phase 4: titles, overviews and the read on a conversation, written by
        // the phone's own model rather than bought from Cloudflare.
        case "summarise":
            let args = call.arguments as? [String: Any] ?? [:]
            let transcript = args["transcript"] as? String ?? ""
            let want = args["want"] as? String ?? "structured"
            guard #available(iOS 26.0, *), ScribeWriter.isAvailable, !transcript.isEmpty else {
                result(FlutterError(code: "unavailable", message: "no on-device model", details: nil)); return
            }
            #if canImport(FoundationModels)
            Task {
                do {
                    switch want {
                    case "sentiment":
                        let r = try await ScribeWriter.sentiment(for: transcript)
                        result(["valence": r.valence, "arousal": r.arousal, "emotion": r.emotion,
                                "quality": r.quality, "curiosity": r.curiosity])
                    case "relationship":
                        let r = try await ScribeWriter.relationship(for: transcript)
                        result(["tension": r.tension, "escalation": r.escalation, "repair": r.repair,
                                "hard": r.hard, "summary": r.summary])
                    default:
                        let r = try await ScribeWriter.structured(for: transcript)
                        result(["title": r.title, "overview": r.overview, "emoji": r.emoji, "category": r.category])
                    }
                } catch {
                    result(FlutterError(code: "generate_failed", message: "\(error)", details: nil))
                }
            }
            #else
            result(FlutterError(code: "unavailable", message: "FoundationModels not in this build", details: nil))
            #endif

        // Phase 3: a drained flash recording, read here instead of uploaded.
        case "processFile":
            let args = call.arguments as? [String: Any] ?? [:]
            guard let path = args["wavPath"] as? String else { result(FlutterError(code: "bad_args", message: "wavPath required", details: nil)); return }
            let stream = args["stream"] as? String ?? "device:file"
            guard #available(iOS 17.0, *) else { result(FlutterError(code: "unavailable", message: "iOS 17+", details: nil)); return }
            Task {
                do {
                    let segs = try await ScribeFile.shared.process(wavPath: path, stream: stream)
                    let data = try JSONEncoder().encode(segs)
                    result(String(data: data, encoding: .utf8) ?? "[]")
                } catch {
                    result(FlutterError(code: "process_failed", message: "\(error)", details: nil))
                }
            }

        case "writerAvailable":
            if #available(iOS 26.0, *) { result(ScribeWriter.isAvailable) } else { result(false) }

        case "enrolledVoices":
            Task { result(await Voiceprints.shared.enrolled) }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func send(_ segs: [ScribeSegment]) {
        guard let sink else { return }
        guard let data = try? JSONEncoder().encode(["segments": segs]),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { sink(json) }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }
}
