// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tunnel: TunnelController

    private let teal = Color(red: 0.31, green: 0.82, blue: 0.77)
    private var connected: Bool { tunnel.status == .connected }
    private var busy: Bool { tunnel.status == .connecting || tunnel.status == .disconnecting }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            LandMap(pins: tunnel.mapPins, arcs: tunnel.mapArcs, connected: connected)
                .frame(minWidth: 480)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 880, minHeight: 580)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // brand
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(teal)
                Text("PharosVPN").font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)

            // profiles
            HStack {
                Text("PROFILES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { tunnel.importProfile() } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).help("Add a .pharos file")
                Button {
                    tunnel.lastError = "Fetch-from-controller (account login) is coming — for now, add a .pharos file."
                } label: { Image(systemName: "icloud.and.arrow.down") }
                    .buttonStyle(.plain).help("Get from controller (account sync — coming)")
            }
            .padding(.horizontal, 16)
            List(selection: Binding(get: { tunnel.selectedProfile },
                                    set: { tunnel.selectedProfile = $0 ?? "" })) {
                ForEach(tunnel.profiles) { p in
                    HStack {
                        Image(systemName: "globe").font(.caption).foregroundStyle(teal.opacity(0.8))
                        Text(p.name)
                        Spacer()
                        Text(p.enc).font(.caption2).foregroundStyle(.secondary)
                    }
                    .tag(p.name)
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: 220)

            if tunnel.profiles.isEmpty {
                Text("No profiles. Import one:\n caravel-mac import <file.pharos>")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }

            Divider().padding(.vertical, 6)

            detail.padding(.horizontal, 16)

            Spacer(minLength: 8)
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
    }

    @ViewBuilder private var detail: some View {
        // status + action
        HStack(spacing: 8) {
            Circle().fill(connected ? .green : (busy ? .yellow : .gray)).frame(width: 9, height: 9)
                .shadow(color: connected ? .green : .clear, radius: 4)
            Text(tunnel.status.label).font(.subheadline.weight(.semibold))
            Spacer()
        }

        Button(action: toggle) {
            Text(connected || tunnel.status == .disconnecting ? "Disconnect" : "Connect")
                .frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(connected || tunnel.status == .disconnecting ? .red : teal)
        .disabled(busy || tunnel.selectedProfile.isEmpty)
        .padding(.top, 6)

        if connected, let s = tunnel.state {
            Label(s.endpoint, systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            HStack(spacing: 14) {
                Label(humanBytes(s.rx ?? 0), systemImage: "arrow.down")
                    .foregroundStyle(.green)
                Label(humanBytes(s.tx ?? 0), systemImage: "arrow.up")
                    .foregroundStyle(teal)
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.top, 2)
        }

        // nodes + IPs
        if let info = tunnel.selectedInfo {
            if info.nodes.isEmpty {
                Text(info.readable ? "no nodes in this profile"
                                   : "encrypted profile — details appear once connected")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(info.nodes) { node in nodeCard(node) }
                    }
                }
                .padding(.top, 10)
            }
        }

        if let err = tunnel.lastError {
            Text(err).font(.caption2).foregroundStyle(.red).lineLimit(3).padding(.top, 6)
        }
    }

    private func nodeCard(_ node: NodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.caption).foregroundStyle(teal)
                Text(node.name).font(.subheadline.weight(.semibold))
                if let city = node.city {
                    Text("· \(city)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let proto = node.proto {
                    Text(proto)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(teal.opacity(0.15), in: Capsule())
                        .foregroundStyle(teal)
                }
            }
            ForEach(node.ips, id: \.self) { ip in
                HStack(spacing: 6) {
                    Circle()
                        .fill(ip == node.activeIP ? teal : Color.gray.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(ip).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ip == node.activeIP ? .primary : .secondary)
                    if ip == node.activeIP {
                        Text("active").font(.caption2).foregroundStyle(teal)
                    }
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toggle() {
        if connected || tunnel.status == .disconnecting { tunnel.disconnect() } else { tunnel.connect() }
    }
}
