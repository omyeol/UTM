//
// Copyright © 2022 osy. All rights reserved.
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

import SwiftUI

struct UTMSettingsView: View {
    enum Tab: Hashable {
        case general
        case jit
    }

    @Environment(\.presentationMode) private var presentationMode: Binding<PresentationMode>
    @State private var selectedTab: Tab

    init(initialTab: Tab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }
    
    private var hasContainer: Bool {
        #if WITH_JIT
        jb_has_container()
        #else
        true
        #endif
    }

    #if WITH_JIT && os(iOS)
    @ObservedObject private var jit = UTMJITCoordinator.shared
    #endif

    var body: some View {
        NavigationView {
            content
                .navigationTitle(selectedTab == .jit ? "JIT" : "Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Close") {
                            presentationMode.wrappedValue.dismiss()
                        }
                    }
                    #if WITH_JIT && os(iOS)
                    ToolbarItem(placement: .principal) {
                        Picker("Settings Section", selection: $selectedTab) {
                            Text("General").tag(Tab.general)
                            Text("JIT").tag(Tab.jit)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 200)
                    }
                    #endif
                }
        }.navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        #if WITH_JIT && os(iOS)
        if selectedTab == .jit {
            UTMJITSettingsView()
        } else {
            VStack(spacing: 0) {
                Button {
                    selectedTab = .jit
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: jit.isJITReadyForCurrentEnvironment ? "bolt.circle.fill" : "bolt.fill")
                            .font(.title3)
                            .foregroundColor(jit.isJITReadyForCurrentEnvironment ? .green : .accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("JIT & Built-in StikJIT")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            Text(jitBannerSubtitle)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("Configure")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                }
                Divider()
                IASKAppSettings()
                    .appSettingsShowPrivacyLink(hasContainer)
            }
        }
        #else
        IASKAppSettings()
            .appSettingsShowPrivacyLink(hasContainer)
        #endif
    }

    #if WITH_JIT && os(iOS)
    private var jitBannerSubtitle: String {
        if jit.isJITReadyForCurrentEnvironment {
            return jit.isTraced ? "\(jit.method.title) · Debugger Attached" : "\(jit.method.title) · Ready"
        }
        if jit.method == .builtIn && !jit.hasPairingFile {
            return "Built-in StikJIT · Needs Developer Mode Pairing or Pairing File"
        }
        return "\(jit.method.title) · Tap to Enable or Configure"
    }
    #endif
}

struct UTMSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        UTMSettingsView()
    }
}
