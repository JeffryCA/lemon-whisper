import AVFoundation
import CoreAudio

/// Lists available microphones and, for the duration of a recording, temporarily points the
/// system default input device at the user's selected microphone (restoring it afterwards).
///
/// `AVAudioRecorder` always records from the system default input device, so there is no
/// per-recorder device parameter to set — this is the standard workaround short of moving the
/// whole capture pipeline to `AVAudioEngine`.
enum MicrophoneManager {
    private static var savedDefaultInputDeviceID: AudioDeviceID?

    static func availableDevices() -> [MicrophoneDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices.map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Call before starting a recording. Pass `nil` to leave the system default untouched.
    static func applySelectedInputDeviceIfNeeded(uniqueID: String?) {
        guard let uniqueID, let targetDeviceID = coreAudioDeviceID(forUniqueID: uniqueID) else { return }
        guard let currentDeviceID = defaultInputDeviceID(), currentDeviceID != targetDeviceID else { return }

        savedDefaultInputDeviceID = currentDeviceID
        setDefaultInputDevice(targetDeviceID)
    }

    /// Call after stopping/cancelling a recording to undo any temporary device switch.
    static func restorePreviousInputDeviceIfNeeded() {
        guard let savedDefaultInputDeviceID else { return }
        setDefaultInputDevice(savedDefaultInputDeviceID)
        self.savedDefaultInputDeviceID = nil
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var mutableDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs
    }

    private static func uniqueID(forCoreAudioDeviceID deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return uid as String?
    }

    private static func coreAudioDeviceID(forUniqueID targetUniqueID: String) -> AudioDeviceID? {
        allDeviceIDs().first { uniqueID(forCoreAudioDeviceID: $0) == targetUniqueID }
    }
}
