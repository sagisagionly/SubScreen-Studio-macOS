import AppKit
import SwiftUI

final class StudioAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NowPlayingMonitor.shared.clearTransientMedia()
        AudioLevelMonitor.shared.stop()
        CodexBridgeMonitor.shared.stop()
        PSUMonitor.shared.stop()
    }
}

@main
struct SubScreenStudioApp: App {
    @NSApplicationDelegateAdaptor(StudioAppDelegate.self) private var appDelegate
    @StateObject private var store = StudioStore()

    var body: some Scene {
        WindowGroup {
            StudioView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Scene") { store.addScene() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Add Clock") { store.addLayer(.clock) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Add Weather") { store.addLayer(.weather) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Add Codex Usage") { store.addLayer(.codex) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { store.save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            CommandMenu("Arrange") {
                Button("Move Left 1 px") { store.nudgeSelected(dx: -1, dy: 0) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option])
                Button("Move Right 1 px") { store.nudgeSelected(dx: 1, dy: 0) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option])
                Button("Move Up 1 px") { store.nudgeSelected(dx: 0, dy: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option])
                Button("Move Down 1 px") { store.nudgeSelected(dx: 0, dy: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option])
                Divider()
                Button("Move Left 10 px") { store.nudgeSelected(dx: -10, dy: 0) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .shift])
                Button("Move Right 10 px") { store.nudgeSelected(dx: 10, dy: 0) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .shift])
                Button("Move Up 10 px") { store.nudgeSelected(dx: 0, dy: -10) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Move Down 10 px") { store.nudgeSelected(dx: 0, dy: 10) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            }
        }
    }
}
