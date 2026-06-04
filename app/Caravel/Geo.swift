// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import CoreLocation
import Foundation

// GeoPoint is a resolved location for a pin on the map.
struct GeoPoint: Equatable {
    var coordinate: CLLocationCoordinate2D
    var city: String
    var country: String

    var label: String {
        [city, country].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (a: CLLocationCoordinate2D, b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}

// Geo resolves IP addresses to coordinates over HTTPS (no ATS exception needed),
// for drawing your location and the node you're connected to.
enum Geo {
    private struct WhoIs: Decodable {
        var latitude: Double?
        var longitude: Double?
        var city: String?
        var country: String?
        var ip: String?
        var success: Bool?
    }

    /// locate resolves an IP (or the caller's own IP when ip is empty) to a GeoPoint.
    static func locate(_ ip: String) async -> GeoPoint? {
        let url = ip.isEmpty
            ? URL(string: "https://ipwho.is/")!
            : URL(string: "https://ipwho.is/\(ip)")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let w = try? JSONDecoder().decode(WhoIs.self, from: data),
              let lat = w.latitude, let lon = w.longitude, (w.success ?? true) else {
            return nil
        }
        return GeoPoint(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            city: w.city ?? "", country: w.country ?? "")
    }

    /// myLocation resolves the caller's public IP location.
    static func myLocation() async -> GeoPoint? { await locate("") }

    /// hostOf strips a port from a "host:port" endpoint.
    static func hostOf(_ endpoint: String) -> String {
        if let i = endpoint.lastIndex(of: ":"), !endpoint.contains("]") {
            return String(endpoint[..<i])
        }
        return endpoint
    }
}
