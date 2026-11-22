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
import Darwin
import Foundation
import Network
import UIKit

@objc private protocol UTMNSExtensionClassShim {
    @objc(extensionWithIdentifier:error:)
    func `extension`(withIdentifier identifier: String) throws -> AnyObject
}

@objc private protocol UTMNSExtensionShim {
    @objc(beginExtensionRequestWithInputItems:completion:)
    func beginExtensionRequest(withInputItems items: [Any], completion: @escaping (NSUUID?) -> Void)
    @objc(pidForRequestIdentifier:)
    func pid(forRequestIdentifier identifier: NSUUID) -> Int32
    @objc(setRequestCompletionBlock:)
    func setRequestCompletionBlock(_ block: @escaping (NSUUID?, [Any]?) -> Void)
    @objc(setRequestCancellationBlock:)
    func setRequestCancellationBlock(_ block: @escaping (NSUUID?, NSError?) -> Void)
    @objc(setRequestInterruptionBlock:)
    func setRequestInterruptionBlock(_ block: @escaping (NSUUID?) -> Void)
}

/// Launches `PlugIns/UTMJITHelper.appex` via `NSExtension` so Built-in StikJIT runs in a separate process
/// and survives sideloaders that rewrite bundle identifiers.
@MainActor
enum UTMJITBuiltIn {
    static let helperFile = "UTMJITHelper.appex"

    private static var running: [HelperRequest] = []

    static var isRunningInLiveContainer: Bool {
        getenv("LC_HOME_PATH") != nil
    }

    static var unavailableReason: String? {
        #if targetEnvironment(simulator)
        return "Built-in StikJIT is available only on a physical device."
        #else
        guard #available(iOS 17.4, *) else {
            return "Built-in StikJIT requires iOS 17.4 or later."
        }
        if isRunningInLiveContainer {
            return "Built-in StikJIT is unavailable inside LiveContainer because it cannot launch the helper extension. Choose StikDebug or Wait for Debugger instead."
        }
        return nil
        #endif
    }

    static var isAvailable: Bool {
        unavailableReason == nil
    }

    static var helperIdentifier: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(helperFile) else {
            return nil
        }
        return Bundle(url: url)?.bundleIdentifier
    }

    static func send(_ request: UTMJITRequest,
                     started: @escaping () -> Void = {},
                     completion: @escaping (Result<UTMJITRequest.Response, Error>) -> Void) {
        func fail(_ code: Int, _ message: String) {
            logger.error("JIT helper: \(message)")
            completion(.failure(HelperRequest.error(code, message)))
        }
        if let reason = unavailableReason {
            fail(1, reason)
            return
        }
        guard let identifier = helperIdentifier else {
            fail(2, "UTM's JIT helper (\(helperFile)) is missing from this installation. Reinstall UTM and keep its app extensions.")
            return
        }
        if NSClassFromString("NSExtension") == nil {
            dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW)
        }
        guard let extensionClass = NSClassFromString("NSExtension") else {
            fail(3, "iOS did not provide the extension API required by UTM's JIT helper.")
            return
        }
        let factory = unsafeBitCast(extensionClass as AnyObject, to: UTMNSExtensionClassShim.self)
        let found: AnyObject
        do {
            found = try factory.extension(withIdentifier: identifier)
        } catch {
            fail(2, "UTM's JIT helper (\(identifier)) could not be loaded: \(error.localizedDescription)")
            return
        }
        guard let data = try? JSONEncoder().encode(request) else {
            fail(4, "The request for UTM's JIT helper could not be encoded.")
            return
        }
        let helper = HelperRequest(extension: found, operation: request.operation.rawValue, completion: completion)
        running.append(helper)
        helper.begin(data: data, identifier: identifier, started: started)
    }

    fileprivate static func finished(_ helper: HelperRequest) {
        running.removeAll { $0 === helper }
    }
}

@MainActor
private final class HelperRequest {
    private let shim: UTMNSExtensionShim
    private let `extension`: AnyObject
    private let operation: String
    private var completion: ((Result<UTMJITRequest.Response, Error>) -> Void)?

    init(extension found: AnyObject, operation: String, completion: @escaping (Result<UTMJITRequest.Response, Error>) -> Void) {
        self.extension = found
        self.shim = unsafeBitCast(found, to: UTMNSExtensionShim.self)
        self.operation = operation
        self.completion = completion
    }

    func begin(data: Data, identifier: String, started: @escaping () -> Void) {
        shim.setRequestCompletionBlock { [weak self] _, items in
            let info = (items?.first as? NSExtensionItem)?.userInfo
            let payload = info?[UTMJITRequest.Response.itemKey] as? Data
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.returned(payload)
                }
            }
        }
        shim.setRequestCancellationBlock { [weak self] _, error in
            let message = error?.localizedDescription ?? "the request was cancelled"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.end(.failure(Self.error(5, "UTM's JIT helper stopped: \(message)")))
                }
            }
        }
        shim.setRequestInterruptionBlock { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.end(.failure(Self.error(6, "UTM's JIT helper stopped unexpectedly. Try again.")))
                }
            }
        }
        let item = NSExtensionItem()
        item.userInfo = [UTMJITRequest.itemKey: data]
        shim.beginExtensionRequest(withInputItems: [item]) { [weak self] uuid in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard let uuid else {
                        self.end(.failure(Self.error(7, "UTM's JIT helper did not start. Reinstall UTM and keep its app extensions.")))
                        return
                    }
                    logger.info("JIT helper \(self.operation) started \(identifier) as pid \(self.shim.pid(forRequestIdentifier: uuid))")
                    started()
                }
            }
        }
    }

    private func returned(_ payload: Data?) {
        guard let payload,
              let response = try? JSONDecoder().decode(UTMJITRequest.Response.self, from: payload) else {
            end(.failure(Self.error(8, "UTM's JIT helper finished without a response.")))
            return
        }
        logger.info("JIT helper \(operation) finished success=\(response.success)")
        end(.success(response))
    }

    private func end(_ result: Result<UTMJITRequest.Response, Error>) {
        guard let completion else { return }
        self.completion = nil
        if case .failure(let error) = result {
            logger.error("JIT helper \(operation): \(error.localizedDescription)")
        }
        UTMJITBuiltIn.finished(self)
        completion(result)
    }

    nonisolated static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "UTMJITBuiltIn", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

enum UTMLocalDevVPN {
    static let appStore = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let connect = URL(string: "localdevvpn://enable?scheme=utm")!

    @MainActor
    static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
    }

    static var isConnected: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if ip >> 16 == 0x0a07, String(cString: ifa.ifa_name).hasPrefix("utun") {
                return true
            }
        }
        return false
    }

    @MainActor
    static func open() {
        UIApplication.shared.open(isInstalled ? connect : appStore)
    }
}

enum UTMRemotePairingPortDiscovery {
    private static let serviceType = "_remotepairing._tcp"
    private static let queue = DispatchQueue(label: "com.utmapp.UTM.remotepairing-discovery", qos: .utility)
    private static let lock = NSLock()
    private static var cachedPort: UInt16?
    private static var lastFailure: Date?

    static func resolve(timeout: TimeInterval = 3, completion: @escaping (UInt16?) -> Void) {
        lock.lock()
        if let cachedPort {
            lock.unlock()
            DispatchQueue.main.async { completion(cachedPort) }
            return
        }
        if let lastFailure, Date().timeIntervalSince(lastFailure) < 30 {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }
        lock.unlock()

        queue.async {
            let port = discover(timeout: timeout)
            lock.lock()
            if let port {
                cachedPort = port
                lastFailure = nil
            } else {
                lastFailure = Date()
            }
            lock.unlock()
            DispatchQueue.main.async { completion(port) }
        }
    }

    private static func discover(timeout: TimeInterval) -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var finished = false
        var resolvedPort: UInt16?
        var pendingConnection: NWConnection?

        func finish(_ port: UInt16?) {
            resultLock.lock()
            if !finished {
                finished = true
                resolvedPort = port
                semaphore.signal()
            }
            resultLock.unlock()
        }

        func hasFinished() -> Bool {
            resultLock.lock()
            defer { resultLock.unlock() }
            return finished
        }

        browser.browseResultsChangedHandler = { results, _ in
            guard !hasFinished() else { return }
            let preferred = results.first { result in
                result.interfaces.contains { $0.name == "lo0" }
            } ?? results.first
            guard let result = preferred, case .service = result.endpoint else { return }

            resultLock.lock()
            let alreadyConnecting = pendingConnection != nil
            if !alreadyConnecting {
                pendingConnection = NWConnection(to: result.endpoint, using: parameters)
            }
            let connection = pendingConnection
            resultLock.unlock()

            guard !alreadyConnecting, let connection else { return }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
                       case .hostPort(_, let port) = remoteEndpoint {
                        finish(port.rawValue)
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        browser.stateUpdateHandler = { state in
            if case .failed = state {
                finish(nil)
            }
        }

        browser.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.cancel()

        resultLock.lock()
        let connectionToCancel = pendingConnection
        resultLock.unlock()
        connectionToCancel?.cancel()

        resultLock.lock()
        defer { resultLock.unlock() }
        return resolvedPort
    }
}
#endif
