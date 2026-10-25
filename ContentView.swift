//
//  ContentView.swift
//  Real Hydrasense
//
//  Created by user292307 on 2/12/26.
//

import SwiftUI
import HealthKit
import Charts
import Combine
import os
import UIKit

private let diagLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HydraSense", category: "Background")

// #region agent log
private enum DebugSessionLog {
    private static let sessionId = "de2ca0"
    private static let ingestPath = "/ingest/e8f73ec8-72a5-4958-8f0e-5cc5ce2d9a8b"
    static var onTrace: ((String) -> Void)?

    static func log(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "runId": runId
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let host = ProcessInfo.processInfo.environment["DEBUG_INGEST_HOST"] ?? "127.0.0.1"
        guard let url = URL(string: "http://\(host):7912\(ingestPath)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionId, forHTTPHeaderField: "X-Debug-Session-Id")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()

        if let line = String(data: body, encoding: .utf8) {
            print("🔬DBG", line)
            appendToLocalFile(line)
        }

        let dataSummary = data.isEmpty ? "" : " \(data)"
        let trace = "[\(hypothesisId)] \(message)\(dataSummary)"
        DispatchQueue.main.async {
            onTrace?(trace)
        }
    }

    private static func appendToLocalFile(_ line: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("debug-de2ca0.log")
        let payload = line + "\n"
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(payload.utf8))
            try? handle.close()
        } else {
            try? payload.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
// #endregion

class HealthKitManager: NSObject, ObservableObject {

    private var hrUpdateQuery: HKAnchoredObjectQuery?
    private var hrAnchor: HKQueryAnchor?
    let healthStore = HKHealthStore()

    override init() {
        super.init()

        healthStore.workoutSessionMirroringStartHandler = { [weak self] session in
            self?.handleMirroredWorkoutSession(session)
        }
    }
    private var mirroredWorkoutSession: HKWorkoutSession?
    private var liveWatchHRHandler: ((Double, Date) -> Void)?
    private(set) var isLiveWatchWorkoutRunning = false


    private var lastKnownHRV: (value: Double, date: Date)?
    private var lastKnownRHR: (value: Double, date: Date)?
    private let staleWindow: TimeInterval = 60 * 60

    // MARK: - Observer Query for Live Updates
    private var hrObserverQuery: HKObserverQuery?

    /// Starts a live observer for heart rate. Calls `onChange` when new data arrives.
    func startHeartRateObserver(onChange: @escaping () -> Void) {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        stopHeartRateObserver()

        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] success, error in
            guard let self = self else { return }
            // #region agent log
            DebugSessionLog.log(
                hypothesisId: "F",
                location: "HealthKitManager.startHeartRateObserver:bgDelivery",
                message: "enableBackgroundDelivery finished",
                data: [
                    "success": success,
                    "error": error?.localizedDescription ?? "none"
                ]
            )
            // #endregion
            if let error = error {
                print("Observer BG delivery error:", error)
            } else {
                print("Observer BG delivery enabled:", success)
            }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if let error = error {
                    // #region agent log
                    DebugSessionLog.log(
                        hypothesisId: "A",
                        location: "HealthKitManager.observerCallback",
                        message: "observer error",
                        data: ["error": error.localizedDescription]
                    )
                    // #endregion
                    print("Observer query error: \(error.localizedDescription)")
                    completionHandler()
                    return
                }
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "A",
                    location: "HealthKitManager.observerCallback",
                    message: "HK Observer fired"
                )
                // #endregion
                print("HK Observer fired — heart rate updated")
                completionHandler()
                DispatchQueue.main.async {
                    onChange()
                }
            }
            self.hrObserverQuery = query
            self.healthStore.execute(query)
            // #region agent log
            DebugSessionLog.log(
                hypothesisId: "A",
                location: "HealthKitManager.startHeartRateObserver",
                message: "observer executed after bg delivery"
            )
            // #endregion
            print("HK Observer query executing (after bg delivery)")
        }
    }
    
    /// Stops the heart rate observer query if running.
    func stopHeartRateObserver() {
        if let query = hrObserverQuery {
            healthStore.stop(query)
            hrObserverQuery = nil
        }
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        if HKHealthStore.isHealthDataAvailable() {
            let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
            let restingHeartRateType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
            let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
            let respRateType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
            let stepCountType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
            let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
            let bodyMassType = HKQuantityType.quantityType(forIdentifier: .bodyMass)!

            let typesToRead: Set<HKObjectType> = [
                heartRateType,
                restingHeartRateType,
                hrvType,
                respRateType,
                stepCountType,
                activeEnergyType,
                bodyMassType
            ]

            healthStore.requestAuthorization(toShare: nil, read: typesToRead) { success, error in
                DispatchQueue.main.async {
                    print("HealthKit authorization completed. success=", success, "error=", String(describing: error))
                    completion(success)
                }
            }
        } else {
            DispatchQueue.main.async { completion(false) }
        }
    }

    func startLiveWatchHeartRate(
        onNew: @escaping (Double, Date) -> Void
    ) {
        liveWatchHRHandler = onNew

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        print("Starting Apple Watch live workout...")

        healthStore.startWatchApp(with: configuration) { success, error in
            if let error = error {
                print("❌ Could not launch Watch workout:", error.localizedDescription)
                return
            }

            print("⌚ Watch workout app launched:", success)
        }
    }
    private func handleMirroredWorkoutSession(_ session: HKWorkoutSession) {
        print("📡 Received mirrored Watch workout session")

        mirroredWorkoutSession = session
        session.delegate = self
        isLiveWatchWorkoutRunning = true

        print("✅ Mirrored Watch session connected")
    }
    func fetchLatestHeartRate(completion: @escaping (Double?) -> Void) {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            let heartRate = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            completion(heartRate)
        }
        healthStore.execute(query)
    }

    func fetchLatestHeartRateWithDate(completion: @escaping (Double?, Date?) -> Void) {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let startWindow = Date().addingTimeInterval(-30 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: startWindow, end: Date(), options: .strictEndDate)

        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil, nil)
                return
            }
            let heartRate = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            completion(heartRate, sample.endDate)
        }
        healthStore.execute(query)
    }

    func fetchMostRecentHeartRateWithDate(completion: @escaping (Double?, Date?) -> Void) {
        fetchMostRecentHeartRateDetail { hr, date, _ in
            completion(hr, date)
        }
    }

    func fetchMostRecentHeartRateDetail(
        completion: @escaping (Double?, Date?, String?) -> Void
    ) {
        let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil, nil, nil)
                return
            }
            let heartRate = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            let source = sample.sourceRevision.source.name
            completion(heartRate, sample.endDate, source)
        }
        healthStore.execute(query)
    }

    func fetchLatestHRV(completion: @escaping (Double?) -> Void) {
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: hrvType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            let hrvSeconds = sample.quantity.doubleValue(for: HKUnit.second())
            let hrvMilliseconds = hrvSeconds * 1000.0
            self.lastKnownHRV = (hrvMilliseconds, sample.endDate)
            completion(hrvMilliseconds)
        }
        healthStore.execute(query)
    }

    func fetchLatestRestingHeartRate(completion: @escaping (Double?) -> Void) {
        let restingHRType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let query = HKSampleQuery(
            sampleType: restingHRType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else {
                completion(nil)
                return
            }
            let restingHR = sample.quantity.doubleValue(for: HKUnit(from: "count/min"))
            self.lastKnownRHR = (restingHR, sample.endDate)
            completion(restingHR)
        }
        healthStore.execute(query)
    }

    func fetchLatestVitals(completion: @escaping (VitalSample?) -> Void) {
        diagLog.log("FETCH LATEST VITALS: begin")

        fetchLatestHeartRateWithDate { hr, hrDate in
            guard let hr = hr, let hrDate = hrDate else {
                diagLog.log("FETCH LATEST VITALS: missing HR or date")
                completion(nil)
                return
            }

            self.fetchLatestHRV { hrv in
                guard let hrv = hrv else {
                    diagLog.log("FETCH LATEST VITALS: missing HRV")
                    completion(nil)
                    return
                }

                self.fetchLatestRestingHeartRate { rhr in
                    guard let rhr = rhr else {
                        diagLog.log("FETCH LATEST VITALS: missing RHR")
                        completion(nil)
                        return
                    }

                    diagLog.log("FETCH LATEST VITALS: success ts=\(hrDate, privacy: .public) hr=\(hr, privacy: .public) hrv=\(hrv, privacy: .public) rhr=\(rhr, privacy: .public)")
                    completion(VitalSample(
                        timestamp: hrDate,
                        heartRateBPM: hr,
                        hrvMS: hrv,
                        restingHeartRateBPM: rhr
                    ))
                }
            }
        }
    }

    func fetchLatestVitalsWithActivity(
        lastMinutes: Int = 10,
        completion: @escaping ((VitalSample, ActivityContext)?) -> Void
    ) {
        fetchLatestVitals { sample in
            guard let sample = sample else {
                completion(nil)
                return
            }
            self.fetchActivityContext(lastMinutes: lastMinutes) { ctx in
                completion((sample, ctx))
            }
        }
    }

    func fetchLatestVitalsLenient(completion: @escaping (VitalSample?) -> Void) {
        fetchMostRecentHeartRateWithDate { hr, hrDate in
            guard let hr = hr, let hrDate = hrDate else {
                diagLog.log("LENIENT VITALS: missing HR/date")
                completion(nil)
                return
            }

            diagLog.log("LENIENT VITALS: got HR ts=\(hrDate, privacy: .public) hr=\(hr, privacy: .public)")

            let group = DispatchGroup()
            var hrvFresh: Double?
            var rhrFresh: Double?

            group.enter()
            self.fetchLatestHRV { v in
                hrvFresh = v
                group.leave()
            }

            group.enter()
            self.fetchLatestRestingHeartRate { v in
                rhrFresh = v
                group.leave()
            }

            group.notify(queue: .main) {
                let now = Date()

                let hrvFinal: Double? = hrvFresh ?? {
                    if let c = self.lastKnownHRV, now.timeIntervalSince(c.date) <= self.staleWindow {
                        return c.value
                    }
                    return nil
                }()

                let rhrFinal: Double? = rhrFresh ?? {
                    if let c = self.lastKnownRHR, now.timeIntervalSince(c.date) <= self.staleWindow {
                        return c.value
                    }
                    return nil
                }()

                let hrv = hrvFinal ?? 0
                let rhr = rhrFinal ?? 0
                completion(VitalSample(timestamp: hrDate, heartRateBPM: hr, hrvMS: hrv, restingHeartRateBPM: rhr))
            }
        }
    }

    func fetchActivityContext(lastMinutes: Int, completion: @escaping (ActivityContext) -> Void) {
        let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!

        let end = Date()
        let start = end.addingTimeInterval(-Double(lastMinutes) * 60.0)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        let group = DispatchGroup()
        var stepsSum: Double = 0
        var energySumKcal: Double = 0

        group.enter()
        let stepsQuery = HKStatisticsQuery(
            quantityType: stepsType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, stats, _ in
            if let q = stats?.sumQuantity() {
                stepsSum = q.doubleValue(for: HKUnit.count())
            }
            group.leave()
        }
        healthStore.execute(stepsQuery)

        group.enter()
        let energyQuery = HKStatisticsQuery(
            quantityType: energyType,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum
        ) { _, stats, _ in
            if let q = stats?.sumQuantity() {
                energySumKcal = q.doubleValue(for: HKUnit.kilocalorie())
            }
            group.leave()
        }
        healthStore.execute(energyQuery)

        group.notify(queue: .main) {
            completion(ActivityContext(windowMinutes: lastMinutes, steps: stepsSum, activeEnergyKcal: energySumKcal))
        }
    }

    // MARK: - Continuous HR Stream

    /// Persistent HKAnchoredObjectQuery with no predicate.
    /// The anchor handles deduplication — initial results handler consumes history
    /// to set the anchor, then updateHandler fires for every new sample.
    /// A 30-second timer in ContentView acts as a fallback between Watch sync batches.
    func startContinuousHeartRateUpdates(onNew: @escaping (Double, Date) -> Void) {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        print("Starting continuous HR live updates. Manager instance:", ObjectIdentifier(self))

        stopHeartRateLiveUpdates()

        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { [weak self] success, error in
            guard let self = self else { return }
            let errorCode = error.map { ($0 as NSError).code } ?? -1
            // #region agent log
            DebugSessionLog.log(
                hypothesisId: "F",
                location: "HealthKitManager.startContinuousHR:bgDelivery",
                message: "anchored enableBackgroundDelivery finished",
                data: [
                    "success": success,
                    "error": error?.localizedDescription ?? "none",
                    "errorCode": errorCode
                ]
            )
            // #endregion
            if let error = error {
                print("BG delivery error:", error)
                if errorCode == 4 {
                    print("❗ Missing HealthKit Background Delivery entitlement.")
                }
            } else {
                print("BG delivery enabled:", success)
            }

            let anchored = HKAnchoredObjectQuery(
                type: type,
                predicate: nil,
                anchor: self.hrAnchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, samples, _, newAnchor, error in
                guard let self = self else { return }
                if let error = error {
                    print("Anchored query initial results error:", error)
                    return
                }
                self.hrAnchor = newAnchor
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "C",
                    location: "HealthKitManager.anchoredInitial",
                    message: "anchor set from initial results",
                    data: ["sampleCount": samples?.count ?? 0]
                )
                // #endregion
                if let quantitySamples = samples as? [HKQuantitySample],
                   let newest = quantitySamples.max(by: { $0.endDate < $1.endDate }),
                   Date().timeIntervalSince(newest.endDate) <= 300 {
                    self.handleHRSamples([newest], onNew)
                }
                print("Anchored query initial results consumed. Anchor set.")
            }

            anchored.updateHandler = { [weak self] _, samples, _, newAnchor, error in
                guard let self = self else { return }
                if let error = error {
                    // #region agent log
                    DebugSessionLog.log(
                        hypothesisId: "C",
                        location: "HealthKitManager.anchoredUpdate",
                        message: "anchored update error",
                        data: ["error": error.localizedDescription]
                    )
                    // #endregion
                    print("Anchored query update error:", error)
                    return
                }
                self.hrAnchor = newAnchor
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "C",
                    location: "HealthKitManager.anchoredUpdate",
                    message: "anchored updateHandler fired",
                    data: ["sampleCount": samples?.count ?? 0]
                )
                // #endregion
                self.handleHRSamples(samples, onNew)
            }

            self.hrUpdateQuery = anchored
            self.healthStore.execute(anchored)
            print("Anchored query executing after bg delivery")
        }
    }

    private func handleHRSamples(_ samples: [HKSample]?, _ onNew: (Double, Date) -> Void) {
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
        let newest = samples.max(by: { $0.endDate < $1.endDate })!
        let unit = HKUnit(from: "count/min")
        let hr = newest.quantity.doubleValue(for: unit)
        print("updateHandler fired — HR:", hr, "at", newest.endDate)
        onNew(hr, newest.endDate)
    }

    /// Only call on explicit user Stop action.
    /// hrAnchor is intentionally preserved so the next start resumes correctly.
    func stopHeartRateLiveUpdates() {
        if let q = hrUpdateQuery {
            healthStore.stop(q)
            print("Anchored query stopped.")
        }
        hrUpdateQuery = nil
    }

    // MARK: - Baseline

    func buildBaselineFromLastDays(days: Int, completion: @escaping (HydrationBaseline?, Int) -> Void) {
        let endDate = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) else {
            completion(nil, 0)
            return
        }

        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!

        fetchDailyAverages(type: hrType, unit: HKUnit(from: "count/min"), start: startDate, end: endDate) { hrDaily in
            self.fetchDailyAverages(type: hrvType, unit: HKUnit.second(), start: startDate, end: endDate) { hrvDailySeconds in
                self.fetchDailyAverages(type: rhrType, unit: HKUnit(from: "count/min"), start: startDate, end: endDate) { rhrDaily in

                    var baseline = HydrationBaseline()
                    var daysUsed = 0

                    let hrvDailyMS: [Date: Double] = Dictionary(uniqueKeysWithValues: hrvDailySeconds.map { (day, sec) in
                        (day, sec * 1000.0)
                    })

                    let allDays = Set(hrDaily.keys)
                        .intersection(Set(hrvDailyMS.keys))
                        .intersection(Set(rhrDaily.keys))

                    for day in allDays.sorted() {
                        guard let hr = hrDaily[day],
                              let hrv = hrvDailyMS[day],
                              let rhr = rhrDaily[day] else { continue }

                        let sample = VitalSample(
                            timestamp: day,
                            heartRateBPM: hr,
                            hrvMS: hrv,
                            restingHeartRateBPM: rhr
                        )
                        baseline.add(sample: sample)
                        daysUsed += 1
                    }

                    completion(daysUsed > 0 ? baseline : nil, daysUsed)
                }
            }
        }
    }

    private func fetchDailyAverages(
        type: HKQuantityType,
        unit: HKUnit,
        start: Date,
        end: Date,
        completion: @escaping ([Date: Double]) -> Void
    ) {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let anchor = Calendar.current.startOfDay(for: start)
        var interval = DateComponents()
        interval.day = 1

        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: [.discreteAverage],
            anchorDate: anchor,
            intervalComponents: interval
        )

        query.initialResultsHandler = { _, results, error in
            guard let results = results, error == nil else {
                DispatchQueue.main.async { completion([:]) }
                return
            }

            var out: [Date: Double] = [:]
            results.enumerateStatistics(from: start, to: end) { stats, _ in
                if let q = stats.averageQuantity() {
                    let day = Calendar.current.startOfDay(for: stats.startDate)
                    out[day] = q.doubleValue(for: unit)
                }
            }
            DispatchQueue.main.async { completion(out) }
        }

        healthStore.execute(query)
    }
}
extension HealthKitManager: HKWorkoutSessionDelegate {

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        print("⌚ Workout state:", fromState.rawValue, "→", toState.rawValue)
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("❌ Watch workout failed:", error.localizedDescription)

        DispatchQueue.main.async {
            self.isLiveWatchWorkoutRunning = false
        }
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didGenerate event: HKWorkoutEvent
    ) {
        print("⌚ Workout event:", event)
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didBeginActivityWith workoutConfiguration: HKWorkoutConfiguration,
        date: Date
    ) {
        print("⌚ Watch workout activity began")
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didEndActivityWith workoutConfiguration: HKWorkoutConfiguration,
        date: Date
    ) {
        print("⌚ Watch workout activity ended")
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didDisconnectFromRemoteDeviceWithError error: Error?
    ) {
        print(
            "❌ Watch disconnected:",
            error?.localizedDescription ?? "no error"
        )

        DispatchQueue.main.async {
            self.isLiveWatchWorkoutRunning = false
        }
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didReceiveDataFromRemoteWorkoutSession data: [Data]
    ) {
        for packet in data {
            do {
                let decoded = try JSONDecoder().decode(
                    LiveHeartRatePacket.self,
                    from: packet
                )

                print(
                    "❤️ LIVE WATCH HR:",
                    decoded.heartRate,
                    "at",
                    decoded.timestamp
                )

                DispatchQueue.main.async {
                    self.liveWatchHRHandler?(
                        decoded.heartRate,
                        decoded.timestamp
                    )
                }

            } catch {
                print(
                    "❌ Could not decode Watch HR packet:",
                    error.localizedDescription
                )
            }
        }
    }
}
// MARK: - ScoreHistoryEntry

struct ScoreHistoryEntry: Codable, Identifiable {
    let id: UUID
    let score: Int
    let date: Date
    let riskLevel: HydrationRiskLevel

    init(score: Int, date: Date, riskLevel: HydrationRiskLevel) {
        self.id = UUID()
        self.score = score
        self.date = date
        self.riskLevel = riskLevel
    }
}

private enum HistoryRange: String, CaseIterable, Identifiable {
    case oneWeek = "1 Week"
    case oneMonth = "1 Month"
    case twoMonths = "2 Months"
    case sixMonths = "6 Months"
    case allTime = "All History"

    var id: String { rawValue }

    func includes(_ date: Date, relativeTo now: Date = Date()) -> Bool {
        guard self != .allTime else { return true }

        let calendar = Calendar.current
        let components: DateComponents
        switch self {
        case .oneWeek: components = DateComponents(day: -7)
        case .oneMonth: components = DateComponents(month: -1)
        case .twoMonths: components = DateComponents(month: -2)
        case .sixMonths: components = DateComponents(month: -6)
        case .allTime: return true
        }

        return date >= (calendar.date(byAdding: components, to: now) ?? .distantPast)
    }
}

private struct DisplayScoreHistoryEntry: Identifiable {
    let id: UUID
    let score: Double
    let riskLevel: HydrationRiskLevel
    let firstDate: Date
    let lastDate: Date
    let readingCount: Int
}

// MARK: - ContentView

struct ContentView: View {

    @StateObject private var healthKitManager = HealthKitManager()
    @StateObject private var liveDisplay = LiveHealthDisplay()
    @State private var isLiveStreamRunning = false
    @State private var heartRate: Double?
    @State private var hrv: Double?
    @State private var restingHeartRate: Double?
    @State private var baseline = BaselineStore.shared.loadBaseline()
    @State private var baselineStartDate: Date? = BaselineStore.shared.loadStartDate()
    @State private var latestRisk: HydrationRisk?
    @State private var mode: SimMode = .hydrated
    @State private var statusText = "Ready"
    @State private var useSimulator = false
    @State private var mlOffProb: Double?
    @State private var simulatorScoreHistory: [Int] = []
    @State private var realScoreHistory: [Int] = []
    @State private var lastAlertTime: Date?
    @State private var lastCheckTime: Date?
    @State private var isMonitoringActive = false
    @State private var lastHRValue: Double?
    @State private var lastScoredDate: Date?
    @State private var lastSeenHRDate: Date?
    @State private var lastHRDate: Date?
    @State private var lastRefreshTime: Date?
    @State private var debugMLText: String = ""
    @State private var lastNotifiedLevel: HydrationRiskLevel? = nil
    @State private var showSettings = false
    @State private var showResetConfirm = false
    @State private var post = RiskPostProcessor()
    @State private var lastActivity: ActivityContext?
    @State private var isWorking = false
    @State private var lastSimTap: Date = .distantPast
    @State private var skipMLOnce = false
    @State private var bgTask: UIBackgroundTaskIdentifier = .invalid
    @State private var uiNow: Date = Date()
    @State private var debugTraceLines: [String] = []
    @State private var pollCount: Int = 0
    @State private var lastPollFiredAt: Date?

    @State private var simExplanation: String? = nil

    @State private var selectedTab: Int = 0
    @State private var showingCurrentDetails = false
    @State private var allScoreHistory: [ScoreHistoryEntry] = []
    @AppStorage("hydrasense.historyRange") private var historyRangeRawValue = HistoryRange.twoMonths.rawValue
    @AppStorage("hydrasense.aggregationLevel") private var aggregationLevelRawValue = AggregationLevel.weekly.rawValue
    @AppStorage("hydrasense.aggregationDefaultUpdated") private var aggregationDefaultUpdated = false

    private var aggregationLevel: AggregationLevel {
        AggregationLevel(rawValue: aggregationLevelRawValue) ?? .all
    }
    @Environment(\.scenePhase) private var scenePhase

    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// Same run-loop mode as `uiTimer` (proven to fire while this view is visible).
    private let healthPollTimer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    let scorer = HydrationRiskScorer()
    let simulator = SimulatorVitalsGenerator()

    private var currentScoreHistory: [Int] {
        useSimulator ? simulatorScoreHistory : realScoreHistory
    }

    private var historyRange: HistoryRange {
        HistoryRange(rawValue: historyRangeRawValue) ?? .twoMonths
    }

    // MARK: - Score History Persistence

    private func saveScoreHistory() {
        if let data = try? JSONEncoder().encode(allScoreHistory) {
            UserDefaults.standard.set(data, forKey: "hydrasense.allScoreHistory")
        }
    }

    private func loadScoreHistory() {
        if let data = UserDefaults.standard.data(forKey: "hydrasense.allScoreHistory"),
           let loaded = try? JSONDecoder().decode([ScoreHistoryEntry].self, from: data) {
            allScoreHistory = loaded
        }
    }

    // MARK: - Historical Backfill
    private func backfillRiskScoreHistory() {
        let daysBack = 14
        let endDate = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: endDate) else { return }
        let group = DispatchGroup()
        var hrSamples: [HKQuantitySample] = []
        var hrvSamples: [HKQuantitySample] = []
        var rhrSamples: [HKQuantitySample] = []
        group.enter()
        healthKitManager.healthStore.execute(HKSampleQuery(
            sampleType: HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            predicate: HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
        ) { _, samples, _ in
            hrSamples = (samples as? [HKQuantitySample]) ?? []
            print("[Backfill] HR samples found: \(hrSamples.count)")
            group.leave()
        })
        group.enter()
        healthKitManager.healthStore.execute(HKSampleQuery(
            sampleType: HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            predicate: HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
        ) { _, samples, _ in
            hrvSamples = (samples as? [HKQuantitySample]) ?? []
            print("[Backfill] HRV samples found: \(hrvSamples.count)")
            group.leave()
        })
        group.enter()
        healthKitManager.healthStore.execute(HKSampleQuery(
            sampleType: HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            predicate: HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate),
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
        ) { _, samples, _ in
            rhrSamples = (samples as? [HKQuantitySample]) ?? []
            print("[Backfill] RHR samples found: \(rhrSamples.count)")
            group.leave()
        })
        group.notify(queue: .main) {
            var added = 0
            let scoredTimestamps: Set<Date> = Set(allScoreHistory.map { $0.date })
            for hr in hrSamples {
                let hrDate = hr.endDate
                guard !scoredTimestamps.contains(where: { abs($0.timeIntervalSince(hrDate)) < 30 }) else { continue }
                let hrv = hrvSamples.min(by: { abs($0.endDate.timeIntervalSince(hrDate)) < abs($1.endDate.timeIntervalSince(hrDate)) })
                let rhr = rhrSamples.min(by: { abs($0.endDate.timeIntervalSince(hrDate)) < abs($1.endDate.timeIntervalSince(hrDate)) })
                let hrvVal = hrv?.quantity.doubleValue(for: HKUnit.second()) ?? 0.0
                let rhrVal = rhr?.quantity.doubleValue(for: HKUnit(from: "count/min")) ?? 0.0
                let sample = VitalSample(
                    timestamp: hrDate,
                    heartRateBPM: hr.quantity.doubleValue(for: HKUnit(from: "count/min")),
                    hrvMS: hrvVal * 1000.0,
                    restingHeartRateBPM: rhrVal
                )
                let baseRisk = scorer.score(sample: sample, baseline: baseline, includeDetails: false)
                let blended = blendedScore(zScore: baseRisk.score0to100, mlOffProb: nil)
                let riskLevel = blended < 35 ? HydrationRiskLevel.low : (blended < 70 ? .moderate : .high)
                let entry = ScoreHistoryEntry(score: blended, date: hrDate, riskLevel: riskLevel)
                allScoreHistory.append(entry)
                added += 1
            }
            allScoreHistory.sort { $0.date < $1.date }
            saveScoreHistory()
            print("[Backfill] History entries added: \(added)")
            print("[Backfill] Total history entries: \(allScoreHistory.count)")
        }
    }

    // MARK: - Scoring

    private func recordScore(_ score: Int) {
        if useSimulator {
            simulatorScoreHistory.append(score)
            if simulatorScoreHistory.count > 20 {
                simulatorScoreHistory.removeFirst(simulatorScoreHistory.count - 20)
            }
            // For simulator, risk level from latestRisk or approximate from score
            let riskLevel = latestRisk?.level ?? (score < 35 ? .low : (score < 70 ? .moderate : .high))
            let entry = ScoreHistoryEntry(score: score, date: Date(), riskLevel: riskLevel)
            allScoreHistory.append(entry)
            saveScoreHistory()
        } else {
            realScoreHistory.append(score)
            if realScoreHistory.count > 20 {
                realScoreHistory.removeFirst(realScoreHistory.count - 20)
            }
            // For real data, risk level from latestRisk or approximate from score
            let riskLevel = latestRisk?.level ?? (score < 35 ? .low : (score < 70 ? .moderate : .high))
            let entry = ScoreHistoryEntry(score: score, date: Date(), riskLevel: riskLevel)
            allScoreHistory.append(entry)
            saveScoreHistory()
        }
    }

    // MARK: - Scoring and Notification (unchanged)

    private func scoreAndMaybeNotify(sample: VitalSample, activity: ActivityContext? = nil) {
        heartRate = sample.heartRateBPM
        hrv = sample.hrvMS
        restingHeartRate = sample.restingHeartRateBPM
        if skipMLOnce {
            mlOffProb = nil
            debugMLText = "ML: skipped once"
            skipMLOnce = false
        } else if !isValidForML(sample) {
            mlOffProb = nil
            debugMLText = "ML: nil"
        } else {
            mlOffProb = MLPredictor.shared.offProbability(sample: sample)
            debugMLText = mlOffProb == nil ? "ML: nil" : String(format: "ML: %.3f", mlOffProb!)
        }

        baseline.add(sample: sample)
        if baseline.hr.n % 10 == 0 {
            BaselineStore.shared.saveBaseline(baseline)
        }
        baselineStartDate = BaselineStore.shared.saveStartDateIfNeeded()

        guard baselineComplete() else {
            latestRisk = nil
            PhoneConnectivityManager.shared.clearRiskScore(isSimulator: useSimulator)
            statusText = "Baseline building… Day \(baselineDay())/14"
            return
        }

        let baseRisk = scorer.score(sample: sample, baseline: baseline, includeDetails: false)

        var final = blendedScore(zScore: baseRisk.score0to100, mlOffProb: mlOffProb)
        if let ctx = activity, ctx.isActive, final < 80 {
            final = min(final, 65)
        }

        let blendedRisk = HydrationRisk(
            score0to100: final,
            level: final < 35 ? .low : (final < 70 ? .moderate : .high),
            details: baseRisk.details
        )

        let improved = post.process(raw: blendedRisk, sample: sample)

        recordScore(improved.score0to100)
        lastCheckTime = Date()
        latestRisk = improved
        PhoneConnectivityManager.shared.sendRiskScore(
            score: improved.score0to100,
            riskLevel: improved.level.rawValue,
            sampleDate: sample.timestamp,
            isSimulator: useSimulator
        )
        statusText = "Scored"

        let crossedIntoHigh = (improved.level == .high && lastNotifiedLevel != .high)

        if crossedIntoHigh && canSendAlert() {
            diagLog.log("NOTIFY: level=high score=\(improved.score0to100)")
            lastAlertTime = Date()
            lastNotifiedLevel = .high
            NotificationManager.shared.sendDehydrationAlert(score: improved.score0to100, level: improved.level)
        }

        if improved.level != .high {
            lastNotifiedLevel = improved.level
        }
    }

    // MARK: - Refresh (unchanged)

    private func backgroundRefreshAndScore() {
        diagLog.log("REFRESH START")
        if useSimulator { return }

        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "HydraRefresh") {
                diagLog.log("BG TASK EXPIRED")
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            diagLog.log("BG TASK BEGIN id=\(String(describing: bgTask))")
        }

        healthKitManager.fetchLatestVitalsLenient { sampleOpt in
            let now = Date()
            let recentWatchSample = LatestSampleStore.shared.latest.flatMap { latest -> VitalSample? in
                let age = now.timeIntervalSince(latest.timestamp)
                return (0...120).contains(age) ? latest : nil
            }
            guard let fetchedSample = sampleOpt ?? recentWatchSample else {
                diagLog.log("REFRESH NO VITALS (lenient)")
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    diagLog.log("BG TASK END (no vitals)")
                    bgTask = .invalid
                }
                return
            }
            let sample = recentWatchSample.flatMap { latest in
                latest.timestamp > fetchedSample.timestamp ? latest : nil
            } ?? fetchedSample

            let group = DispatchGroup()
            group.enter()
            var ctxOut: ActivityContext?

            DispatchQueue.global(qos: .utility).async {
                healthKitManager.fetchActivityContext(lastMinutes: 10) { ctx in
                    ctxOut = ctx
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                let ctx = ctxOut
                lastActivity = ctx
                lastRefreshTime = Date()
                lastHRDate = sample.timestamp
                lastSeenHRDate = sample.timestamp
                let age = Int(Date().timeIntervalSince(sample.timestamp))
                statusText = "Latest HR \(Int(sample.heartRateBPM)) • age \(age)s • \(ctx?.summary ?? "no activity")"

                HealthDataLogger.shared.updateLatest(sample: sample)
                scoreAndMaybeNotify(sample: sample, activity: ctx)

                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    diagLog.log("BG TASK END")
                    bgTask = .invalid
                }
            }
        }
    }

    @MainActor
    private func refreshNow() {
        print("[RefreshNow] Triggered at", Date())
        liveDisplay.recordPoll()
        pollCount = liveDisplay.pollCount
        lastPollFiredAt = liveDisplay.lastRefreshAt
        // #region agent log
        DebugSessionLog.log(
            hypothesisId: "D",
            location: "ContentView.refreshNow:entry",
            message: "refreshNow called",
            data: [
                "useSimulator": useSimulator,
                "isMonitoringActive": isMonitoringActive,
                "pollCount": pollCount,
                "scenePhase": String(describing: scenePhase)
            ],
            runId: "post-fix"
        )
        // #endregion
        if useSimulator { return }

        healthKitManager.fetchMostRecentHeartRateDetail { hr, date, source in
            Task { @MainActor in
                guard let hr, let date else { return }
                if !healthKitManager.isLiveWatchWorkoutRunning {
                    liveDisplay.apply(
                        heartRate: hr,
                        timestamp: date,
                        source: source
                    )
                }
                let age = liveDisplay.sampleAgeSec
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "B",
                    location: "ContentView.refreshNow:rawHK",
                    message: "phone HealthKit latest HR",
                    data: [
                        "hr": hr,
                        "sampleAgeSec": age,
                        "source": source ?? "none"
                    ],
                    runId: "post-fix"
                )
                // #endregion
            }
        }

        var localBGTask: UIBackgroundTaskIdentifier = .invalid
        localBGTask = UIApplication.shared.beginBackgroundTask(withName: "HydraForegroundRefresh") {
            print("BG TASK EXPIRED (fg refresh)")
            if localBGTask != .invalid {
                UIApplication.shared.endBackgroundTask(localBGTask)
                localBGTask = .invalid
            }
        }
        print("BG TASK BEGIN (fg refresh)")

        healthKitManager.fetchLatestVitalsLenient { sampleOpt in
            Task { @MainActor in
                let now = Date()
                let recentWatchSample = LatestSampleStore.shared.latest.flatMap { latest -> VitalSample? in
                    let age = now.timeIntervalSince(latest.timestamp)
                    return (0...120).contains(age) ? latest : nil
                }
                guard let fetchedSample = sampleOpt ?? recentWatchSample else {
                    // #region agent log
                    DebugSessionLog.log(
                        hypothesisId: "E",
                        location: "ContentView.refreshNow:fetch",
                        message: "fetchLatestVitalsLenient returned nil",
                        runId: "post-fix"
                    )
                    // #endregion
                    if localBGTask != .invalid {
                        print("BG TASK END (fg refresh) — no vitals")
                        UIApplication.shared.endBackgroundTask(localBGTask)
                        localBGTask = .invalid
                    }
                    return
                }
                // Prefer a newer watch sample only while it is still recent.
                let sample = recentWatchSample.flatMap { latest in
                    latest.timestamp > fetchedSample.timestamp ? latest : nil
                } ?? fetchedSample
                let sampleAgeSec = Int(Date().timeIntervalSince(sample.timestamp))
                let tsChanged = lastSeenHRDate.map { $0 != sample.timestamp } ?? true
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "B",
                    location: "ContentView.refreshNow:fetch",
                    message: "vitals fetched",
                    data: [
                        "hr": sample.heartRateBPM,
                        "sampleAgeSec": sampleAgeSec,
                        "timestamp": sample.timestamp.timeIntervalSince1970,
                        "timestampChanged": tsChanged
                    ],
                    runId: "post-fix"
                )
                // #endregion

                if !healthKitManager.isLiveWatchWorkoutRunning {
                    liveDisplay.apply(
                        sample: sample,
                        source: liveDisplay.phoneSource
                    )
                }
                pollCount = liveDisplay.pollCount
                lastPollFiredAt = liveDisplay.lastRefreshAt

                // Update UI immediately from vitals — do not block on activity (can hang).
                lastRefreshTime = Date()
                lastHRDate = sample.timestamp
                lastSeenHRDate = sample.timestamp
                if sampleAgeSec > 120 {
                    statusText = "Refreshed • HR \(Int(sample.heartRateBPM))"
                } else {
                    let activityLabel = lastActivity?.summary ?? "activity pending"
                    statusText = "Refreshed • HR \(Int(sample.heartRateBPM)) • \(activityLabel)"
                }
                HealthDataLogger.shared.updateLatest(sample: sample)
                scoreAndMaybeNotify(sample: sample, activity: lastActivity)

                if localBGTask != .invalid {
                    print("BG TASK END (fg refresh)")
                    UIApplication.shared.endBackgroundTask(localBGTask)
                    localBGTask = .invalid
                }

                healthKitManager.fetchActivityContext(lastMinutes: 10) { ctx in
                    Task { @MainActor in
                        lastActivity = ctx
                        if sampleAgeSec <= 120 {
                            statusText = "Refreshed • HR \(Int(sample.heartRateBPM)) • \(ctx.summary)"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Live Stream

    /// Updates HR label immediately when anchored query delivers a sample (before full vitals fetch).
    private func applyQuickHRUpdate(hr: Double, date: Date) {
        heartRate = hr
        liveDisplay.apply(heartRate: hr, timestamp: date, source: liveDisplay.phoneSource)
        lastHRDate = date
        lastSeenHRDate = date
        lastHRValue = hr
        let age = Int(Date().timeIntervalSince(date))
        statusText = "Live HR \(Int(hr)) bpm"
        // #region agent log
        DebugSessionLog.log(
            hypothesisId: "B",
            location: "ContentView.applyQuickHRUpdate",
            message: "quick HR applied to UI",
            data: ["hr": hr, "sampleAgeSec": age]
        )
        // #endregion
    }

    private func startLiveStream() {

        if isLiveStreamRunning {
            return
        }

        isLiveStreamRunning = true

        healthKitManager.stopHeartRateObserver()
        healthKitManager.stopHeartRateLiveUpdates()

        healthKitManager.startLiveWatchHeartRate { hr, date in
            Task { @MainActor in
                applyQuickHRUpdate(
                    hr: hr,
                    date: date
                )

                // IMPORTANT:
                // Do not call refreshNow() here.
                // refreshNow() reads the latest SAVED HealthKit sample,
                // which can be older than this live Watch reading.
            }
        }

        print("HydraSense live Watch stream started")
    }
    private func stopLiveStream() {
        isLiveStreamRunning = false
        healthKitManager.stopHeartRateObserver()
        healthKitManager.stopHeartRateLiveUpdates()
    }

    /// Foreground poll tick. Re-registering HealthKit matches `scenePhase == .active` (the only path that used to update).
    @MainActor
    private func performPollTick(restartHealthKitStream: Bool) {
        pollCount += 1
        lastPollFiredAt = Date()
        // #region agent log
        DebugSessionLog.log(
            hypothesisId: "D",
            location: "ContentView.performPollTick",
            message: "foreground poll tick",
            data: [
                "pollCount": pollCount,
                "restartHealthKitStream": restartHealthKitStream
            ],
            runId: "post-fix"
        )
        // #endregion
        if restartHealthKitStream {
            startLiveStream()
        } else {
            refreshNow()
        }
    }

    // MARK: - Mode Switching

    private func enterRealMode() {
        skipMLOnce = true
        statusText = "Connecting to HealthKit..."

        healthKitManager.requestAuthorization { success in
            statusText = success ? "HealthKit ready." : "HealthKit authorization failed."
            guard success else { return }

            HealthDataLogger.shared.startUsingLatestSample(baselineProvider: { baseline }, scorer: scorer)
            printLatestSampleToConsole(tag: "Mode Switch Catch-up")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if isMonitoringActive {
                    startLiveStream()
                }
            }
        }
    }

    private func enterSimulatorMode() {
        stopLiveStream()
        HealthDataLogger.shared.stop()

        latestRisk = nil
        statusText = "Ready"
        simulatorScoreHistory.removeAll()
        realScoreHistory.removeAll()
        post = RiskPostProcessor()
        lastCheckTime = nil
        lastRefreshTime = nil
        lastHRDate = nil
        lastSeenHRDate = nil
        heartRate = nil
        hrv = nil
        restingHeartRate = nil
        debugMLText = ""
        simExplanation = nil
    }

    // MARK: - Helpers

    private func currentDetailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func healthMetricCard(
        title: String,
        symbol: String,
        value: Double?,
        unit: String,
        baselineValue: Double?,
        tint: Color,
        decimals: Int
    ) -> some View {
        let format = decimals == 0 ? "%.0f" : "%.1f"
        let reading = value.map { String(format: format, $0) } ?? "—"
        let comparison: String
        if let value, let baselineValue {
            let delta = value - baselineValue
            comparison = String(format: "Baseline %@ %@", delta >= 0 ? "+" : "−", String(format: format, abs(delta)))
        } else if value != nil {
            comparison = "Baseline building"
        } else {
            comparison = "Waiting for reading"
        }

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: Circle())
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(reading)
                    .font(.title2.bold().monospacedDigit())
                    .foregroundStyle(.primary)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(comparison)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(11)
        .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        }
    }

    private func activityMetricCard(_ activity: ActivityContext?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 26, height: 26)
                    .background(Color.green.opacity(0.12), in: Circle())
                Text("Recent Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let activity {
                Text("\(Int(activity.steps)) steps")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("\(Int(activity.activeEnergyKcal)) kcal · last \(activity.windowMinutes) min")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text("—")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("Waiting for activity data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(11)
        .background(Color.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.green.opacity(0.14), lineWidth: 1)
        }
    }

    private func baselineProgress() -> Double {
        Double(baselineDay()) / 14.0
    }

    private func riskColor(for level: HydrationRiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .moderate: return .orange
        case .high: return .red
        }
    }

    private func canSendAlert() -> Bool {
        guard let last = lastAlertTime else { return true }
        return Date().timeIntervalSince(last) > 60 * 30
    }

    private func blendedScore(zScore: Int, mlOffProb: Double?) -> Int {
        guard let p = mlOffProb else { return zScore }
        let blended = (0.65 * Double(zScore)) + (0.35 * (p * 100.0))
        return Int(blended.rounded())
    }

    private func baselineDay() -> Int {
        guard let start = baselineStartDate else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        return min(max(days, 0), 14)
    }

    private func baselineComplete() -> Bool {
        guard let start = baselineStartDate else { return false }
        let days = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        return days >= 14
    }

    private func isValidForML(_ s: VitalSample) -> Bool {
        (30...220).contains(s.heartRateBPM)
        && (1...500).contains(s.hrvMS)
        && (30...120).contains(s.restingHeartRateBPM)
    }

    private func debugPrintSample(_ s: VitalSample, tag: String) {
        print("✅ [\(tag)] sample @ \(s.timestamp)")
        print("   HR: \(s.heartRateBPM) bpm")
        print("   HRV: \(s.hrvMS) ms")
        print("   RHR: \(s.restingHeartRateBPM) bpm")
    }

    private func printLatestSampleToConsole(tag: String = "FG Catch-up") {
        if let s = LatestSampleStore.shared.latest {
            let df = ISO8601DateFormatter()
            let age = Int(Date().timeIntervalSince(s.timestamp))
            print("✅ [\(tag)] sample @ \(df.string(from: s.timestamp))")
            print("   age: \(age)s")
            print("   HR: \(s.heartRateBPM) bpm")
            print("   HRV: \(s.hrvMS) ms")
            print("   RHR: \(s.restingHeartRateBPM) bpm")
        } else {
            print("⚠️ [\(tag)] No latest sample available")
        }
    }

    private func runSim(mode: SimMode) {
        let now = Date()
        if now.timeIntervalSince(lastSimTap) < 0.35 { return }
        lastSimTap = now
        if isWorking { return }
        isWorking = true

        let baselineSnapshot = baseline

        DispatchQueue.global(qos: .userInitiated).async {
            let sample = simulator.next(mode: mode)
            let baseRisk = scorer.score(sample: sample, baseline: baselineSnapshot, includeDetails: false)
            let mlProb: Double? = isValidForML(sample) ? MLPredictor.shared.offProbability(sample: sample) : nil
            let blended = blendedScore(zScore: baseRisk.score0to100, mlOffProb: mlProb)

            let improved = HydrationRisk(
                score0to100: blended,
                level: blended < 35 ? .low : (blended < 70 ? .moderate : .high),
                details: nil
            )
            let explanation = simulatedExplanation(for: sample, using: baselineSnapshot)

            DispatchQueue.main.async {
                mlOffProb = mlProb
                debugMLText = mlProb == nil ? "ML: nil" : String(format: "ML: %.3f", mlProb!)
                latestRisk = improved
                simExplanation = explanation
                recordScore(improved.score0to100)
                lastCheckTime = Date()
                PhoneConnectivityManager.shared.sendRiskScore(
                    score: improved.score0to100,
                    riskLevel: improved.level.rawValue,
                    sampleDate: sample.timestamp,
                    isSimulator: true
                )
                let crossedIntoHigh = improved.level == .high && lastNotifiedLevel != .high
                if crossedIntoHigh && canSendAlert() {
                    diagLog.log("NOTIFY: simulator level=high score=\(improved.score0to100)")
                    lastAlertTime = Date()
                    lastNotifiedLevel = .high
                    NotificationManager.shared.sendDehydrationAlert(
                        score: improved.score0to100,
                        level: improved.level
                    )
                }
                if improved.level != .high {
                    lastNotifiedLevel = improved.level
                }
                statusText = "Simulated \(mode == .hydrated ? "Hydrated" : "Dehydration") • score \(improved.score0to100)"
                isWorking = false
            }
        }
    }

    private func simulatedExplanation(for sample: VitalSample, using baseline: HydrationBaseline) -> String {
        // Calculate baseline averages; if unavailable, return a default message
        guard baseline.hr.n > 0 else {
            return "Baseline data not available for comparison."
        }

        let avgHR = baseline.hr.mean
        let avgHRV = baseline.hrv.mean
        let avgRHR = baseline.rhr.mean

        // Differences
        let hrDiff = sample.heartRateBPM - avgHR
        let hrvDiff = sample.hrvMS - avgHRV
        let rhrDiff = sample.restingHeartRateBPM - avgRHR

        // Thresholds for "abnormal" values (these can be tuned)
        let hrThreshold = 10.0
        let hrvThreshold = 20.0
        let rhrThreshold = 10.0

        var messages: [String] = []

        if hrDiff > hrThreshold {
            messages.append(String(format: "Heart Rate (%.0f) is above your baseline (%.0f).", sample.heartRateBPM, avgHR))
        } else if hrDiff < -hrThreshold {
            messages.append(String(format: "Heart Rate (%.0f) is below your baseline (%.0f).", sample.heartRateBPM, avgHR))
        }

        if hrvDiff < -hrThreshold {
            messages.append(String(format: "HRV (%.0f ms) is below your baseline (%.0f ms).", sample.hrvMS, avgHRV))
        } else if hrvDiff > hrvThreshold {
            messages.append(String(format: "HRV (%.0f ms) is above your baseline (%.0f ms).", sample.hrvMS, avgHRV))
        }

        if rhrDiff > rhrThreshold {
            messages.append(String(format: "Resting HR (%.0f) is above your baseline (%.0f).", sample.restingHeartRateBPM, avgRHR))
        } else if rhrDiff < -rhrThreshold {
            messages.append(String(format: "Resting HR (%.0f) is below your baseline (%.0f).", sample.restingHeartRateBPM, avgRHR))
        }

        if messages.isEmpty {
            return "Sample readings are close to your baseline."
        }

        return messages.joined(separator: " ")
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack {
                if selectedTab == 0 {
                    ScrollView {
                        VStack(spacing: 14) {

                            Card(nil) {
                                VStack(spacing: 10) {
                                    HStack {
                                        Text("Risk Score")
                                            .font(.headline)
                                        Spacer()
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.22)) {
                                                showingCurrentDetails.toggle()
                                            }
                                        } label: {
                                            Label(showingCurrentDetails ? "Hide Details" : "Details", systemImage: showingCurrentDetails ? "chevron.up.circle" : "info.circle")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .buttonStyle(.bordered)
                                        .tint(.blue)
                                    }

                                    if let risk = latestRisk {
                                        RiskBadge(level: risk.level, score: risk.score0to100)
                                        if useSimulator, let explanation = simExplanation {
                                            Text(explanation)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let details = risk.details {
                                            Text(details)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    } else {
                                        HStack(spacing: 12) {
                                            Image(systemName: "chart.pie")
                                                .font(.title2)
                                                .foregroundStyle(.secondary)
                                            Text("A risk score will appear after your next reading.")
                                                .font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }

                            if !currentScoreHistory.isEmpty {
                                Card("Score Trend") {
                                    Chart {
                                        ForEach(Array(currentScoreHistory.enumerated()), id: \.offset) { index, score in
                                            LineMark(
                                                x: .value("Reading", index + 1),
                                                y: .value("Score", score)
                                            )
                                        }
                                    }
                                    .chartXAxisLabel("Reading")
                                    .frame(height: 140)
                                }
                            }

                            if showingCurrentDetails {
                                Card("Current Details") {
                                    VStack(spacing: 9) {
                                        currentDetailRow("Status", statusText)
                                        currentDetailRow("Baseline samples", "n=\(baseline.hr.n) · Day \(baselineDay())/14")
                                        currentDetailRow("ML probability", mlOffProb.map { String(format: "%.3f", $0) } ?? "Unavailable")
                                        if !debugMLText.isEmpty {
                                            currentDetailRow("ML", debugMLText)
                                        }
                                        currentDetailRow("Last poll", lastPollFiredAt.map { "\($0.formatted(date: .omitted, time: .shortened)) · \(pollCount) polls" } ?? "Not yet")
                                        currentDetailRow("Last refresh", lastRefreshTime?.formatted(date: .omitted, time: .shortened) ?? "Not yet")
                                        currentDetailRow("Last score", lastCheckTime?.formatted(date: .omitted, time: .shortened) ?? "Not yet")
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            Card("Monitoring") {
                                VStack(spacing: 12) {
                                    HStack(spacing: 12) {
                                        Button(isMonitoringActive ? "Monitoring: ON" : "Start Monitoring") {
                                            if !useSimulator {
                                                isMonitoringActive = true
                                                pollCount = 0
                                                lastPollFiredAt = nil
                                                Task { @MainActor in
                                                    performPollTick(restartHealthKitStream: true)
                                                }
                                            }
                                        }
                                        .buttonStyle(PrimaryButtonStyle())
                                        .disabled(useSimulator)

                                        Button("Stop") {
                                            isMonitoringActive = false
                                            stopLiveStream()
                                        }
                                        .buttonStyle(SecondaryButtonStyle(tint: .red))
                                        .disabled(!isMonitoringActive)
                                    }

                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(isMonitoringActive ? Color.green : Color.gray)
                                            .frame(width: 10, height: 10)
                                        Text(isMonitoringActive ? "Live Monitoring Active" : "Monitoring Off")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let t = lastRefreshTime {
                                            Text("Refreshed: \(t.formatted(date: .omitted, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

                                    if let lastPollFiredAt, isMonitoringActive && !useSimulator {
                                        Text("Last poll: \(lastPollFiredAt.formatted(date: .omitted, time: .shortened)) • Polls: \(pollCount)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                }
                            }

                            Divider()

                            if useSimulator {
                                Button("Build Baseline (Simulated)") {
                                    baseline = HydrationBaseline()
                                    for _ in 0..<200 {
                                        let sample = simulator.next(mode: .hydrated)
                                        baseline.add(sample: sample)
                                    }
                                    latestRisk = nil
                                    PhoneConnectivityManager.shared.clearRiskScore(isSimulator: true)
                                    statusText = "Baseline built"
                                }

                                Button(isWorking ? "Working..." : "Simulate Hydrated Reading") {
                                    runSim(mode: .hydrated)
                                }
                                .disabled(isWorking)

                                Button(isWorking ? "Working..." : "Simulate Dehydration-Like Reading") {
                                    runSim(mode: .dehydrationLike)
                                }
                                .disabled(isWorking)

                            } else {
                            }

                            if !useSimulator {
                                Card("Health Metrics") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Latest readings compared with your personal baseline")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                                            healthMetricCard(title: "Heart Rate", symbol: "heart.fill", value: heartRate, unit: "bpm", baselineValue: baseline.hr.n > 0 ? baseline.hr.mean : nil, tint: .pink, decimals: 0)
                                            healthMetricCard(title: "HRV", symbol: "waveform.path.ecg", value: hrv, unit: "ms", baselineValue: baseline.hrv.n > 0 ? baseline.hrv.mean : nil, tint: .blue, decimals: 1)
                                            healthMetricCard(title: "Resting HR", symbol: "heart.text.square.fill", value: restingHeartRate, unit: "bpm", baselineValue: baseline.rhr.n > 0 ? baseline.rhr.mean : nil, tint: .orange, decimals: 0)
                                            activityMetricCard(lastActivity)
                                        }
                                    }
                                }
                            }

                            Card("Baseline") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Day \(baselineDay()) / 14")
                                        .font(.subheadline.weight(.semibold))
                                    ProgressView(value: baselineProgress())
                                        .tint(.blue)
                                    Text(baselineComplete() ? "Baseline complete " : "Building baseline for personalization…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 68)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    HistoryView(entries: allScoreHistory, range: historyRange, aggregationLevel: aggregationLevel)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    Text("Current").tag(0)
                    Text("History").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 0)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                HStack(spacing: 12) {
                    Text("Hydrasense")
                        .font(.system(size: 28, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 8)

                    StatusPill(
                        text: useSimulator ? "Simulator" : "HealthKit",
                        systemImage: useSimulator ? "sparkles" : "heart.fill",
                        color: useSimulator ? .purple : .pink
                    )

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, 16)
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsSheet(
                    showSettings: $showSettings,
                    statusText: $statusText,
                    useSimulator: $useSimulator,
                    showResetConfirm: $showResetConfirm,
                    historyRangeRawValue: $historyRangeRawValue,
                    aggregationLevelRawValue: $aggregationLevelRawValue,
                    onShowCSV: {
                        statusText = DataLogger.shared.exportPath()
                    },
                    onCheckCSV: {
                        let path = DataLogger.shared.exportPath()
                        let exists = FileManager.default.fileExists(atPath: path)
                        statusText = exists ? "CSV exists ✅" : "CSV missing ❌"
                    },
                    onTestNotification: {
                        NotificationManager.shared.sendDehydrationAlert(score: 99, level: .high)
                    },
                    onBuildBaseline: {
                        statusText = "Building baseline from last 14 days..."
                        healthKitManager.buildBaselineFromLastDays(days: 14) { newBaseline, daysUsed in
                            guard let newBaseline = newBaseline else {
                                statusText = "Not enough Health data to build baseline."
                                return
                            }
                            baseline = newBaseline
                            BaselineStore.shared.saveBaseline(baseline)
                            let start = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
                            baselineStartDate = start
                            UserDefaults.standard.set(start, forKey: "hydrasense.baselineStart")
                            latestRisk = nil
                            statusText = "Baseline built from \(daysUsed) days ✅"
                        }
                    },
                    onReadHealthKit: {
                        statusText = "Fetching vitals..."
                        healthKitManager.fetchLatestVitals { sample in
                            DispatchQueue.main.async {
                                guard let sample = sample else {
                                    statusText = "No HealthKit samples found."
                                    return
                                }
                                debugPrintSample(sample, tag: "HK Manual Read")
                                heartRate = sample.heartRateBPM
                                hrv = sample.hrvMS
                                restingHeartRate = sample.restingHeartRateBPM
                                if !isValidForML(sample) {
                                    print("⚠️ sample fails sanity checks; skipping ML", sample)
                                    mlOffProb = nil
                                } else {
                                    mlOffProb = MLPredictor.shared.offProbability(sample: sample)
                                }
                                debugMLText = mlOffProb == nil ? "ML: nil" : String(format: "ML: %.3f", mlOffProb!)
                                print("📥 CoreML INPUTS",
                                      "hr=\(sample.heartRateBPM)",
                                      "hrv=\(sample.hrvMS)",
                                      "rhr=\(sample.restingHeartRateBPM)")
                                if let p = mlOffProb {
                                    print("✅ CoreML output offProbability =", p)
                                } else {
                                    print("❌ CoreML output is NIL")
                                }
                                DataLogger.shared.append(sample: sample, label: "normal")
                                baseline.add(sample: sample)
                                BaselineStore.shared.saveBaseline(baseline)
                                baselineStartDate = BaselineStore.shared.saveStartDateIfNeeded()
                                HealthDataLogger.shared.updateLatest(sample: sample)
                                if baselineComplete() {
                                    let baseRisk = scorer.score(sample: sample, baseline: baseline, includeDetails: false)
                                    let blended = blendedScore(zScore: baseRisk.score0to100, mlOffProb: mlOffProb)
                                    let blendedRisk = HydrationRisk(
                                        score0to100: blended,
                                        level: blended < 35 ? .low : (blended < 70 ? .moderate : .high),
                                        details: baseRisk.details
                                    )
                                    let improved = post.process(raw: blendedRisk, sample: sample)
                                    recordScore(improved.score0to100)
                                    lastCheckTime = Date()
                                    latestRisk = improved
                                    PhoneConnectivityManager.shared.sendRiskScore(
                                        score: improved.score0to100,
                                        riskLevel: improved.level.rawValue,
                                        sampleDate: sample.timestamp,
                                        isSimulator: false
                                    )
                                    statusText = "Scored"
                                    if improved.level == .high {
                                        diagLog.log("NOTIFY: level=high score=\(improved.score0to100)")
                                        NotificationManager.shared.sendDehydrationAlert(
                                            score: improved.score0to100,
                                            level: improved.level
                                        )
                                    }
                                } else {
                                    latestRisk = nil
                                    PhoneConnectivityManager.shared.clearRiskScore(isSimulator: false)
                                    statusText = "Baseline building… Day \(baselineDay())/14"
                                }
                            }
                        }
                    },
                    onBackfillHistory: {
                        backfillRiskScoreHistory()
                    },
                    onResetBaseline: {
                        BaselineStore.shared.reset()
                        baseline = HydrationBaseline()
                        baselineStartDate = nil
                        latestRisk = nil
                        PhoneConnectivityManager.shared.clearRiskScore(isSimulator: useSimulator)
                        statusText = "Baseline reset."
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .hydrasenseAppBecameActive)) { _ in
                guard !useSimulator, isMonitoringActive else { return }
                Task { @MainActor in
                    performPollTick(restartHealthKitStream: true)
                    backfillRiskScoreHistory()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .hydrasenseHealthKitUpdate)) { _ in
                guard !useSimulator, isMonitoringActive else { return }
                Task { @MainActor in
                    // #region agent log
                    DebugSessionLog.log(
                        hypothesisId: "A",
                        location: "ContentView.healthKitNotification",
                        message: "HealthKit background delivery notification",
                        runId: "post-fix"
                    )
                    // #endregion
                    refreshNow()
                }
            }
            .onReceive(uiTimer) { now in
                uiNow = now
            }
            .onReceive(healthPollTimer) { _ in
                guard !useSimulator, isMonitoringActive else { return }
                performPollTick(restartHealthKitStream: false)
            }
            .onAppear {
                PhoneConnectivityManager.shared.activate()
                if !aggregationDefaultUpdated {
                    aggregationLevelRawValue = AggregationLevel.weekly.rawValue
                    aggregationDefaultUpdated = true
                }
                DebugSessionLog.onTrace = { line in
                    debugTraceLines.append(line)
                    if debugTraceLines.count > 24 {
                        debugTraceLines.removeFirst(debugTraceLines.count - 24)
                    }
                }
                loadScoreHistory()
                backfillRiskScoreHistory()
                if !useSimulator && isMonitoringActive {
                    startLiveStream()
                }
            }
            .onDisappear {
                // Do not stop live stream on disappear — only on explicit Stop button.
            }
            .onChange(of: scenePhase) { phase in
                // #region agent log
                DebugSessionLog.log(
                    hypothesisId: "D",
                    location: "ContentView.scenePhase",
                    message: "scenePhase changed",
                    data: [
                        "phase": String(describing: phase),
                        "isMonitoringActive": isMonitoringActive,
                        "useSimulator": useSimulator
                    ]
                )
                // #endregion
                if phase == .active && !useSimulator && isMonitoringActive {
                    Task { @MainActor in
                        printLatestSampleToConsole()
                        performPollTick(restartHealthKitStream: true)
                    }
                }
                // Query keeps running in background — intentionally no stop here.
            }
            .onChange(of: useSimulator) { newValue in
                PhoneConnectivityManager.shared.clearRiskScore(isSimulator: newValue)
                if newValue {
                    enterSimulatorMode()
                } else {
                    latestRisk = nil
                    debugMLText = ""
                    realScoreHistory.removeAll()
                    post = RiskPostProcessor()
                    lastCheckTime = nil
                    lastRefreshTime = nil
                    lastHRDate = nil
                    lastSeenHRDate = nil
                    simExplanation = nil
                    enterRealMode()
                }
            }
        }
    }
}
enum AggregationLevel: String, CaseIterable, Identifiable {
    case all = "All Entries"
    case daily = "Daily Average"
    case weekly = "Weekly Average"
    var id: String { rawValue }
}
// MARK: - HistoryView

private struct HistoryView: View {
    let entries: [ScoreHistoryEntry]
    let range: HistoryRange
    let aggregationLevel: AggregationLevel

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var visibleDays = 90.0
    @State private var initialVisibleDays = 90.0
    @State private var scrollPosition = Date()

    private var filteredEntries: [ScoreHistoryEntry] {
        entries
            .filter { range.includes($0.date) }
            .sorted { $0.date < $1.date }
    }

    private var displayedEntries: [DisplayScoreHistoryEntry] {
        switch aggregationLevel {
        case .all:
            return filteredEntries.reduce(into: [DisplayScoreHistoryEntry]()) { result, entry in
                guard let last = result.last,
                      last.score == Double(entry.score),
                      last.riskLevel == entry.riskLevel else {
                    result.append(DisplayScoreHistoryEntry(
                        id: entry.id, score: Double(entry.score), riskLevel: entry.riskLevel,
                        firstDate: entry.date, lastDate: entry.date, readingCount: 1
                    ))
                    return
                }
                result[result.count - 1] = DisplayScoreHistoryEntry(
                    id: last.id, score: last.score, riskLevel: last.riskLevel,
                    firstDate: last.firstDate, lastDate: entry.date,
                    readingCount: last.readingCount + 1
                )
            }
        case .daily, .weekly:
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: filteredEntries) { entry -> Date in
                let component: Calendar.Component = aggregationLevel == .daily ? .day : .weekOfYear
                return calendar.dateInterval(of: component, for: entry.date)?.start ?? calendar.startOfDay(for: entry.date)
            }
            return grouped.keys.sorted().compactMap { date in
                guard let bucket = grouped[date], !bucket.isEmpty else { return nil }
                let average = Double(bucket.reduce(0) { $0 + $1.score }) / Double(bucket.count)
                let level: HydrationRiskLevel = average < 35 ? .low : (average < 70 ? .moderate : .high)
                return DisplayScoreHistoryEntry(
                    id: UUID(), score: average, riskLevel: level,
                    firstDate: bucket.first!.date, lastDate: bucket.last!.date,
                    readingCount: bucket.count
                )
            }
        }
    }

    private var visibleMonthLabel: String {
        let calendar = Calendar.current
        let visibleEnd = calendar.date(byAdding: .second, value: Int(visibleDays * 86_400), to: scrollPosition) ?? scrollPosition
        let startParts = calendar.dateComponents([.month, .year], from: scrollPosition)
        let endParts = calendar.dateComponents([.month, .year], from: visibleEnd)
        if startParts.month == endParts.month && startParts.year == endParts.year {
            return scrollPosition.formatted(.dateTime.month(.wide).year())
        }

        let startMonth = scrollPosition.formatted(.dateTime.month(.wide))
        let endMonth = visibleEnd.formatted(.dateTime.month(.wide))
        if startParts.year == endParts.year, let year = startParts.year {
            return "\(startMonth) – \(endMonth) \(year)"
        }
        return "\(scrollPosition.formatted(.dateTime.month(.wide).year())) – \(visibleEnd.formatted(.dateTime.month(.wide).year()))"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("YOUR TRENDS")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.blue)
                    Text("History")
                        .font(.largeTitle.weight(.bold))
                    Text("A clearer look at your hydration risk over time.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 62)

                if let latest = displayedEntries.last {
                    HStack(spacing: 12) {
                        summaryCard(
                            title: aggregationLevel == .all ? "LATEST SCORE" : "LATEST AVERAGE",
                            value: latest.score.formatted(.number.precision(.fractionLength(aggregationLevel == .all ? 0 : 1))),
                            detail: latest.riskLevel.rawValue.capitalized,
                            tint: color(for: latest.riskLevel),
                            symbol: "waveform.path.ecg"
                        )
                        summaryCard(
                            title: "DATA POINTS",
                            value: displayedEntries.count.formatted(),
                            detail: aggregationLevel.rawValue,
                            tint: .blue,
                            symbol: "chart.xyaxis.line"
                        )
                    }
                }

                if filteredEntries.isEmpty {
                    ContentUnavailableView(
                        "No history yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Scores in the selected date range will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Risk score trend")
                                    .font(.headline)
                                Text(aggregationLevel.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                zoomButton("Zoom out", systemImage: "minus.magnifyingglass", factor: 1.5)
                                zoomButton("Zoom in", systemImage: "plus.magnifyingglass", factor: 1 / 1.5)
                            }
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "calendar")
                                .font(.subheadline.weight(.semibold))
                            Text(visibleMonthLabel)
                                .font(.subheadline.weight(.semibold))
                                .contentTransition(.numericText())
                            Spacer()
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                        Chart {
                            ForEach(displayedEntries) { entry in
                                LineMark(
                                    x: .value("Date", entry.lastDate),
                                    y: .value("Score", entry.score)
                                )
                                .foregroundStyle(Color.blue.gradient)
                                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                                PointMark(
                                    x: .value("Date", entry.lastDate),
                                    y: .value("Score", entry.score)
                                )
                                .foregroundStyle(color(for: entry.riskLevel))
                                .symbolSize(aggregationLevel == .all ? 20 : 48)
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                                AxisTick().foregroundStyle(.secondary.opacity(0.4))
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: [0, 25, 50, 75, 100]) { _ in
                                AxisGridLine().foregroundStyle(.secondary.opacity(0.14))
                                AxisValueLabel().font(.caption2)
                            }
                        }
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: visibleDays * 86_400)
                        .chartScrollPosition(x: $scrollPosition)
                        .frame(height: verticalSizeClass == .compact ? 240 : 330)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    visibleDays = min(365, max(14, initialVisibleDays / Double(value.magnification)))
                                }
                                .onEnded { _ in initialVisibleDays = visibleDays }
                        )

                        HStack(spacing: 14) {
                            riskLegend("Low", tint: .green)
                            riskLegend("Moderate", tint: .orange)
                            riskLegend("High", tint: .red)
                            Spacer(minLength: 0)
                        }

                        Text("Swipe to browse · Pinch or use the zoom buttons")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("Recent history")
                            .font(.title3.weight(.bold))
                        Spacer()
                        Text("\(displayedEntries.count) periods")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)

                    LazyVStack(spacing: 9) {
                        ForEach(displayedEntries.reversed()) { entry in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(color(for: entry.riskLevel))
                                    .frame(width: 5, height: 42)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(aggregationLevel == .all
                                         ? "Score \(Int(entry.score.rounded()))"
                                         : "Average \(entry.score.formatted(.number.precision(.fractionLength(1))))")
                                        .font(.subheadline.weight(.semibold))
                                    HStack(spacing: 5) {
                                        Text(entry.riskLevel.rawValue.capitalized)
                                        if entry.readingCount > 1 {
                                            Text("· \(entry.readingCount) readings")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(entry.firstDate.formatted(date: .abbreviated, time: .omitted))
                                    if !Calendar.current.isDate(entry.firstDate, inSameDayAs: entry.lastDate) {
                                        Text("to \(entry.lastDate.formatted(date: .abbreviated, time: .omitted))")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: aggregationLevel) { _, _ in
            visibleDays = 90
            initialVisibleDays = 90
            scrollPosition = Date()
        }
    }

    private func summaryCard(title: String, value: String, detail: String, tint: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
        }
    }

    private func zoomButton(_ label: String, systemImage: String, factor: Double) -> some View {
        Button {
            visibleDays = min(365, max(14, visibleDays * factor))
            initialVisibleDays = visibleDays
        } label: {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(.background.opacity(0.85), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private func riskLegend(_ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func color(for level: HydrationRiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .moderate: return .orange
        case .high: return .red
        }
    }
}

// MARK: - Supporting Views

private struct SettingsSheet: View {
    @Binding var showSettings: Bool
    @Binding var statusText: String
    @Binding var useSimulator: Bool
    @Binding var showResetConfirm: Bool
    @Binding var historyRangeRawValue: String
    @Binding var aggregationLevelRawValue: String

    let onShowCSV: () -> Void
    let onCheckCSV: () -> Void
    let onTestNotification: () -> Void
    let onBuildBaseline: () -> Void
    let onReadHealthKit: () -> Void
    let onBackfillHistory: () -> Void
    let onResetBaseline: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Mode") {
                    Toggle("Use Simulator", isOn: $useSimulator)
                    Text(useSimulator ? "Simulator readings are shown on the Current tab." : "Current readings come from HealthKit.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("History") {
                    Picker("Show history from", selection: $historyRangeRawValue) {
                        ForEach(HistoryRange.allCases) { range in
                            Text(range.rawValue).tag(range.rawValue)
                        }
                    }
                    Picker("Show", selection: $aggregationLevelRawValue) {
                        ForEach(AggregationLevel.allCases) { level in
                            Text(level.rawValue).tag(level.rawValue)
                        }
                    }
                    Text("Repeated consecutive scores are combined in All Entries. Daily and weekly views show averages.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Data") {
                    Button("Show Training CSV Path") { onShowCSV() }
                    Button("Check CSV Exists") { onCheckCSV() }
                }

                Section("Notifications") {
                    Button("Test Notification (score 99)") { onTestNotification() }
                }

                Section("Important") {
                    Button("Build Baseline from HealthKit (Last 14 Days)", action: onBuildBaseline)
                    Button("Read HealthKit (Real) → Score", action: onReadHealthKit)
                    Button("Force Backfill Risk Score History", action: onBackfillHistory)
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Text("Reset Baseline")
                    }
                }

                Section {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettings = false }
                }
            }
            .confirmationDialog(
                "Reset baseline?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset Baseline", role: .destructive) {
                    onResetBaseline()
                    showSettings = false
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This clears your saved baseline and start date.")
            }
        }
    }

}

private struct Card<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.25), lineWidth: 1)
        )
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.85 : 1.0)
            )
            .scaleEffect(configuration.isPressed ? 0.99 : 1.0)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

private struct RiskBadge: View {
    let level: HydrationRiskLevel
    let score: Int

    var body: some View {
        let (color, label): (Color, String) = {
            switch level {
            case .low: return (.green, "Low")
            case .moderate: return (.orange, "Moderate")
            case .high: return (.red, "High")
            }
        }()

        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                Text("HYDRATION")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text("RISK")
                    .font(.caption.weight(.bold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            ZStack {
                Circle()
                    .stroke(color.opacity(0.14), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 36, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 116, height: 116)
            .accessibilityLabel("Risk score \(score) out of 100")

            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
                Text("OUT OF 100")
                    .font(.caption2.weight(.bold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
    }
}
