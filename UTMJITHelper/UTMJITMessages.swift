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

/// Codable messages shared by UTM and `UTMJITHelper`.
struct UTMJITRequest: Codable, Sendable {
    static let itemKey = "utm-jit-request"

    enum Operation: String, Codable, Sendable {
        case status
        case prepare
        case enable
        case resetDDI
    }

    let operation: Operation
    let targetPID: Int32?
    let pairingData: Data?
    let forceScript: Bool
    let rsdPort: UInt16?

    static var status: UTMJITRequest {
        UTMJITRequest(operation: .status, targetPID: nil, pairingData: nil, forceScript: false, rsdPort: nil)
    }

    static func prepare(pairingData: Data, rsdPort: UInt16? = nil) -> UTMJITRequest {
        UTMJITRequest(operation: .prepare, targetPID: nil, pairingData: pairingData, forceScript: false, rsdPort: rsdPort)
    }

    static func enable(targetPID: Int32, pairingData: Data, forceScript: Bool, rsdPort: UInt16? = nil) -> UTMJITRequest {
        UTMJITRequest(operation: .enable, targetPID: targetPID, pairingData: pairingData, forceScript: forceScript, rsdPort: rsdPort)
    }

    static var resetDDI: UTMJITRequest {
        UTMJITRequest(operation: .resetDDI, targetPID: nil, pairingData: nil, forceScript: false, rsdPort: nil)
    }

    struct Response: Codable, Sendable {
        static let itemKey = "utm-jit-response"
        let success: Bool
        let message: String
        let txmPresent: Bool?
    }
}
