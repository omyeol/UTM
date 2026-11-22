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

import XCTest
@testable import UTM

#if os(iOS) && WITH_JIT
final class UTMJITTests: XCTestCase {
    func testRequestRoundTrip() throws {
        let pairing = Data([1, 2, 3, 4])
        let request = UTMJITRequest.enable(targetPID: 4242, pairingData: pairing, forceScript: true, rsdPort: 51234)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(UTMJITRequest.self, from: encoded)
        XCTAssertEqual(decoded.operation, .enable)
        XCTAssertEqual(decoded.targetPID, 4242)
        XCTAssertEqual(decoded.pairingData, pairing)
        XCTAssertTrue(decoded.forceScript)
        XCTAssertEqual(decoded.rsdPort, 51234)
    }

    func testPairingFileValidationAcceptsValidPlist() throws {
        let dict: [String: Any] = [
            "public_key": Data(repeating: 0x11, count: 32),
            "private_key": Data(repeating: 0x22, count: 32),
            "identifier": "test-host-id"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        XCTAssertNoThrow(try UTMJITPairingFileStore.validate(data))
    }

    func testPairingFileValidationRejectsInvalidPlist() throws {
        let shortKey: [String: Any] = [
            "public_key": Data(repeating: 0x11, count: 16),
            "private_key": Data(repeating: 0x22, count: 32),
            "identifier": "test-host-id"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: shortKey, format: .xml, options: 0)
        XCTAssertThrowsError(try UTMJITPairingFileStore.validate(data))
        XCTAssertThrowsError(try UTMJITPairingFileStore.validate(Data("not a plist".utf8)))
    }

    func testStikDebugURLIncludesScriptOnlyWhenRequired() throws {
        let withScript = try XCTUnwrap(UTMJITStikDebugURL.build(bundleID: "com.utmapp.UTM", pid: 123, requiresScript: true))
        let withItems = URLComponents(url: withScript, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(withItems.first(where: { $0.name == "bundle-id" })?.value, "com.utmapp.UTM")
        XCTAssertEqual(withItems.first(where: { $0.name == "pid" })?.value, "123")
        XCTAssertEqual(withItems.first(where: { $0.name == "script-name" })?.value, "legacy.js")

        let withoutScript = try XCTUnwrap(UTMJITStikDebugURL.build(bundleID: "com.utmapp.UTM", pid: 123, requiresScript: false))
        let withoutItems = URLComponents(url: withoutScript, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(withoutItems.first(where: { $0.name == "script-name" }))
    }

    func testRetryPolicyRetriesOnlyOnCellularUnreachable() {
        XCTAssertEqual(
            UTMJITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 1),
            .retry(after: 4)
        )
        XCTAssertEqual(
            UTMJITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 3),
            .giveUp
        )
        XCTAssertEqual(
            UTMJITRetryPolicy.decision(situation: .wifi, problem: .unreachable, attempt: 1),
            .giveUp
        )
        XCTAssertEqual(
            UTMJITRetryPolicy.decision(situation: .cellularOnly, problem: .pairing, attempt: 1),
            .giveUp
        )
    }
}
#endif
