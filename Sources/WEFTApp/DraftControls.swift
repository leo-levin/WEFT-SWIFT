// DraftControls.swift - Control strip for Draft visualization

import SwiftUI
import WEFTLib

struct DraftControls: View {
    @ObservedObject var state: DraftState
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
                        set: { state.resolution = max(2, min(DraftState.maxResolution, Int($0))) }
                    ),
                    in: 2...Double(DraftState.maxResolution),
                    step: 1
                )
                .frame(width: 60)
                Text("\(state.resolution)×\(state.resolution)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
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

                regionField("x₀", value: $state.regionMin.x)
                regionField("y₀", value: $state.regionMin.y)
                Text("–")
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                regionField("x₁", value: $state.regionMax.x)
                regionField("y₁", value: $state.regionMax.y)

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

            Spacer()

            // Sample count
            Text("\(state.sampleCount) samples")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.panelHeaderBackground)
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
