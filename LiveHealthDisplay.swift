//
//  LiveHealthDisplay.swift
//  Real Hydrasense
//

import Foundation

/// Published vitals for SwiftUI — updates here always re-render bound views.
@MainActor
final class LiveHealthDisplay: ObservableObject {
    @Published private(set) var heartRateBPM: Int?
    @Published private(set) var sampleTimestamp: Date?
    @Published private(set) var sampleAgeSec: Int = 0
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var pollCount: Int = 0
    @Published private(set) var phoneSource: String?
    @Published var syncHint: String?

    func recordPoll() {
        pollCount += 1
        lastRefreshAt = Date()
    }

    func apply(heartRate: Double, timestamp: Date, source: String?) {
        heartRateBPM = Int(heartRate.rounded())
        sampleTimestamp = timestamp
        sampleAgeSec = Int(Date().timeIntervalSince(timestamp))
        phoneSource = source
        if sampleAgeSec > 120 {
            syncHint = "iPhone Health is \(sampleAgeSec)s behind your Watch. Open the Health app, then return here."
        } else {
            syncHint = nil
        }
    }

    func apply(sample: VitalSample, source: String?) {
        apply(heartRate: sample.heartRateBPM, timestamp: sample.timestamp, source: source)
    }
}
