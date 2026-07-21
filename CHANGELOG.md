# Changelog

All notable changes to Quiet Vibe Status. Dates are the day the version was cut.

## 1.0.2 — 21 Jul 2026

App icon redesign, take two.

### Changed

- **App icon** — the session grid and alert badge didn't read as anything in particular at a
  glance. Replaced with a `>_` terminal prompt sitting directly on the gradient body, the notch
  bitten out of the top edge above it, and a lit dot in the notch like a camera housing. The prompt
  is painted solid rather than cut through, so it stays high-contrast at every size instead of
  fading into whatever is behind the icon

## 1.0.1 — 21 Jul 2026

Homebrew tap.

### Added

- **Homebrew tap** — `brew tap quietapps/quietvibestatus && brew install --cask quietvibestatus`, at
  [quietapps/homebrew-quietvibestatus](https://github.com/quietapps/homebrew-quietvibestatus)

## 1.0.0 — 20 Jul 2026

First release.

### Notch panel

- Pill under the physical notch that merges with the hardware cutout, with an activity equaliser
  that animates only while an agent is working
- Clean and Detailed pill styles — Clean stays notch-width to leave the menu bar alone
- Panel expands on hover, on completion, or when something needs you, and hugs its content rather
  than claiming a fixed height
- Clicks pass through everywhere the panel isn't painted
- Joins every Space, survives fullscreen, follows keyboard focus across displays
- Compact bar on displays without a notch

### Sessions

- Live cards driven by agent hook events: project, worktree branch, prompt, current activity, model,
  and host terminal
- Subagents nest under their parent session
- Cards sort so anything blocking on you floats to the top
- Session recap from the agent's final message on an idle card
- Directory and first-prompt filters, with presets for the helper sessions agents spawn in the
  background
- Idle cleanup for agents that don't send a clear close signal

### Approvals

- Blocking permission cards showing the actual command, with Allow, Always allow, Deny, and a
  hand-back-to-terminal escape hatch
- "Always allow" writes a scoped permission rule rather than a blanket one — `npm test` doesn't
  approve all of `npm`
- Plan review with Markdown rendering, approve, approve with auto-accepted edits, or reject with
  written feedback
- Paginated question wizard for structured multi-question prompts, including free-text answers
- Quitting the app mid-approval releases the agent instead of hanging it

### Agents

- Claude Code, wired to fourteen hook events
- Codex, Gemini CLI, and Cursor Agent through a shared adapter that normalises their event names
- Hooks are merged into each CLI's config, never clobbered; JSON-with-comments is handled, symlinks
  are written through, and a backup is kept next to every file
- Hooks are re-applied on every launch, repairing configs another tool overwrote

### Jump

- Precise focus for iTerm2 and Terminal.app by session id, Ghostty by process tree, VS Code, Cursor,
  and Windsurf by workspace
- tmux panes are selected before the window is raised
- Falls back to activating the app when a precise route isn't available

### Sound

- Eight assignable events with synthesized 8-bit phrases, envelope-ramped so square waves don't
  click on good headphones
- Custom WAV, MP3, and AIFF import
- Quiet hours, including ranges that cross midnight
- Quiet scenes for Focus mode, a locked screen, and screen recording or sharing
- Audio engine shuts down when idle so the app never holds the output device

### Usage

- Optional status line bridge reads Claude's five-hour and seven-day limits, chaining in front of
  any status line you already had and passing your own output through untouched
- Codex quota read from its own state files
- Used or remaining display, with an Auto / Claude / Codex provider picker

### Settings

- Nine panes: General, Integrations, Notifications, Display, Sound, Usage, Shortcuts, Labs, About
- First-run onboarding that connects whichever agents it finds
- Full uninstall that removes every hook, the status line bridge, and the support folder

### Notes

- No licensing, trial, payment, or telemetry code exists anywhere in the app
- ⌘Y and ⌘N work inside the panel. The system-wide version is opt-in and ships off: it would take
  those keys from every other app while a request is pending, and a stray press would approve
  something unread
