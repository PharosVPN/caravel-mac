// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import SwiftUI

@main
struct CaravelApp: App {
    @StateObject private var tunnel = TunnelController()

    var body: some Scene {
        WindowGroup("PharosVPN") {
            ContentView()
                .environmentObject(tunnel)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { tunnel.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
