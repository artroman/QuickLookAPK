//
//  ContentView.swift
//  QuickLookAPK
//
//  Created by Roman on 7. 7. 2026.
//

import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            
            Text("QuickLook APK")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Preview and thumbnail Android .apk files in Finder and Quick Look.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                openExtensionsSettings()
            } label: {
                Label("Open Extensions Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 260)
    }
    
    /// Opens System Settings to the Extensions pane, where the Quick Look
    /// preview and thumbnail extensions can be enabled.
    private func openExtensionsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}
