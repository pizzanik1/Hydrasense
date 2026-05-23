//
//  AppDelegate.swift
//  Real Hydrasense
//

import UIKit

extension Notification.Name {
    static let hydrasenseHealthKitUpdate = Notification.Name("hydrasense.healthkit.update")
    static let hydrasenseAppBecameActive = Notification.Name("hydrasense.app.becameActive")
}

/// HealthKit background delivery wakes the app via `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func applicationDidBecomeActive(_ application: UIApplication) {
        NotificationCenter.default.post(name: .hydrasenseAppBecameActive, object: nil)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        NotificationCenter.default.post(name: .hydrasenseHealthKitUpdate, object: nil)
        completionHandler(.newData)
    }
}
