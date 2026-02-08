// ScopeView.swift - Oscilloscope waveform visualization

import SwiftUI
import WEFTLib

struct ScopeView: View {
    let scopeBuffer: ScopeBuffer

    private let displaySamples = 2048  // samples to display per trace
    private let traceColors: [Color] = [
        .green, .cyan, .yellow, .orange, .pink, .mint, .indigo, .teal
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            ZStack {
                Color.canvasBackground
                Canvas { context, size in
                    drawTraces(context: context, size: size, date: timeline.date)
                }
            }
        }
    }

    private func drawTraces(context: GraphicsContext, size: CGSize, date: Date) {
        // Read more than we display so we have room to find a trigger point
        let readCount = displaySamples * 2
        let snapshot = scopeBuffer.snapshot(count: readCount)
        let strandCount = snapshot.count
        guard strandCount > 0 else { return }

        let dividerHeight: CGFloat = 1
        let totalDividers = CGFloat(strandCount - 1) * dividerHeight
        let laneHeight = (size.height - totalDividers) / CGFloat(strandCount)
        let tracePadding: CGFloat = max(4, laneHeight * 0.08)

        for (strandIdx, allSamples) in snapshot.enumerated() {
            let laneTop = CGFloat(strandIdx) * (laneHeight + dividerHeight)
            let traceTop = laneTop + tracePadding
            let traceHeight = laneHeight - tracePadding * 2
            let color = traceColors[strandIdx % traceColors.count]

            // Divider above this lane (except first)
            if strandIdx > 0 {
                let divY = laneTop - dividerHeight
                var divPath = Path()
                divPath.move(to: CGPoint(x: 0, y: divY))
                divPath.addLine(to: CGPoint(x: size.width, y: divY))
                context.stroke(divPath, with: .color(.white.opacity(0.25)), lineWidth: dividerHeight)
            }

            // Zero line
            let zeroY = traceTop + traceHeight / 2
            var zeroPath = Path()
            zeroPath.move(to: CGPoint(x: 0, y: zeroY))
            zeroPath.addLine(to: CGPoint(x: size.width, y: zeroY))
            context.stroke(zeroPath, with: .color(.white.opacity(0.08)), lineWidth: 0.5)

            // Strand label
            let labelText = Text(scopeBuffer.strandNames[strandIdx])
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(color.opacity(0.7))
            context.draw(context.resolve(labelText), at: CGPoint(x: 6, y: laneTop + 4), anchor: .topLeading)

            guard allSamples.count >= displaySamples else { continue }

            // Find trigger point: rising zero-crossing in the first half
            let triggerOffset = findTrigger(in: allSamples, windowSize: displaySamples)
            let samples = Array(allSamples[triggerOffset..<(triggerOffset + displaySamples)])

            // Draw waveform
            let pixelWidth = Int(size.width)
            guard pixelWidth > 0 else { continue }
            let samplesPerPixel = Float(samples.count) / Float(pixelWidth)

            if samplesPerPixel <= 1.5 {
                drawLine(context: context, samples: samples, color: color,
                         traceTop: traceTop, traceHeight: traceHeight, width: size.width)
            } else {
                drawEnvelope(context: context, samples: samples, color: color,
                             traceTop: traceTop, traceHeight: traceHeight,
                             pixelWidth: pixelWidth, samplesPerPixel: samplesPerPixel)
            }
        }
    }

    /// Find a rising zero-crossing to use as a stable trigger point.
    /// Searches the first half of the buffer so we always have `windowSize` samples after it.
    private func findTrigger(in samples: [Float], windowSize: Int) -> Int {
        let searchEnd = samples.count - windowSize
        guard searchEnd > 1 else { return 0 }

        // Look for a rising zero-crossing (negative -> positive)
        for i in 1..<searchEnd {
            if samples[i - 1] <= 0 && samples[i] > 0 {
                return i
            }
        }
        // Fallback: no crossing found, use start of displayable region
        return 0
    }

    private func drawLine(context: GraphicsContext, samples: [Float], color: Color,
                          traceTop: CGFloat, traceHeight: CGFloat, width: CGFloat) {
        var path = Path()
        let xStep = width / CGFloat(samples.count - 1)

        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * xStep
            let y = sampleToY(sample, traceTop: traceTop, traceHeight: traceHeight)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawEnvelope(context: GraphicsContext, samples: [Float], color: Color,
                              traceTop: CGFloat, traceHeight: CGFloat,
                              pixelWidth: Int, samplesPerPixel: Float) {
        var topPath = Path()
        var botPoints: [(CGFloat, CGFloat)] = []

        for px in 0..<pixelWidth {
            let sStart = Int(Float(px) * samplesPerPixel)
            let sEnd = min(Int(Float(px + 1) * samplesPerPixel), samples.count)
            guard sStart < sEnd else { continue }

            var lo: Float = samples[sStart]
            var hi: Float = samples[sStart]
            for s in sStart..<sEnd {
                let v = samples[s]
                if v < lo { lo = v }
                if v > hi { hi = v }
            }

            let x = CGFloat(px)
            let yHi = sampleToY(hi, traceTop: traceTop, traceHeight: traceHeight)
            let yLo = sampleToY(lo, traceTop: traceTop, traceHeight: traceHeight)

            if px == 0 {
                topPath.move(to: CGPoint(x: x, y: yHi))
            } else {
                topPath.addLine(to: CGPoint(x: x, y: yHi))
            }
            botPoints.append((x, yLo))
        }

        for (x, yLo) in botPoints.reversed() {
            topPath.addLine(to: CGPoint(x: x, y: yLo))
        }
        topPath.closeSubpath()

        context.fill(topPath, with: .color(color.opacity(0.5)))

        // Center line (average per bin)
        var midPath = Path()
        for px in 0..<pixelWidth {
            let sStart = Int(Float(px) * samplesPerPixel)
            let sEnd = min(Int(Float(px + 1) * samplesPerPixel), samples.count)
            guard sStart < sEnd else { continue }

            var sum: Float = 0
            for s in sStart..<sEnd { sum += samples[s] }
            let avg = sum / Float(sEnd - sStart)

            let x = CGFloat(px)
            let y = sampleToY(avg, traceTop: traceTop, traceHeight: traceHeight)
            if px == 0 {
                midPath.move(to: CGPoint(x: x, y: y))
            } else {
                midPath.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(midPath, with: .color(color), lineWidth: 1)
    }

    private func sampleToY(_ sample: Float, traceTop: CGFloat, traceHeight: CGFloat) -> CGFloat {
        let clamped = max(-1, min(1, sample))
        let normalized = CGFloat(clamped) * -0.5 + 0.5
        return traceTop + normalized * traceHeight
    }
}
