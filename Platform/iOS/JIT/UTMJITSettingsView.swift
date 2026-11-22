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
import SwiftUI

struct UTMJITSettingsView: View {
    @ObservedObject private var jit = UTMJITCoordinator.shared
    @State private var importingPairingFile = false

    var body: some View {
        Form {
            statusSection
            methodSection

            switch jit.method {
            case .builtIn:
                builtInSection
                instructionsSection
            case .stikDebug:
                stikDebugSection
            case .waitForDebugger:
                waitForDebuggerSection
            }
        }
        .onAppear {
            jit.refreshStatus()
        }
        .fileImporter(
            isPresented: $importingPairingFile,
            allowedContentTypes: UTMJITPairingFileStore.supportedContentTypes
        ) { result in
            switch result {
            case .success(let url):
                jit.importPairingFile(url)
            case .failure(let error):
                logger.error("Failed to import pairing file: \(error.localizedDescription)")
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text("JIT Status")
                Spacer()
                Text(jitStatusText)
                    .foregroundColor(jit.isJITReadyForCurrentEnvironment ? .green : .secondary)
            }
            HStack {
                Text("get-task-allow")
                Spacer()
                Text(jit.hasGetTaskAllow ? "Present" : "Missing")
                    .foregroundColor(jit.hasGetTaskAllow ? .green : .red)
            }
            HStack {
                Text("TXM / SPTM")
                Spacer()
                Text(jit.txmStatus.displayText)
                    .foregroundColor(.secondary)
            }
            if jit.isRunningInLiveContainer {
                Label(
                    "Running inside LiveContainer. Built-in StikJIT is unavailable; use StikDebug or Wait for Debugger.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundColor(.orange)
            }
            if !jit.hasGetTaskAllow {
                Text("This installation does not have get-task-allow. Reinstall UTM using a signing method that preserves this entitlement.")
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            if jit.busy, let status = jit.status {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(status)
                        .font(.footnote)
                }
            } else if let error = jit.error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            } else if let status = jit.status {
                Text(status)
                    .font(.footnote)
                    .foregroundColor(.green)
            }
            if let advice = jit.advice {
                ForEach(advice.actions, id: \.self) { action in
                    switch action {
                    case .connectLocalDevVPN:
                        Button(UTMLocalDevVPN.isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN") {
                            UTMLocalDevVPN.open()
                        }
                    case .reimportPairingFile:
                        Button("Import Pairing File…") {
                            importingPairingFile = true
                        }
                    }
                }
            }
        } header: {
            Text("Status")
        }
    }

    private var methodSection: some View {
        Section {
            Picker("JIT Method", selection: $jit.method) {
                ForEach(UTMJITMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
        } header: {
            Text("Acquisition Method")
        } footer: {
            Text(methodFooter)
        }
    }

    @ViewBuilder
    private var builtInSection: some View {
        Section {
            if let reason = jit.builtInUnavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
            HStack {
                Text("Pairing File")
                Spacer()
                Text(jit.hasPairingFile ? "pairingFile.plist" : "Not Imported")
                    .foregroundColor(jit.hasPairingFile ? .green : .secondary)
            }
            Button {
                importingPairingFile = true
            } label: {
                Label(jit.hasPairingFile ? "Replace Pairing File…" : "Import Pairing File…", systemImage: "doc.badge.plus")
            }
            .disabled(jit.builtInUnavailableReason != nil || jit.busy)

            if jit.hasPairingFile {
                Button(role: .destructive) {
                    jit.removePairingFile()
                } label: {
                    Label("Remove Pairing File", systemImage: "trash")
                }
                .disabled(jit.busy)
            }

            HStack {
                Text("LocalDevVPN")
                Spacer()
                Text(UTMLocalDevVPN.isConnected ? "Connected" : (UTMLocalDevVPN.isInstalled ? "Disconnected" : "Not Installed"))
                    .foregroundColor(UTMLocalDevVPN.isConnected ? .green : .secondary)
            }
            Button {
                UTMLocalDevVPN.open()
            } label: {
                Label(UTMLocalDevVPN.isInstalled ? "Connect LocalDevVPN" : "Get LocalDevVPN", systemImage: "network.badge.shield.half.filled")
            }

            Button {
                jit.prepareBuiltIn()
            } label: {
                HStack {
                    Label("Prepare JIT", systemImage: "bolt.badge.checkmark")
                    Spacer()
                    if jit.prepared {
                        Text("Ready")
                            .foregroundColor(.green)
                    }
                }
            }
            .disabled(jit.builtInUnavailableReason != nil || !jit.hasPairingFile || !jit.hasGetTaskAllow || jit.busy)

            Toggle("Force JIT Script", isOn: $jit.forceScript)
                .disabled(jit.builtInUnavailableReason != nil || jit.busy)

            Button(role: .destructive) {
                jit.resetDDI()
            } label: {
                Label("Reset Developer Disk Image", systemImage: "arrow.counterclockwise")
            }
            .disabled(jit.builtInUnavailableReason != nil || jit.busy)
        } header: {
            Text("Built-in StikJIT")
        } footer: {
            Text("Force JIT Script bypasses TXM detection and always runs the legacy script. Built-in StikJIT automatically prepares and attaches when you start a VM.")
        }
    }

    private var instructionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Requires iOS 17.4 or later with Developer Mode enabled.")
                Text("2. Install UTM with get-task-allow preserved.")
                Text("3. Import a pairing file or place it at Documents/StikJIT/pairingFile.plist via Finder, AFC, or idevice_pair.")
                Text("4. Connect LocalDevVPN before starting a VM.")
                Text("5. Use a Wi-Fi network when available. Without Wi-Fi, enable cellular data, connect LocalDevVPN, then enable Airplane Mode before returning to UTM.")
                Text("6. If preparation repeatedly fails, reboot your device and try again or reset the Developer Disk Image.")
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.vertical, 4)
        } header: {
            Text("Setup Instructions")
        }
    }

    private var stikDebugSection: some View {
        Section {
            HStack {
                Text("StikDebug")
                Spacer()
                Text(jit.isStikDebugInstalled ? "Installed" : "Unavailable")
                    .foregroundColor(jit.isStikDebugInstalled ? .green : .secondary)
            }
            Toggle("Force JIT Script", isOn: $jit.forceScript)
                .disabled(jit.busy)
            Button {
                jit.enableWithStikDebugFromSettings()
            } label: {
                Label("Enable JIT with StikDebug", systemImage: "ant")
            }
            .disabled(!jit.hasGetTaskAllow || jit.busy)
            if jit.isRunningInLiveContainer {
                Text("Inside LiveContainer, enable Use LiveContainer's Bundle ID in LiveContainer settings so StikDebug attaches to the container process.")
                    .font(.footnote)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("StikDebug")
        } footer: {
            Text("UTM opens StikDebug with its bundle ID and PID (and legacy.js when TXM/SPTM is present).")
        }
    }

    private var waitForDebuggerSection: some View {
        Section {
            Text("UTM will wait for an external debugger (such as Xcode, AltJIT, or JitStreamer) to attach before starting a VM.")
                .font(.footnote)
                .foregroundColor(.secondary)
            if jit.requiresScriptProtocol {
                Text("Because TXM/SPTM is active, the attached debugger must service UTM's brk #0x69 script (legacy.js).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Wait for Debugger")
        }
    }

    private var jitStatusText: String {
        if jit.isTraced {
            return "Debugger Attached"
        }
        if jit.isJITReadyForCurrentEnvironment {
            return "Ready"
        }
        return "Not Ready"
    }

    private var methodFooter: String {
        switch jit.method {
        case .builtIn:
            return "Recommended. Uses UTM's built-in StikJIT helper extension to enable JIT directly."
        case .stikDebug:
            return "Opens the standalone StikDebug app to attach to UTM."
        case .waitForDebugger:
            return "Waits for an external debugger, AltJIT, or JitStreamer."
        }
    }
}
#endif
