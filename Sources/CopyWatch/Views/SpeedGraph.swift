import SwiftUI

/// Lightweight line graph of transfer speed over time (like the Windows copy
/// dialog), with a filled area and the current MB/s labelled.
struct SpeedGraph: View {
    let history: [Double]   // MB/s samples
    let current: Double     // bytes/sec

    private var peak: Double { max(history.max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f MB/s", current / 1_000_000))
                    .font(.caption.monospacedDigit().bold())
                Text("peak \(Int(peak)) MB/s")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                let pts = points(in: geo.size)
                ZStack {
                    areaPath(pts, height: geo.size.height, width: geo.size.width)
                        .fill(LinearGradient(
                            colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    linePath(pts)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                }
            }
            .background(Color(.quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let n = max(history.count - 1, 1)
        return history.indices.map { i in
            CGPoint(
                x: size.width * CGFloat(i) / CGFloat(n),
                y: size.height - size.height * CGFloat(min(history[i] / peak, 1)))
        }
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat, width: CGFloat) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: CGPoint(x: 0, y: height))
            p.addLine(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.addLine(to: CGPoint(x: width, y: height))
            p.closeSubpath()
        }
    }
}
