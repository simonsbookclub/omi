import SwiftUI

struct WatchRecorderView<Recorder: WatchRecorderControlling>: View {
    @ObservedObject var viewModel: Recorder
    @StateObject private var presentationController = RecordingPresentationController()
    @State private var isPressed = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background
                Color.black
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer()
                    
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isPressed = true
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation(.easeInOut(duration: 0.1)) {
                                isPressed = false
                            }
                        }
                        
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    }) {
                        ZStack {
                            if presentationController.phase.showsRecordingRipple {
                                RecordingRippleView()
                            }
                            
                            // Main button circle (white background)
                            Circle()
                                .fill(Color.white)
                                .frame(width: 80, height: 80)
                                .scaleEffect(isPressed ? 1.05 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: isPressed)
                            
                            Image("OmiLogo")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                                .scaleEffect(isPressed ? 1.05 : 1.0)
                                .animation(.easeInOut(duration: 0.15), value: isPressed)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(
                        viewModel.isRecording
                            ? Text("watch.accessibility.stopRecording")
                            : Text("watch.accessibility.startRecording")
                    )
                    
                    Spacer()
                    
                    Group {
                        if viewModel.isRecording, let startedAt = viewModel.recordingStartedAt {
                            if presentationController.phase.showsRecordingRipple {
                                Text("Listening")
                                    .font(.system(size: 16, weight: .medium))
                                    .accessibilityLabel(Text("watch.accessibility.recordingInProgress"))
                            } else {
                                Text(startedAt, style: .timer)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .monospacedDigit()
                                    .accessibilityLabel(Text("watch.accessibility.elapsedRecordingTime"))
                                    .accessibilityValue(Text(startedAt, style: .timer))
                            }
                        } else {
                            Text("Tap to Record")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .foregroundColor(.white)

                    Spacer()
                        .frame(height: 20)
                }
            }
        }
        .task(id: viewModel.recordingStartedAt) {
            await presentationController.update(
                isRecording: viewModel.isRecording,
                startedAt: viewModel.recordingStartedAt
            )
        }
    }
}

private struct RecordingRippleView: View {
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0.8

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 2)
                    .frame(width: 100, height: 100)
                    .scaleEffect(rippleScale)
                    .opacity(rippleOpacity)
                    .animation(
                        .easeOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.3),
                        value: rippleScale
                    )
            }
        }
        .onAppear {
            rippleScale = 2.5
            rippleOpacity = 0
        }
    }
}

#if canImport(WatchConnectivity)
    #Preview {
        WatchRecorderView(viewModel: WatchAudioRecorderViewModel())
    }
#endif

// MARK: - Live heart rate
//
// Why this exists: nothing in the chain streams. The watch batches heart rate
// into HealthKit every few minutes, HealthKit hands it to the phone in its own
// time, and Oura's cloud was two hours behind even after its app was opened
// (measured 2026-09-10). The one exception is a WORKOUT: while a session runs,
// watchOS samples heart rate about once a second and hands each one straight
// to us.
//
// So this starts a workout session purely to keep the sensor awake, and
// forwards every reading to the phone, which posts it to the server. It is the
// only way to get a live number on the desk, and it costs watch battery — so
// it is a switch the wearer turns on, never something left running.

import HealthKit
import WatchConnectivity

@MainActor
final class LiveHeartRate: NSObject, ObservableObject {
    @Published private(set) var isLive = false
    @Published private(set) var bpm: Int?
    @Published private(set) var problem: String?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let hr = HKQuantityType.quantityType(forIdentifier: .heartRate) { types.insert(hr) }
        return types
    }

    func toggle() { isLive ? stop() : start() }

    func start() {
        guard HKHealthStore.isHealthDataAvailable() else {
            problem = "No HealthKit on this watch"
            return
        }
        // A workout needs share access even though we only read from it.
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: readTypes) { [weak self] ok, error in
            Task { @MainActor in
                guard ok else {
                    self?.problem = error?.localizedDescription ?? "Health access refused"
                    return
                }
                self?.begin()
            }
        }
    }

    private func begin() {
        let config = HKWorkoutConfiguration()
        // "Other" and indoor: this is not exercise, it is a sensor session, and
        // labelling it as a run would put a false workout in Health.
        config.activityType = .other
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            b.delegate = self
            s.delegate = self
            session = s
            builder = b
            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { [weak self] ok, error in
                Task { @MainActor in
                    if !ok { self?.problem = error?.localizedDescription ?? "Could not start collecting" }
                }
            }
            isLive = true
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func stop() {
        isLive = false
        let end = Date()
        session?.end()
        builder?.endCollection(withEnd: end) { [weak self] _, _ in
            // Discard rather than save: this was never a workout, and saving it
            // would put a phantom session in the wearer's Health history.
            self?.builder?.discardWorkout()
            Task { @MainActor in
                self?.session = nil
                self?.builder = nil
            }
        }
    }

    fileprivate func publish(_ value: Double, at date: Date) {
        bpm = Int(value.rounded())
        guard WCSession.isSupported() else { return }
        let payload: [String: Any] = [
            "type": "live_heart_rate",
            "bpm": value,
            "at_ms": date.timeIntervalSince1970 * 1000,
        ]
        let wc = WCSession.default
        if wc.isReachable {
            wc.sendMessage(payload, replyHandler: nil, errorHandler: { _ in
                wc.transferUserInfo(payload)
            })
        } else {
            // The phone is asleep or away; queued delivery still gets there.
            wc.transferUserInfo(payload)
        }
    }
}

extension LiveHeartRate: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended {
            Task { @MainActor in self.isLive = false }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.problem = error.localizedDescription
            self.isLive = false
        }
    }
}

extension LiveHeartRate: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let at = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        Task { @MainActor in self.publish(bpm, at: at) }
    }
}

/// The control the wearer actually taps.
struct LiveHeartRateView: View {
    @StateObject private var live = LiveHeartRate()

    var body: some View {
        VStack(spacing: 8) {
            Text(live.bpm.map { "\($0)" } ?? "—")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(live.isLive ? Color.green : Color.white)
            Text(live.isLive ? "streaming to your desk" : "heart rate, live")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let problem = live.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button(live.isLive ? "Stop" : "Start") { live.toggle() }
                .tint(live.isLive ? .red : .green)
        }
        .padding()
    }
}
