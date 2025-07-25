//
//  LemonWhisperApp.swift
//  LemonWhisper
//
//  Created by Jeffry Cacho on 24.07.25.
//

import SwiftUI

@main
struct LemonWhisperApp: App {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var whisperManager = WhisperManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(appSettings)
                .environmentObject(whisperManager)
        } label: {
            Text(whisperManager.isRecording ? "📝" : "🍋")
        }
    }
}
