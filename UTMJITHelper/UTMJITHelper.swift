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

import Foundation
#if !targetEnvironment(simulator) && canImport(StikJIT)
import StikJIT
#endif

private enum UTMJITWork {
    /// StikJIT preparation and enablement are synchronous and blocking; run them on one serial queue.
    static let queue = DispatchQueue(label: "com.utmapp.UTM.jit-helper")

    static func handle(_ request: UTMJITRequest) -> UTMJITRequest.Response {
        #if !targetEnvironment(simulator) && canImport(StikJIT)
        if request.operation == .status {
            return .init(success: true, message: "OK", txmPresent: StikJIT.isTXMPresent)
        }

        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        var portNote = ""
        var needsScan = false
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
            configuration.automaticallyDiscoverRSDPort = false
        } else if request.operation != .resetDDI {
            let lookup = RSDPortResolver.resolve()
            NSLog("[UTMJIT] RemotePairing port: %@", lookup.detail)
            if let port = lookup.port {
                configuration.rsdPort = port
                configuration.automaticallyDiscoverRSDPort = false
            } else {
                needsScan = true
            }
            portNote = " [helper port lookup: \(lookup.detail); using \(configuration.rsdPort)]"
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "Developer Disk Image cache reset.", txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "UTMJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The pairing file was not provided."])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            if needsScan {
                if let port = findRSDPort(pairingFile: pairingURL, base: configuration) {
                    configuration.rsdPort = port
                    configuration.automaticallyDiscoverRSDPort = false
                    portNote += " [port scan: using \(port)]"
                } else {
                    portNote += " [port scan: no RemotePairing port found]"
                }
            }

            switch request.operation {
            case .status:
                preconditionFailure("Handled above")
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL,
                    paths: paths,
                    configuration: configuration,
                    progress: { NSLog("[UTMJIT] prepare: %@", String(describing: $0)) }
                )
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN is reachable and the Developer Disk Image is ready." + portNote,
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason + portNote, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT returned an unknown preparation state.",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID else {
                    throw NSError(domain: "UTMJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "The target process was not provided."])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .legacy,
                    forceScript: request.forceScript,
                    preparationProgress: { NSLog("[UTMJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[UTMJIT] %@", $0) }
                )
                return .init(success: true, message: "Built-in StikJIT finished enabling JIT." + portNote,
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription + portNote, txmPresent: StikJIT.isTXMPresent)
        }
        #else
        return .init(success: false, message: "Built-in StikJIT is unavailable in the iOS Simulator.", txmPresent: nil)
        #endif
    }

    #if !targetEnvironment(simulator) && canImport(StikJIT)
    private static let lastPortKey = "utm.jit.lastRSDPort"

    private static func findRSDPort(pairingFile: URL, base: StikJIT.Configuration) -> UInt16? {
        func works(_ port: UInt16) -> Bool {
            var probe = base
            probe.rsdPort = port
            probe.automaticallyDiscoverRSDPort = false
            probe.connectionTimeout = 2
            return (try? StikJIT.isDDIMounted(pairingFile: pairingFile, configuration: probe)) != nil
        }
        let last = UInt16(exactly: UserDefaults.standard.integer(forKey: lastPortKey)) ?? 0
        if last != 0, works(last) {
            return last
        }
        let open = RSDPortScanner.openPorts(host: base.deviceAddress)
        NSLog("[UTMJIT] open ports: %@", open.map(String.init).joined(separator: ","))
        guard let port = open.first(where: works) else { return nil }
        UserDefaults.standard.set(Int(port), forKey: lastPortKey)
        return port
    }
    #endif
}

@objc(UTMJITHelperHandler)
final class UTMJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[UTMJITRequest.itemKey] as? Data
        UTMJITWork.queue.async {
            let response: UTMJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(UTMJITRequest.self, from: data) {
                response = UTMJITWork.handle(request)
            } else {
                response = .init(success: false, message: "UTM's JIT helper received an invalid request.", txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [UTMJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
