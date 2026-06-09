**English** · [中文](./README.zh-CN.md)

# EnvCue

> A menu-bar **scene switcher** for your shell environment on macOS — flip between global scenes like *personal* / *work* in one click, see which scene you're in from the menu bar at all times, and get an **honest, visible** notice in already-open terminals when a switch actually takes effect.

**Status: M2 reached** (full CLI pipeline + the menu-bar Liquid Glass experience are usable); M3 (Homebrew distribution) is wrapping up. See the [roadmap](#roadmap).

---

## Why

Like many people, you may have piled aliases, plugins, SDK config, and several switchable environments (different LLM `API_KEY`s for personal vs. company, different JDKs…) into a single `~/.zshrc`. The result:

1. **You can't tell which set is active right now** — you have to `echo $API_KEY` to be sure.
2. **Switching means hand-editing or naming conventions** — unintuitive and error-prone.
3. **Secrets sit in plaintext in a dotfile** — a leak risk.

EnvCue fixes exactly these three: **visibility** (the menu bar always shows the current scene), **safety** (secrets live in the Keychain, never on disk in plaintext), and **honesty** (every switch gives a clear, visible path to taking effect — it never pretends a hot-reload succeeded).

## Where it fits: integration + visibility + honesty, not reinvention

EnvCue sits *on top of* [mise](https://mise.jdx.dev/) / [direnv](https://direnv.net/) and does only the two things the whole category leaves empty — **visibility** and **honesty**. It **never touches PATH**:

| Concern | Owner |
|---|---|
| PATH / versions / per-directory loading | **Delegated to mise·direnv** — EnvCue never writes PATH |
| Secret storage | macOS **Keychain** (the tool never holds or writes plaintext) |
| Scene definition → evaluation → snapshot → shell picks it up → honest notice | **EnvCue** |

## Core design principles

- **Secrets and config live apart.** API keys go in the Keychain (only a reference is stored; the real value is fetched at `source` time); ordinary env vars go in `~/.config/envcue/` (plaintext TOML, shareable, hand-edit friendly). **No file on disk ever holds a plaintext secret.**
- **Deterministic, traceable evaluation.** Every variable's final value traces back to exactly one layer (`base` or the active `scene`) — no implicit precedence.
- **It respects physics.** A running shell can't have its environment rewritten from outside. EnvCue only controls (a) what the *next* shell reads at startup, and (b) re-reads in an already-open terminal on its next prompt — and **prints a one-shot single-line notice only when that terminal is genuinely affected**. It never lies.

## How it works (overview)

```
Scene definitions (base + scene, TOML)
        │  evaluate (pure function, base < scene overlay)
        ▼
   atomic snapshot.zsh  +  generation fingerprint
        │
        ├─ new shell starts → .zshrc shim sources it
        └─ open terminal, next prompt → precmd hook checks generation;
                                        re-reads (and fetches secrets) only if it changed,
                                        then prints one honest notice
```

- In the snapshot a secret is only a `$(envcue keychain-get ...)` reference; the real value travels through an stdout pipe into the shell — **never through argv or history**.
- `generation` fingerprints the **environment content only** (not the scene name): if two scenes resolve to the same environment, switching prints **no** notice (because this terminal's environment truly didn't change).
- When you switch scenes, variables that belonged only to the previous scene (secrets included) are `unset` on an open terminal's next prompt — what the diff preview promises to remove is actually removed.

## Scope (v1)

**In:** macOS only (Tahoe 26+) / zsh only; a `base + scene` layer model (scenes are mutually exclusive — one at a time); Keychain secret backend; a pre-switch diff preview; menu-bar visibility (SwiftUI + Liquid Glass).

**Out (explicitly deferred; the data model reserves room):** freely stacking multiple scenes, a mise/direnv management UI, a persistent prompt segment, version switching (JDK, etc.), injecting env into GUI apps, bash/fish, remote sync / team features. **Per-directory loading or any PATH manipulation — never, by design; delegated to mise·direnv.**

## Install

Via Homebrew (the csthink tap):

```sh
brew install csthink/tap/envcue
```

This is a **source-build** formula: it compiles on your machine with **Xcode 26** and requires **macOS Tahoe 26+**. After installing:

```sh
# Launch the menu-bar app (add it to Login Items to start at login)
open "$(brew --prefix)/opt/envcue/EnvCue.app"

# Enable the per-terminal shim (idempotent — only touches the block between paired
# anchors in ~/.zshrc), then open a new terminal
envcue install
```

The `envcue` CLI is on your PATH after `brew install`; the menu-bar app and the CLI share one binary and one apply path.

## Quick start (CLI)

```sh
# Store a secret in a scene (read from stdin — never argv / history)
printf %s "$OPENAI_API_KEY" | envcue secret set personal OPENAI_API_KEY

# Preview what switching to a scene would change (secrets shown as references, not plaintext)
envcue diff work

# Switch scene (eval → diff → confirm → atomic write)
envcue scene work

# Show the active scene / generation / snapshot path
envcue status
```

Config lives in `~/.config/envcue/` (`base.toml` + `scenes/<name>.toml`, shareable plaintext TOML); generated state lives in `~/.config/envcue/state/` (snapshot / generation / manifest — **do not hand-edit**).

## Tech stack

Swift · SwiftUI `MenuBarExtra` · minimum macOS Tahoe 26 · Liquid Glass (all system materials, nothing self-drawn) · one binary, two modes (the menu-bar `.app` + the `envcue` CLI) · macOS Keychain.

## Roadmap

| Milestone | Scope | Status |
|---|---|---|
| **M1** | Full CLI pipeline (eval / secrets / snapshot / shim / subcommands) — usable day to day | ✅ |
| **M2** | Menu-bar visibility + the Liquid Glass experience | ✅ |
| **M3** | Homebrew distribution + bilingual README | 🚧 wrapping up |

## License

[MIT](./LICENSE) © 2026 Mars
