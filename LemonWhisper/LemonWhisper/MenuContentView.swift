
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var appSettings: AppSettings

    var body: some View {
        VStack {
            Picker("Transcription Mode", selection: $appSettings.transcriptionMode) {
                ForEach(TranscriptionMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(MenuPickerStyle())

            Picker("Language", selection: $appSettings.language) {
                Text("Auto").tag("auto")
                Text("English").tag("en")
                Text("Spanish").tag("es")
                Text("German").tag("de")
                // Add more languages as needed
            }
            .pickerStyle(MenuPickerStyle())

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
    }
}
