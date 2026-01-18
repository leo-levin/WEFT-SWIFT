// Theme.swift - Design system for SWeftApp

import SwiftUI
import AppKit

// MARK: - Spacing Scale

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Colors

extension Color {
    // Panel backgrounds
    static let panelBackground = Color(NSColor.controlBackgroundColor)
    static let panelHeaderBackground = Color(NSColor.windowBackgroundColor)
    static let canvasBackground = Color.black

    // Text colors
    static let textPrimary = Color(NSColor.labelColor)
    static let textSecondary = Color(NSColor.secondaryLabelColor)
    static let textTertiary = Color(NSColor.tertiaryLabelColor)

    // Borders and separators
    static let separator = Color(NSColor.separatorColor)
    static let subtleBorder = Color(NSColor.separatorColor).opacity(0.5)

    // Status colors
    static let statusRunning = Color.green
    static let statusStopped = Color(NSColor.secondaryLabelColor)
    static let statusError = Color.red

    // Accent colors for graph nodes
    static let nodeVisual = Color.blue
    static let nodeAudio = Color.green
    static let nodeCompute = Color.orange
}

// MARK: - Typography

extension Font {
    static let panelTitle = Font.system(size: 11, weight: .medium)
    static let panelSubtitle = Font.system(size: 10, weight: .regular)
    static let codeSmall = Font.system(size: 10, design: .monospaced)
    static let codeMedium = Font.system(size: 11, design: .monospaced)
    static let codeLarge = Font.system(size: 13, design: .monospaced)
    static let statsOverlay = Font.system(size: 10, weight: .medium, design: .monospaced)
}

// MARK: - Panel Header Style

struct PanelHeader<TrailingContent: View>: View {
    let title: String
    let icon: String?
    let isCollapsed: Bool
    let onToggle: (() -> Void)?
    @ViewBuilder let trailing: () -> TrailingContent

    init(
        _ title: String,
        icon: String? = nil,
        isCollapsed: Bool = false,
        onToggle: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> TrailingContent = { EmptyView() }
    ) {
        self.title = title
        self.icon = icon
        self.isCollapsed = isCollapsed
        self.onToggle = onToggle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if let onToggle {
                Button(action: onToggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }

            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(.panelTitle)
                .foregroundStyle(.secondary)

            Spacer()

            trailing()
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Color.panelHeaderBackground)
    }
}

// MARK: - Panel Container

struct Panel<Content: View, Header: View>: View {
    let header: Header
    let content: Content
    let showSeparator: Bool

    init(
        showSeparator: Bool = true,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
        self.showSeparator = showSeparator
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if showSeparator {
                Divider()
            }

            content
        }
    }
}

// MARK: - Subtle Divider

struct SubtleDivider: View {
    let orientation: Orientation

    enum Orientation {
        case horizontal, vertical
    }

    init(_ orientation: Orientation = .horizontal) {
        self.orientation = orientation
    }

    var body: some View {
        switch orientation {
        case .horizontal:
            Rectangle()
                .fill(Color.subtleBorder)
                .frame(height: 1)
        case .vertical:
            Rectangle()
                .fill(Color.subtleBorder)
                .frame(width: 1)
        }
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: Status

    enum Status {
        case running
        case stopped
        case error

        var color: Color {
            switch self {
            case .running: return .statusRunning
            case .stopped: return .statusStopped
            case .error: return .statusError
            }
        }
    }

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - Toolbar Button Style

struct ToolbarIconButton: View {
    let icon: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    init(_ icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let content: String
    let placeholder: String
    let fontSize: CGFloat

    init(_ content: String, placeholder: String = "No output", fontSize: CGFloat = 10) {
        self.content = content
        self.placeholder = placeholder
        self.fontSize = fontSize
    }

    var body: some View {
        ScrollView {
            Text(content.isEmpty ? placeholder : content)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(content.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(Spacing.sm)
        }
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String
    let onDismiss: (() -> Void)?

    init(_ message: String, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))

            Text(message)
                .font(.codeSmall)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.sm)
        .background(Color.red.opacity(0.08))
        .overlay(
            Rectangle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 3),
            alignment: .leading
        )
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {
    let icon: String
    let message: String
    let hint: String?

    init(_ icon: String, message: String, hint: String? = nil) {
        self.icon = icon
        self.message = message
        self.hint = hint
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)

            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stats Overlay

struct StatsOverlay: View {
    let fps: Double
    let frameTime: Double
    let droppedFrames: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1f fps", fps))
            Text(String(format: "%.2f ms", frameTime))
            if droppedFrames > 0 {
                Text("\(droppedFrames) dropped")
                    .foregroundStyle(.red)
            }
        }
        .font(.statsOverlay)
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
    }
}
