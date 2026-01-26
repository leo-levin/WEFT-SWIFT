# Hover Documentation for Editor

## Status: Blocked

## Goal
Show documentation popover when hovering over spindle/builtin names in the editor.

## What's Done
- `DocParser.swift` - Parses `///` doc comments from WEFT source files
- `SpindleDocManager.swift` - Loads and caches all spindle docs (stdlib + builtins)
- `BuiltinDocs.swift` (in DocParser.swift) - Hardcoded docs for ~25 builtins (sin, cos, lerp, cache, etc.)
- `DocumentationPopoverView` - SwiftUI view for displaying docs in a popover
- Doc comments added to `std_music.weft` and `std_noise.weft`
- Mouse tracking infrastructure in `FocusableTextView`

## The Problem
`NSTrackingArea` with `.mouseMoved` option doesn't fire `mouseMoved(with:)` events when the `NSTextView` is wrapped in `NSViewRepresentable` inside SwiftUI.

Tried:
- Adding tracking area in `viewDidMoveToWindow`
- Using `.inVisibleRect` option
- Adding to `.common` run loop mode

## Possible Solutions

1. **Use a different trigger** - Instead of hover, use:
   - Option+click to show docs
   - F1 or keyboard shortcut when cursor is on a word
   - Right-click context menu

2. **Native NSTextView approach** - Skip SwiftUI wrapper entirely for the editor, use pure AppKit

3. **LSP approach** - Build a `weft-language-server` for VSCode/other editors. More portable but more work.

4. **Debug further** - The mouse tracking might work if:
   - The scroll view is configured differently
   - We use `NSView.TrackingArea` with different options
   - We handle events at the scroll view level instead

## Files
- `Sources/SWeftLib/Parser/DocParser.swift`
- `Sources/SWeftLib/Parser/SpindleDocManager.swift`
- `Sources/SWeftApp/ContentView.swift` (FocusableTextView, DocumentationPopoverView)
- `Sources/SWeftLib/stdlib/std_music.weft` (has /// doc comments)
- `Sources/SWeftLib/stdlib/std_noise.weft` (has /// doc comments)
