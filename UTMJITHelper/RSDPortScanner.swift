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
import Darwin

/// Fallback TCP port scan when Bonjour does not advertise `_remotepairing._tcp`.
enum RSDPortScanner {
    /// Ports that are open on the tunnel host but are not RemotePairing (lockdownd).
    static let known: Set<UInt16> = [62078]

    static func openPorts(host: String = "10.7.0.1", range: ClosedRange<UInt16> = 49152...65535,
                          batch: Int = 512, waitMs: Int32 = 250) -> [UInt16] {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return [] }

        var open: [UInt16] = []
        let ports = Array(range)
        var start = 0
        while start < ports.count {
            let chunk = ports[start..<min(start + batch, ports.count)]
            start += batch
            var fds: [pollfd] = []
            var portFor: [Int32: UInt16] = [:]
            for port in chunk {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var a = addr
                a.sin_port = port.bigEndian
                let rc = withUnsafePointer(to: &a) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc == 0 || errno == EINPROGRESS {
                    fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
                    portFor[fd] = port
                } else {
                    close(fd)
                }
            }
            _ = poll(&fds, nfds_t(fds.count), waitMs)
            for p in fds {
                if p.revents & Int16(POLLOUT) != 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0, let port = portFor[p.fd], !known.contains(port) {
                        open.append(port)
                    }
                }
                close(p.fd)
            }
        }
        return open
    }
}
