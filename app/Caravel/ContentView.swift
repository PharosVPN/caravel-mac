// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelController

    private var connected: Bool { tunnel.status == .connected }
    private var busy: Bool { tunnel.status == .connecting || tunnel.status == .disconnecting }

    private var nodeName: String {
        tunnel.selectedInfo?.nodeName ?? tunnel.state?.profile ?? tunnel.selectedProfile
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PathMap(me: tunnel.myLocation, node: tunnel.nodeLocation,
                    nodeName: nodeName, connected: connected)
                .ignoresSafeArea()

            controlCard
                .frame(maxWidth: 560)
                .padding(20)
        }
        .preferredColorScheme(.dark)
    }

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // status + route
            HStack(spacing: 10) {
                Circle()
                    .fill(connected ? Color.green : (busy ? Color.yellow : Color.gray))
                    .frame(width: 10, height: 10)
                    .shadow(color: connected ? .green : .clear, radius: 5)
                Text(tunnel.status.label).font(.headline)
                Spacer()
                if connected, let s = tunnel.state {
                    Text(s.endpoint).font(.caption).foregroundStyle(.secondary)
                }
            }

            route

            // controls
            HStack(spacing: 12) {
                Picker("", selection: $tunnel.selectedProfile) {
                    if tunnel.profiles.isEmpty {
                        Text("no profiles — import one with caravel-mac").tag("")
                    }
                    ForEach(tunnel.profiles) { p in
                        Text("\(p.name)  (\(p.enc))").tag(p.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .disabled(connected || busy)

                Button(action: toggle) {
                    Text(connected || tunnel.status == .disconnecting ? "Disconnect" : "Connect")
                        .frame(width: 110)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(connected || tunnel.status == .disconnecting ? .red : .accentColor)
                .disabled(busy || tunnel.selectedProfile.isEmpty)
            }

            if let err = tunnel.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }

    private var route: some View {
        HStack(spacing: 10) {
            endpoint(title: "You", place: tunnel.myLocation?.label ?? "locating…",
                     symbol: "location.fill", color: .cyan)
            Image(systemName: "arrow.right")
                .foregroundStyle(connected ? .green : .secondary)
            endpoint(title: nodeName.isEmpty ? "Exit" : nodeName,
                     place: tunnel.nodeLocation?.label ?? (tunnel.selectedProfile.isEmpty ? "—" : "resolving…"),
                     symbol: "shield.lefthalf.filled", color: connected ? .green : .gray)
        }
    }

    private func endpoint(title: String, place: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(place).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        if connected || tunnel.status == .disconnecting {
            tunnel.disconnect()
        } else {
            tunnel.connect()
        }
    }
}
