I have a JavaScript toolchain in proto copy/ that uses Ohm.js to parse WEFT source code, build an AST, lower it to an IR, and output JSON. I also have a Swift app that currently takes that JSON IR and interprets/runs it.
I want to:
Embed the JS toolchain directly into the Swift app using JavaScriptCore
Add a UI so I can write and run WEFT code entirely within the app
Part 1: Bundle the JS for JavaScriptCore
First, explore proto copy/ to understand how the parser and lowering pipeline works—find the entry point and see how it currently takes source code and outputs IR JSON.
Then bundle the JS into a single file that can run in JavaScriptCore:
Inline any .ohm grammar files—there's no filesystem in JSC
Output as IIFE or CJS, not ES modules (JSC doesn't support import/export)
Add a console.log shim since it doesn't exist in JSC and will silently fail
Remove any other Node.js APIs (fs, path, process, etc.)
Expose a single function like compile(source) that returns the IR as a JSON string
Part 2: Swift integration
Create a Swift wrapper that:
Loads the bundled JS into a JSContext
Exposes a clean Swift API like func compile(_ source: String) throws -> IR
Handles errors gracefully (check context.exception)
Part 3: Full WEFT editor UI
Add a UI to the Swift app with:
A text editor/field where I can write WEFT code
A run button that compiles the code and executes the IR
Display for the output/result
Error display if parsing or execution fails
Start by exploring the JS codebase, then implement everything fully—don't leave stubs or TODOs.