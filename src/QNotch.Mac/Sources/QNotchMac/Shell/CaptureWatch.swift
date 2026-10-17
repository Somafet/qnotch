import AppKit
import CoreAudio
import CoreMediaIO
import QNotchMacCore

/// Shared microphone and camera watcher (Windows Core/CaptureWatch), used by the Mic and camera
/// module and, later, by features that keep quiet during calls. It starts with the first
/// observer and stops with the last. Property listeners only; no timer:
/// - CoreAudio `DeviceIsRunningSomewhere` on every input device (and the device list).
/// - CoreAudio process objects (`IsRunningInput`, macOS 14.2+) name the apps, with listeners
///   attached only while the microphone is in use.
/// - CoreMediaIO `DeviceIsRunningSomewhere` on every camera. Per-app camera use is not public.
final class CaptureWatch {
    private(set) var state = CaptureState()
    private var observers: [ObjectIdentifier: (CaptureState) -> Void] = [:]
    private var running = false
    private(set) var inputDevices: [AudioObjectID] = []
    private var processes: [AudioObjectID] = []
    private(set) var cameras: [CMIOObjectID] = []
    private var pending = false

    private lazy var audioListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRead() }
    private lazy var audioDevicesListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildAudio() }
    private lazy var processListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildProcesses() }
    private lazy var cameraListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRead() }
    private lazy var cameraDevicesListener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuildCameras() }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var devicesAddress = address(kAudioHardwarePropertyDevices)
    private static var runningAddress = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private static var processListAddress = address(kAudioHardwarePropertyProcessObjectList)
    private static var processInputAddress = address(kAudioProcessPropertyIsRunningInput)
    private static var processPIDAddress = address(kAudioProcessPropertyPID)
    private static var processBundleAddress = address(kAudioProcessPropertyBundleID)
    private static var inputStreamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    private static var cameraDevicesAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private static var cameraRunningAddress = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func observe(_ owner: AnyObject, _ handler: @escaping (CaptureState) -> Void) {
        observers[ObjectIdentifier(owner)] = handler
        if !running { start() }
        handler(state)
    }

    func remove(_ owner: AnyObject) {
        observers[ObjectIdentifier(owner)] = nil
        if observers.isEmpty { stop() }
    }

    deinit { stop() }

    private func start() {
        running = true
        AudioObjectAddPropertyListenerBlock(Self.system, &Self.devicesAddress, .main, audioDevicesListener)
        CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraDevicesAddress, .main, cameraDevicesListener)
        rebuildAudio()
        rebuildCameras()
    }

    private func stop() {
        guard running else { return }
        running = false
        AudioObjectRemovePropertyListenerBlock(Self.system, &Self.devicesAddress, .main, audioDevicesListener)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &Self.cameraDevicesAddress, .main, cameraDevicesListener)
        setInputDevices([])
        setProcesses([], watchingList: false)
        setCameras([])
        state = CaptureState()
    }

    // MARK: Device lists

    private func rebuildAudio() {
        guard running else { return }
        let devices: [AudioObjectID] = Self.audioArray(Self.system, &Self.devicesAddress).filter { device in
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &Self.inputStreamsAddress, 0, nil, &size) == noErr && size > 0
        }
        setInputDevices(devices)
        scheduleRead()
    }

    private func setInputDevices(_ devices: [AudioObjectID]) {
        for device in inputDevices where !devices.contains(device) { AudioObjectRemovePropertyListenerBlock(device, &Self.runningAddress, .main, audioListener) }
        for device in devices where !inputDevices.contains(device) { AudioObjectAddPropertyListenerBlock(device, &Self.runningAddress, .main, audioListener) }
        inputDevices = devices
    }

    private var watchingProcessList = false
    private func rebuildProcesses() {
        guard running, watchingProcessList else { return }
        setProcesses(Self.audioArray(Self.system, &Self.processListAddress), watchingList: true)
        scheduleRead()
    }

    private func setProcesses(_ list: [AudioObjectID], watchingList: Bool) {
        if watchingList != watchingProcessList {
            if watchingList { AudioObjectAddPropertyListenerBlock(Self.system, &Self.processListAddress, .main, processListListener) }
            else { AudioObjectRemovePropertyListenerBlock(Self.system, &Self.processListAddress, .main, processListListener) }
            watchingProcessList = watchingList
        }
        for process in processes where !list.contains(process) { AudioObjectRemovePropertyListenerBlock(process, &Self.processInputAddress, .main, audioListener) }
        for process in list where !processes.contains(process) { AudioObjectAddPropertyListenerBlock(process, &Self.processInputAddress, .main, audioListener) }
        processes = list
    }

    private func rebuildCameras() {
        guard running else { return }
        setCameras(Self.cameraArray())
        scheduleRead()
    }

    private func setCameras(_ list: [CMIOObjectID]) {
        for camera in cameras where !list.contains(camera) { CMIOObjectRemovePropertyListenerBlock(camera, &Self.cameraRunningAddress, .main, cameraListener) }
        for camera in list where !cameras.contains(camera) { CMIOObjectAddPropertyListenerBlock(camera, &Self.cameraRunningAddress, .main, cameraListener) }
        cameras = list
    }

    // MARK: Reading

    /// Listener bursts (several properties flip together) coalesce into one read.
    private func scheduleRead() {
        guard running, !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.read()
        }
    }

    private func read() {
        guard running else { return }
        var next = CaptureState()
        next.microphone = inputDevices.contains { Self.audioFlag($0, &Self.runningAddress) }
        // Per-app attribution exists on macOS 14.2+; older systems simply report no process list.
        let attributable = AudioObjectHasProperty(Self.system, &Self.processListAddress)
        if next.microphone, attributable {
            if !watchingProcessList { setProcesses(Self.audioArray(Self.system, &Self.processListAddress), watchingList: true) }
            next.microphoneApps = processes.filter { Self.audioFlag($0, &Self.processInputAddress) }.compactMap(Self.appName)
        } else if watchingProcessList || !processes.isEmpty {
            setProcesses([], watchingList: false)
        }
        next.camera = cameras.contains { camera in
            var value: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(camera, &Self.cameraRunningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr && value != 0
        }
        guard next != state else { return }
        state = next
        observers.values.forEach { $0(next) }
    }

    private static func appName(_ process: AudioObjectID) -> String? {
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        if AudioObjectGetPropertyData(process, &processPIDAddress, 0, nil, &size, &pid) == noErr, pid != getpid(),
           let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        // Helpers without an app (e.g. a browser's audio service) fall back to their bundle ID's last part.
        var bundle: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &processBundleAddress, 0, nil, &size, &bundle) == noErr,
              let id = bundle?.takeRetainedValue() as String?, !id.isEmpty, !id.hasPrefix("com.apple.") || id.hasPrefix("com.apple.Safari") || id.hasPrefix("com.apple.FaceTime") else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id.split(separator: ".").last.map(String.init)
    }

    private static func audioFlag(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func audioArray(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> [AudioObjectID] {
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func cameraArray() -> [CMIOObjectID] {
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &cameraDevicesAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &cameraDevicesAddress, 0, nil, size, &used, &items) == noErr else { return [] }
        return Array(items.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }
}
