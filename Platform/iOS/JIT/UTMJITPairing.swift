//
// Copyright © 2026 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#if os(iOS) && WITH_JIT
import BackgroundTasks
import Darwin
import dnssd
import Foundation
import UIKit
import UserNotifications

/// Dynamic C-ABI bridge into `StikJIT.framework` for on-device pairing.
///
/// `StikJIT.framework` targets iOS 17.4+, whereas UTM's main iOS target sets
/// deployment target 15.0. Loading the already-embedded framework via `dlopen`
/// at runtime avoids a Swift module deployment-target mismatch while keeping
/// pairing lifecycle (background task + notifications) inside the main UTM app.
private final class StikJITPairingBridge: @unchecked Sendable {
    typealias PinCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    typealias PrepareFn = @convention(c) (
        UnsafePointer<CChar>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        UnsafeMutablePointer<Int>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> UnsafeMutableRawPointer?
    typealias AcceptFDFn = @convention(c) (
        UnsafeMutableRawPointer,
        Int32,
        PinCallback?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        UnsafeMutablePointer<Int>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    ) -> Int32
    typealias FreeHostFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias FreeBufferFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    struct PreparedHost {
        let handle: UnsafeMutableRawPointer
        let serviceName: String
        let txtRecords: [String: Data]
    }

    struct PairingResult {
        let pairingData: Data
        let deviceName: String?
    }

    private let prepareFn: PrepareFn
    private let acceptFDFn: AcceptFDFn
    private let freeHostFn: FreeHostFn
    private let freeBufferFn: FreeBufferFn

    static func load() throws -> StikJITPairingBridge {
        #if targetEnvironment(simulator)
        throw NSError(domain: "UTMJITPairing", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "On-device pairing is unavailable in the iOS Simulator."
        ])
        #else
        guard let frameworksURL = Bundle.main.privateFrameworksURL else {
            throw NSError(domain: "UTMJITPairing", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "UTM Frameworks directory was not found."
            ])
        }
        let dylibURL = frameworksURL
            .appendingPathComponent("StikJIT.framework", isDirectory: true)
            .appendingPathComponent("StikJIT", isDirectory: false)
        guard FileManager.default.fileExists(atPath: dylibURL.path),
              let handle = dlopen(dylibURL.path, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "StikJIT.framework could not be loaded."
            throw NSError(domain: "UTMJITPairing", code: 3, userInfo: [
                NSLocalizedDescriptionKey: reason
            ])
        }
        guard let pSym = dlsym(handle, "stikjit_pairable_host_prepare"),
              let aSym = dlsym(handle, "stikjit_pairable_host_accept_fd"),
              let fhSym = dlsym(handle, "stikjit_pairable_host_free"),
              let fbSym = dlsym(handle, "stikjit_buffer_free") else {
            throw NSError(domain: "UTMJITPairing", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Embedded StikJIT.framework is missing on-device pairing symbols."
            ])
        }
        return StikJITPairingBridge(
            prepareFn: unsafeBitCast(pSym, to: PrepareFn.self),
            acceptFDFn: unsafeBitCast(aSym, to: AcceptFDFn.self),
            freeHostFn: unsafeBitCast(fhSym, to: FreeHostFn.self),
            freeBufferFn: unsafeBitCast(fbSym, to: FreeBufferFn.self)
        )
        #endif
    }

    private init(prepareFn: PrepareFn, acceptFDFn: AcceptFDFn, freeHostFn: FreeHostFn, freeBufferFn: FreeBufferFn) {
        self.prepareFn = prepareFn
        self.acceptFDFn = acceptFDFn
        self.freeHostFn = freeHostFn
        self.freeBufferFn = freeBufferFn
    }

    func prepare(hostName: String) throws -> PreparedHost {
        var serviceNamePtr: UnsafeMutablePointer<CChar>?
        var txtPtr: UnsafeMutablePointer<UInt8>?
        var txtLen: Int = 0
        var errorPtr: UnsafeMutablePointer<CChar>?

        let rawHandle = hostName.withCString { namePtr in
            prepareFn(namePtr, &serviceNamePtr, &txtPtr, &txtLen, &errorPtr)
        }
        defer {
            if let serviceNamePtr { freeBufferFn(serviceNamePtr) }
            if let txtPtr { freeBufferFn(txtPtr) }
            if let errorPtr { freeBufferFn(errorPtr) }
        }

        guard let rawHandle, let serviceNamePtr else {
            let message = errorPtr.map { String(cString: $0) } ?? "Failed to initialize pairing host."
            throw NSError(domain: "UTMJITPairing", code: 5, userInfo: [NSLocalizedDescriptionKey: message])
        }

        var parsedRecords: [String: Data] = [:]
        if let txtPtr, txtLen > 0 {
            let plistData = Data(bytes: txtPtr, count: txtLen)
            if let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                for (key, value) in plist {
                    if let s = value as? String, let d = s.data(using: .utf8) {
                        parsedRecords[key] = d
                    } else if let d = value as? Data {
                        parsedRecords[key] = d
                    }
                }
            }
        }

        return PreparedHost(
            handle: rawHandle,
            serviceName: String(cString: serviceNamePtr),
            txtRecords: parsedRecords
        )
    }

    func accept(handle: UnsafeMutableRawPointer, fileDescriptor: Int32, onPin: @escaping (String) -> Void) throws -> PairingResult {
        final class PinBox {
            let onPin: (String) -> Void
            init(_ onPin: @escaping (String) -> Void) { self.onPin = onPin }
        }

        let box = PinBox(onPin)
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()
        var bytesPtr: UnsafeMutablePointer<UInt8>?
        var bytesLen: Int = 0
        var devicePtr: UnsafeMutablePointer<CChar>?
        var errorPtr: UnsafeMutablePointer<CChar>?

        let callback: PinCallback = { pinPtr, ctx in
            guard let pinPtr, let ctx else { return }
            let context = Unmanaged<PinBox>.fromOpaque(ctx).takeUnretainedValue()
            context.onPin(String(cString: pinPtr))
        }

        let rc = withExtendedLifetime(box) {
            acceptFDFn(handle, fileDescriptor, callback, boxPtr, &bytesPtr, &bytesLen, &devicePtr, &errorPtr)
        }
        defer {
            if let bytesPtr { freeBufferFn(bytesPtr) }
            if let devicePtr { freeBufferFn(devicePtr) }
            if let errorPtr { freeBufferFn(errorPtr) }
        }

        guard rc == 0, let bytesPtr, bytesLen > 0 else {
            let message = errorPtr.map { String(cString: $0) } ?? "Pairing handshake failed."
            throw NSError(domain: "UTMJITPairing", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }

        return PairingResult(
            pairingData: Data(bytes: bytesPtr, count: bytesLen),
            deviceName: devicePtr.map { String(cString: $0) }
        )
    }

    func freeHost(_ handle: UnsafeMutableRawPointer?) {
        freeHostFn(handle)
    }
}

private final class PairingSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var activeClientFD: Int32 = -1
    private var cancelled = false

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenFD >= 0
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func begin(listenFD: Int32) {
        lock.lock()
        self.listenFD = listenFD
        self.activeClientFD = -1
        self.cancelled = false
        lock.unlock()
    }

    func setClientFD(_ fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            return false
        }
        activeClientFD = fd
        return true
    }

    func closeClientFD() {
        lock.lock()
        let fd = activeClientFD
        activeClientFD = -1
        lock.unlock()
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    func cancelAndCloseAll() {
        lock.lock()
        cancelled = true
        let lfd = listenFD
        let cfd = activeClientFD
        listenFD = -1
        activeClientFD = -1
        lock.unlock()
        if cfd >= 0 { Darwin.close(cfd) }
        if lfd >= 0 { Darwin.close(lfd) }
    }

    func closeAll() {
        lock.lock()
        let lfd = listenFD
        let cfd = activeClientFD
        listenFD = -1
        activeClientFD = -1
        lock.unlock()
        if cfd >= 0 { Darwin.close(cfd) }
        if lfd >= 0 { Darwin.close(lfd) }
    }
}

/// On-device wireless pairing for Built-in StikJIT.
///
/// Advertises `_remotepairing-pairable-host._tcp` via mDNSResponder (`dns_sd`)
/// so the device's Developer Mode settings ("Settings > Privacy & Security >
/// Developer Mode") can pair directly with UTM without a separate computer.
@MainActor
final class UTMJITOnDevicePairing: ObservableObject {
    static let shared = UTMJITOnDevicePairing()

    static let hostName = "UTM"
    static let timeout: TimeInterval = 300

    enum Phase: Equatable {
        case idle
        case waiting
        case pin(String)
        case paired(device: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var backgroundLimited = false

    static var isSupported: Bool {
        UTMJITBuiltIn.isAvailable
    }

    static var deviceKind: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    var isShowingPin: Bool {
        if case .pin = phase { return true }
        return false
    }

    var active: Bool {
        switch phase {
        case .waiting, .pin: return true
        default: return false
        }
    }

    nonisolated private let socketState = PairingSocketState()

    private var registration: DNSServiceRef?
    private var continued: AnyObject?
    private var registeredTaskIdentifier: String?
    private var graceTask: UIBackgroundTaskIdentifier = .invalid
    private var deadlineTimer: Timer?
    private var bridge: StikJITPairingBridge?
    private var rawHostHandle: UnsafeMutableRawPointer?

    private init() {}

    func start() {
        guard Self.isSupported, !active else { return }
        if let reason = UTMJITBuiltIn.unavailableReason {
            phase = .failed(reason)
            return
        }

        let loadedBridge: StikJITPairingBridge
        let prepared: StikJITPairingBridge.PreparedHost
        do {
            loadedBridge = try StikJITPairingBridge.load()
            prepared = try loadedBridge.prepare(hostName: Self.hostName)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        guard let (sockFD, port) = Self.openListeningSocket() else {
            loadedBridge.freeHost(prepared.handle)
            phase = .failed("UTM could not open a local listening socket for pairing.")
            return
        }

        socketState.begin(listenFD: sockFD)

        bridge = loadedBridge
        rawHostHandle = prepared.handle
        phase = .waiting
        backgroundLimited = false
        requestNotifications()

        guard publish(serviceName: prepared.serviceName, txtRecords: prepared.txtRecords, port: port) else {
            socketState.closeAll()
            loadedBridge.freeHost(prepared.handle)
            rawHostHandle = nil
            bridge = nil
            return
        }

        beginBackground()
        deadlineTimer?.invalidate()
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { _ in
            Task { @MainActor in
                UTMJITOnDevicePairing.shared.cancel(
                    reason: "Pairing timed out. Try again when you are ready to pair from Developer Mode Settings."
                )
            }
        }

        let state = socketState
        let hostHandlePtr = UInt(bitPattern: prepared.handle)
        DispatchQueue.global(qos: .userInitiated).async {
            Self.acceptLoop(socketState: state, listenFD: sockFD, bridge: loadedBridge, hostHandleBits: hostHandlePtr)
        }
    }

    func cancel(reason: String? = nil) {
        guard active || socketState.isOpen else { return }
        socketState.cancelAndCloseAll()
        stopAdvertising()
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let bridge, let rawHostHandle {
            bridge.freeHost(rawHostHandle)
        }
        rawHostHandle = nil
        bridge = nil
        phase = reason.map(Phase.failed) ?? .idle
        endBackground(success: false)
    }

    func reset() {
        guard !active else { return }
        phase = .idle
    }

    nonisolated private static func acceptLoop(socketState: PairingSocketState, listenFD: Int32, bridge: StikJITPairingBridge, hostHandleBits: UInt) {
        guard let hostHandle = UnsafeMutableRawPointer(bitPattern: hostHandleBits) else { return }
        while true {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &len)
                }
            }
            if clientFD < 0 {
                if errno == EINTR && !socketState.isCancelled {
                    continue
                }
                if socketState.isCancelled {
                    return
                }
                let errCode = errno
                DispatchQueue.main.async {
                    UTMJITOnDevicePairing.shared.fail("Pairing socket closed unexpectedly (errno \(errCode)).")
                }
                return
            }

            if !socketState.setClientFD(clientFD) {
                Darwin.close(clientFD)
                return
            }

            do {
                let result = try bridge.accept(handle: hostHandle, fileDescriptor: clientFD) { pin in
                    DispatchQueue.main.async {
                        UTMJITOnDevicePairing.shared.showPin(pin)
                    }
                }
                socketState.closeClientFD()
                DispatchQueue.main.async {
                    UTMJITOnDevicePairing.shared.finished(result: .success(result))
                }
                return
            } catch {
                socketState.closeClientFD()
                if socketState.isCancelled {
                    return
                }
                DispatchQueue.main.async {
                    UTMJITOnDevicePairing.shared.finished(result: .failure(error))
                }
                return
            }
        }
    }

    private func finished(result: Result<StikJITPairingBridge.PairingResult, Error>) {
        socketState.closeAll()
        stopAdvertising()
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let bridge, let rawHostHandle {
            bridge.freeHost(rawHostHandle)
        }
        rawHostHandle = nil
        bridge = nil

        switch result {
        case .success(let pairing):
            do {
                try UTMJITCoordinator.shared.storeOnDevicePairing(pairing.pairingData)
                phase = .paired(device: pairing.deviceName ?? "this \(Self.deviceKind)")
                if UIApplication.shared.applicationState != .active {
                    notify("Paired with UTM", body: "Return to UTM to finish enabling Built-in StikJIT.")
                }
                endBackground(success: true)
            } catch {
                fail("Pairing succeeded, but UTM could not save the pairing file: \(error.localizedDescription)")
            }
        case .failure(let err):
            fail("Pairing failed: \(err.localizedDescription)")
        }
    }

    private func showPin(_ pin: String) {
        guard active else { return }
        phase = .pin(pin)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it in Developer Mode to pair with UTM")
            task.progress.completedUnitCount = 1
        }
        #endif
        if UIApplication.shared.applicationState != .active {
            notify("UTM pairing code: \(pin)", body: "Enter this code on your \(Self.deviceKind) to finish pairing.")
        }
    }

    private func fail(_ message: String) {
        guard !socketState.isCancelled else { return }
        socketState.closeAll()
        stopAdvertising()
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let bridge, let rawHostHandle {
            bridge.freeHost(rawHostHandle)
        }
        rawHostHandle = nil
        bridge = nil
        phase = .failed(message)
        endBackground(success: false)
    }

    // MARK: - Socket & Bonjour

    nonisolated private static func openListeningSocket() -> (Int32, UInt16)? {
        let fd6 = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        if fd6 >= 0 {
            var zero: Int32 = 0
            _ = Darwin.setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
            var one: Int32 = 1
            _ = Darwin.setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = 0
            addr6.sin6_addr = in6addr_any

            let bound = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            if bound == 0 && Darwin.listen(fd6, 4) == 0 {
                var boundAddr = sockaddr_in6()
                var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let rc = withUnsafeMutablePointer(to: &boundAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.getsockname(fd6, $0, &len)
                    }
                }
                if rc == 0 {
                    return (fd6, UInt16(bigEndian: boundAddr.sin6_port))
                }
            }
            Darwin.close(fd6)
        }

        let fd4 = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else { return nil }
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr4 = sockaddr_in()
        addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr4.sin_family = sa_family_t(AF_INET)
        addr4.sin_port = 0
        addr4.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bound = withUnsafePointer(to: &addr4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd4, 4) == 0 else {
            Darwin.close(fd4)
            return nil
        }
        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd4, $0, &len)
            }
        }
        guard rc == 0 else {
            Darwin.close(fd4)
            return nil
        }
        return (fd4, UInt16(bigEndian: boundAddr.sin_port))
    }

    private func publish(serviceName: String, txtRecords: [String: Data], port: UInt16) -> Bool {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        defer { TXTRecordDeallocate(&txt) }
        for (key, value) in txtRecords {
            _ = value.withUnsafeBytes { raw in
                key.withCString { keyPtr in
                    TXTRecordSetValue(&txt, keyPtr, UInt8(clamping: value.count), raw.baseAddress)
                }
            }
        }

        var ref: DNSServiceRef?
        let error = serviceName.withCString { namePtr in
            DNSServiceRegister(
                &ref,
                0,
                0,
                namePtr,
                "_remotepairing-pairable-host._tcp",
                nil,
                nil,
                port.bigEndian,
                TXTRecordGetLength(&txt),
                TXTRecordGetBytesPtr(&txt),
                { _, _, error, _, _, _, _ in
                    guard error != DNSServiceErrorType(kDNSServiceErr_NoError) else { return }
                    DispatchQueue.main.async {
                        UTMJITOnDevicePairing.shared.advertisingFailed(error)
                    }
                },
                nil
            )
        }
        guard error == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
            advertisingFailed(error)
            return false
        }
        DNSServiceSetDispatchQueue(ref, .main)
        registration = ref
        return true
    }

    private func advertisingFailed(_ error: DNSServiceErrorType) {
        guard active else { return }
        fail(
            error == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
                ? "UTM needs Local Network permission to pair. Allow it in Settings > Apps > UTM, then try again."
                : "UTM could not advertise its pairing service (error \(error)). Make sure Wi-Fi is enabled and try again."
        )
    }

    private func stopAdvertising() {
        if let registration {
            DNSServiceRefDeallocate(registration)
        }
        registration = nil
    }

    // MARK: - Background Execution

    private var taskIdentifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard let wildcard = permitted.first(where: { $0.hasSuffix(".pairing.*") }) else { return nil }
        return String(wildcard.dropLast()) + "session"
    }

    private func beginBackground() {
        graceTask = UIApplication.shared.beginBackgroundTask(withName: "UTM JIT pairing") {
            Task { @MainActor in
                let pairing = UTMJITOnDevicePairing.shared
                if pairing.continued == nil && pairing.active {
                    pairing.cancel(
                        reason: "iOS paused UTM in the background before pairing finished. Open Developer Mode Settings straight away and try again."
                    )
                }
                pairing.endGrace()
            }
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            submitContinuedTask()
        } else {
            backgroundLimited = true
        }
        #else
        backgroundLimited = true
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func submitContinuedTask() {
        guard let identifier = taskIdentifier else {
            backgroundLimited = true
            return
        }
        if registeredTaskIdentifier != identifier {
            let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    UTMJITOnDevicePairing.shared.attachContinuedTask(task)
                }
            }
            guard ok else {
                backgroundLimited = true
                return
            }
            registeredTaskIdentifier = identifier
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Pairing with UTM",
            subtitle: "Settings > Privacy & Security > Developer Mode"
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            backgroundLimited = true
        }
    }

    @available(iOS 26.0, *)
    private func attachContinuedTask(_ task: BGContinuedProcessingTask) {
        guard active else {
            task.setTaskCompleted(success: false)
            return
        }
        continued = task
        task.progress.totalUnitCount = 2
        if case .pin(let pin) = phase {
            task.updateTitle("Pairing code \(pin)", subtitle: "Enter it in Developer Mode to pair with UTM")
            task.progress.completedUnitCount = 1
        }
        task.expirationHandler = {
            DispatchQueue.main.async {
                UTMJITOnDevicePairing.shared.continued = nil
                UTMJITOnDevicePairing.shared.cancel(reason: "iOS stopped pairing in the background. Try again.")
            }
        }
    }
    #endif

    private func endBackground(success: Bool) {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = continued as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        #endif
        continued = nil
        endGrace()
    }

    private func endGrace() {
        guard graceTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(graceTask)
        graceTask = .invalid
    }

    // MARK: - Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "utm.jit.pairing.\(UUID().uuidString)", content: content, trigger: nil)
        )
    }
}
#endif
