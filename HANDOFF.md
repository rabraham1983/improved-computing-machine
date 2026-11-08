# Handoff: CodeScope (macOS app)

Branch: `claude/osx-code-analyzer-optimizer-b21kyg`
Written for the next Claude Code session, running locally on the Mac.

## Goal (from the user)

A macOS application that scans the code of an existing application, works out how it does what it
does at a granular level, and then accepts text prompts to modify/optimize that code. See README.md
for the full feature description and architecture map.

## State of the work

Everything is written and pushed, but **nothing has been compiled yet**. The previous session ran in
a Linux cloud container with no Swift toolchain and no network path to swift.org, so the code was
authored carefully but never built. Expect a handful of compile errors; nothing structural should
be wrong.

Layout:

- `Package.swift` — swift-tools-version 5.9, macOS 14, targets `CodeScopeCore` (library, Foundation
  only), `CodeScope` (SwiftUI executable), `CodeScopeCoreTests` (XCTest).
- `Sources/CodeScopeCore/*` — indexer, Claude streaming client, tool loop, engines, edit applier,
  diff engine (≈4,000 lines).
- `Sources/CodeScope/*` — app state, settings/Keychain, SwiftUI views (≈3,500 lines).
- `Tests/CodeScopeCoreTests/*` — unit tests for extractor, scanner, glob rules, diff, edits, SSE
  parser, request-body shape, report decoding.
- `Scripts/build-app.sh` / `make app` — wraps the release binary into `build/CodeScope.app`.

## First things to do on the Mac

```bash
git fetch origin && git checkout claude/osx-code-analyzer-optimizer-b21kyg
swift build 2>&1 | head -80        # fix compile errors in order; Core first, then the app
swift test                          # all tests in Tests/CodeScopeCoreTests should pass
swift run CodeScope                 # launch; Settings (⌘,) → paste ANTHROPIC API key → Open Project
```

Then do a real end-to-end run on a small project (this repo itself is a fine test subject):
Open Project → Analyze (⌘R) → watch the narrative stream → check the Report tab → ask a question in
Ask → run an optimization in Optimize → apply a diff → Revert last apply.

## Places most likely to need a compiler's attention

Checked by eye only; verify with the compiler:

1. `Sources/CodeScope/AppState.swift` — `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`
   is used to hop streaming callbacks onto the main actor in FIFO order. If the compiler complains
   about isolation, `Task { @MainActor in … }` is the fallback (ordering is practically FIFO).
2. `Sources/CodeScope/AppState.swift` — lazy `StreamThrottle` properties capturing `[weak self]`;
   `Task.detached { () -> Result<ProjectIndex, Error> in … }` in `rescan`.
3. `Sources/CodeScopeCore/SymbolExtractor.swift` — all regexes are built with `Rx.make`, which
   traps on an invalid pattern at first use. Run `swift test`; `SymbolExtractorTests` exercises every
   language's rule set and will surface a bad pattern immediately.
4. `Sources/CodeScopeCore/ClaudeClient.swift` — `URLSession.bytes(for:)` + `.lines`; SSE parsing is
   covered by `ClaudeClientTests`.
5. `Sources/CodeScope/Views/OverviewView.swift` / `AssistantPanel.swift` — `FlowLayout: Layout`,
   `Grid`, `confirmationDialog`, `.onChange(of:) { _, _ in }` (macOS 14 two-parameter form).
6. `Sources/CodeScope/Views/SidebarView.swift` — `OutlineGroup` over `FileNode` with
   `List(selection: $appState.selectedFilePath)` (selection type `String?`, rows tagged with path).
7. `Sources/CodeScopeCore/JSONValue.swift` — `Codable` `init(from:)` tries Bool before Double; this
   relies on `JSONDecoder` not coercing numbers to Bool (true on current Foundation).

## Claude API decisions already made (keep unless there is a reason to change)

- Default model `claude-opus-5-5`, user-selectable (Fable 5.1, Sonnet 5.5, Haiku 5.5). Default
  effort `high` via `output_config.effort`; `thinking: {type: "adaptive", display: summarized|omitted}`.
- Every request streams (`stream: true`, `max_tokens` 64,000). Header `anthropic-version: 2026-10-21`.
- `fallbacks: "default"` + header `anthropic-beta: server-side-fallback-2026-07-01` on models that
  support it (not Haiku). `stop_reason: "refusal"` is surfaced as `ClaudeError.refusal`.
- Prompt caching: the codebase snapshot is the first `system` block with `cache_control: ephemeral`;
  the tool list is identical in every mode so the cached prefix is shared across analyze/ask/optimize.
- Structured report uses `output_config.format = {type: "json_schema", schema: …}` with tools still
  present and `tool_choice: {type: "none"}` (keeps the cache prefix). If the API rejects that
  combination with a 400, the engine retries without tools automatically.
- Tool use: `tool_choice` is never forced (Opus 5.5 rejects `any`/`tool`); `propose_edits` is
  `strict: true`. Message history is append-only so replayed thinking blocks stay valid; the chat
  conversation is reset whenever the project is re-indexed (the system block changes).
- No `temperature`/`top_p`, no assistant prefill, no `budget_tokens`.

## Known gaps / ideas for after it compiles

- Syntax highlighting in the code viewer is minimal (comments only).
- `ContextBuilder.build` runs on the main thread in `AppState.updateContextSummary`; move it off
  main if large projects stall the UI.
- `.codescope/` (saved analysis + edit backups) is written inside the project; README tells users to
  gitignore it. Consider offering to append it to the project's `.gitignore`.
- No app icon yet (`Resources/AppIcon.icns` is picked up by the build script if added).
- Profiling-backed optimization (running the project's tests/benchmarks and feeding results back)
  was discussed with the user as a possible later feature; not started.

## Conventions

- Commit messages end with the attribution lines the harness provides; do not include model IDs in
  anything pushed to the repository.
- Push to `claude/osx-code-analyzer-optimizer-b21kyg` only; do not open a PR unless asked.
