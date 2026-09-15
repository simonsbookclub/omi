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
    /// `sink` and `engine` are written on the platform thread and read from
    /// background tasks. The lock is what the unused dispatch queue here was
    /// meant to be.
    private let lock = NSLock()
    /// One ordered pipe for audio. A Task per packet raced: PCM reached the
    /// engine out of order, and hundreds queued behind a busy window.
    private var audio: AsyncStream<Data>.Continuation?
    private var audioBytes = 0
    private var lastAudioLog = Date()

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
            lock.lock()
            let old = engine
            let oldPipe = audio
            let e = ScribeEngine(sessionId: sessionId)
            engine = e
            let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { self.audio = $0 }
            lock.unlock()
            oldPipe?.finish()
            Task {
                // The previous session's last words, if any, before it goes.
                if let old { await old.finish() }
                await e.onSegments { [weak self] segs in self?.send(segs) }
                // Dart does not wait for the models: audio that arrives in the
                // meantime is kept and read once they are up.
                do { try await e.prepare() } catch {
                    NSLog("scribe: engine could not prepare: \(error)")
                }
            }
            // One consumer, so packets reach the engine in the order they came.
            Task { for await d in stream { await e.feed(pcm16: d) } }
            result(true)

        case "audio":
            guard let data = (call.arguments as? FlutterStandardTypedData)?.data else { result(false); return }
            lock.lock()
            let pipe = audio
            // Whether audio is arriving at all was invisible, and that is the
            // one question worth being able to answer: on 2026-09-15 a whole
            // dinner produced no transcript and it took an hour to establish
            // that almost no audio had reached the engine.
            audioBytes += data.count
            let now = Date()
            let due = now.timeIntervalSince(lastAudioLog) >= 30
            if due {
                let seconds = Double(audioBytes) / 32_000
                lastAudioLog = now
                audioBytes = 0
                lock.unlock()
                NSLog("scribe: %.1fs of audio in the last 30s", seconds)
            } else {
                lock.unlock()
            }
            guard let pipe else { result(false); return }
            pipe.yield(data)
            result(true)

        case "media":
            let on = (call.arguments as? [String: Any])?["playing"] as? Bool ?? false
            lock.lock(); let e = engine; lock.unlock()
            if let e { Task { await e.setMedia(playing: on) } }
            result(true)

        case "stop":
            // Answer only once the last window has been read and emitted.
            // Returning early let Dart cancel the event subscription first, and
            // every session's closing words went into a nil sink.
            lock.lock()
            let e = engine
            let pipe = audio
            engine = nil
            audio = nil
            lock.unlock()
            pipe?.finish()
            guard let e else { result(true); return }
            Task {
                await e.finish()
                DispatchQueue.main.async { result(true) }
            }

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
                                "self_blame": r.self_blame, "hard": r.hard, "summary": r.summary,
                                "repair_examples": Array(r.repair_examples.prefix(3))])
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
                    DispatchQueue.main.async { result(String(data: data, encoding: .utf8) ?? "[]") }
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
        lock.lock(); let sink = self.sink; lock.unlock()
        guard let sink else {
            NSLog("scribe: %d segment(s) had nowhere to go", segs.count)
            return
        }
        guard let data = try? JSONEncoder().encode(["segments": segs]),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { sink(json) }
    }

    func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        lock.lock(); sink = events; lock.unlock(); return nil
    }

    func onCancel(withArguments _: Any?) -> FlutterError? {
        lock.lock(); sink = nil; lock.unlock(); return nil
    }
}
