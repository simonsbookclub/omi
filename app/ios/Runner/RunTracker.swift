import CoreLocation
import CoreMotion
import Flutter
import UIKit

// MARK: - The run in progress — SIMONSBOOKCLUB stats page "running" mode

/// The phone's own GPS during a run. The watch's workout arrives with its
/// route only when the run ends, and its distance samples come in lumps of
/// up to twelve minutes, so the live picture has to come from here.
///
/// Core Motion says when a run starts (running, not low confidence, for
/// 45 s) and when it stops (four minutes of anything else). In between,
/// CoreLocation gives a point every few metres and the points go to the
/// worker in thirty-second batches; the last batch says `ended`. State
/// lives in memory: a run interrupted by a relaunch simply starts a new id.
final class RunTracker: NSObject, CLLocationManagerDelegate {
    static let shared = RunTracker()

    private let location = CLLocationManager()
    private let motion = CMMotionActivityManager()
    private let defaults = UserDefaults.standard
    private let endpointKey = "chronicle.run.endpoint" // …/omi/
    private let authKey = "chronicle.run.auth"         // bearer, without "Bearer "
    private var channel: FlutterMethodChannel?

    private var runId: String?
    private var startedAt: Date?
    private var pending: [[String: Any]] = []
    private var sent = 0
    private var flushTimer: Timer?
    private var watchTimer: Timer?
    private var runningSince: Date?
    private var notRunningSince: Date?
    private var lastActivityRunning = false
    private var lastFlushOk: Date?
    private var lastError: String?

    private var reportedMotion = false

    private static let startAfter: TimeInterval = 45
    private static let endAfter: TimeInterval = 240
    private static let flushEvery: TimeInterval = 30

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.distanceFilter = 8
        location.activityType = .fitness
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true
        if #available(iOS 11.0, *) { location.showsBackgroundLocationIndicator = true }
    }

    func attach(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.simonsbookclub.run", binaryMessenger: messenger)
        channel?.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { return }
            switch call.method {
            case "configure":
                let args = call.arguments as? [String: Any]
                if let endpoint = args?["endpoint"] as? String { self.defaults.set(endpoint, forKey: self.endpointKey) }
                if let auth = args?["auth"] as? String { self.defaults.set(auth, forKey: self.authKey) }
                self.start()
                result(self.statusDict())
            case "status":
                result(self.statusDict())
            case "stop":
                self.endRun()
                result(self.statusDict())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Where to send points: the tracker's own keys from Dart's configure,
    /// or the health sync's, which the same worker and bearer serve. So the
    /// tracker runs from launch even before Dart gets round to it.
    private func config() -> (base: String, token: String)? {
        let own = { (k: String) -> String? in let v = self.defaults.string(forKey: k); return (v ?? "").isEmpty ? nil : v }
        guard let base = own(endpointKey) ?? own("healthSyncBaseUrl"),
              let token = own(authKey) ?? own("healthSyncToken") else { return nil }
        return (base, token)
    }

    /// Called from the app delegate at launch: the tracker should not wait
    /// for Dart, and a reinstall must not silently leave it off (2026-09-14).
    func startIfConfigured() {
        if config() != nil { start() }
    }

    /// The tracker's state as a beacon on the server. A release build has no
    /// other way to show whether the phone was ever asked for motion and
    /// location, or why a run went untracked.
    private func report(_ event: String) {
        guard let c = config(), let url = URL(string: c.base + "v1/integrations/apple-health/sync") else { return }
        var body = statusDict()
        body["beacon"] = "run_tracker"
        body["event"] = event
        body["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request).resume()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        report("location_authorization")
    }

    /// Ask for what is missing (Always, so a run can start from a pocket)
    /// and begin listening to Core Motion. Idempotent.
    func start() {
        if location.authorizationStatus == .notDetermined || location.authorizationStatus == .authorizedWhenInUse {
            location.requestAlwaysAuthorization()
        }
        guard CMMotionActivityManager.isActivityAvailable() else { lastError = "motion unavailable"; return }
        motion.stopActivityUpdates()
        motion.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self = self, let a = activity else { return }
            self.lastActivityRunning = a.running && a.confidence != .low
            if !self.reportedMotion { self.reportedMotion = true; self.report("motion_first_update") }
            self.tick()
        }
        // Core Motion only reports changes; the clock does the counting.
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        report("start")
    }

    private func tick() {
        let now = Date()
        if lastActivityRunning {
            if runningSince == nil { runningSince = now }
            notRunningSince = nil
            if runId == nil, let since = runningSince, now.timeIntervalSince(since) >= Self.startAfter { beginRun() }
        } else if runId != nil {
            if notRunningSince == nil { notRunningSince = now }
            if let since = notRunningSince, now.timeIntervalSince(since) >= Self.endAfter { endRun() }
        } else {
            runningSince = nil
        }
    }

    private func beginRun() {
        guard location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse else {
            lastError = "location not authorized"; report("run_blocked"); return
        }
        runId = "run_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        startedAt = Date()
        pending = []
        sent = 0
        location.startUpdatingLocation()
        flushTimer?.invalidate()
        flushTimer = Timer.scheduledTimer(withTimeInterval: Self.flushEvery, repeats: true) { [weak self] _ in self?.flush(ended: false) }
        report("run_begin")
    }

    private func endRun() {
        guard runId != nil else { return }
        location.stopUpdatingLocation()
        flushTimer?.invalidate(); flushTimer = nil
        flush(ended: true)
        report("run_end")
        runId = nil; startedAt = nil
        runningSince = nil; notRunningSince = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard runId != nil else { return }
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= 50 {
            pending.append([
                "t": Int(loc.timestamp.timeIntervalSince1970 * 1000),
                "lat": loc.coordinate.latitude,
                "lng": loc.coordinate.longitude,
                "acc": Int(loc.horizontalAccuracy.rounded()),
            ])
        }
        if pending.count > 600 { pending.removeFirst(pending.count - 600) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }

    private func flush(ended: Bool) {
        guard let id = runId, let c = config(), let url = URL(string: c.base + "v1/run/live") else { return }
        let token = c.token
        if pending.isEmpty && !ended { return }
        let batch = pending
        let iso = ISO8601DateFormatter()
        let body: [String: Any] = [
            "id": id,
            "started_at": iso.string(from: startedAt ?? Date()),
            "points": batch,
            "ended": ended,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 20
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
                guard let self = self else { return }
                if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self.pending.removeFirst(min(batch.count, self.pending.count))
                    self.sent += batch.count
                    self.lastFlushOk = Date()
                } else {
                    self.lastError = error?.localizedDescription ?? "http \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                }
            }
        }.resume()
    }

    private func statusDict() -> [String: Any] {
        let auth: String = {
            switch location.authorizationStatus {
            case .authorizedAlways: return "always"
            case .authorizedWhenInUse: return "whenInUse"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "notDetermined"
            }
        }()
        let motionAuth: String = {
            switch CMMotionActivityManager.authorizationStatus() {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            default: return "notDetermined"
            }
        }()
        return [
            "location": auth,
            "motion": motionAuth,
            "running": runId != nil,
            "run_id": runId ?? "",
            "pending": pending.count,
            "sent": sent,
            "last_error": lastError ?? "",
        ]
    }
}
