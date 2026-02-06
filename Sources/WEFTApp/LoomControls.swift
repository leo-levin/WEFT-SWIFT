// LoomControls.swift - Control strip for Loom visualization

import SwiftUI
import WEFTLib

struct LoomControls: View {
    @ObservedObject var state: LoomState
    let coordinator: Coordinator

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Play/Pause
            Button {
                state.isPlaying.toggle()
                if !state.isPlaying {
                    state.scrubTime = coordinator.time
                }
            } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help(state.isPlaying ? "Pause" : "Play")

            // Time scrubber (when paused)
            if !state.isPlaying {
                HStack(spacing: Spacing.xs) {
                    Text("t")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Slider(value: $state.scrubTime, in: 0...60)
                        .frame(width: 80)
                    Text(String(format: "%.1f", state.scrubTime))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                }
            }

            SubtleDivider(.vertical)
                .frame(height: 14)

            // Resolution
            HStack(spacing: Spacing.xs) {
                Text("Res")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { Double(state.resolution) },
                        set: { state.resolution = max(2, min(LoomState.maxResolution, Int($0))) }
                    ),
                    in: 2...Double(LoomState.maxResolution),
                    step: 1
                )
                .frame(width: 60)
                Text("\(state.resolution)\u{00D7}\(state.resolution)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }

            SubtleDivider(.vertical)
                .frame(height: 14)

            // Zoom
            HStack(spacing: Spacing.xs) {
                Text("Zoom")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Slider(value: $state.camera.scale, in: 0.3...1.5)
                    .frame(width: 50)
            }

            SubtleDivider(.vertical)
                .frame(height: 14)

            // Spread
            HStack(spacing: Spacing.xs) {
                Text("Spread")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Slider(value: $state.spread, in: 0.1...1.5)
                    .frame(width: 50)
            }

            SubtleDivider(.vertical)
                .frame(height: 14)

            // Region
            HStack(spacing: Spacing.xs) {
                Text("Region")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)

                regionField("x\u{2080}", value: $state.regionMin.x)
                regionField("y\u{2080}", value: $state.regionMin.y)
                Text("\u{2013}")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                regionField("x\u{2081}", value: $state.regionMax.x)
                regionField("y\u{2081}", value: $state.regionMax.y)

                Button {
                    state.regionMin = SIMD2(0, 0)
                    state.regionMax = SIMD2(1, 1)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reset region")
            }

            SubtleDivider(.vertical)
                .frame(height: 14)

            // Camera reset
            Button {
                state.camera = Camera3D.default
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reset camera (R)")

            Spacer()

            // Sample count and keyboard hints
            HStack(spacing: Spacing.md) {
                Text("\(state.sampleCount) samples")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)

                Text("Space: play  Arrows: rotate  R: reset")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(.regularMaterial)
    }

    private func regionField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.quaternary)
            TextField("", value: value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 9, design: .monospaced))
                .textFieldStyle(.plain)
                .frame(width: 32)
                .multilineTextAlignment(.trailing)
        }
    }
}
