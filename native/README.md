# Apeiron, native

A native macOS app (SwiftUI) and terminal client for working with AI models as
an agent: it reads your project, edits files, runs commands and keeps a task
list, while you stay in control of what it's allowed to do.

The web app at the repository root is unchanged; this folder is a separate
Swift package.

```
native/
  Sources/ApeironKit   the agent harness: providers, tools, permissions, hooks,
                       context management, sessions (Foundation only; macOS + Linux)
  Sources/ApeironApp   the SwiftUI app (macOS 14+)
  Sources/ApeironCLI   `apeiron`, the same harness in a terminal
  Tests/               harness tests (run on macOS and Linux)
```

## Run it

Requirements: macOS 14 Sonoma or later and Xcode 16 (Swift 6 toolchain).

```bash
cd native
swift run Apeiron                    # the app
swift run apeiron --demo             # terminal client, offline demo model
ANTHROPIC_API_KEY=… swift run apeiron "explain this repo"
scripts/build-app.sh                 # release build/Apeiron.app (+ zip)
```

Opening `native/Package.swift` in Xcode also works: pick the `Apeiron` scheme
and run.

Add API keys in **Settings → Models** (stored in the Keychain) or via the usual
environment variables (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENROUTER_API_KEY`, `GEMINI_API_KEY`, `MISTRAL_API_KEY`, `DEEPSEEK_API_KEY`,
`MINIMAX_API_KEY`). Ollama works locally without a key. The **Demo** model runs
the whole loop offline (real tools, scripted model) so you can see how it
works before adding a key.

## The app

- **Calm, readable transcript.** Warm paper palette with real dark mode, a
  serif reading face (switchable), streamed markdown with tables and
  highlighted code, collapsible thinking, and tool calls as compact cards that
  expand to show output or a diff.
- **Approvals inline.** When the agent wants to edit or run something, a card
  slides up above the composer with the command or diff. Return allows once,
  ⌘Return always allows (it saves a rule), Esc declines, and you can tell it
  why.
- **Permission modes** (⌘⇧M): *Ask first*, *Auto-edit*, *Plan* (read-only)
  and *Full access*. Catastrophic commands are blocked in every mode.
- **Inspector** (⌥⌘I): the live task list, a context gauge with cache hit rate
  and estimated cost, and every file changed this session with its diff.
- **Command palette** (⌘K): actions, models, modes and chats, fuzzy-matched.
- **Projects** in the sidebar: recent folders, pinned and recent chats,
  search, rename, export to Markdown.
- **Composer**: slash commands with completion, file and image attachments
  (drag and drop works), model picker grouped by provider, mode chip.

## The harness

`ApeironKit.Agent` is the loop: call the model, run the tools it asks for,
feed results back, repeat. Its design follows a few rules that make long
agent sessions reliable and cheap.

**The transcript is append-only.** The system prompt and tool list are fixed
for a session, so provider prompt caches stay warm turn after turn. Things
that change mid-session (permission mode, hook output, a file the user
edited) travel as `<system-reminder>` blocks on the next user message rather
than rewriting history. Anthropic thinking blocks are replayed only with
their signatures, and unknown block types round-trip untouched.

**Every tool call gets exactly one result.** Errors, denials, timeouts and
interruptions all produce a result in the very next message, and
`repairHistory` fills any gap before a request (for example after a crash),
so the conversation is always valid to send.

**Context is a budget.** Usage is tracked per request; when the prompt nears
the threshold (80% by default) the conversation is compacted into a
structured summary (goal, decisions, files, open tasks) and the latest
request is carried forward. Large tool outputs are truncated in the middle
and the full text is spilled to a file the agent can read back with
`read_file`.

**Tools are small and honest.** `read_file`, `write_file`, `edit_file`
(exact string replacement with uniqueness checks), `list_directory`, `glob`,
`grep`, `bash` (timeouts, process-group kill), `web_fetch`, `todo_write`,
`use_skill` and `task` (a sub-agent with its own context that returns only
its conclusion). Writes require the file to have been read first and not
changed on disk since. Read-only calls in one turn run in parallel.

**Permissions are policy, not prompts.** `PermissionPolicy` decides allow,
ask or deny from the mode, rules like `bash(npm test:*)` or
`edit_file(src/**)`, and a classifier for risky and catastrophic commands.
The UI only answers the questions the policy asks.

**Resilient streaming.** SSE streaming for Anthropic and OpenAI-compatible
APIs, retries with exponential backoff and jitter on 429/5xx/overloaded
(honouring `retry-after`), partial output discarded on retry, and clean
cancellation. On Anthropic: adaptive thinking with an effort setting, prompt
caching, eager tool-input streaming, and server-side fallbacks so a declined
request is retried on a fallback model instead of failing the turn.

**Your project, your rules.** Memory comes from `APEIRON.md`, `AGENTS.md` or
`CLAUDE.md` (plus `~/.apeiron/APEIRON.md`). Skills live in
`.apeiron/skills/<name>/SKILL.md` and load only when used. Custom slash
commands are Markdown files in `.apeiron/commands/` with `$ARGUMENTS`. Hooks
(`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`) are
shell commands configured in `.apeiron/settings.json`. They receive the event
as JSON on stdin; exit code 2 blocks and feeds stderr back to the model.

Example `.apeiron/settings.json`:

```json
{
  "permissions": { "allow": ["bash(npm test:*)", "edit_file(src/**)"], "deny": ["bash(git push:*)"] },
  "hooks": [
    { "event": "PostToolUse", "matcher": "edit_file|write_file", "command": "jq -r .tool_input.path | xargs npx prettier --write" }
  ]
}
```

## Tests

```bash
swift test
```

The tests drive the full loop with a scripted provider: parallel tool calls,
permission denials with feedback, interruption mid-tool, history repair,
compaction, SSE parsing for both API styles, the request bodies we send, and
the file tools' edge cases. CI runs them on macOS and Linux, builds the app,
and uploads a zipped `Apeiron.app` as a workflow artifact.
