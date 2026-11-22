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

struct UTMNetworkPathSnapshot: Equatable, Sendable {
    var isSatisfied: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
}

enum UTMNetworkSituation: Equatable, Sendable {
    case wifi
    case cellularOnly
    case wired
    case offline

    init(_ path: UTMNetworkPathSnapshot) {
        if !path.isSatisfied {
            self = .offline
        } else if path.usesWiFi {
            self = .wifi
        } else if path.usesWired {
            self = .wired
        } else {
            self = path.usesCellular ? .cellularOnly : .wifi
        }
    }
}

enum UTMJITAdviceAction: Equatable, Sendable {
    case connectLocalDevVPN
    case reimportPairingFile
}

struct UTMJITAdvice: Equatable, Sendable {
    var message: String
    var actions: [UTMJITAdviceAction]
}

enum UTMJITConnectionProblem: Equatable, Sendable {
    case unreachable
    case pairing

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["connectionreset", "connection reset", "device refused connection"]) {
            self = .pairing
        } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                       "networkunreachable", "network unreachable", "hostunreachable",
                       "host unreachable", "no route", "cannot reach", "unreachable"]) {
            self = .unreachable
        } else {
            return nil
        }
    }
}

enum UTMJITNetworkAdvice {
    static func advice(forHelperMessage helperMessage: String, situation: UTMNetworkSituation) -> UTMJITAdvice? {
        guard let problem = UTMJITConnectionProblem(helperMessage: helperMessage) else { return nil }
        if problem == .pairing {
            return UTMJITAdvice(
                message: "This device closed the connection, which usually means the pairing file is no longer accepted. Re-import a valid pairing file and ensure LocalDevVPN is connected.",
                actions: [.reimportPairingFile, .connectLocalDevVPN]
            )
        }
        guard situation == .cellularOnly else {
            return UTMJITAdvice(
                message: "UTM could not reach the device debugging service. Connect LocalDevVPN, then try again.",
                actions: [.connectLocalDevVPN]
            )
        }
        return UTMJITAdvice(
            message: "LocalDevVPN can report Connected while iOS still routes traffic over cellular. Toggle Cellular Data off for 2 seconds and back on, or connect to Wi-Fi (or enable Airplane Mode after connecting LocalDevVPN), then try again.",
            actions: [.connectLocalDevVPN]
        )
    }
}

enum UTMJITRetryDecision: Equatable, Sendable {
    case retry(after: TimeInterval)
    case giveUp
}

enum UTMJITRetryPolicy {
    static let maxAttempts = 3

    static func statusText(nextAttempt: Int) -> String {
        "Retrying over LocalDevVPN (\(nextAttempt) of \(maxAttempts))…"
    }

    static func decision(situation: UTMNetworkSituation, problem: UTMJITConnectionProblem, attempt: Int) -> UTMJITRetryDecision {
        guard situation == .cellularOnly, problem == .unreachable else { return .giveUp }
        return attempt < maxAttempts ? .retry(after: 4) : .giveUp
    }
}
#endif
