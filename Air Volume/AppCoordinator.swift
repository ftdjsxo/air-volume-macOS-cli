//
//  AppCoordinator.swift
//  Air Volume
//
//  Created by Codex on behalf of Francesco.
//

import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    let windowCoordinator = MainWindowCoordinator()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory policy keeps the app out of the Dock while retaining status-item interaction
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Air Volume")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Mostra Air Volume", action: #selector(showWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Esci", action: #selector(terminate), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func showWindow() {
        windowCoordinator.showWindow()
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class MainWindowCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let objectWillChange = ObservableObjectPublisher()
    private weak var window: NSWindow?
    private let windowIdentifier = NSUserInterfaceItemIdentifier("AirVolumeMainWindow")
    private var openWindowAction: OpenWindowAction?

    func register(openWindow action: OpenWindowAction) {
        openWindowAction = action
    }

    func captureCurrentWindow() {
        guard let candidate = NSApp.keyWindow ?? findWindow() else { return }
        attach(to: candidate)
    }

    func showWindow() {
        DispatchQueue.main.async {
            if let window = self.window ?? self.findWindow() {
                self.attach(to: window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else if let action = self.openWindowAction {
                action(id: "main")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.captureCurrentWindow()
                }
            }
        }
    }

    private func findWindow() -> NSWindow? {
        if let window = window { return window }
        return NSApp.windows.first { $0.identifier == windowIdentifier }
    }

    private func attach(to window: NSWindow) {
        if self.window !== window {
            self.window = window
        }
        window.identifier = windowIdentifier
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.fullScreenAuxiliary)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of terminating: window can be reopened from the status-item menu
        sender.orderOut(nil)
        return false
    }
}
