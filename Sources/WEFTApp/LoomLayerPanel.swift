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
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                addLayerMenu
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            // Layer list
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(Array(state.layers.enumerated()), id: \.element.id) { index, layer in
                        layerRow(layer: layer, index: index)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Layer Row

    private func layerRow(layer: LoomLayer, index: Int) -> some View {
        HStack(spacing: Spacing.xs) {
            // Color indicator
            Circle()
                .fill(layer.color)
                .frame(width: 6, height: 6)

            // Type icon
            Image(systemName: layerTypeIcon(layer.type))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            // Label
            VStack(alignment: .leading, spacing: 0) {
                Text(layer.bundleName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(layerTypeLabel(layer.type))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            // Remove button (don't allow removing the input "me" layer)
            if layer.bundleName != "me" {
                Button {
                    state.layers.removeAll { $0.id == layer.id }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
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
                        Button(name) {
                            addLayer(bundleName: name, program: program)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 16)
    }

    // MARK: - Helpers

    private func availableBundleNames(program: IRProgram) -> [String] {
        let existing = Set(state.layers.map { $0.bundleName })
        return program.bundles.keys
            .filter { !existing.contains($0) && $0 != "me" }
            .sorted()
    }

    private func addLayer(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })

        let type: LoomLayerSpec.LayerType
        let label: String
        let strandExprs: [(String, IRExpr)]

        if strands.count >= 2 {
            type = .plane(xStrand: "\(bundleName).\(strands[0].name)",
                          yStrand: "\(bundleName).\(strands[1].name)")
            label = "\(bundleName).\(strands[0].name), \(bundleName).\(strands[1].name)"
            strandExprs = [(strands[0].name, strands[0].expr), (strands[1].name, strands[1].expr)]
        } else if strands.count == 1 {
            type = .axis(strand: "\(bundleName).\(strands[0].name)")
            label = "\(bundleName).\(strands[0].name)"
            strandExprs = [(strands[0].name, strands[0].expr)]
        } else {
            return
        }

        let spec = LoomLayerSpec(bundleName: bundleName, type: type, label: label, strandExprs: strandExprs)
        let color = Color.purple.opacity(0.8)
        state.layers.append(LoomLayer(from: spec, color: color))
    }

    private func layerTypeIcon(_ type: LoomLayerSpec.LayerType) -> String {
        switch type {
        case .plane: return "square"
        case .axis: return "line.diagonal"
        }
    }

    private func layerTypeLabel(_ type: LoomLayerSpec.LayerType) -> String {
        switch type {
        case .plane: return "plane"
        case .axis: return "axis"
        }
    }
}
