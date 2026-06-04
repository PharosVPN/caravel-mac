// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import Foundation

// ProfileInfo is what the UI shows about a stored .pharos without decrypting it.
// For plaintext (`none`) profiles we can also peek the destination node so the
// map previews the path before connecting; for password/account modes we only
// know the name + mode until the worker connects (the state file then carries
// the live endpoint).
struct ProfileInfo: Identifiable, Equatable {
    var name: String
    var enc: String
    var nodeName: String?
    var region: String?
    var endpointIP: String?

    var id: String { name }
}

enum Profiles {
    /// dir is ~/Library/Application Support/PharosVPN/profiles.
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

    /// peek reads the always-readable header and, for none-mode, the first node.
    static func peek(_ url: URL) -> ProfileInfo {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: url),
              let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              env["fmt"] as? String == "pharos-profile" else {
            return ProfileInfo(name: name, enc: "?")
        }
        let enc = env["enc"] as? String ?? "?"
        var info = ProfileInfo(name: name, enc: enc)
        if enc == "none", let payload = env["payload"] as? [String: Any],
           let nodes = payload["nodes"] as? [[String: Any]], let n0 = nodes.first {
            info.nodeName = n0["name"] as? String
            info.region = n0["region"] as? String
            info.endpointIP = firstEndpointIP(n0)
        }
        return info
    }

    private static func firstEndpointIP(_ node: [String: Any]) -> String? {
        if let protos = node["protocols"] as? [[String: Any]] {
            for p in protos where (p["type"] as? String) == "amneziawg" {
                if let params = p["params"] as? [String: Any],
                   let eps = params["endpoints"] as? [[String: Any]],
                   let ip = eps.first?["ip"] as? String { return ip }
            }
        }
        return (node["endpoints"] as? [String])?.first
    }
}
