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
import Foundation
import Network
import UIKit
import UniformTypeIdentifiers
#if canImport(AltKit)
import AltKit
#endif

enum UTMJITMethod: String, CaseIterable, Identifiable, Sendable {
    case builtIn
    case stikDebug
    case waitForDebugger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .builtIn: return "Built-in StikJIT"
        case .stikDebug: return "StikDebug"
        case .waitForDebugger: return "Wait for Debugger"
        }
    }
}

enum UTMJITTXMStatus: Equatable, Sendable {
    case unknown
    case present
    case absent

    init(_ value: Bool?) {
        switch value {
        case .some(true): self = .present
        case .some(false): self = .absent
        case .none: self = .unknown
        }
    }

    var displayText: String {
        switch self {
        case .present: return "Present"
        case .absent: return "Not Present"
        case .unknown: return "Unknown"
        }
    }
}

enum UTMJITPairingFileStore {
    static let supportedContentTypes: [UTType] = {
        var types: [UTType] = [.propertyList, .data]
        if let pairing = UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) {
            types.insert(pairing, at: 0)
        }
        if let pair = UTType(filenameExtension: "mobiledevicepair", conformingTo: .data) {
            types.insert(pair, at: 1)
        }
        return types
    }()

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
    }

    static var url: URL {
        directory.appendingPathComponent("pairingFile.plist")
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func data() throws -> Data {
        try Data(contentsOf: url)
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let publicKey = dictionary["public_key"] as? Data, publicKey.count == 32,
              let privateKey = dictionary["private_key"] as? Data, privateKey.count == 32,
              let identifier = dictionary["identifier"] as? String, !identifier.isEmpty else {
            throw UTMJITError.invalidPairingFile
        }
    }

    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: source)
        try store(data)
    }

    static func store(_ data: Data) throws {
        try validate(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove() throws {
        if exists {
            try FileManager.default.removeItem(at: url)
        }
    }
}

enum UTMJITStikDebugURL {
    static let scriptName = "legacy.js"

    static func build(bundleID: String, pid: Int32, requiresScript: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = "stikdebug"
        components.host = "enable-jit"
        var queryItems = [
            URLQueryItem(name: "bundle-id", value: bundleID),
            URLQueryItem(name: "pid", value: String(pid))
        ]
        if requiresScript {
            queryItems.append(URLQueryItem(name: "script-name", value: scriptName))
        }
        components.queryItems = queryItems
        return components.url
    }
}

enum UTMJITError: Error, LocalizedError {
    case missingGetTaskAllow
    case missingPairingFile
    case invalidPairingFile
    case stikDebugUnavailable
    case stikDebugTimeout
    case debuggerTimeout
    case missingBundleID
    case malformedURL
    case helperAttachTimeout

    var errorDescription: String? {
        switch self {
        case .missingGetTaskAllow:
            return "This installation does not have get-task-allow. Reinstall UTM using a signing method that preserves this entitlement."
        case .missingPairingFile:
            return "Import a valid pairing file before enabling JIT."
        case .invalidPairingFile:
            return "The selected file is not a valid remote pairing file."
        case .stikDebugUnavailable:
            return "StikDebug could not be opened. Install StikDebug or choose another JIT method in Settings."
        case .stikDebugTimeout:
            return "StikDebug did not attach within 90 seconds. Make sure StikDebug is installed and paired, then try again."
        case .debuggerTimeout:
            return "Timed out waiting for an external debugger to attach."
        case .missingBundleID:
            return "Could not determine UTM's bundle identifier."
        case .malformedURL:
            return "Could not create the StikDebug request URL."
        case .helperAttachTimeout:
            return "UTM's JIT helper did not attach within 90 seconds. Check that LocalDevVPN is connected, then try again."
        }
    }
}

@MainActor
final class UTMJITCoordinator: ObservableObject {
    static let shared = UTMJITCoordinator()

    private static let methodKey = "UTMJITMethod"
    private static let forceScriptKey = "UTMJITForceScript"

    @Published var method: UTMJITMethod {
        didSet {
            UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey)
            error = nil
            connectionProblem = nil
            advice = nil
        }
    }

    @Published var forceScript: Bool {
        didSet {
            UserDefaults.standard.set(forceScript, forKey: Self.forceScriptKey)
        }
    }

    @Published var showSetup = false
    @Published private(set) var txmStatus: UTMJITTXMStatus = .unknown
    @Published private(set) var hasPairingFile = UTMJITPairingFileStore.exists
    @Published private(set) var prepared = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    @Published private(set) var connectionProblem: UTMJITConnectionProblem?
    @Published private(set) var advice: UTMJITAdvice?

    private let pathMonitor = NWPathMonitor()
    private var builtInAttachInFlight = false
    private var inFlightEnableTask: Task<Void, Error>?

    var isRunningInLiveContainer: Bool {
        UTMJITBuiltIn.isRunningInLiveContainer
    }

    var builtInUnavailableReason: String? {
        UTMJITBuiltIn.unavailableReason
    }

    var hasGetTaskAllow: Bool {
        jb_has_get_task_allow()
    }

    var isJailbroken: Bool {
        FileManager.default.fileExists(atPath: "/var/jb")
    }

    var isStikDebugInstalled: Bool {
        URL(string: "stikdebug://").map(UIApplication.shared.canOpenURL) ?? false
    }

    var isTraced: Bool {
        jb_is_debugger_traced()
    }

    var isDebugged: Bool {
        jb_is_debugged_cs_status()
    }

    var networkSituation: UTMNetworkSituation {
        let path = pathMonitor.currentPath
        return UTMNetworkSituation(UTMNetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            usesWiFi: path.usesInterfaceType(.wifi),
            usesCellular: path.usesInterfaceType(.cellular),
            usesWired: path.usesInterfaceType(.wiredEthernet)
        ))
    }

    var requiresScriptProtocol: Bool {
        if forceScript {
            return true
        }
        switch txmStatus {
        case .present:
            return true
        case .absent:
            return false
        case .unknown:
            return Self.fallbackHasTXM
        }
    }

    var isJITReadyForCurrentEnvironment: Bool {
        if jb_has_jit_entitlement() {
            return true
        }
        if requiresScriptProtocol {
            return jb_is_debugger_traced()
        }
        return Main.jitAvailable || jb_is_debugged_cs_status()
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: Self.methodKey),
           let parsed = UTMJITMethod(rawValue: saved) {
            method = parsed
        } else if UserDefaults.standard.bool(forKey: "JitStreamerAttach") {
            method = .waitForDebugger
        } else if UTMJITBuiltIn.isAvailable {
            method = .builtIn
        } else {
            method = .waitForDebugger
        }
        forceScript = UserDefaults.standard.bool(forKey: Self.forceScriptKey)
        pathMonitor.start(queue: DispatchQueue(label: "com.utmapp.UTM.jit-path", qos: .utility))
    }

    func refreshStatus() {
        hasPairingFile = UTMJITPairingFileStore.exists
        if txmStatus == .unknown, UTMJITBuiltIn.isAvailable {
            UTMJITBuiltIn.send(.status) { [weak self] result in
                guard let self else { return }
                if case .success(let response) = result, let present = response.txmPresent {
                    self.txmStatus = UTMJITTXMStatus(present)
                }
            }
        }
    }

    func importPairingFile(_ url: URL) {
        do {
            try UTMJITPairingFileStore.importFile(from: url)
            hasPairingFile = true
            prepared = false
            status = "Pairing file imported."
            error = nil
            connectionProblem = nil
            advice = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removePairingFile() {
        do {
            try UTMJITPairingFileStore.remove()
            hasPairingFile = false
            prepared = false
            status = "Pairing file removed."
            error = nil
            connectionProblem = nil
            advice = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func prepareBuiltIn(attempt: Int = 1) {
        if let reason = UTMJITBuiltIn.unavailableReason {
            error = reason
            return
        }
        guard hasGetTaskAllow else {
            error = UTMJITError.missingGetTaskAllow.localizedDescription
            return
        }
        guard let pairingData = try? UTMJITPairingFileStore.data() else {
            hasPairingFile = false
            error = UTMJITError.missingPairingFile.localizedDescription
            return
        }
        hasPairingFile = true
        busy = true
        error = nil
        connectionProblem = nil
        advice = nil
        if attempt == 1 {
            status = "Checking LocalDevVPN and Developer Disk Image…"
        }

        UTMRemotePairingPortDiscovery.resolve { [weak self] port in
            UTMJITBuiltIn.send(.prepare(pairingData: pairingData, rsdPort: port)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let response):
                    if let present = response.txmPresent {
                        self.txmStatus = UTMJITTXMStatus(present)
                    }
                    if !response.success,
                       self.retryIfAdvised(helperMessage: response.message, attempt: attempt, retry: { [weak self] next in
                           self?.prepareBuiltIn(attempt: next)
                       }) {
                        return
                    }
                    self.busy = false
                    self.prepared = response.success
                    self.status = response.success ? response.message : nil
                    self.error = response.success ? nil : self.helperFailure(response.message)
                case .failure(let failure):
                    self.busy = false
                    self.prepared = false
                    self.status = nil
                    self.error = failure.localizedDescription
                }
            }
        }
    }

    func resetDDI() {
        if let reason = UTMJITBuiltIn.unavailableReason {
            error = reason
            return
        }
        busy = true
        error = nil
        connectionProblem = nil
        advice = nil
        status = "Resetting Developer Disk Image cache…"
        UTMJITBuiltIn.send(.resetDDI) { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.prepared = false
            switch result {
            case .success(let response):
                if let present = response.txmPresent {
                    self.txmStatus = UTMJITTXMStatus(present)
                }
                self.status = response.success ? response.message : nil
                self.error = response.success ? nil : response.message
            case .failure(let failure):
                self.status = nil
                self.error = failure.localizedDescription
            }
        }
    }

    func enableWithStikDebugFromSettings() {
        Task {
            do {
                try await enableUsingStikDebug()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func ensureJITBeforeVMStart() async throws {
        if let existing = inFlightEnableTask {
            try await existing.value
            return
        }
        let task = Task { @MainActor in
            try await performEnsureJITBeforeVMStart()
        }
        inFlightEnableTask = task
        defer {
            inFlightEnableTask = nil
        }
        try await task.value
    }

    func releasePendingBuiltInAttachIfNeeded() {
        guard builtInAttachInFlight else { return }
        builtInAttachInFlight = false
        jb_trigger_legacy_jit_detach()
    }

    private func performEnsureJITBeforeVMStart() async throws {
        if jb_has_jit_entitlement() {
            return
        }

        if txmStatus == .unknown, UTMJITBuiltIn.isAvailable {
            await refreshTXMStatusAsync()
        }

        let needsScript = requiresScriptProtocol
        if needsScript {
            if jb_is_debugger_traced() {
                return
            }
        } else if Main.jitAvailable || jb_is_debugged_cs_status() {
            Main.jitAvailable = true
            return
        }

        if !hasGetTaskAllow && !isJailbroken && !jb_has_cs_disabled() {
            throw UTMJITError.missingGetTaskAllow
        }

        switch method {
        case .builtIn:
            try await enableUsingBuiltIn(needsScript: needsScript)
        case .stikDebug:
            try await enableUsingStikDebug()
        case .waitForDebugger:
            try await enableUsingExternalDebugger(needsScript: needsScript)
        }
    }

    private func refreshTXMStatusAsync() async {
        await withCheckedContinuation { continuation in
            UTMJITBuiltIn.send(.status) { [weak self] result in
                if case .success(let response) = result, let present = response.txmPresent {
                    self?.txmStatus = UTMJITTXMStatus(present)
                }
                continuation.resume()
            }
        }
    }

    private func enableUsingBuiltIn(needsScript: Bool) async throws {
        if let reason = UTMJITBuiltIn.unavailableReason {
            throw NSError(domain: "UTMJITCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        guard hasGetTaskAllow else {
            throw UTMJITError.missingGetTaskAllow
        }
        guard let pairingData = try? UTMJITPairingFileStore.data() else {
            hasPairingFile = false
            showSetup = true
            throw UTMJITError.missingPairingFile
        }
        hasPairingFile = true

        try await runBuiltInEnableAttempt(pairingData: pairingData, needsScript: needsScript, attempt: 1)
    }

    private func runBuiltInEnableAttempt(pairingData: Data, needsScript: Bool, attempt: Int) async throws {
        busy = true
        error = nil
        connectionProblem = nil
        advice = nil
        if attempt == 1 {
            status = "Starting Built-in StikJIT helper…"
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var completed = false
                var pollTask: Task<Void, Never>?

                let finish: (Result<Void, Error>) -> Void = { [weak self] result in
                    guard !completed else { return }
                    completed = true
                    pollTask?.cancel()
                    pollTask = nil
                    self?.busy = false
                    switch result {
                    case .success:
                        self?.error = nil
                        self?.status = needsScript ? "JIT helper attached." : "JIT enabled."
                        continuation.resume()
                    case .failure(let err):
                        self?.status = nil
                        self?.error = err.localizedDescription
                        continuation.resume(throwing: err)
                    }
                }

                UTMRemotePairingPortDiscovery.resolve { [weak self] port in
                    guard let self else {
                        finish(.failure(CancellationError()))
                        return
                    }
                    self.builtInAttachInFlight = true
                    UTMJITBuiltIn.send(
                        .enable(targetPID: getpid(), pairingData: pairingData, forceScript: self.forceScript, rsdPort: port),
                        started: { [weak self] in
                            guard let self else { return }
                            if attempt == 1 {
                                self.status = "Waiting for JIT helper to attach…"
                            }
                            if needsScript {
                                pollTask = Task { @MainActor in
                                    let deadline = Date().addingTimeInterval(90)
                                    while !Task.isCancelled && !completed {
                                        if jb_is_debugger_traced() {
                                            finish(.success(()))
                                            return
                                        }
                                        if Date() >= deadline {
                                            finish(.failure(UTMJITError.helperAttachTimeout))
                                            return
                                        }
                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                    }
                                }
                            }
                        },
                        completion: { [weak self] result in
                            guard let self else { return }
                            self.builtInAttachInFlight = false
                            switch result {
                            case .success(let response):
                                if let present = response.txmPresent {
                                    self.txmStatus = UTMJITTXMStatus(present)
                                }
                                if response.success {
                                    if !needsScript {
                                        Main.jitAvailable = true
                                    }
                                    finish(.success(()))
                                } else {
                                    let message = self.helperFailure(response.message)
                                    if !completed,
                                       let problem = self.connectionProblem,
                                       case .retry(let wait) = UTMJITRetryPolicy.decision(situation: self.networkSituation, problem: problem, attempt: attempt) {
                                        completed = true
                                        pollTask?.cancel()
                                        self.status = UTMJITRetryPolicy.statusText(nextAttempt: attempt + 1)
                                        Task {
                                            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                                            continuation.resume(throwing: RetrySignalError())
                                        }
                                        return
                                    }
                                    finish(.failure(NSError(domain: "UTMJITCoordinator", code: 2, userInfo: [NSLocalizedDescriptionKey: message])))
                                }
                            case .failure(let failure):
                                finish(.failure(failure))
                            }
                        }
                    )
                }
            }
        } catch is RetrySignalError {
            try await runBuiltInEnableAttempt(pairingData: pairingData, needsScript: needsScript, attempt: attempt + 1)
        }
    }

    private func enableUsingStikDebug() async throws {
        if txmStatus == .unknown, UTMJITBuiltIn.isAvailable {
            await refreshTXMStatusAsync()
        }
        guard let bundleID = Bundle.main.bundleIdentifier else {
            throw UTMJITError.missingBundleID
        }
        let needsScript = requiresScriptProtocol
        guard let url = UTMJITStikDebugURL.build(bundleID: bundleID, pid: getpid(), requiresScript: needsScript) else {
            throw UTMJITError.malformedURL
        }

        busy = true
        error = nil
        status = "Opening StikDebug…"
        defer {
            busy = false
        }

        let opened = await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
        guard opened else {
            status = nil
            throw UTMJITError.stikDebugUnavailable
        }

        status = "Waiting for StikDebug to attach…"
        try await waitForDebugger(needsScript: needsScript, timeoutError: UTMJITError.stikDebugTimeout)
        if !needsScript {
            Main.jitAvailable = true
        }
        status = "StikDebug attached."
    }

    private func enableUsingExternalDebugger(needsScript: Bool) async throws {
        busy = true
        error = nil
        defer {
            busy = false
        }

        if UserDefaults.standard.bool(forKey: "JitStreamerAttach") {
            status = "Connecting to JitStreamer…"
            try await attachJitStreamer()
            if !needsScript {
                Main.jitAvailable = true
                return
            }
            if jb_is_debugger_traced() {
                status = "Debugger attached."
                return
            }
        }

        #if canImport(AltKit)
        if Bundle.main.infoDictionary?["ALTServerID"] != nil && Bundle.main.infoDictionary?["ALTDeviceID"] != nil {
            status = "Connecting to AltServer…"
            try await attachAltJIT()
            if !needsScript {
                Main.jitAvailable = true
                return
            }
            if jb_is_debugger_traced() {
                status = "Debugger attached."
                return
            }
        }
        #endif

        status = "Waiting for an external debugger to attach…"
        try await waitForDebugger(needsScript: needsScript, timeoutError: UTMJITError.debuggerTimeout)
        if !needsScript {
            Main.jitAvailable = true
        }
        status = "Debugger attached."
    }

    private func waitForDebugger(needsScript: Bool, timeout: TimeInterval = 90, timeoutError: Error) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if needsScript {
                if jb_is_debugger_traced() {
                    return
                }
            } else if jb_is_debugged_cs_status() || jb_is_debugger_traced() {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw timeoutError
    }

    private func attachJitStreamer() async throws {
        let address = UserDefaults.standard.string(forKey: "JitStreamerAddress") ?? ""
        let urlString = String(format: "http://%@/attach/%ld/", address, getpid())
        guard let url = URL(string: urlString) else {
            throw UTMDataError.jitStreamerUrlInvalid(urlString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data()
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw UTMDataError.jitStreamerAttachFailed
        }
        let response: JitStreamerResponse
        do {
            response = try JSONDecoder().decode(JitStreamerResponse.self, from: data)
        } catch {
            throw UTMDataError.jitStreamerDecodeFailed
        }
        if !response.success {
            throw NSError(domain: "UTMJITCoordinator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: String.localizedStringWithFormat(
                    NSLocalizedString("Failed to attach to JitStreamer:\n%@", comment: "ContentView"),
                    response.message
                )
            ])
        }
    }

    #if canImport(AltKit)
    private func attachAltJIT() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                ServerManager.shared.stopDiscovering()
                continuation.resume(with: result)
            }
            ServerManager.shared.autoconnect { result in
                switch result {
                case .failure(let error):
                    finish(.failure(UTMDataError.altJitError(error.localizedDescription)))
                case .success(let connection):
                    connection.enableUnsignedCodeExecution { jitResult in
                        connection.disconnect()
                        switch jitResult {
                        case .failure(let error):
                            finish(.failure(UTMDataError.altJitError(error.localizedDescription)))
                        case .success:
                            finish(.success(()))
                        }
                    }
                }
            }
            ServerManager.shared.startDiscovering()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                finish(.failure(UTMDataError.altServerNotFound))
            }
        }
    }
    #endif

    private func helperFailure(_ message: String) -> String {
        connectionProblem = UTMJITConnectionProblem(helperMessage: message)
        advice = UTMJITNetworkAdvice.advice(forHelperMessage: message, situation: networkSituation)
        return advice?.message ?? message
    }

    private func retryIfAdvised(helperMessage: String, attempt: Int, retry: @escaping (Int) -> Void) -> Bool {
        guard let problem = UTMJITConnectionProblem(helperMessage: helperMessage),
              case .retry(let wait) = UTMJITRetryPolicy.decision(situation: networkSituation, problem: problem, attempt: attempt) else {
            return false
        }
        status = UTMJITRetryPolicy.statusText(nextAttempt: attempt + 1)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard self != nil else { return }
            retry(attempt + 1)
        }
        return true
    }

    private static var fallbackHasTXM: Bool {
        if #available(iOS 27.0, *) {
            let hardware = hardwareIdentifier()
            return hardware != "iPad8,11" && hardware != "iPad8,12"
        }
        if #available(iOS 26.0, *) {
            let hardware = hardwareIdentifier()
            if let version = deviceVersion(from: hardware) {
                return hardware.hasPrefix("iPad") ? version >= 14.5 : version >= 14.2
            }
        }
        return false
    }

    private static func deviceVersion(from identifier: String) -> Double? {
        for pattern in [#"iPhone(\d+),(\d+)"#, #"iPad(\d+),(\d+)"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: identifier, range: NSRange(identifier.startIndex..., in: identifier)),
                  let majorRange = Range(match.range(at: 1), in: identifier),
                  let minorRange = Range(match.range(at: 2), in: identifier),
                  let major = Double(identifier[majorRange]),
                  let minor = Double(identifier[minorRange]) else {
                continue
            }
            let divisor = pow(10.0, Double(String(Int(minor)).count))
            return major + (minor / divisor)
        }
        return nil
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

private struct RetrySignalError: Error {}

private struct JitStreamerResponse: Decodable {
    var message: String
    var success: Bool
}
#endif
