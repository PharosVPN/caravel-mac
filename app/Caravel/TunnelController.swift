// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    var rx: Int64?
    var tx: Int64?
}

// humanBytes formats a byte count compactly (e.g. "1.2 MB").
func humanBytes(_ n: Int64) -> String {
    let u: Double = 1024
    if n < 1024 { return "\(n) B" }
    var x = Double(n), i = 0
    let units = ["KB", "MB", "GB", "TB", "PB"]
    repeat { x /= u; i += 1 } while x >= u && i < units.count
    return String(format: "%.1f %@", x, units[i - 1])
}

// TunnelController is the app's view-model: it lists stored profiles, polls the
// worker's state file for live status, and connects / disconnects. It is fully
// offline — no network, no geolocation. (Connect/disconnect currently authorize
// each time via the system prompt; a once-installed privileged helper to make
// that one-time is the next step.)
@MainActor
final class TunnelController: ObservableObject {
    @Published var status: TunnelStatus = .disconnected
    @Published var state: TunnelState?
    @Published var profiles: [ProfileInfo] = []
    @Published var selectedProfile: String = ""
    @Published var lastError: String?

    private var timer: Timer?
    private let stateFile = "/Library/Application Support/PharosVPN/state.json"

    func start() {
        reloadProfiles()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func reloadProfiles() {
        profiles = Profiles.list()
        if selectedProfile.isEmpty || !profiles.contains(where: { $0.name == selectedProfile }) {
            selectedProfile = profiles.first?.name ?? ""
        }
    }

    // importProfile adds a .pharos file to the local store (the GUI counterpart of
    // `caravel-mac import`). The other way to get a profile — fetching it from the
    // controller via account login — is the account-sync flow (still to come).
    func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Add a .pharos profile"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pharos") ?? .data]
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dest = Profiles.dir.appendingPathComponent(src.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: Profiles.dir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            reloadProfiles()
            selectedProfile = dest.deletingPathExtension().lastPathComponent
            lastError = nil
        } catch {
            lastError = "import failed: \(error.localizedDescription)"
        }
    }

    // deleteProfile removes a file-imported profile. Cloud-synced profiles can't be
    // deleted (they'd re-sync from the controller) — disable them instead.
    func deleteProfile(_ name: String) {
        guard !(profiles.first { $0.name == name }?.cloudSynced ?? false) else { return }
        if state?.profile == name { disconnect() }
        Profiles.delete(name)
        if selectedProfile == name { selectedProfile = "" }
        reloadProfiles()
        lastError = nil
    }

    // setProfileDisabled toggles a profile off/on — the only client action allowed
    // on a cloud-synced profile.
    func setProfileDisabled(_ name: String, _ disabled: Bool) {
        if disabled, state?.profile == name { disconnect() }
        Profiles.setDisabled(name, disabled)
        reloadProfiles()
    }

    var selectedInfo: ProfileInfo? { profiles.first { $0.name == selectedProfile } }
    var connected: Bool { status == .connected }

    // clientCoord is an offline, no-permission approximation of "you": longitude
    // from the current timezone offset (no geolocation, no network).
    var clientCoord: GeoCoord {
        let lon = Double(TimeZone.current.secondsFromGMT()) / 3600.0 * 15.0
        return GeoCoord(lat: 30, lon: max(-179, min(179, lon)))
    }

    // mapPins: the "You" point + the selected profile's placeable nodes. When the
    // profile carries an egress path, the pins are its ordered hops (entry →
    // [mid] → exit, the exit marked as where traffic leaves); otherwise the
    // entry node(s) the profile lists.
    var mapPins: [MapPin] {
        let nodes: [MapPin]
        if let path = selectedInfo?.path {
            nodes = path.hops.compactMap { h -> MapPin? in
                guard let c = h.coord else { return nil }
                return MapPin(coord: c, label: h.city ?? h.name, sub: h.role.capitalized,
                              active: h.role == "exit", kind: .node)
            }
        } else {
            nodes = (selectedInfo?.nodes ?? []).compactMap { n -> MapPin? in
                guard let c = n.coord else { return nil }
                return MapPin(coord: c, label: n.city ?? n.name, sub: n.activeIP,
                              active: n.activeIP != nil, kind: .node)
            }
        }
        guard !nodes.isEmpty else { return [] }
        return [MapPin(coord: clientCoord, label: "You", sub: nil, active: connected, kind: .client)] + nodes
    }

    // mapArcs: the data-plane path (dashed) — You → the hop chain. Control-plane
    // (solid) arcs join here once the profile carries them.
    var mapArcs: [MapArc] {
        let coords: [GeoCoord]
        if let path = selectedInfo?.path {
            coords = path.hops.compactMap { $0.coord }
        } else {
            coords = (selectedInfo?.nodes ?? []).compactMap { $0.coord }
        }
        guard !coords.isEmpty else { return [] }
        let chain = [clientCoord] + coords
        return (0..<(chain.count - 1)).map {
            MapArc(points: greatCircle(chain[$0], chain[$0 + 1]), style: .dataPlane)
        }
    }

    func poll() {
        if let data = FileManager.default.contents(atPath: stateFile),
           let s = try? JSONDecoder().decode(TunnelState.self, from: data),
           processAlive(s.pid) {
            state = s
            status = .connected
        } else {
            state = nil
            if status == .connected || status == .disconnecting { status = .disconnected }
        }
    }

    // connect installs the root helper once (one authorization prompt), then
    // brings the tunnel up over the helper's control socket — no prompt per
    // connect after the first install.
    func connect() {
        guard !selectedProfile.isEmpty else { lastError = "no profile selected"; return }
        status = .connecting
        lastError = nil
        let path = Profiles.path(selectedProfile).path
        Task.detached {
            var prompted = false
            if !helperInstalled() || helperIsStale() {
                if let err = ensureHelper() {
                    await MainActor.run { [weak self] in self?.lastError = err; self?.status = .disconnected }
                    return
                }
                prompted = true
            }
            // A just-(re)installed daemon takes a moment to bind its control socket;
            // poll the connect rather than failing on the first try (the bug that
            // needed an app restart).
            var err = runCtlWaiting(["connect", path])
            // If it is still unreachable AND we have not already prompted, the
            // daemon was registered but down — (re)bootstrap it once, then retry.
            if let e = err, (e.contains("not reachable") || e.contains("refused")), !prompted {
                if let ierr = ensureHelper() { err = ierr } else { err = runCtlWaiting(["connect", path]) }
            }
            await MainActor.run { [weak self] in
                if let err { self?.lastError = err; self?.status = .disconnected }
            }
        }
    }

    func disconnect() {
        status = .disconnecting
        Task.detached {
            let err = runCtl(["disconnect"])
            await MainActor.run { [weak self] in if let err { self?.lastError = err } }
        }
    }
}

// caravelBinPath locates the worker: bundled in the .app, else a dev install.
func caravelBinPath() -> String {
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("caravel-mac").path,
       FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
    if let v = ProcessInfo.processInfo.environment["CARAVEL_MAC_BIN"], !v.isEmpty { return v }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for c in ["\(home)/go/bin/caravel-mac", "/usr/local/bin/caravel-mac", "/opt/homebrew/bin/caravel-mac"] {
        if FileManager.default.isExecutableFile(atPath: c) { return c }
    }
    return "caravel-mac"
}

// helperInstalled reports whether the root LaunchDaemon is installed.
func helperInstalled() -> Bool {
    FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/org.pharosvpn.caravel.helper.plist")
}

// helperIsStale reports whether the installed daemon differs from the app's
// bundled worker (file-size proxy), so a freshly-installed app reinstalls the
// daemon on the next connect — picking up worker changes like the RX/TX stats
// writer. Conservative: if it can't compare, it does not force a reinstall.
func helperIsStale() -> Bool {
    let fm = FileManager.default
    guard let installed = try? fm.attributesOfItem(atPath: "/Library/Application Support/PharosVPN/caravel-mac")[.size] as? Int,
          let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("caravel-mac").path,
          let bundled = try? fm.attributesOfItem(atPath: bundledPath)[.size] as? Int
    else { return false }
    return installed != bundled
}

// ensureHelper installs the privileged helper via the system authorization
// prompt (the one and only password the user is asked for). Returns an error
// message, or nil on success.
func ensureHelper() -> String? {
    runAdmin("'\(caravelBinPath())' install-helper")
}

// runCtlWaiting drives the daemon but briefly retries while the control socket is
// not yet up — a just-bootstrapped daemon needs a moment to bind, so the first
// connect after an install would otherwise fail until an app restart. Retrying a
// `connect` that never reached the daemon is safe (no tunnel was brought up).
func runCtlWaiting(_ args: [String]) -> String? {
    var err = runCtl(args)
    var tries = 0
    while let e = err, e.contains("not reachable") || e.contains("refused"), tries < 30 {
        usleep(400_000) // 0.4s, up to ~12s — covers a freshly-bootstrapped daemon
        err = runCtl(args)
        tries += 1
    }
    return err
}

// runCtl drives the daemon over its control socket via `caravel-mac ctl …` — no
// privilege needed (the daemon already holds root). Returns an error string or nil.
func runCtl(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caravelBinPath())
    p.arguments = ["ctl"] + args
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return error.localizedDescription }
    if p.terminationStatus != 0 {
        let d = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return msg.isEmpty ? "ctl exited \(p.terminationStatus)" : msg
    }
    return nil
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
