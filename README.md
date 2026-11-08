# CodeScope

CodeScope is a native macOS application that reads an entire codebase, works out how the application
is built and how it runs, explains it to you, and then optimizes the code according to your
instructions — producing reviewable diffs that you can apply (and revert) with one click.

It is written in Swift and SwiftUI and uses the Claude API (Claude Opus 5.5 by default) for the
understanding and optimization work. All indexing happens locally; only the project snapshot and
your prompts are sent to `api.anthropic.com`.

## What it does

1. **Indexes a project locally.** Walks the folder (honouring `.gitignore` and skipping build
   output, dependencies and binaries), detects 30+ languages, extracts functions, types, imports
   and metrics (lines, comments, cyclomatic complexity), resolves imports into an internal
   dependency graph, and finds likely entry points.
2. **Understands the application.** Builds a token-budgeted "repo map" (directory tree, manifests,
   dependency hubs, every file in full or as a symbol outline) and hands it to Claude, which can
   read any file, search the code, list directories and inspect symbols through tools. The result
   is a streamed narrative of how the application works plus a structured report: purpose,
   architecture style, components, execution flow, data flow, external dependencies, build & run
   instructions, concerns, and ranked optimization opportunities with ready-made prompts.
3. **Answers questions.** A conversation panel with the same codebase context and tools, so you can
   ask "where is authentication handled?" or "walk me through startup" and get file-cited answers.
4. **Optimizes on request.** Type an instruction (or pick a preset: Performance, Memory,
   Readability, Concurrency, Startup, Security, Tests, Modernize), optionally focus on specific
   files, and Claude investigates the code, then records concrete edits through a strict
   `propose_edits` tool. CodeScope validates every hunk against the current files, shows a diff per
   file, and lets you apply the selected edits. Originals are backed up under
   `.codescope/backups/<timestamp>/` and the batch can be reverted.
5. **Visualises structure.** A code viewer with symbol outline, and a dependency graph of internal
   imports coloured by directory.

## Requirements

- macOS 14 Sonoma or later
- Xcode 15.3+ (or a Swift 5.9+ toolchain) to build
- An Anthropic API key — create one at <https://console.anthropic.com/settings/keys>

## Build and run

```bash
git clone <this repository>
cd improved-computing-machine

# Run directly from the command line
swift run CodeScope

# …or build a double-clickable app bundle at build/CodeScope.app
make app
open build/CodeScope.app

# Unit tests for the engine (indexing, diffing, edit application, API client)
swift test
```

You can also open `Package.swift` in Xcode and run the `CodeScope` scheme.

On first launch open **Settings (⌘,)** and paste your API key. It is stored in your login
Keychain. The `ANTHROPIC_API_KEY` environment variable is used as a fallback.

### Using it

1. **Open Project…** (⌘O) and choose the root folder of an application.
2. Browse files in the sidebar; the **Code** tab shows source with a clickable symbol outline, the
   **Graph** tab shows internal dependencies.
3. Press **Analyze** (⌘R). The narrative streams into the **Overview** tab; the structured
   **Report** appears when it finishes. Analyses are saved to `.codescope/analysis.json` in the
   project and reloaded the next time you open it.
4. Use **Ask** to question the codebase, or **Optimize** to request changes. Review each proposed
   edit's diff, untick anything you do not want, then **Apply**. Use **Revert last apply** if you
   change your mind. The project is re-indexed after every apply.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Model | Claude Opus 5.5 | Also Claude Fable 5.1 (most capable), Sonnet 5.5, Haiku 5.5 |
| Effort | High | `low` – `max`; controls adaptive-thinking depth and cost |
| Reasoning summaries | On | Shows Claude's summarised reasoning while it works |
| Safety fallback | On | `fallbacks: "default"`: if a safety classifier declines, the API re-runs the request on another Claude model |
| Snapshot budget | 300K tokens | How much of the project is embedded in full; the rest is outlined and read on demand |

## How CodeScope itself is built

```
Sources/CodeScopeCore/          Platform-independent engine (Foundation only)
  Models.swift                  Language, CodeFile, CodeSymbol, ProjectIndex, …
  SymbolExtractor.swift         Regex-based per-language symbol & import extraction
  Metrics.swift                 Line counts, complexity estimate, token estimator
  IgnoreRules.swift             .gitignore-style glob matching and default exclusions
  ProjectScanner.swift          Directory walk, dependency resolution, entry-point detection
  ContextBuilder.swift          Token-budgeted repo map sent to Claude (cached system block)
  ClaudeClient.swift            Streaming Messages API client over URLSession (SSE parser)
  Tools.swift                   Tool definitions + local executor (read_file, search_code, …)
  AgentLoop.swift               request → tool_use → tool_result loop, append-only history
  ArchitectureReport.swift      Structured-output schema and model
  Prompts.swift                 System prompts for explain / report / chat / optimize
  Engines.swift                 CodebaseSession, AnalysisEngine, ChatEngine, OptimizationEngine
  EditApplier.swift             Hunk application, previews, apply with backups, revert
  DiffEngine.swift              Line diff for previews
Sources/CodeScope/              The macOS app (SwiftUI)
  AppState.swift                View model coordinating indexing, analysis, chat, optimisation
  AppSettings.swift / KeychainStore.swift
  Views/                        Sidebar, code viewer, overview & report, graph, assistant panel
Tests/CodeScopeCoreTests/       Unit tests for the engine
```

Claude API usage follows the current Messages API conventions: adaptive thinking with a
configurable `effort`, streaming for every request, prompt caching on the codebase snapshot
(the cached prefix is shared across analysis, chat and optimization requests), strict tool
schemas, structured outputs (`output_config.format`) for the architecture report, and
server-side refusal fallbacks. Conversation history is append-only so replayed thinking blocks
remain valid.

## Costs and privacy

Each request includes the codebase snapshot (up to the configured budget). The first request
writes it to the prompt cache; subsequent requests within the cache lifetime read it at a
fraction of the price. Token usage is shown in the Activity sections. Nothing is sent anywhere
except the Anthropic API, and nothing is written to the project except
`.codescope/analysis.json` and `.codescope/backups/` (add `.codescope/` to your `.gitignore`).

## Limitations

- Symbol extraction is regex-based: it is tuned for navigation and context, not for compiler
  accuracy. Unusual formatting can produce missed or extra symbols.
- Dependency edges are inferred from import statements that resolve to project files; module-level
  imports (e.g. Swift modules) are reported as internal/external modules rather than file edges.
- Very large monorepos exceed the snapshot budget; Claude then works from outlines and reads files
  on demand, which costs more tool calls per answer.
- The app is not sandboxed (it needs to read and write arbitrary project folders), and the
  generated bundle is ad-hoc signed; distributing it requires a Developer ID signature.
