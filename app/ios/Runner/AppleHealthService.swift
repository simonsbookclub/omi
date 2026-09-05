import Foundation
import HealthKit
import Flutter

class AppleHealthService {
    private let healthStore = HKHealthStore()

    // Health data types we want to read
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()

        // Activity
        if let stepCount = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            types.insert(stepCount)
        }
        if let activeEnergy = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(activeEnergy)
        }
        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distance)
        }

        // Heart
        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let restingHeartRate = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            types.insert(restingHeartRate)
        }
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            types.insert(hrv)
        }
        if let walkingHR = HKQuantityType.quantityType(forIdentifier: .walkingHeartRateAverage) {
            types.insert(walkingHR)
        }
        if let respiratoryRate = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            types.insert(respiratoryRate)
        }
        if let oxygenSaturation = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            types.insert(oxygenSaturation)
        }
        if let vo2Max = HKQuantityType.quantityType(forIdentifier: .vo2Max) {
            types.insert(vo2Max)
        }
        if let cyclingDistance = HKQuantityType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(cyclingDistance)
        }

        // Running dynamics (watch records these during runs)
        if #available(iOS 16.0, *) {
            if let runningSpeed = HKQuantityType.quantityType(forIdentifier: .runningSpeed) {
                types.insert(runningSpeed)
            }
            if let runningPower = HKQuantityType.quantityType(forIdentifier: .runningPower) {
                types.insert(runningPower)
            }
            if let strideLength = HKQuantityType.quantityType(forIdentifier: .runningStrideLength) {
                types.insert(strideLength)
            }
        }

        // Sleep
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }

        // SIMONSBOOKCLUB ("Us" body features): daylight the watch measured,
        // exercise minutes as Apple counts them.
        if #available(iOS 17.0, *) {
            if let daylight = HKQuantityType.quantityType(forIdentifier: .timeInDaylight) {
                types.insert(daylight)
            }
        }
        if let exercise = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) {
            types.insert(exercise)
        }

        // Workouts
        types.insert(HKWorkoutType.workoutType())

        return types
    }

    func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(FlutterError(code: "UNAVAILABLE", message: "HealthKit is not available on this device", details: nil))
            return
        }

        switch call.method {
        case "hasPermission":
            hasPermission(result: result)
        case "requestPermission":
            requestPermission(result: result)
        case "probeAccess":
            probeAccess(result: result)
        case "getHealthSummary":
            getHealthSummary(call: call, result: result)
        case "getStepCount":
            getStepCount(call: call, result: result)
        case "getSleepData":
            getSleepData(call: call, result: result)
        case "getHeartRateData":
            getHeartRateData(call: call, result: result)
        case "getActiveEnergy":
            getActiveEnergy(call: call, result: result)
        case "getWorkouts":
            getWorkouts(call: call, result: result)
        case "getSamples":
            getSamples(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func hasPermission(result: @escaping FlutterResult) {
        // Check if we have authorization for at least step count
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            result(false)
            return
        }

        let status = healthStore.authorizationStatus(for: stepType)
        // HealthKit only reveals authorization status for write access
        // For read access, we check if user has at least been asked (not .notDetermined)
        result(status != .notDetermined)
    }

    private func requestPermission(result: @escaping FlutterResult) {
        healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Error requesting HealthKit authorization: \(error.localizedDescription)")
                    result(false)
                    return
                }
                result(success)
            }
        }
    }

    // Apple does not reveal read-authorization status for privacy reasons — requestAuthorization's
    // `success` flag only means the prompt was shown, not that the user allowed it. To detect a
    // denial we probe multiple common data types over the last 90 days; if any returns at least one
    // sample, read access is confirmed.
    private func probeAccess(result: @escaping FlutterResult) {
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -90, to: endDate)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        var probeTypes: [HKSampleType] = []
        if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { probeTypes.append(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .heartRate) { probeTypes.append(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { probeTypes.append(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) { probeTypes.append(t) }
        if let t = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { probeTypes.append(t) }
        probeTypes.append(HKWorkoutType.workoutType())

        var hasAnyData = false
        let group = DispatchGroup()
        let lock = NSLock()

        for sampleType in probeTypes {
            group.enter()
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                if let samples = samples, !samples.isEmpty {
                    lock.lock()
                    hasAnyData = true
                    lock.unlock()
                }
                group.leave()
            }
            healthStore.execute(query)
        }

        group.notify(queue: .main) {
            result(hasAnyData)
        }
    }

    private func getHealthSummary(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let days = args?["days"] as? Int ?? 7

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate)!

        var summary: [String: Any] = [:]
        let group = DispatchGroup()

        // Get steps with daily breakdown
        group.enter()
        fetchDailySteps(startDate: startDate, endDate: endDate) { dailySteps, total in
            summary["totalSteps"] = total
            summary["averageStepsPerDay"] = total / days
            summary["dailySteps"] = dailySteps  // Array of {date, steps}
            group.leave()
        }

        // Get active energy with daily breakdown
        group.enter()
        fetchDailyActiveEnergy(startDate: startDate, endDate: endDate) { dailyEnergy, total in
            summary["totalActiveEnergy"] = total
            summary["averageActiveEnergyPerDay"] = total / Double(days)
            summary["dailyActiveEnergy"] = dailyEnergy  // Array of {date, calories}
            group.leave()
        }

        // Get heart rate
        group.enter()
        fetchHeartRateStats(startDate: startDate, endDate: endDate) { stats in
            summary["heartRate"] = stats
            group.leave()
        }

        // Get sleep with daily breakdown
        group.enter()
        fetchDailySleep(startDate: startDate, endDate: endDate) { dailySleep, totalHours, sessions in
            summary["sleep"] = [
                "totalSleepHours": totalHours,
                "sessionsCount": sessions.count,
                "sessions": sessions,
                "daily": dailySleep  // Array of {date, sleepHours}
            ]
            group.leave()
        }

        // Get workouts count
        group.enter()
        fetchWorkouts(startDate: startDate, endDate: endDate) { workouts in
            summary["workoutsCount"] = workouts?.count ?? 0
            summary["workouts"] = workouts ?? []
            group.leave()
        }

        group.notify(queue: .main) {
            summary["periodDays"] = days
            summary["startDate"] = startDate.timeIntervalSince1970 * 1000
            summary["endDate"] = endDate.timeIntervalSince1970 * 1000
            result(summary)
        }
    }

    private func getStepCount(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let (startDate, endDate) = parseDateRange(call: call)

        fetchStepCount(startDate: startDate, endDate: endDate) { steps in
            DispatchQueue.main.async {
                result(steps)
            }
        }
    }

    private func getSleepData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let (startDate, endDate) = parseDateRange(call: call)

        fetchSleepData(startDate: startDate, endDate: endDate) { sleepData in
            DispatchQueue.main.async {
                result(sleepData)
            }
        }
    }

    private func getHeartRateData(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let (startDate, endDate) = parseDateRange(call: call)

        fetchHeartRateStats(startDate: startDate, endDate: endDate) { stats in
            DispatchQueue.main.async {
                result(stats)
            }
        }
    }

    private func getActiveEnergy(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let (startDate, endDate) = parseDateRange(call: call)

        fetchActiveEnergy(startDate: startDate, endDate: endDate) { energy in
            DispatchQueue.main.async {
                result(energy)
            }
        }
    }

    private func getWorkouts(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let (startDate, endDate) = parseDateRange(call: call)

        fetchWorkouts(startDate: startDate, endDate: endDate) { workouts in
            DispatchQueue.main.async {
                result(workouts)
            }
        }
    }

    // MARK: - Helper Methods

    private func parseDateRange(call: FlutterMethodCall) -> (Date, Date) {
        let args = call.arguments as? [String: Any]
        let endDate: Date
        let startDate: Date

        if let endMs = args?["endDate"] as? Int64 {
            endDate = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0)
        } else {
            endDate = Date()
        }

        if let startMs = args?["startDate"] as? Int64 {
            startDate = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0)
        } else {
            startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate)!
        }

        return (startDate, endDate)
    }

    private func fetchStepCount(startDate: Date, endDate: Date, completion: @escaping (Int?) -> Void) {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            completion(nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKStatisticsQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, statistics, error in
            guard let statistics = statistics, let sum = statistics.sumQuantity() else {
                completion(nil)
                return
            }
            let steps = Int(sum.doubleValue(for: HKUnit.count()))
            completion(steps)
        }

        healthStore.execute(query)
    }

    private func fetchDailySteps(startDate: Date, endDate: Date, completion: @escaping ([[String: Any]], Int) -> Void) {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            completion([], 0)
            return
        }

        let calendar = Calendar.current
        var interval = DateComponents()
        interval.day = 1

        // Anchor to start of day
        let anchorDate = calendar.startOfDay(for: startDate)

        // Add date predicate for the query
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKStatisticsCollectionQuery(
            quantityType: stepType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: anchorDate,
            intervalComponents: interval
        )

        query.initialResultsHandler = { _, results, error in
            guard let statsCollection = results else {
                completion([], 0)
                return
            }

            var dailySteps: [[String: Any]] = []
            var totalSteps = 0

            statsCollection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                let steps = statistics.sumQuantity()?.doubleValue(for: HKUnit.count()) ?? 0
                let stepsInt = Int(steps)
                totalSteps += stepsInt

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let dateString = dateFormatter.string(from: statistics.startDate)

                dailySteps.append([
                    "date": dateString,
                    "dateMs": statistics.startDate.timeIntervalSince1970 * 1000,
                    "steps": stepsInt
                ])
            }

            completion(dailySteps, totalSteps)
        }

        healthStore.execute(query)
    }

    private func fetchDailyActiveEnergy(startDate: Date, endDate: Date, completion: @escaping ([[String: Any]], Double) -> Void) {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            completion([], 0)
            return
        }

        let calendar = Calendar.current
        var interval = DateComponents()
        interval.day = 1

        let anchorDate = calendar.startOfDay(for: startDate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKStatisticsCollectionQuery(
            quantityType: energyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: anchorDate,
            intervalComponents: interval
        )

        query.initialResultsHandler = { _, results, error in
            guard let statsCollection = results else {
                completion([], 0)
                return
            }

            var dailyEnergy: [[String: Any]] = []
            var totalEnergy: Double = 0

            statsCollection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                let energy = statistics.sumQuantity()?.doubleValue(for: HKUnit.kilocalorie()) ?? 0
                totalEnergy += energy

                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"
                let dateString = dateFormatter.string(from: statistics.startDate)

                dailyEnergy.append([
                    "date": dateString,
                    "dateMs": statistics.startDate.timeIntervalSince1970 * 1000,
                    "calories": energy
                ])
            }

            completion(dailyEnergy, totalEnergy)
        }

        healthStore.execute(query)
    }

    private func fetchDailySleep(startDate: Date, endDate: Date, completion: @escaping ([[String: Any]], Double, [[String: Any]]) -> Void) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion([], 0, [])
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            guard let samples = samples as? [HKCategorySample] else {
                completion([], 0, [])
                return
            }

            let calendar = Calendar.current
            var dailySleepMap: [String: Double] = [:]
            var totalSleepSeconds: Double = 0
            var sleepSessions: [[String: Any]] = []
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            for sample in samples {
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                var isSleep = false

                if #available(iOS 16.0, *) {
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                         HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                         HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                         HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        isSleep = true
                    default:
                        break
                    }
                } else {
                    if sample.value == HKCategoryValueSleepAnalysis.asleep.rawValue {
                        isSleep = true
                    }
                }

                if isSleep {
                    totalSleepSeconds += duration
                    // Aggregate by the date the sleep ended (woke up)
                    let dateString = dateFormatter.string(from: sample.endDate)
                    dailySleepMap[dateString, default: 0] += duration
                }

                sleepSessions.append([
                    "startDate": sample.startDate.timeIntervalSince1970 * 1000,
                    "endDate": sample.endDate.timeIntervalSince1970 * 1000,
                    "durationMinutes": duration / 60.0,
                    "type": self.sleepTypeString(sample.value)
                ])
            }

            // Convert daily map to array
            var dailySleep: [[String: Any]] = []
            for (date, seconds) in dailySleepMap {
                dailySleep.append([
                    "date": date,
                    "sleepHours": seconds / 3600.0
                ])
            }
            // Sort by date descending
            dailySleep.sort { ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }

            completion(dailySleep, totalSleepSeconds / 3600.0, sleepSessions)
        }

        healthStore.execute(query)
    }

    private func fetchActiveEnergy(startDate: Date, endDate: Date, completion: @escaping (Double?) -> Void) {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            completion(nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKStatisticsQuery(
            quantityType: energyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, statistics, error in
            guard let statistics = statistics, let sum = statistics.sumQuantity() else {
                completion(nil)
                return
            }
            let energy = sum.doubleValue(for: HKUnit.kilocalorie())
            completion(energy)
        }

        healthStore.execute(query)
    }

    private func fetchHeartRateStats(startDate: Date, endDate: Date, completion: @escaping ([String: Any]?) -> Void) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            completion(nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        let query = HKStatisticsQuery(
            quantityType: heartRateType,
            quantitySamplePredicate: predicate,
            options: [.discreteAverage, .discreteMin, .discreteMax]
        ) { _, statistics, error in
            guard let statistics = statistics else {
                completion(nil)
                return
            }

            let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
            var result: [String: Any] = [:]

            if let avg = statistics.averageQuantity() {
                result["average"] = avg.doubleValue(for: unit)
            }
            if let min = statistics.minimumQuantity() {
                result["minimum"] = min.doubleValue(for: unit)
            }
            if let max = statistics.maximumQuantity() {
                result["maximum"] = max.doubleValue(for: unit)
            }

            completion(result.isEmpty ? nil : result)
        }

        healthStore.execute(query)
    }

    private func fetchSleepData(startDate: Date, endDate: Date, completion: @escaping ([String: Any]?) -> Void) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(nil)
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: sleepType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            guard let samples = samples as? [HKCategorySample] else {
                completion(nil)
                return
            }

            var totalSleepSeconds: Double = 0
            var inBedSeconds: Double = 0
            var sleepSessions: [[String: Any]] = []

            for sample in samples {
                let duration = sample.endDate.timeIntervalSince(sample.startDate)

                if #available(iOS 16.0, *) {
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                         HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                         HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                         HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        totalSleepSeconds += duration
                    case HKCategoryValueSleepAnalysis.inBed.rawValue:
                        inBedSeconds += duration
                    default:
                        break
                    }
                } else {
                    if sample.value == HKCategoryValueSleepAnalysis.asleep.rawValue {
                        totalSleepSeconds += duration
                    } else if sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
                        inBedSeconds += duration
                    }
                }

                sleepSessions.append([
                    "startDate": sample.startDate.timeIntervalSince1970 * 1000,
                    "endDate": sample.endDate.timeIntervalSince1970 * 1000,
                    "durationMinutes": duration / 60.0,
                    "type": self.sleepTypeString(sample.value)
                ])
            }

            let result: [String: Any] = [
                "totalSleepHours": totalSleepSeconds / 3600.0,
                "totalInBedHours": inBedSeconds / 3600.0,
                "sessionsCount": sleepSessions.count,
                "sessions": sleepSessions
            ]

            completion(result)
        }

        healthStore.execute(query)
    }

    private func sleepTypeString(_ value: Int) -> String {
        if #available(iOS 16.0, *) {
            switch value {
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                return "core"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                return "deep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                return "rem"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                return "asleep"
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                return "inBed"
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                return "awake"
            default:
                return "unknown"
            }
        } else {
            switch value {
            case HKCategoryValueSleepAnalysis.asleep.rawValue:
                return "asleep"
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                return "inBed"
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                return "awake"
            default:
                return "unknown"
            }
        }
    }

    private func fetchWorkouts(startDate: Date, endDate: Date, completion: @escaping ([[String: Any]]?) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: HKWorkoutType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            guard let workouts = samples as? [HKWorkout] else {
                completion(nil)
                return
            }

            let result: [[String: Any]] = workouts.map { workout in
                var workoutData: [String: Any] = [
                    "type": self.workoutTypeString(workout.workoutActivityType),
                    "startDate": workout.startDate.timeIntervalSince1970 * 1000,
                    "endDate": workout.endDate.timeIntervalSince1970 * 1000,
                    "durationMinutes": workout.duration / 60.0
                ]

                if let totalEnergy = workout.totalEnergyBurned {
                    workoutData["caloriesBurned"] = totalEnergy.doubleValue(for: HKUnit.kilocalorie())
                }

                if let totalDistance = workout.totalDistance {
                    workoutData["distanceKm"] = totalDistance.doubleValue(for: HKUnit.meterUnit(with: .kilo))
                }

                return workoutData
            }

            completion(result)
        }

        healthStore.execute(query)
    }

    private func workoutTypeString(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Strength Training"
        case .crossTraining: return "Cross Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance: return "Dance"
        case .pilates: return "Pilates"
        case .tennis: return "Tennis"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .golf: return "Golf"
        default: return "Other"
        }
    }

    // MARK: - Granular sample export (simonsbookclub)

    /// Everything HealthKit will give us as timestamped samples, for
    /// correlating body state with speech. Raw samples for the sparse
    /// series (heart rate, HRV, resting HR, respiratory rate, SpO2,
    /// VO2max); hourly sums for the dense cumulative ones (steps, active
    /// energy) where raw samples double-count across watch and phone;
    /// sleep as one row per stage interval; workouts as one row each.
    private func getSamples(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        let sinceMs = args?["sinceMs"] as? Double ?? Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970 * 1000
        let startDate = Date(timeIntervalSince1970: sinceMs / 1000)
        let endDate = Date()
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        // Descending: when a series overflows the cap, keep the NEWEST
        // samples. Ascending silently dropped the most recent week of heart
        // rate on the first 30-day backfill (2026-08-19). Order is
        // irrelevant to the server (idempotent keyed inserts).
        let sortByDate = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let perTypeLimit = 40000

        var samples: [[String: Any]] = []
        let lock = NSLock()
        let group = DispatchGroup()

        func appendRows(_ rows: [[String: Any]]) {
            lock.lock()
            samples.append(contentsOf: rows)
            lock.unlock()
        }

        // Sparse quantity series: every sample, timestamped.
        var quantitySeries: [(HKQuantityTypeIdentifier, String, HKUnit, String)] = [
            (.heartRate, "heart_rate", HKUnit.count().unitDivided(by: .minute()), "bpm"),
            (.restingHeartRate, "resting_heart_rate", HKUnit.count().unitDivided(by: .minute()), "bpm"),
            (.walkingHeartRateAverage, "walking_heart_rate", HKUnit.count().unitDivided(by: .minute()), "bpm"),
            (.heartRateVariabilitySDNN, "hrv_sdnn", HKUnit.secondUnit(with: .milli), "ms"),
            (.respiratoryRate, "respiratory_rate", HKUnit.count().unitDivided(by: .minute()), "breaths/min"),
            (.oxygenSaturation, "oxygen_saturation", HKUnit.percent(), "%"),
            // NB: the unit string needs the parentheses — "ml/kg*min" parses
            // as (ml/kg)·min, which is INCOMPATIBLE with VO2max samples and
            // makes doubleValue(for:) throw an uncatchable NSException the
            // moment a real sample exists (crashed the app on cold start the
            // first time VO2max became readable, 2026-08-19).
            (.vo2Max, "vo2_max", HKUnit(from: "ml/(kg*min)"), "ml/kg/min"),
        ]
        if #available(iOS 16.0, *) {
            quantitySeries.append((.runningSpeed, "running_speed", HKUnit.meter().unitDivided(by: .second()), "m/s"))
            quantitySeries.append((.runningPower, "running_power", HKUnit.watt(), "W"))
            quantitySeries.append((.runningStrideLength, "running_stride_length", HKUnit.meter(), "m"))
        }
        for (identifier, name, unit, unitLabel) in quantitySeries {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            group.enter()
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: perTypeLimit, sortDescriptors: [sortByDate]) { _, results, _ in
                let rows: [[String: Any]] = (results as? [HKQuantitySample] ?? []).compactMap { s in
                    // doubleValue(for:) throws an uncatchable NSException on
                    // a unit mismatch — guard instead of crash.
                    guard s.quantity.is(compatibleWith: unit) else { return nil }
                    var value = s.quantity.doubleValue(for: unit)
                    if identifier == .oxygenSaturation { value *= 100 }
                    return [
                        "type": name,
                        "start_ms": s.startDate.timeIntervalSince1970 * 1000,
                        "end_ms": s.endDate.timeIntervalSince1970 * 1000,
                        "value": value,
                        "unit": unitLabel,
                    ]
                }
                appendRows(rows)
                group.leave()
            }
            healthStore.execute(query)
        }

        // Dense cumulative series: hourly sums.
        var hourlySeries: [(HKQuantityTypeIdentifier, String, HKUnit, String)] = [
            (.stepCount, "steps_hourly", HKUnit.count(), "steps"),
            (.activeEnergyBurned, "active_energy_hourly", HKUnit.kilocalorie(), "kcal"),
            (.distanceWalkingRunning, "distance_hourly", HKUnit.meterUnit(with: .kilo), "km"),
            (.appleExerciseTime, "exercise_hourly", HKUnit.minute(), "min"),
        ]
        if #available(iOS 17.0, *) {
            // Time in Daylight — the watch's ambient light sensor, minutes per hour.
            hourlySeries.append((.timeInDaylight, "daylight_hourly", HKUnit.minute(), "min"))
        }
        var hourly = DateComponents()
        hourly.hour = 1
        for (identifier, name, unit, unitLabel) in hourlySeries {
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { continue }
            group.enter()
            let anchor = Calendar.current.startOfDay(for: startDate)
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchor,
                intervalComponents: hourly
            )
            query.initialResultsHandler = { _, collection, _ in
                var rows: [[String: Any]] = []
                collection?.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    guard let sum = stats.sumQuantity() else { return }
                    rows.append([
                        "type": name,
                        "start_ms": stats.startDate.timeIntervalSince1970 * 1000,
                        "end_ms": stats.endDate.timeIntervalSince1970 * 1000,
                        "value": sum.doubleValue(for: unit),
                        "unit": unitLabel,
                    ])
                }
                appendRows(rows)
                group.leave()
            }
            healthStore.execute(query)
        }

        // Sleep stages: one row per stage interval, value = minutes.
        if let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) {
            group.enter()
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: perTypeLimit, sortDescriptors: [sortByDate]) { _, results, _ in
                let rows: [[String: Any]] = (results as? [HKCategorySample] ?? []).compactMap { s in
                    let stage: String
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .inBed: stage = "in_bed"
                    case .awake: stage = "awake"
                    case .asleepCore: stage = "core"
                    case .asleepDeep: stage = "deep"
                    case .asleepREM: stage = "rem"
                    case .asleepUnspecified: stage = "asleep"
                    default: return nil
                    }
                    return [
                        "type": "sleep_stage",
                        "start_ms": s.startDate.timeIntervalSince1970 * 1000,
                        "end_ms": s.endDate.timeIntervalSince1970 * 1000,
                        "value": s.endDate.timeIntervalSince(s.startDate) / 60,
                        "unit": "min",
                        "meta": stage,
                    ]
                }
                appendRows(rows)
                group.leave()
            }
            healthStore.execute(query)
        }

        // Workouts: one row each, value = duration minutes, meta = JSON with
        // activity, kcal, km, average pace — and for distance sports, per-km
        // splits computed from the workout's own distance samples (this is
        // the same data the Fitness app shows for a run).
        group.enter()
        let workoutQuery = HKSampleQuery(sampleType: HKWorkoutType.workoutType(), predicate: predicate, limit: perTypeLimit, sortDescriptors: [sortByDate]) { _, results, _ in
            let workouts = results as? [HKWorkout] ?? []
            let inner = DispatchGroup()
            var rows: [[String: Any]] = []
            let rowsLock = NSLock()

            func finishRow(_ w: HKWorkout, _ metaDict: [String: Any]) {
                let metaJson = (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let row: [String: Any] = [
                    "type": "workout",
                    "start_ms": w.startDate.timeIntervalSince1970 * 1000,
                    "end_ms": w.endDate.timeIntervalSince1970 * 1000,
                    "value": w.duration / 60,
                    "unit": "min",
                    "meta": metaJson,
                ]
                rowsLock.lock()
                rows.append(row)
                rowsLock.unlock()
            }

            for w in workouts {
                var metaDict: [String: Any] = ["activity": self.workoutTypeString(w.workoutActivityType)]
                if let energy = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                    metaDict["kcal"] = Int(energy.rounded())
                }
                // Indoor/outdoor and the workout's own heart-rate statistics
                // (exertion is judged against the person's ceiling server-side).
                if let indoor = w.metadata?[HKMetadataKeyIndoorWorkout] as? Bool {
                    metaDict["indoor"] = indoor
                }
                if #available(iOS 16.0, *), let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                    let bpm = HKUnit.count().unitDivided(by: .minute())
                    if let stats = w.statistics(for: hrType) {
                        if let avg = stats.averageQuantity()?.doubleValue(for: bpm) { metaDict["avg_hr"] = Int(avg.rounded()) }
                        if let mx = stats.maximumQuantity()?.doubleValue(for: bpm) { metaDict["max_hr"] = Int(mx.rounded()) }
                    }
                }
                let km = w.totalDistance?.doubleValue(for: .meterUnit(with: .kilo))
                if let km = km, km > 0 {
                    metaDict["km"] = (km * 100).rounded() / 100
                    metaDict["avg_pace_s_per_km"] = Int((w.duration / km).rounded())
                }

                let distanceIdentifier: HKQuantityTypeIdentifier? = {
                    switch w.workoutActivityType {
                    case .running, .walking, .hiking: return .distanceWalkingRunning
                    case .cycling: return .distanceCycling
                    default: return nil
                    }
                }()

                guard let identifier = distanceIdentifier, km ?? 0 >= 1,
                      let distType = HKQuantityType.quantityType(forIdentifier: identifier) else {
                    finishRow(w, metaDict)
                    continue
                }

                // Walk the workout's distance samples, stamping elapsed time
                // at each cumulative kilometer boundary.
                inner.enter()
                // Splits need chronological order — the shared descriptor is
                // descending (cap policy), which would corrupt the cumulative
                // distance walk.
                let splitQuery = HKSampleQuery(
                    sampleType: distType,
                    predicate: HKQuery.predicateForObjects(from: w),
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
                ) { _, dResults, _ in
                    var splits: [Int] = []
                    var cumulativeMeters = 0.0
                    var nextBoundary = 1000.0
                    var lastBoundaryTime = w.startDate
                    for s in (dResults as? [HKQuantitySample] ?? []) {
                        cumulativeMeters += s.quantity.doubleValue(for: .meter())
                        while cumulativeMeters >= nextBoundary {
                            splits.append(Int(s.endDate.timeIntervalSince(lastBoundaryTime).rounded()))
                            lastBoundaryTime = s.endDate
                            nextBoundary += 1000
                        }
                    }
                    if !splits.isEmpty {
                        metaDict["splits_s_per_km"] = splits
                    }
                    finishRow(w, metaDict)
                    inner.leave()
                }
                self.healthStore.execute(splitQuery)
            }

            inner.notify(queue: .global()) {
                appendRows(rows)
                group.leave()
            }
        }
        healthStore.execute(workoutQuery)

        group.notify(queue: .main) {
            result(samples)
        }
    }
}
