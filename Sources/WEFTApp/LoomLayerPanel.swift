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
            .background(Color.panelHeaderBackground)

            SubtleDivider(.horizontal)

            // Layer list
            ScrollView {
                VStack(spacing: 2) {
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
        HStack(spacing: Spacing.sm) {
            // Color indicator
            Circle()
                .fill(layer.color)
                .frame(width: 8, height: 8)

            // Type icon
            Image(systemName: layerTypeIcon(layer.type))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            // Label
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.bundleName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(layerSubtitle(layer))
                    .font(.system(size: 10))
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
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs + 2)
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
                        let bundle = program.bundles[name]!
                        let strandCount = bundle.strands.count
                        if strandCount >= 2 {
                            Menu(name) {
                                Button("As Plane") {
                                    addLayerAsPlane(bundleName: name, program: program)
                                }
                                Button("As Axes (Group)") {
                                    addLayerAsAxisGroup(bundleName: name, program: program)
                                }
                            }
                        } else {
                            Button(name) {
                                addLayerAsAxis(bundleName: name, strandName: bundle.strands[0].name, expr: bundle.strands[0].expr)
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

    private func addLayerAsPlane(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })
        guard strands.count >= 2 else { return }

        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .plane(xStrand: "\(bundleName).\(strands[0].name)",
                         yStrand: "\(bundleName).\(strands[1].name)"),
            label: "\(bundleName).\(strands[0].name), \(bundleName).\(strands[1].name)",
            strandExprs: [(strands[0].name, strands[0].expr), (strands[1].name, strands[1].expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: .purple.opacity(0.8)))
    }

    private func addLayerAsAxisGroup(bundleName: String, program: IRProgram) {
        guard let bundle = program.bundles[bundleName] else { return }
        let strands = bundle.strands.sorted(by: { $0.index < $1.index })

        for strand in strands {
            let spec = LoomLayerSpec(
                bundleName: bundleName,
                type: .axis(strand: "\(bundleName).\(strand.name)"),
                label: "\(bundleName).\(strand.name)",
                strandExprs: [(strand.name, strand.expr)]
            )
            state.layers.append(LoomLayer(from: spec, color: .purple.opacity(0.8)))
        }
    }

    private func addLayerAsAxis(bundleName: String, strandName: String, expr: IRExpr) {
        let spec = LoomLayerSpec(
            bundleName: bundleName,
            type: .axis(strand: "\(bundleName).\(strandName)"),
            label: "\(bundleName).\(strandName)",
            strandExprs: [(strandName, expr)]
        )
        state.layers.append(LoomLayer(from: spec, color: .purple.opacity(0.8)))
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
