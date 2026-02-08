// ScopeView.swift - Oscilloscope waveform visualization

import SwiftUI
import WEFTLib

struct ScopeView: View {
    let scopeBuffer: ScopeBuffer

    @State private var drawVersion = 0
    private let sampleCount = 2048
    private let traceColors: [Color] = [
        .green, .cyan, .yellow, .orange, .pink, .mint, .indigo, .teal
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.canvasBackground

            Canvas { context, size in
                drawTraces(context: context, size: size)
            }

            // Strand labels
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(scopeBuffer.strandNames.enumerated()), id: \.offset) { idx, name in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(traceColors[idx % traceColors.count])
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(Spacing.sm)
        }
        .onAppear { startTimer() }
    }

    private func startTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            drawVersion += 1
        }
    }

    private func drawTraces(context: GraphicsContext, size: CGSize) {
        let _ = drawVersion
        let snapshot = scopeBuffer.snapshot(count: sampleCount)
        let strandCount = snapshot.count
        guard strandCount > 0 else { return }

        let traceHeight = size.height / CGFloat(strandCount)

        for (strandIdx, samples) in snapshot.enumerated() {
            let yOffset = CGFloat(strandIdx) * traceHeight
            let color = traceColors[strandIdx % traceColors.count]

            // Draw zero line
            let zeroY = yOffset + traceHeight / 2
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zeroPath, with: .color(.white.opacity(0.1)), lineWidth: 0.5)

            // Draw waveform
            guard !samples.isEmpty else { continue }

            var path = Path()
            let xStep = size.width / CGFloat(samples.count - 1)

            for (i, sample) in samples.enumerated() {
                let x = CGFloat(i) * xStep
                let normalizedY = CGFloat(sample) * -0.5 + 0.5
                let y = yOffset + normalizedY * traceHeight

                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(color), lineWidth: 1.5)

            // Separator between traces (except last)
            if strandIdx < strandCount - 1 {
                let separatorY = yOffset + traceHeight
                var sepPath = Path()
                sepPath.move(to: CGPoint(x: 0, y: separatorY))
                sepPath.addLine(to: CGPoint(x: size.width, y: separatorY))
                context.stroke(sepPath, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
            }
        }
    }
}
