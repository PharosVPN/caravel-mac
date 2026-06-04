// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import Foundation

// GeoCoord is a plain lat/lon (no MapKit / no network).
struct GeoCoord: Equatable {
    var lat: Double
    var lon: Double
}

// Regions maps a node's region code to coordinates entirely offline — the same
// idea as the website's geo.ts fallback table, so a node lands on its city
// without any IP-geolocation lookup. Unknown regions return nil (no pin).
enum Regions {
    private static let table: [String: (GeoCoord, String)] = [
        // DigitalOcean regions (+ a few common provider cities).
        "nyc1": (GeoCoord(lat: 40.71, lon: -74.01), "New York"),
        "nyc2": (GeoCoord(lat: 40.71, lon: -74.01), "New York"),
        "nyc3": (GeoCoord(lat: 40.71, lon: -74.01), "New York"),
        "sfo1": (GeoCoord(lat: 37.77, lon: -122.42), "San Francisco"),
        "sfo2": (GeoCoord(lat: 37.77, lon: -122.42), "San Francisco"),
        "sfo3": (GeoCoord(lat: 37.77, lon: -122.42), "San Francisco"),
        "tor1": (GeoCoord(lat: 43.65, lon: -79.38), "Toronto"),
        "ams2": (GeoCoord(lat: 52.37, lon: 4.90), "Amsterdam"),
        "ams3": (GeoCoord(lat: 52.37, lon: 4.90), "Amsterdam"),
        "lon1": (GeoCoord(lat: 51.51, lon: -0.13), "London"),
        "fra1": (GeoCoord(lat: 50.11, lon: 8.68), "Frankfurt"),
        "sgp1": (GeoCoord(lat: 1.35, lon: 103.82), "Singapore"),
        "blr1": (GeoCoord(lat: 12.97, lon: 77.59), "Bangalore"),
        "syd1": (GeoCoord(lat: -33.87, lon: 151.21), "Sydney"),
        // Bare country / city codes that may appear in a region field.
        "us": (GeoCoord(lat: 39.0, lon: -98.0), "United States"),
        "eu": (GeoCoord(lat: 50.0, lon: 9.0), "Europe"),
        "nl": (GeoCoord(lat: 52.37, lon: 4.90), "Netherlands"),
        "de": (GeoCoord(lat: 51.0, lon: 9.0), "Germany"),
        "gb": (GeoCoord(lat: 51.51, lon: -0.13), "United Kingdom"),
        "uk": (GeoCoord(lat: 51.51, lon: -0.13), "United Kingdom"),
        "sg": (GeoCoord(lat: 1.35, lon: 103.82), "Singapore"),
        "in": (GeoCoord(lat: 20.6, lon: 78.96), "India"),
        "au": (GeoCoord(lat: -33.87, lon: 151.21), "Australia"),
        "ca": (GeoCoord(lat: 43.65, lon: -79.38), "Canada"),
    ]

    /// locate returns the coordinate + a display city for a region code, or nil.
    static func locate(_ region: String?) -> (coord: GeoCoord, city: String)? {
        guard let r = region?.lowercased(), !r.isEmpty else { return nil }
        if let hit = table[r] { return (hit.0, hit.1) }
        // A region like "eu-nl" → try the trailing country, then the leading area.
        let parts = r.split(separator: "-").map(String.init)
        for p in parts.reversed() {
            if let hit = table[p] { return (hit.0, hit.1) }
        }
        return nil
    }
}
