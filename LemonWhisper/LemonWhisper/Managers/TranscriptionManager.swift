import Foundation
import AVFoundation
import Carbon
import AppKit
import ApplicationServices

class TranscriptionManager {
    static let shared = TranscriptionManager()

    func transcribe(
        buffer: AVAudioPCMBuffer,
        language: String = "en",
        prompt: String? = nil,
        isLiveMode: Bool = false,
        completion: @escaping (String) -> Void
    ) {
        Task {
            do {
                let tempURL = try FileManager.default.writeBufferToWav(buffer)
                let file = try AVAudioFile(forReading: tempURL)
                let totalFrames = Int(file.length)
                guard
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(totalFrames))
                else { throw NSError(domain: "BufferFail", code: -1) }
                try file.read(into: buffer)

                guard let floatData = buffer.floatChannelData else { throw NSError(domain: "NoData", code: -2) }
                let channelPtr = floatData[0]
                let sampleCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelPtr, count: sampleCount))

                guard let ctx = WhisperContext.getShared() else {
                    print("❌ Whisper context not initialized")
                    completion("Transcription failed.")
                    return
                }

                let ok = await ctx.fullTranscribe(
                    samples: samples,
                    language: language,
                    prompt: prompt,
                    isLiveMode: isLiveMode
                )
                let result = ok ? await ctx.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines) : "Transcription failed."
                completion(result)
            } catch {
                print("❌ Error during transcription: \(error)")
                completion("Transcription failed.")
            }
        }
    }

    func transcribe(
        from url: URL,
        language: String = "en",
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?
    ) {
        Task {
            do {
                let file = try AVAudioFile(forReading: url)
                let totalFrames = Int(file.length)
                guard
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(totalFrames))
                else { throw NSError(domain: "BufferFail", code: -1) }
                try file.read(into: buffer)

                // Down‑mix to mono if needed
                guard let floatData = buffer.floatChannelData else { throw NSError(domain: "NoData", code: -2) }
                let channelPtr = floatData[0]   // assuming mono
                let sampleCount = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelPtr, count: sampleCount))

                guard let ctx = WhisperContext.getShared() else {
                    print("❌ Whisper context not initialized")
                    return
                }

                let ok = await ctx.fullTranscribe(
                    samples: samples,
                    language: language,
                    prompt: nil,
                    isLiveMode: false
                )
                let result = ok ? await ctx.getTranscription().trimmingCharacters(in: .whitespacesAndNewlines) : "Transcription failed."
                copyAndPaste(
                    result,
                    targetBundleIdentifier: targetBundleIdentifier,
                    targetProcessID: targetProcessID
                )

            } catch {
                print("❌ Error during transcription: \(error)")
            }
        }
    }

    func copyAndPaste(
        _ text: String,
        targetBundleIdentifier: String?,
        targetProcessID: pid_t?
    ) {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sanitized, forType: .string)
        print("📋 Copied \(sanitized.count) chars to clipboard")

        let focused = focusTargetApp(bundleIdentifier: targetBundleIdentifier, processID: targetProcessID)
        print("🎯 Focus target result: \(focused)")
        Thread.sleep(forTimeInterval: 0.20)

        if insertTextViaAccessibility(sanitized) {
            print("✅ Paste path: Accessibility text insertion")
            return
        }

        if postCommandV(tap: .cghidEventTap) {
            print("✅ Paste path: CGEvent cghidEventTap")
            return
        }
        if postCommandV(tap: .cgAnnotatedSessionEventTap) {
            print("✅ Paste path: CGEvent cgAnnotatedSessionEventTap")
            return
        }

        if pasteWithAppleScript() {
            print("✅ Paste path: AppleScript System Events")
            return
        }

        print("❌ All paste paths failed")
    }

    private func focusTargetApp(bundleIdentifier: String?, processID: pid_t?) -> Bool {
        if let processID,
           let app = NSRunningApplication(processIdentifier: processID) {
            return app.activate()
        }

        if let bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            return app.activate()
        }
        return false
    }

    private func postCommandV(tap: CGEventTapLocation) -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            print("⚠️ CGEvent source unavailable")
            return false
        }
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false) else {
            print("⚠️ Failed to create CGEvents")
            return false
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdDown.post(tap: tap)
        vDown.post(tap: tap)
        vUp.post(tap: tap)
        cmdUp.post(tap: tap)
        return true
    }

    private func pasteWithAppleScript() -> Bool {
        let scriptSource = """
        tell application "System Events"
            keystroke "v" using {command down}
        end tell
        """
        guard let script = NSAppleScript(source: scriptSource) else { return false }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            print("⚠️ AppleScript paste failed: \(errorInfo)")
            return false
        }
        return true
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            print("⚠️ Accessibility not trusted for AX text insertion")
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedResult == .success, let focusedObject else {
            print("⚠️ Could not get focused AX element (\(focusedResult.rawValue))")
            return false
        }

        let focusedElement = focusedObject as! AXUIElement

        var settable = DarwinBoolean(false)
        let selectedTextSettableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        )
        if selectedTextSettableResult == .success && settable.boolValue {
            let selectedTextResult = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if selectedTextResult == .success {
                return true
            }
            print("⚠️ AX selected text set failed (\(selectedTextResult.rawValue))")
        }

        settable = DarwinBoolean(false)
        let valueSettableResult = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &settable
        )
        if valueSettableResult == .success && settable.boolValue {
            let valueResult = AXUIElementSetAttributeValue(
                focusedElement,
                kAXValueAttribute as CFString,
                text as CFTypeRef
            )
            if valueResult == .success {
                return true
            }
            print("⚠️ AX value set failed (\(valueResult.rawValue))")
        }

        return false
    }
}
