//
//  ContentView.swift
//  LemonWhisper
//
//  Created by Jeffry Cacho on 24.07.25.
//


import SwiftUI

struct ContentView: View {
    @EnvironmentObject var whisperManager: WhisperManager
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        VStack {
            Text("Lemon Whisper")
                .font(.largeTitle)

            Button(action: {
                toggleRecording()
            }) {
                Text(whisperManager.isRecording ? "Stop Recording" : "Start Recording")
            }

            Text(whisperManager.transcription)
                .padding()
        }
        .padding()
        .onAppear(perform: setupHotkey)
        .alert(isPresented: $whisperManager.showAlert) {
            Alert(title: Text("Error"), message: Text(whisperManager.alertMessage), dismissButton: .default(Text("OK")))
        }
    }

    private func setupHotkey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            // Cmd + Shift + Space
            if event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift) && event.keyCode == 49 {
                toggleRecording()
            }
        }
    }

    private func toggleRecording() {
        if whisperManager.isRecording {
            if appSettings.transcriptionMode == .base {
                whisperManager.stopRecording()
            } else {
                whisperManager.stopLiveRecording()
            }
        } else {
            if appSettings.transcriptionMode == .base {
                whisperManager.startRecording()
            } else {
                whisperManager.startLiveRecording()
            }
        }
    }
}

