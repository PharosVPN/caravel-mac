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

// ProfileInfo is what the UI shows about a stored .pharos. For plaintext (`none`)
// profiles we can read the nodes for the map + IP list; for password/account we
// only know the name + mode until the worker connects (the live endpoint then
// appears via the state file).
struct ProfileInfo: Identifiable, Equatable {
    var name: String
    var enc: String
    var nodes: [NodeInfo]
    var path: PathView?

    var id: String { name }
    var readable: Bool { enc == "none" }
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
            .map { peek($0) }
            .sorted { $0.name < $1.name }
    }

    static func path(_ name: String) -> URL { dir.appendingPathComponent("\(name).pharos") }

    static func peek(_ url: URL) -> ProfileInfo {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              env["fmt"] as? String == "pharos-profile" else {
            return ProfileInfo(name: name, enc: "?", nodes: [])
        }
        let enc = env["enc"] as? String ?? "?"
        var nodes: [NodeInfo] = []
        var path: PathView?
        if enc == "none", let payload = env["payload"] as? [String: Any] {
            if let raw = payload["nodes"] as? [[String: Any]] {
                nodes = raw.map { node in
                    let ips = endpointIPs(node)
                    return NodeInfo(name: node["name"] as? String ?? "node",
                                    region: node["region"] as? String,
                                    ips: ips, activeIP: ips.first, proto: protoLabel(node))
                }
            }
            path = parsePath(payload["path"])
        }
        return ProfileInfo(name: name, enc: enc, nodes: nodes, path: path)
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
