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
    var proto: String?
    var iface: String
    var endpoint: String
    var pid: Int
    var since: String
    var rx: Int64?
    var tx: Int64?

    // protoLabel is the live data-plane protocol for display, or nil.
    var protoLabel: String? {
        switch proto {
        case "amneziawg": return "AmneziaWG"
        case "xray-reality", "xray": return "XRay/REALITY"
        default: return nil
        }
    }
}

// ControllerStatus mirrors `caravel-mac controller-status` — the cloud session's
// liveness. reachable is informational (the data plane runs without it).
struct ControllerStatus: Codable, Equatable {
    var reachable: Bool
    var last_synced_at: String?
    var relay: String?
    var controller: Endpoint?

    struct Endpoint: Codable, Equatable {
        var label: String
        var city: String?
        var lat: Double
        var lon: Double
    }

    // lastSyncedAgo renders the last-sync time compactly (e.g. "3m ago").
    var lastSyncedAgo: String? {
        guard let s = last_synced_at,
              let t = ISO8601DateFormatter().date(from: s) else { return nil }
        let d = Date().timeIntervalSince(t)
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60))m ago" }
        if d < 86_400 { return "\(Int(d / 3600))h ago" }
        return "\(Int(d / 86_400))d ago"
    }
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
    // Data-plane protocol: "auto" (prefer AmneziaWG), "amneziawg", or "xray"
    // (VLESS+REALITY). Passed to the worker on connect.
    @Published var proto: String = "auto"
    @Published var lastError: String?
    // controller is the cloud session's liveness (reachable + last sync); nil
    // until refreshed or when no cloud profile is present.
    @Published var controller: ControllerStatus?
    // needsLogin asks the UI to open the sync sheet (no stored passphrase).
    @Published var needsLogin = false

    private var timer: Timer?
    private var ctlTimer: Timer?
    private let stateFile = "/Library/Application Support/PharosVPN/state.json"

    func start() {
        reloadProfiles()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Controller liveness is cheap-but-not-free (a TLS dial) — poll it gently.
        refreshController()
        ctlTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshController() }
        }
    }

    // cloudInfo is the cloud-synced bundle to act on — the selected one if it is
    // cloud, else the first cloud profile in the list.
    var cloudInfo: ProfileInfo? {
        if let s = selectedInfo, s.cloudSynced { return s }
        return profiles.first { $0.cloudSynced }
    }
    var loggedIn: Bool { Keychain.hasCredential }

    // refreshController re-reads the cloud bundle's controller status (reachable +
    // last sync + location) off the main thread.
    func refreshController() {
        guard let bundle = cloudInfo?.bundle else {
            controller = nil
            return
        }
        Task.detached {
            let st = runControllerStatus(bundle: bundle)
            await MainActor.run { [weak self] in self?.controller = st }
        }
    }

    // syncNow re-fetches the cloud bundle using the stored passphrase (one tap).
    // With no stored passphrase it asks the UI to open the sync sheet.
    func syncNow() {
        guard let info = cloudInfo else { return }
        guard let pass = Keychain.read() else {
            needsLogin = true
            return
        }
        let pidPath = Profiles.dir.appendingPathComponent(info.bundle + ".pharosid").path
        status = .connecting // reuse the busy state for the spinner
        lastError = nil
        Task.detached {
            let (_, err) = runSync(bundle: pidPath, email: "", password: pass)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = self.state == nil ? .disconnected : .connected
                if let err { self.lastError = "sync failed: \(err)" }
                self.reloadProfiles()
                self.refreshController()
            }
        }
    }

    // logout removes every cloud profile and the stored passphrase, disconnecting
    // first if a cloud profile is up.
    func logout() {
        if state != nil { disconnect() }
        Task.detached {
            _ = runWorker(["logout"])
            await MainActor.run { [weak self] in
                guard let self else { return }
                Keychain.delete()
                self.controller = nil
                self.selectedProfile = ""
                self.reloadProfiles()
                self.lastError = nil
            }
        }
    }

    func reloadProfiles() {
        profiles = Profiles.list()
        if selectedProfile.isEmpty || !profiles.contains(where: { $0.id == selectedProfile }) {
            selectedProfile = profiles.first?.id ?? ""
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

    // pickDeviceBundle opens a panel to choose a `.pharosid` device file (the
    // offline identity `cox devices issue` produces). Returns nil if cancelled.
    func pickDeviceBundle() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose your .pharosid device file"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pharosid") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }

    // syncFromController fetches the account's end-to-end-encrypted profile from
    // the controller (through the relay in the device bundle), decrypts it on this
    // Mac, and stores it as a cloud-synced profile — the GUI counterpart of
    // `caravel-mac sync`. The controller only ever serves ciphertext.
    func syncFromController(bundle: URL, email: String, password: String) {
        status = .connecting // reuse the busy state for the spinner
        lastError = nil
        Task.detached {
            let (name, err) = runSync(bundle: bundle.path, email: email, password: password)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = self.state == nil ? .disconnected : .connected
                if let err {
                    self.lastError = "sync failed: \(err)"
                    return
                }
                Keychain.store(password) // logged in — one-tap re-sync from now on
                self.needsLogin = false
                self.reloadProfiles()
                if let name, let first = self.profiles.first(where: { $0.bundle == name }) {
                    self.selectedProfile = first.id
                }
                self.refreshController()
                self.lastError = nil
            }
        }
    }

    // enrollDevice redeems a `pharosvpn://enroll` join link: the worker generates
    // this Mac's device key on-device, claims the one-time ticket through the relay
    // (no passphrase), and stores the per-device-sealed profile cloud-marked — the
    // GUI counterpart of `caravel-mac enroll`. There is no passphrase to keep.
    func enrollDevice(link: String, deviceName: String) {
        status = .connecting // reuse the busy state for the spinner
        lastError = nil
        Task.detached {
            let (name, err) = runEnroll(link: link, deviceName: deviceName)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = self.state == nil ? .disconnected : .connected
                if let err {
                    self.lastError = "enrollment failed: \(err)"
                    return
                }
                self.needsLogin = false
                self.reloadProfiles()
                if let name, let first = self.profiles.first(where: { $0.bundle == name }) {
                    self.selectedProfile = first.id
                }
                self.refreshController()
                self.lastError = nil
            }
        }
    }

    // deleteProfile removes a file-imported bundle (all its profiles). Cloud-synced
    // bundles can't be deleted (they'd re-sync from the controller) — disable them
    // instead. Keyed on the bundle (the .pharos file), since markers are per-bundle.
    func deleteProfile(_ bundle: String) {
        guard !(profiles.first { $0.bundle == bundle }?.cloudSynced ?? false) else { return }
        Profiles.delete(bundle)
        if selectedInfo?.bundle == bundle { selectedProfile = "" }
        reloadProfiles()
        lastError = nil
    }

    // setProfileDisabled toggles a bundle off/on — the only client action allowed
    // on a cloud-synced bundle.
    func setProfileDisabled(_ bundle: String, _ disabled: Bool) {
        Profiles.setDisabled(bundle, disabled)
        reloadProfiles()
    }

    var selectedInfo: ProfileInfo? { profiles.first { $0.id == selectedProfile } }
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
    var controllerReachable: Bool { controller?.reachable ?? false }

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
        // The controller (control plane), placed from the bundle's embedded coords.
        var ctlPins: [MapPin] = []
        if let ctl = selectedInfo?.control {
            ctlPins.append(MapPin(coord: ctl.coord, label: ctl.city ?? ctl.label,
                                  sub: "Controller", active: controllerReachable, kind: .controller))
        }
        guard !nodes.isEmpty || !ctlPins.isEmpty else { return [] }
        return [MapPin(coord: clientCoord, label: "You", sub: nil, active: connected, kind: .client)]
            + ctlPins + nodes
    }

    // mapArcs: the data-plane path (dashed) — You → the hop chain. Control-plane
    // (solid) arcs join here once the profile carries them.
    var mapArcs: [MapArc] {
        var arcs: [MapArc] = []
        // Data plane (dashed): You → the egress chain / entry node(s).
        let coords: [GeoCoord]
        if let path = selectedInfo?.path {
            coords = path.hops.compactMap { $0.coord }
        } else {
            coords = (selectedInfo?.nodes ?? []).compactMap { $0.coord }
        }
        if !coords.isEmpty {
            let chain = [clientCoord] + coords
            arcs += (0..<(chain.count - 1)).map {
                MapArc(points: greatCircle(chain[$0], chain[$0 + 1]), style: .dataPlane)
            }
        }
        // Control plane (solid): You → the controller, the line you sync over.
        if let ctl = selectedInfo?.control {
            arcs.append(MapArc(points: greatCircle(clientCoord, ctl.coord), style: .controlPlane))
        }
        return arcs
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
        guard let info = selectedInfo else { lastError = "no profile selected"; return }
        status = .connecting
        lastError = nil
        let path = Profiles.path(info.bundle).path
        let pname = info.profileName
        let proto = self.proto
        let isBoth = info.isBoth
        Task.detached {
            var prompted = false
            if !helperInstalled() || helperIsStale() {
                if let err = ensureHelper() {
                    await MainActor.run { [weak self] in self?.lastError = err; self?.status = .disconnected }
                    return
                }
                prompted = true
            }
            // The chosen named profile carries its own protocol → connect by --name.
            // A "both" profile additionally honors --protocol (the picker). A
            // legacy/opaque bundle (no named profile) falls back to --protocol.
            var connectArgs = ["connect", path]
            if pname.isEmpty {
                connectArgs += ["--protocol", proto]
            } else {
                connectArgs += ["--name", pname]
                if isBoth {
                    connectArgs += ["--protocol", proto]
                }
            }
            // A just-(re)installed daemon takes a moment to bind its control socket;
            // poll the connect rather than failing on the first try (the bug that
            // needed an app restart).
            var err = runCtlWaiting(connectArgs)
            // If it is still unreachable AND we have not already prompted, the
            // daemon was registered but down — (re)bootstrap it once, then retry.
            if let e = err, (e.contains("not reachable") || e.contains("refused")), !prompted {
                if let ierr = ensureHelper() { err = ierr } else { err = runCtlWaiting(connectArgs) }
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

// runSync runs `caravel-mac sync`, piping the account passphrase on stdin so it
// never lands in the argv / process table. Returns the stored profile name (on
// success) and an error string (on failure).
func runSync(bundle: String, email: String, password: String) -> (name: String?, error: String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caravelBinPath())
    var args = ["sync", bundle]
    if !email.isEmpty { args += ["--email", email] }
    args += ["--password-stdin"]
    p.arguments = args
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (nil, error.localizedDescription) }
    inPipe.fileHandleForWriting.write(Data((password + "\n").utf8))
    try? inPipe.fileHandleForWriting.close()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (nil, msg.isEmpty ? "sync exited \(p.terminationStatus)" : msg)
    }
    // Worker prints: synced profile "NAME" (rev N, …) — pull NAME out for selection.
    let out = String(data: outData, encoding: .utf8) ?? ""
    var name: String?
    if let lo = out.firstIndex(of: "\""),
       let hi = out[out.index(after: lo)...].firstIndex(of: "\"") {
        name = String(out[out.index(after: lo)..<hi])
    }
    return (name, nil)
}

// runEnroll runs `caravel-mac enroll <link>`, returning the stored profile name
// (on success) and an error string (on failure). Enrollment needs no passphrase —
// the join link carries the one-time ticket; the device key is generated on-device.
func runEnroll(link: String, deviceName: String) -> (name: String?, error: String?) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caravelBinPath())
    var args = ["enroll", link]
    if !deviceName.isEmpty { args += ["--name", deviceName] }
    p.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch { return (nil, error.localizedDescription) }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (nil, msg.isEmpty ? "enroll exited \(p.terminationStatus)" : msg)
    }
    // Worker prints: enrolled "NAME" → path — pull NAME out for selection.
    let out = String(data: outData, encoding: .utf8) ?? ""
    var name: String?
    if let lo = out.firstIndex(of: "\""),
       let hi = out[out.index(after: lo)...].firstIndex(of: "\"") {
        name = String(out[out.index(after: lo)..<hi])
    }
    return (name, nil)
}

// runControllerStatus runs `caravel-mac controller-status <bundle>` and decodes
// the JSON. Returns nil on any failure (treated as "unknown / unreachable").
func runControllerStatus(bundle: String) -> ControllerStatus? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caravelBinPath())
    p.arguments = ["controller-status", bundle]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return try? JSONDecoder().decode(ControllerStatus.self, from: data)
}

// runWorker runs the bundled worker directly (no privilege) — used for `logout`.
func runWorker(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: caravelBinPath())
    p.arguments = args
    let errPipe = Pipe()
    p.standardError = errPipe
    p.standardOutput = Pipe()
    do { try p.run(); p.waitUntilExit() } catch { return error.localizedDescription }
    if p.terminationStatus != 0 {
        let d = errPipe.fileHandleForReading.readDataToEndOfFile()
        let msg = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return msg.isEmpty ? "worker exited \(p.terminationStatus)" : msg
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
