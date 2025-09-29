//
//  Air_VolumeApp.swift
//  Air Volume
//
//  Created by Francesco on 28/09/25.
//

import SwiftUI

@main
struct Air_VolumeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appDelegate.windowCoordinator)
        }
        .defaultSize(width: 420, height: 520)
    }
}
