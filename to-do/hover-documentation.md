# Spindle Documentation Popovers

## Status: Implemented

## Trigger
**Option+Click** on any spindle or builtin name in the editor to show its documentation.

This follows the Xcode Quick Help pattern (which also uses Option+Click).

## Features
- Shows signature, description, parameters, return value, and examples
- Works for stdlib spindles (with `///` doc comments) and builtins (hardcoded docs)
- Popover dismisses on: click elsewhere, Escape key, scrolling

## Infrastructure
- `DocParser.swift` - Parses `///` doc comments from WEFT source files
- `SpindleDocManager.swift` - Singleton that loads and caches all spindle docs
- `BuiltinDocs` (in DocParser.swift) - Hardcoded docs for ~25 builtins (sin, cos, lerp, cache, etc.)
- `DocumentationPopoverView` - SwiftUI view for displaying docs in a popover
- `FocusableTextView` - NSTextView subclass handling Option+Click

## Files
- `Sources/SWeftLib/Parser/DocParser.swift`
- `Sources/SWeftLib/Parser/SpindleDocManager.swift`
- `Sources/SWeftApp/ContentView.swift` (FocusableTextView, DocumentationPopoverView)
- `Sources/SWeftLib/stdlib/std_music.weft` (has /// doc comments)
- `Sources/SWeftLib/stdlib/std_noise.weft` (has /// doc comments)

## Previous Approach (Abandoned)
Originally attempted hover-based triggering with `NSTrackingArea` and `mouseMoved` events, but these don't fire reliably when NSTextView is wrapped in NSViewRepresentable inside SwiftUI.
