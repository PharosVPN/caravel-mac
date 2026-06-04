// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import Darwin
import Foundation
import SwiftUI

enum TunnelStatus: Equatable {
    case disconnected, connecting, connected, disconnecting

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        }
    }
}

// TunnelState mirrors the JSON the caravel-mac worker writes to the shared state
// file while connected (cmd/caravel-mac/state.go).
struct TunnelState: Codable {
    var profile: String
    var iface: String
    var endpoint: String
    var pid: Int
    var since: String
}

// TunnelController is the app's view-model: it lists stored profiles, polls the
// worker's state file for live status, resolves the map pins, and connects /
// disconnects by driving the bundled caravel-mac CLI as root through the system
// authorization prompt. No privileged daemon — the root worker is caravel-mac.
@MainActor
final class TunnelController: ObservableObject {
    @Published var status: TunnelStatus = .disconnected
    @Published var state: TunnelState?
    @Published var profiles: [ProfileInfo] = []
    @Published var selectedProfile: String = "" { didSet { Task { await updateNodeLocation() } } }
    @Published var myLocation: GeoPoint?
    @Published var nodeLocation: GeoPoint?
    @Published var lastError: String?

    private var timer: Timer?
    private var resolvedNodeIP: String = ""
    private let stateFile = "/Library/Application Support/PharosVPN/state.json"

    func start() {
        reloadProfiles()
        poll()
        Task { myLocation = await Geo.myLocation() }
        Task { await updateNodeLocation() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func reloadProfiles() {
        profiles = Profiles.list()
        if selectedProfile.isEmpty { selectedProfile = profiles.first?.name ?? "" }
    }

    var selectedInfo: ProfileInfo? { profiles.first { $0.name == selectedProfile } }

    func poll() {
        let prev = state
        if let data = FileManager.default.contents(atPath: stateFile),
           let s = try? JSONDecoder().decode(TunnelState.self, from: data),
           processAlive(s.pid) {
            state = s
            status = .connected
        } else {
            state = nil
            if status == .connected || status == .disconnecting { status = .disconnected }
        }
        if state?.endpoint != prev?.endpoint { Task { await updateNodeLocation() } }
    }

    // updateNodeLocation resolves the node pin: the live endpoint when connected,
    // else the selected (plaintext) profile's previewable endpoint.
    func updateNodeLocation() async {
        let ip: String
        if let ep = state?.endpoint, !ep.isEmpty {
            ip = Geo.hostOf(ep)
        } else if let preview = selectedInfo?.endpointIP {
            ip = preview
        } else {
            nodeLocation = nil
            resolvedNodeIP = ""
            return
        }
        if ip == resolvedNodeIP { return }
        resolvedNodeIP = ip
        nodeLocation = await Geo.locate(ip)
    }

    func connect() {
        guard !selectedProfile.isEmpty else { lastError = "no profile selected"; return }
        status = .connecting
        lastError = nil
        let path = Profiles.path(selectedProfile).path
        let cmd = "'\(caravelBin())' connect --profile '\(shellSafe(path))' >/tmp/caravel-mac.log 2>&1 &"
        Task.detached {
            let err = runAdmin(cmd)
            await MainActor.run { [weak self] in
                if let err { self?.lastError = err; self?.status = .disconnected }
            }
        }
    }

    func disconnect() {
        guard let pid = state?.pid else { status = .disconnected; return }
        status = .disconnecting
        Task.detached {
            let err = runAdmin("kill \(pid)")
            await MainActor.run { [weak self] in if let err { self?.lastError = err } }
        }
    }

    // caravelBin prefers the worker bundled in the .app (Contents/Resources),
    // then a dev install.
    private func caravelBin() -> String {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("caravel-mac").path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if let v = ProcessInfo.processInfo.environment["CARAVEL_MAC_BIN"], !v.isEmpty { return v }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for c in ["\(home)/go/bin/caravel-mac", "/usr/local/bin/caravel-mac", "/opt/homebrew/bin/caravel-mac"] {
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return "caravel-mac"
    }
}

// processAlive reports whether a pid names a live process (kill -0).
func processAlive(_ pid: Int) -> Bool { kill(pid_t(pid), 0) == 0 || errno == EPERM }

// shellSafe strips single quotes (we single-quote args in the shell command).
func shellSafe(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "") }

// runAdmin runs a shell command as root via the system authorization prompt
// (osascript). Returns an error message on failure (nil on success).
func runAdmin(_ shell: String) -> String? {
    let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let src = "do shell script \"\(escaped)\" with administrator privileges"
    var errInfo: NSDictionary?
    guard let script = NSAppleScript(source: src) else { return "could not build authorization script" }
    script.executeAndReturnError(&errInfo)
    if let errInfo, let msg = errInfo[NSAppleScript.errorMessage] as? String { return msg }
    return nil
}
