// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 The PharosVPN Authors

import SwiftUI

// ───────── map model ─────────

enum PinKind { case client, node, relay, controller }

struct MapPin: Identifiable, Equatable {
    var id = UUID()
    var coord: GeoCoord
    var label: String
    var sub: String?
    var active: Bool
    var kind: PinKind
}

// ArcStyle follows the platform convention (DESIGN §3): the data plane is dashed,
// the control plane is solid.
enum ArcStyle { case dataPlane, controlPlane }

struct MapArc: Identifiable, Equatable {
    var id = UUID()
    var points: [GeoCoord]
    var style: ArcStyle
}

// ───────── world geometry (offline land + naturalEarth1) ─────────

final class WorldGeometry {
    static let shared = WorldGeometry()
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

    func fit(_ size: CGSize, pad: CGFloat = 18) -> (s: CGFloat, tx: CGFloat, ty: CGFloat) {
        let bw = maxX - minX, bh = maxY - minY
        guard bw > 0, bh > 0 else { return (1, 0, 0) }
        let s = min((size.width - 2 * pad) / bw, (size.height - 2 * pad) / bh)
        return (s, size.width / 2 - s * (minX + maxX) / 2, size.height / 2 + s * (minY + maxY) / 2)
    }
    func projectRaw(_ p: CGPoint, _ f: (s: CGFloat, tx: CGFloat, ty: CGFloat)) -> CGPoint {
        CGPoint(x: f.s * p.x + f.tx, y: f.ty - f.s * p.y)
    }
    func project(_ c: GeoCoord, _ f: (s: CGFloat, tx: CGFloat, ty: CGFloat)) -> CGPoint {
        let (x, y) = WorldGeometry.naturalEarth1(c.lon, c.lat)
        return projectRaw(CGPoint(x: x, y: y), f)
    }
    static func naturalEarth1(_ lonDeg: Double, _ latDeg: Double) -> (Double, Double) {
        let lambda = lonDeg * .pi / 180, phi = latDeg * .pi / 180
        let phi2 = phi * phi, phi4 = phi2 * phi2
        let x = lambda * (0.8707 - 0.131979 * phi2 + phi4 * (-0.013791 + phi4 * (0.003971 * phi2 - 0.001529 * phi4)))
        let y = phi * (1.007226 + phi2 * (0.015085 + phi4 * (-0.044475 + 0.028874 * phi2 - 0.005916 * phi4)))
        return (x, y)
    }
}

// ───────── the map ─────────

struct LandMap: View {
    var pins: [MapPin]
    var arcs: [MapArc]
    var connected: Bool

    static let teal = Color(red: 0.31, green: 0.82, blue: 0.77)
    static let control = Color(red: 0.62, green: 0.55, blue: 0.95)
    private let geo = WorldGeometry.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    draw(ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
            Legend().padding(14)
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.07))
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let fit = geo.fit(size)

        // ocean
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.11),
                                                          Color(red: 0.03, green: 0.04, blue: 0.07)]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        // graticule
        var grat = Path()
        for lon in stride(from: -180.0, through: 180.0, by: 30) {
            var first = true
            for lat in stride(from: -80.0, through: 80.0, by: 4) {
                let p = geo.project(GeoCoord(lat: lat, lon: lon), fit)
                if first { grat.move(to: p); first = false } else { grat.addLine(to: p) }
            }
        }
        for lat in stride(from: -60.0, through: 60.0, by: 30) {
            var first = true
            for lon in stride(from: -180.0, through: 180.0, by: 4) {
                let p = geo.project(GeoCoord(lat: lat, lon: lon), fit)
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

        // arcs + flowing traffic
        for arc in arcs {
            let screen = arc.points.map { geo.project($0, fit) }
            guard screen.count > 1 else { continue }
            let color = arc.style == .controlPlane ? LandMap.control : (connected ? .green : LandMap.teal)
            var path = Path(); path.move(to: screen[0]); for p in screen.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                          dash: arc.style == .dataPlane ? [4, 6] : []))
            // flow dots
            let lengths = cumulativeLengths(screen)
            let total = lengths.last ?? 0
            if total > 1 {
                let dots = 3
                for k in 0..<dots {
                    let frac = ((t * 0.18) + Double(k) / Double(dots)).truncatingRemainder(dividingBy: 1)
                    let p = pointAt(frac, screen, lengths, total)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.4, y: p.y - 2.4, width: 4.8, height: 4.8)),
                             with: .color(color))
                }
            }
        }

        // pins
        for pin in pins {
            let p = geo.project(pin.coord, fit)
            drawPin(ctx, at: p, pin: pin, t: t)
        }
    }

    private func drawPin(_ ctx: GraphicsContext, at p: CGPoint, pin: MapPin, t: Double) {
        let color: Color
        switch pin.kind {
        case .client: color = LandMap.teal
        case .controller: color = LandMap.control
        case .relay: color = LandMap.control
        case .node: color = connected ? .green : (pin.active ? LandMap.teal : .gray)
        }
        // pulsing ring (client + connected nodes)
        if pin.kind == .client || (pin.kind == .node && (connected || pin.active)) {
            let phase = (t * 0.8).truncatingRemainder(dividingBy: 1)
            let r = 8 + CGFloat(phase) * 18
            ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                       with: .color(color.opacity(0.5 * (1 - phase))), lineWidth: 1.5)
        }
        // glow
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 15, y: p.y - 15, width: 30, height: 30)),
                 with: .radialGradient(Gradient(colors: [color.opacity(0.45), .clear]),
                                       center: p, startRadius: 0, endRadius: 15))
        // dot
        let r: CGFloat = pin.kind == .client ? 4 : 5
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(color))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .color(.white.opacity(0.9)), lineWidth: 1.4)
        // label
        ctx.draw(Text(pin.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white),
                 at: CGPoint(x: p.x, y: p.y - 15), anchor: .bottom)
    }
}

// Legend — the routes/pins key, mirroring the website FleetMap legend.
private struct Legend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LEGEND").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            row(line: true, dashed: true, color: LandMap.teal, title: "Data path", sub: "to the exit")
            row(line: true, dashed: false, color: LandMap.control, title: "Control path", sub: "controller ↔ relays")
            row(line: false, dashed: false, color: LandMap.teal, title: "Node", sub: "active = filled")
            row(line: false, dashed: false, color: .gray, title: "You", sub: "approx (offline)")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder private func row(line: Bool, dashed: Bool, color: Color, title: String, sub: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if line {
                    Line().stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 3] : []))
                        .frame(width: 20, height: 2)
                } else {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
            }.frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct Line: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p
    }
}

// polyline sampling for flow dots
func cumulativeLengths(_ pts: [CGPoint]) -> [CGFloat] {
    var out: [CGFloat] = [0]
    for i in 1..<pts.count { out.append(out[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
    return out
}
func pointAt(_ frac: Double, _ pts: [CGPoint], _ lengths: [CGFloat], _ total: CGFloat) -> CGPoint {
    let target = CGFloat(frac) * total
    for i in 1..<pts.count where lengths[i] >= target {
        let seg = lengths[i] - lengths[i - 1]
        let u = seg > 0 ? (target - lengths[i - 1]) / seg : 0
        return CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * u,
                       y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * u)
    }
    return pts.last ?? .zero
}

// greatCircle interpolates the shortest path on the sphere (lon/lat in degrees).
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
        out.append(GeoCoord(lat: atan2(z, sqrt(x * x + y * y)) * 180 / .pi, lon: atan2(y, x) * 180 / .pi))
    }
    return out
}
