//
//  Real_HydrasenseApp.swift
//  Real Hydrasense
//

import SwiftUI

@main
struct Real_HydrasenseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NotificationManager.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
