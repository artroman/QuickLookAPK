//
//  LabelLanguageSettings.swift
//  QuickLookAPK
//
//  The language whose app name the preview's name dropdown pre-selects. Set in the
//  main app and read by the preview extension through their shared App Group.
//

import Foundation

enum LabelLanguageSettings {
    /// App Group shared by the app and the preview extension. On macOS a group
    /// prefixed with the team ID needs no provisioning profile.
    static let appGroup = "XNAZEWFH6C.ru.artroman.QuickLookAPK"
    static let key = "labelLanguage"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    /// ISO 639 language code (e.g. "ru"), or nil when none is chosen.
    static var language: String? {
        guard let value = defaults?.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }
}
