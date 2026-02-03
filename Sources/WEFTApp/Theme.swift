// Theme.swift - Design system for WEFTApp

import SwiftUI
import AppKit

// MARK: - Spacing Scale

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
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
    static let statsLabel = Font.system(size: 9, weight: .medium, design: .monospaced)
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
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.panelHeaderBackground)
    }
}

// MARK: - Collapsed Panel Header (minimal)

struct CollapsedPanelHeader: View {
    let title: String
    let icon: String?
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)

                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if let hint {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Stats Badge (cleaner design)

struct StatsBadge: View {
    let fps: Double
    let frameTime: Double

    var body: some View {
        HStack(spacing: Spacing.sm) {
            StatItem(value: String(format: "%.0f", fps), label: "FPS")
            StatItem(value: String(format: "%.1f", frameTime), label: "MS")
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct StatItem: View {
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compilation Error View

struct CompilationErrorView: View {
    let error: CompilationError

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Location header
            if let location = error.location {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text("Line \(location.line), column \(location.column)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)
            }

            // Code context
            if !error.codeContext.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(error.codeContext, id: \.lineNumber) { line in
                            HStack(spacing: 0) {
                                Text("\(line.lineNumber)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .trailing)
                                    .padding(.trailing, Spacing.sm)

                                if line.isErrorLine {
                                    Text("> ")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.red)
                                } else {
                                    Text("  ")
                                        .font(.system(size: 10, design: .monospaced))
                                }

                                Text(line.content)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(line.isErrorLine ? .primary : .secondary)
                            }

                            // Caret line
                            if line.isErrorLine, let col = error.location?.column {
                                HStack(spacing: 0) {
                                    Text("")
                                        .frame(width: 24)
                                        .padding(.trailing, Spacing.sm)
                                    Text("  ")
                                        .font(.system(size: 10, design: .monospaced))
                                    Text(String(repeating: " ", count: max(0, col - 1)) + "^")
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                }
                .background(Color(NSColor.textBackgroundColor))
            }

            // Error message
            Text(error.message)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
        }
    }
}

// MARK: - Compilation Error Model

struct CompilationError {
    struct Location {
        let line: Int
        let column: Int
    }

    struct CodeLine {
        let lineNumber: Int
        let content: String
        let isErrorLine: Bool
    }

    let message: String
    let location: Location?
    let codeContext: [CodeLine]

    /// Parse an Ohm.js error message into structured form
    static func parse(from errorString: String, source: String) -> CompilationError {
        // Ohm errors look like:
        // "Line 2, col 42: expected..."
        // or just raw error text

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Try to extract line/col from error
        var location: Location? = nil
        var message = errorString

        if let lineColPattern = try? NSRegularExpression(pattern: "[Ll]ine\\s+(\\d+),?\\s*[Cc]ol(?:umn)?\\s+(\\d+)"),
           let match = lineColPattern.firstMatch(in: errorString, range: NSRange(errorString.startIndex..., in: errorString)) {
            if let lineRange = Range(match.range(at: 1), in: errorString),
               let colRange = Range(match.range(at: 2), in: errorString),
               let line = Int(errorString[lineRange]),
               let col = Int(errorString[colRange]) {
                location = Location(line: line, column: col)
            }
        }

        // Also check for "at position X" style
        if location == nil,
           let posPattern = try? NSRegularExpression(pattern: "at position (\\d+)"),
           let match = posPattern.firstMatch(in: errorString, range: NSRange(errorString.startIndex..., in: errorString)),
           let posRange = Range(match.range(at: 1), in: errorString),
           let pos = Int(errorString[posRange]) {
            // Convert position to line/col
            var charCount = 0
            for (i, line) in lines.enumerated() {
                if charCount + line.count >= pos {
                    location = Location(line: i + 1, column: pos - charCount + 1)
                    break
                }
                charCount += line.count + 1 // +1 for newline
            }
        }

        // Extract just the error description (after the colon if present)
        if let colonRange = errorString.range(of: ": ") {
            message = String(errorString[colonRange.upperBound...])
        }

        // Build code context (1 line before, error line, 1 line after)
        var codeContext: [CodeLine] = []
        if let loc = location, !lines.isEmpty {
            let errorLineIndex = loc.line - 1
            let startIndex = max(0, errorLineIndex - 1)
            let endIndex = min(lines.count - 1, errorLineIndex + 1)

            // Guard against invalid range (can happen with invalid line numbers)
            guard startIndex <= endIndex else {
                return CompilationError(message: message, location: location, codeContext: codeContext)
            }

            for i in startIndex...endIndex {
                if i < lines.count {
                    codeContext.append(CodeLine(
                        lineNumber: i + 1,
                        content: lines[i],
                        isErrorLine: i == errorLineIndex
                    ))
                }
            }
        }

        return CompilationError(message: message, location: location, codeContext: codeContext)
    }
}
