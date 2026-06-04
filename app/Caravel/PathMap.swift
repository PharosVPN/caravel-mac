// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import MapKit
import SwiftUI

// PathMap draws the connection path on the world: your location, the node you
// (will) egress through, and a great-circle arc between them. The arc highlights
// (solid, brighter) when the tunnel is up, and is a faint dashed preview when
// it isn't.
struct PathMap: View {
    var me: GeoPoint?
    var node: GeoPoint?
    var nodeName: String
    var connected: Bool

    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            if let me {
                Annotation("You", coordinate: me.coordinate) {
                    Pin(symbol: "location.fill", color: .cyan, pulse: connected)
                }
            }
            if let node {
                Annotation(nodeName, coordinate: node.coordinate) {
                    Pin(symbol: "shield.lefthalf.filled", color: connected ? .green : .gray, pulse: connected)
                }
            }
            if let me, let node {
                MapPolyline(coordinates: greatCircle(me.coordinate, node.coordinate))
                    .stroke(
                        connected ? Color.green : Color.cyan.opacity(0.55),
                        style: StrokeStyle(lineWidth: connected ? 3 : 2, lineCap: .round,
                                           dash: connected ? [] : [3, 7]))
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .onChange(of: me) { refit() }
        .onChange(of: node) { refit() }
    }

    private func refit() {
        // Re-frame to fit both endpoints with a little padding.
        camera = .automatic
    }
}

// Pin is a glowing map marker.
private struct Pin: View {
    var symbol: String
    var color: Color
    var pulse: Bool
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.18)).frame(width: 34, height: 34)
                .scaleEffect(pulse && animate ? 1.5 : 1.0)
                .opacity(pulse && animate ? 0.0 : 0.6)
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
        }
        .shadow(color: color.opacity(0.6), radius: 6)
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true }
        }
    }
}

// greatCircle returns interpolated points along the shortest path on the sphere,
// so the polyline bows like a flight path rather than a straight screen line.
func greatCircle(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, steps: Int = 72) -> [CLLocationCoordinate2D] {
    let lat1 = a.latitude * .pi / 180, lon1 = a.longitude * .pi / 180
    let lat2 = b.latitude * .pi / 180, lon2 = b.longitude * .pi / 180

    let x1 = cos(lat1) * cos(lon1), y1 = cos(lat1) * sin(lon1), z1 = sin(lat1)
    let x2 = cos(lat2) * cos(lon2), y2 = cos(lat2) * sin(lon2), z2 = sin(lat2)

    let dot = max(-1, min(1, x1 * x2 + y1 * y2 + z1 * z2))
    let omega = acos(dot)
    if omega < 1e-6 { return [a, b] }
    let sinOmega = sin(omega)

    var out: [CLLocationCoordinate2D] = []
    out.reserveCapacity(steps + 1)
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let s1 = sin((1 - t) * omega) / sinOmega
        let s2 = sin(t * omega) / sinOmega
        let x = s1 * x1 + s2 * x2
        let y = s1 * y1 + s2 * y2
        let z = s1 * z1 + s2 * z2
        let lat = atan2(z, sqrt(x * x + y * y))
        let lon = atan2(y, x)
        out.append(CLLocationCoordinate2D(latitude: lat * 180 / .pi, longitude: lon * 180 / .pi))
    }
    return out
}
