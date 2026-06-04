// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import SwiftUI

// WorldGeometry loads the bundled land GeoJSON (the same Natural-Earth land the
// website map uses) once and pre-projects it with the Natural Earth I projection.
// Everything is offline — no tiles, no network.
final class WorldGeometry {
    static let shared = WorldGeometry()

    // Land as raw-projected polygon rings, plus the raw bounds for fitting.
    private(set) var rings: [[CGPoint]] = []
    private(set) var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0

    private init() {
        guard let url = Bundle.main.url(forResource: "land", withExtension: "geojson"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = obj["features"] as? [[String: Any]] else { return }

        var (mnX, mxX, mnY, mxY) = (Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                                    Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude)
        for f in features {
            guard let geom = f["geometry"] as? [String: Any] else { continue }
            let type = geom["type"] as? String
            var polys: [[[[Double]]]] = []
            if type == "Polygon", let c = geom["coordinates"] as? [[[Double]]] { polys = [c] }
            else if type == "MultiPolygon", let c = geom["coordinates"] as? [[[[Double]]]] { polys = c }
            for poly in polys {
                for ring in poly {
                    var pts: [CGPoint] = []
                    pts.reserveCapacity(ring.count)
                    for p in ring where p.count >= 2 {
                        let (x, y) = WorldGeometry.naturalEarth1(p[0], p[1])
                        pts.append(CGPoint(x: x, y: y))
                        mnX = min(mnX, x); mxX = max(mxX, x); mnY = min(mnY, y); mxY = max(mxY, y)
                    }
                    if pts.count > 1 { rings.append(pts) }
                }
            }
        }
        (minX, maxX, minY, maxY) = (mnX, mxX, mnY, mxY)
    }

    // fit returns the scale + translation to draw the land centered in `size`.
    func fit(_ size: CGSize, pad: CGFloat = 18) -> (s: CGFloat, tx: CGFloat, ty: CGFloat) {
        let bw = maxX - minX, bh = maxY - minY
        guard bw > 0, bh > 0 else { return (1, 0, 0) }
        let s = min((size.width - 2 * pad) / bw, (size.height - 2 * pad) / bh)
        let tx = size.width / 2 - s * (minX + maxX) / 2
        let ty = size.height / 2 + s * (minY + maxY) / 2
        return (s, tx, ty)
    }

    func projectRaw(_ p: CGPoint, _ fit: (s: CGFloat, tx: CGFloat, ty: CGFloat)) -> CGPoint {
        CGPoint(x: fit.s * p.x + fit.tx, y: fit.ty - fit.s * p.y)
    }

    func project(lon: Double, lat: Double, _ fit: (s: CGFloat, tx: CGFloat, ty: CGFloat)) -> CGPoint {
        let (x, y) = WorldGeometry.naturalEarth1(lon, lat)
        return projectRaw(CGPoint(x: x, y: y), fit)
    }

    // naturalEarth1 is d3.geoNaturalEarth1Raw — the website map's projection.
    static func naturalEarth1(_ lonDeg: Double, _ latDeg: Double) -> (Double, Double) {
        let lambda = lonDeg * .pi / 180, phi = latDeg * .pi / 180
        let phi2 = phi * phi, phi4 = phi2 * phi2
        let x = lambda * (0.8707 - 0.131979 * phi2 + phi4 * (-0.013791 + phi4 * (0.003971 * phi2 - 0.001529 * phi4)))
        let y = phi * (1.007226 + phi2 * (0.015085 + phi4 * (-0.044475 + 0.028874 * phi2 - 0.005916 * phi4)))
        return (x, y)
    }
}

// LandMap draws the world + the selected profile's node(s) and any path arcs,
// fully offline, in a dark "living map" style.
struct LandMap: View {
    var nodes: [NodeInfo]
    var connected: Bool

    private let teal = Color(red: 0.31, green: 0.82, blue: 0.77)
    private let geo = WorldGeometry.shared

    // Placeable nodes (those whose region resolves to a coordinate).
    private var pins: [(node: NodeInfo, coord: GeoCoord)] {
        nodes.compactMap { n in n.coord.map { (n, $0) } }
    }

    var body: some View {
        Canvas { ctx, size in
            let fit = geo.fit(size)

            // ocean
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(
                        Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.11),
                                          Color(red: 0.03, green: 0.04, blue: 0.07)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // graticule (every 30°)
            var grat = Path()
            for lon in stride(from: -180.0, through: 180.0, by: 30) {
                var first = true
                for lat in stride(from: -80.0, through: 80.0, by: 4) {
                    let p = geo.project(lon: lon, lat: lat, fit)
                    if first { grat.move(to: p); first = false } else { grat.addLine(to: p) }
                }
            }
            for lat in stride(from: -60.0, through: 60.0, by: 30) {
                var first = true
                for lon in stride(from: -180.0, through: 180.0, by: 4) {
                    let p = geo.project(lon: lon, lat: lat, fit)
                    if first { grat.move(to: p); first = false } else { grat.addLine(to: p) }
                }
            }
            ctx.stroke(grat, with: .color(.white.opacity(0.04)), lineWidth: 0.6)

            // land
            var land = Path()
            for ring in geo.rings {
                guard let f = ring.first else { continue }
                land.move(to: geo.projectRaw(f, fit))
                for p in ring.dropFirst() { land.addLine(to: geo.projectRaw(p, fit)) }
                land.closeSubpath()
            }
            ctx.fill(land, with: .color(Color(red: 0.11, green: 0.15, blue: 0.21)))
            ctx.stroke(land, with: .color(Color(red: 0.20, green: 0.28, blue: 0.38)), lineWidth: 0.5)

            // arcs between consecutive placeable nodes (a path, when present)
            let placed = pins
            if placed.count > 1 {
                for i in 0..<(placed.count - 1) {
                    let a = placed[i].coord, b = placed[i + 1].coord
                    var arc = Path()
                    let gc = greatCircle(a, b)
                    if let f = gc.first { arc.move(to: geo.project(lon: f.lon, lat: f.lat, fit)) }
                    for c in gc.dropFirst() { arc.addLine(to: geo.project(lon: c.lon, lat: c.lat, fit)) }
                    ctx.stroke(arc, with: .color(connected ? .green : teal),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                                  dash: connected ? [] : [3, 6]))
                }
            }

            // node pins
            for (i, pin) in placed.enumerated() {
                let p = geo.project(lon: pin.coord.lon, lat: pin.coord.lat, fit)
                let active = pin.node.activeIP != nil
                let color: Color = connected ? .green : (active ? teal : .gray)
                // glow
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.45), .clear]),
                                               center: p, startRadius: 0, endRadius: 16))
                // dot
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(color))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                           with: .color(.white.opacity(0.9)), lineWidth: 1.5)
                // label
                let label = pin.node.city ?? pin.node.name
                ctx.draw(Text("\(label)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white),
                         at: CGPoint(x: p.x, y: p.y - 16), anchor: .bottom)
                _ = i
            }
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.07))
    }
}

// greatCircle interpolates the shortest path on the sphere so an arc bows like a
// flight path. (lon/lat in degrees.)
func greatCircle(_ a: GeoCoord, _ b: GeoCoord, steps: Int = 64) -> [GeoCoord] {
    let lat1 = a.lat * .pi / 180, lon1 = a.lon * .pi / 180
    let lat2 = b.lat * .pi / 180, lon2 = b.lon * .pi / 180
    let x1 = cos(lat1) * cos(lon1), y1 = cos(lat1) * sin(lon1), z1 = sin(lat1)
    let x2 = cos(lat2) * cos(lon2), y2 = cos(lat2) * sin(lon2), z2 = sin(lat2)
    let dot = max(-1, min(1, x1 * x2 + y1 * y2 + z1 * z2))
    let omega = acos(dot)
    if omega < 1e-6 { return [a, b] }
    let sinO = sin(omega)
    var out: [GeoCoord] = []
    for i in 0...steps {
        let t = Double(i) / Double(steps)
        let s1 = sin((1 - t) * omega) / sinO, s2 = sin(t * omega) / sinO
        let x = s1 * x1 + s2 * x2, y = s1 * y1 + s2 * y2, z = s1 * z1 + s2 * z2
        let lat = atan2(z, sqrt(x * x + y * y)), lon = atan2(y, x)
        out.append(GeoCoord(lat: lat * 180 / .pi, lon: lon * 180 / .pi))
    }
    return out
}
