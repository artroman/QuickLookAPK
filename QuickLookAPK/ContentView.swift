//
//  ContentView.swift
//  QuickLookAPK
//
//  Created by Roman on 7. 7. 2026.
//

import SwiftUI
import AppKit

struct ContentView: View {
    /// Language pre-selected in the preview's dropdown of localized app names;
    /// "" means the system language. Shared with the preview extension.
    @AppStorage(LabelLanguageSettings.key, store: LabelLanguageSettings.defaults)
    private var labelLanguage = ""

    /// Two-letter ISO 639-1 languages, sorted by their name in the current locale.
    private let languages: [(code: String, name: String)] = Locale.isoLanguageCodes
        .filter { $0.count == 2 }
        .compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { (code, $0.localizedCapitalized) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Picker("App name language:", selection: $labelLanguage) {
                    Text("Same as System").tag("")
                    Divider()
                    ForEach(languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .fixedSize()

                Text("Selected in the preview's list of localized app names. Regional variants count too, e.g. \"pt\" also matches pt-BR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
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
