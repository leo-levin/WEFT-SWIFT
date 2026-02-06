// LoomLayerPanel.swift - Layer list sidebar for Loom visualization

import SwiftUI
import WEFTLib

struct LoomLayerPanel: View {
    @ObservedObject var state: LoomState
    let coordinator: Coordinator

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Layers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                addLayerMenu
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(.ultraThinMaterial)

            SubtleDivider(.horizontal)

            // Layer list with drag reordering
            List {
                ForEach(Array(state.layers.enumerated()), id: \.element.id) { index, layer in
                    layerRow(layer: layer, index: index)
                        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .onMove { source, destination in
                    state.layers.move(fromOffsets: source, toOffset: destination)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            // Selected sample readout
            if !state.selectedSampleIndices.isEmpty {
                selectedSampleReadout
            }
        }
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Selected Sample Readout

    @ViewBuilder
    private var selectedSampleReadout: some View {
        let indices = Array(state.selectedSampleIndices.sorted())
        if let first = indices.first, first < state.samples.count {
            VStack(alignment: .leading, spacing: 4) {
                SubtleDivider(.horizontal)

                HStack {
                    Text(indices.count == 1 ? "Selected" : "\(indices.count) selected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xs)

                let sample = state.samples[first]
                ForEach(Array(state.layers.enumerated()), id: \.element.id) { idx, layer in
                    if idx < sample.count {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(layer.color.opacity(layer.isVisible ? 1.0 : 0.3))
                                .frame(width: 6, height: 6)
                            Text(layer.label)
                                .font(.system(size: 10))
                                .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatSampleValue(sample[idx], layer.type))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(layer.isVisible ? .secondary : .quaternary)
                        }
                        .padding(.horizontal, Spacing.sm)
                    }
                }
                .padding(.bottom, Spacing.xs)
            }
        }
    }

    private func formatSampleValue(_ val: SIMD2<Double>, _ type: LoomLayerSpec.LayerType) -> String {
        switch type {
        case .plane:
            return "(\(String(format: "%.3f", val.x)), \(String(format: "%.3f", val.y)))"
        case .axis:
            return String(format: "%.3f", val.x)
        }
    }

    // MARK: - Layer Row

    private func layerRow(layer: LoomLayer, index: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            // Visibility toggle
            Button {
                state.layers[index].isVisible.toggle()
            } label: {
                Image(systemName: layer.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .secondary : .quaternary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(layer.isVisible ? "Hide layer" : "Show layer")

            // Color indicator
            Circle()
                .fill(layer.color.opacity(layer.isVisible ? 1.0 : 0.3))
                .frame(width: 8, height: 8)

            // Type icon
            Image(systemName: layerTypeIcon(layer.type))
                .font(.system(size: 10))
                .foregroundStyle(layer.isVisible ? .tertiary : .quaternary)
                .frame(width: 14)

            // Label
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.bundleName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(layer.isVisible ? .primary : .tertiary)
                    .lineLimit(1)
                Text(layerSubtitle(layer))
                    .font(.system(size: 10))
                    .foregroundStyle(layer.isVisible ? .tertiary : .quaternary)
                    .lineLimit(1)
            }

            Spacer()

            // Remove button (don't allow removing the input "me" layer)
            if layer.bundleName != "me" {
                Button {
                    state.layers.removeAll { $0.id == layer.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 2)
        .opacity(layer.isVisible ? 1.0 : 0.6)
    }

    // MARK: - Add Layer Menu

    private var addLayerMenu: some View {
        Menu {
            if let program = coordinator.program {
                let available = availableBundleNames(program: program)
                if available.isEmpty {
                    Text("No additional bundles")
                } else {
                    ForEach(available, id: \.self) { name in
                        if let bundle = program.bundles[name] {
                            if bundle.strands.count >= 2 {
                                Button("\(name) (plane)") {
                                    addLayerAsPlane(bundleName: name, program: program)
                                }
                                Button("\(name) (axes)") {
                                    addLayerAsAxisGroup(bundleName: name, program: program)
                                }
                            } else if !bundle.strands.isEmpty {
                                Button(name) {
                                    addLayerAsAxis(bundleName: name, strandName: bundle.strands[0].name, expr: bundle.strands[0].expr)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 18)
    }

    // MARK: - Helpers

    private func availableBundleNames(program: IRProgram) -> [String] {
        let existing = Set(state.layers.map { $0.bundleName })
        return program.bundles.keys
            .filter { !existing.contains($0) && $0 != "me" }
            .sorted()
    }

    /// Generate a color for a new layer based on how many distinct bundles exist
    private func nextLayerColor() -> Color {
        let distinctBundles = Set(state.layers.map { $0.bundleName }).count
        return layerColor(index: distinctBundles)
    }

    private func layerColor(index: Int) -> Color {
        // Cycle through distinct hues
        let hues: [Color] = [
            Color(hue: 0.8, saturation: 0.6, brightness: 0.9),   // purple
            Color(hue: 0.55, saturation: 0.6, brightness: 0.85), // teal
            Color(hue: 0.1, saturation: 0.7, brightness: 0.95),  // orange
            Color(hue: 0.35, saturation: 0.6, brightness: 0.8),  // green
            Color(hue: 0.95, saturation: 0.6, brightness: 0.9),  // pink
            Color(hue: 0.6, saturation: 0.5, brightness: 0.9),   // blue
        ]
        return hues[index % hues.count]
    }

    private func addLayerAsPlane(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })
        guard strands.count >= 2 else { return }

        let color = nextLayerColor()
        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .plane(xStrand: "\(bundleName).\(strands[0].name)",
                         yStrand: "\(bundleName).\(strands[1].name)"),
            label: "\(bundleName).\(strands[0].name), \(bundleName).\(strands[1].name)",
            strandExprs: [(strands[0].name, strands[0].expr), (strands[1].name, strands[1].expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: color))
    }

    private func addLayerAsAxisGroup(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })

        // All axes in the group share the same color
        let color = nextLayerColor()
        for strand in strands {
            let spec = LoomLayerSpec(
                bundleName: bundleName,
                type: .axis(strand: "\(bundleName).\(strand.name)"),
                label: "\(bundleName).\(strand.name)",
                strandExprs: [(strand.name, strand.expr)]
            )
            state.layers.append(LoomLayer(from: spec, color: color))
        }
    }

    private func addLayerAsAxis(bundleName: String, strandName: String, expr: IRExpr) {
        let color = nextLayerColor()
        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .axis(strand: "\(bundleName).\(strandName)"),
            label: "\(bundleName).\(strandName)",
            strandExprs: [(strandName, expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: color))
    }

    private func layerTypeIcon(_ type: LoomLayerSpec.LayerType) -> String {
        switch type {
        case .plane: return "square"
        case .axis: return "line.diagonal"
        }
    }

    private func layerSubtitle(_ layer: LoomLayer) -> String {
        switch layer.type {
        case .plane(let x, let y):
            let xShort = x.components(separatedBy: ".").last ?? x
            let yShort = y.components(separatedBy: ".").last ?? y
            return "plane (\(xShort), \(yShort))"
        case .axis(let s):
            let sShort = s.components(separatedBy: ".").last ?? s
            return "axis (\(sShort))"
        }
    }
}
