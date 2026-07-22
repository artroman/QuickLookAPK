//
//  QuickLookAPKApp.swift
//  QuickLookAPK
//
//  Created by Roman on 7. 7. 2026..
//

import SwiftUI
import AppKit

@main
struct QuickLookAPKApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
