import AppKit
import AVFoundation
import CoreAudio

/// Reads activity metadata only. It never opens a capture session, reads window
/// titles, requests camera access, or takes audio samples.
@MainActor
enum MeetingActivityMonitor {
    static var microphoneDetectionAvailable: Bool {
        if #available(macOS 14.2, *) { return true }; return false
    }

    static func sample(excluded: Set<String>) -> MeetingActivity {
        var apps: [MeetingApp] = []
        if #available(macOS 14.2, *) {
            let running = NSWorkspace.shared.runningApplications
            for object in processObjects() {
                guard uint(object, kAudioProcessPropertyIsRunningInput) == 1,
                      let pid = uint(object, kAudioProcessPropertyPID), pid != UInt32(ProcessInfo.processInfo.processIdentifier) else { continue }
                let process = NSRunningApplication(processIdentifier: pid_t(pid))
                guard let raw = string(object, kAudioProcessPropertyBundleID) ?? process?.bundleIdentifier else { continue }
                // Chromium and meeting apps often capture in a child helper.
                let app = running.filter { candidate in
                    guard let bundle = candidate.bundleIdentifier else { return false }
                    return raw == bundle || raw.hasPrefix(bundle + ".")
                }.min { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) } ?? process
                let bundle = app?.bundleIdentifier ?? raw
                let ignored = [Bundle.main.bundleIdentifier ?? "com.wolfieeee.heynotch", "com.apple.Siri", "com.apple.assistant", "com.apple.VoiceMemos", "com.apple.SpeechRecognitionCore"]
                guard !excluded.contains(bundle), !ignored.contains(where: { bundle.hasPrefix($0) }) else { continue }
                apps.append(MeetingApp(id: bundle, name: app?.localizedName ?? bundle))
            }
        }
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
        let cameraActive = !WebcamManager.shared.isSessionRunning && cameras.contains { $0.isConnected && $0.isInUseByAnotherApplication }
        return MeetingActivity(microphoneApps: Array(Set(apps)).sorted { $0.name < $1.name }, cameraInUse: cameraActive)
    }

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }
    private static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let pointer = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: 1)
        pointer.initialize(to: nil); defer { pointer.deinitialize(count: 1); pointer.deallocate() }
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee?.takeRetainedValue() as String?
    }
}
