// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import Foundation

// NodeInfo is one node in a profile: its region (→ an offline map coordinate)
// and its endpoint IP pool, with the one the client dials marked active. (The
// mid/exit hops of a multi-hop path are server-side and not yet carried in the
// profile — so today a profile lists its entry node(s).)
struct NodeInfo: Identifiable, Equatable {
    var name: String
    var region: String?
    var ips: [String]
    var activeIP: String?
    var proto: String?

    var id: String { name + "|" + (region ?? "") }
    var coord: GeoCoord? { Regions.locate(region)?.coord }
    var city: String? { Regions.locate(region)?.city }
}

// PathHop is one node in a device's egress chain (entry → [mid] → exit). The
// client dials the entry; the controller routes the rest server-side.
struct PathHop: Equatable {
    var name: String
    var region: String?
    var role: String   // "entry", "mid", or "exit"
    var ips: [String]

    var coord: GeoCoord? { Regions.locate(region)?.coord }
    var city: String? { Regions.locate(region)?.city }
}

// PathView is the ordered egress chain a path-bound profile carries.
struct PathView: Equatable {
    var name: String
    var hops: [PathHop]
}

// ProfileInfo is one named profile the UI can connect with — the rendered form
// of one entry in a bundle's profiles[]. A `.pharos` bundle holds several; the
// list flattens them so each is independently selectable. `bundle` is the store
// file (connect's --profile); `profileName` is the entry within it (--name). For
// plaintext (`none`) we read the nodes for the map + IP list; for
// password/account we only know the bundle + mode until the worker connects.
struct ProfileInfo: Identifiable, Equatable {
    var bundle: String        // store name (the .pharos file)
    var profileName: String   // the named profile within the bundle ("" = legacy/opaque)
    var enc: String
    var proto: String?        // this profile's data-plane protocol
    var nodes: [NodeInfo]
    var path: PathView?
    // cloudSynced profiles come from the controller (account sync) — the client
    // may DISABLE them (they'd just re-sync) but never delete. File-imported
    // profiles can be deleted outright. Markers are per-bundle.
    var cloudSynced: Bool = false
    var disabled: Bool = false

    var id: String { bundle + "/" + profileName }
    var name: String { profileName.isEmpty ? bundle : profileName }
    var readable: Bool { enc == "none" }
    // isBoth: the profile offers both protocols; the client picks at connect.
    var isBoth: Bool { proto == "both" }
    // protoBadge is the short protocol label for the row/detail, or nil.
    var protoBadge: String? {
        switch proto {
        case "amneziawg": return "AmneziaWG"
        case "xray-reality", "xray": return "XRay"
        case "both": return "Both"
        case .some(let p) where !p.isEmpty: return p
        default: return nil
        }
    }
}

enum Profiles {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("PharosVPN", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }

    static func list() -> [ProfileInfo] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "pharos" }
            .flatMap { peek($0) }
            .sorted { ($0.bundle, $0.name) < ($1.bundle, $1.name) }
    }

    static func path(_ name: String) -> URL { dir.appendingPathComponent("\(name).pharos") }

    // Sidecar markers: `<name>.synced` is written by account-sync (a cloud profile,
    // disable-only), `<name>.disabled` toggles a profile off.
    static func markerURL(_ name: String, _ ext: String) -> URL { dir.appendingPathComponent("\(name).\(ext)") }
    static func isCloudSynced(_ name: String) -> Bool { FileManager.default.fileExists(atPath: markerURL(name, "synced").path) }
    static func isDisabled(_ name: String) -> Bool { FileManager.default.fileExists(atPath: markerURL(name, "disabled").path) }

    // delete removes a file-imported profile and its markers. Cloud-synced
    // profiles must not be deleted (they'd re-sync) — disable them instead.
    static func delete(_ name: String) {
        guard !isCloudSynced(name) else { return }
        try? FileManager.default.removeItem(at: path(name))
        try? FileManager.default.removeItem(at: markerURL(name, "disabled"))
    }

    static func setDisabled(_ name: String, _ disabled: Bool) {
        let u = markerURL(name, "disabled")
        if disabled { try? Data().write(to: u) } else { try? FileManager.default.removeItem(at: u) }
    }

    // peek expands one stored bundle into its named profiles (profiles[]). A
    // plaintext bundle yields one ProfileInfo per named profile; an opaque
    // (password/account) or unreadable bundle yields a single placeholder whose
    // details appear once the worker connects.
    static func peek(_ url: URL) -> [ProfileInfo] {
        let bundle = url.deletingPathExtension().lastPathComponent
        let synced = isCloudSynced(bundle), off = isDisabled(bundle)
        let opaque = { (enc: String) in
            [ProfileInfo(bundle: bundle, profileName: "", enc: enc, nodes: [], cloudSynced: synced, disabled: off)]
        }
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              env["fmt"] as? String == "pharos-profile" else {
            return opaque("?")
        }
        let enc = env["enc"] as? String ?? "?"
        guard enc == "none", let payload = env["payload"] as? [String: Any],
              let profs = payload["profiles"] as? [[String: Any]], !profs.isEmpty else {
            return opaque(enc)
        }
        return profs.map { pr in
            let nodesRaw = pr["nodes"] as? [[String: Any]] ?? []
            let nodes = nodesRaw.map { node -> NodeInfo in
                let ips = endpointIPs(node)
                return NodeInfo(name: node["name"] as? String ?? "node",
                                region: node["region"] as? String,
                                ips: ips, activeIP: ips.first, proto: protoLabel(node))
            }
            return ProfileInfo(bundle: bundle,
                               profileName: pr["name"] as? String ?? "profile",
                               enc: enc,
                               proto: pr["protocol"] as? String,
                               nodes: nodes,
                               path: parsePath(pr["path"]),
                               cloudSynced: synced, disabled: off)
        }
    }

    // parsePath reads the optional egress-chain display metadata (entry → [mid]
    // → exit). Present only for a device bound to a multi-hop path.
    private static func parsePath(_ raw: Any?) -> PathView? {
        guard let pj = raw as? [String: Any],
              let hopsj = pj["hops"] as? [[String: Any]], !hopsj.isEmpty else { return nil }
        let hops = hopsj.map { h in
            PathHop(name: h["name"] as? String ?? "node",
                    region: h["region"] as? String,
                    role: h["role"] as? String ?? "",
                    ips: h["ips"] as? [String] ?? [])
        }
        return PathView(name: pj["name"] as? String ?? "path", hops: hops)
    }

    // protoLabel lists the node's protocol(s) for display. Only AmneziaWG is
    // implemented today; XRay shows here once the engine supports it.
    private static func protoLabel(_ node: [String: Any]) -> String? {
        guard let protos = node["protocols"] as? [[String: Any]] else { return nil }
        let names = protos.compactMap { $0["type"] as? String }.map { t -> String in
            switch t {
            case "amneziawg": return "AmneziaWG"
            case "xray": return "XRay"
            default: return t
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // endpointIPs returns a node's endpoint pool IPs (the multiple IPs per node,
    // decision 17), falling back to the node's flat endpoint list.
    private static func endpointIPs(_ node: [String: Any]) -> [String] {
        if let protos = node["protocols"] as? [[String: Any]] {
            for p in protos where (p["type"] as? String) == "amneziawg" {
                if let params = p["params"] as? [String: Any],
                   let eps = params["endpoints"] as? [[String: Any]] {
                    let ips = eps.compactMap { $0["ip"] as? String }
                    if !ips.isEmpty { return ips }
                }
            }
        }
        return (node["endpoints"] as? [String]) ?? []
    }
}
