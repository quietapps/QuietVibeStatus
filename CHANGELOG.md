# Changelog

All notable changes to Quiet Vibe Status. Dates are the day the version was cut.

## 1.0.8 — 23 Jul 2026

### Added

- **Notification Center banners for blocking requests** — Allow, Always allow and Deny sit on the
  banner itself, so an agent waiting on you still gets through while you are in a fullscreen editor
  or looking at a display the panel isn't on. Answering from a banner resolves the same request the
  card would have, and never brings the app to the front. Plans get Approve and Reject; a structured
  question only offers to open the panel, because its options and free-text answers can't be
  represented honestly on a banner. Off during quiet scenes, and set by default to appear only when
  the panel can't be seen — Settings → **Notifications** → **Approval banners**
- **Diff preview on Edit, MultiEdit and Write cards** — the lines that change, with a little context
  and long unchanged runs collapsed, instead of the raw tool JSON with the old and new text quoted
  end to end
- **Risk strip on permission cards** — marks commands that delete outside the project, pipe a
  download straight into a shell, force-push, run as root, write to system locations, or touch
  credentials and private keys. Advisory only: nothing is blocked, and it is deliberately quiet on
  everyday work, since a warning that fires on `git status` is a warning you stop reading. Toggle in
  Settings → **Notifications**
- **Allow all / Deny all** for one session's queued permissions. Scoped to that session and to
  permissions only — plans and questions each still need their own answer — and Deny all asks for
  confirmation, because a denial the agent treats as a refusal is not as recoverable as an approval

### Fixed

- **Cards that outlived the decision** — a blocking request holds its hook connection open, and that
  connection *is* the agent's wait, but nothing watched it while you decided. If the agent stopped
  waiting — you answered the same prompt in its own terminal, the CLI exited, someone pressed
  Ctrl-C — the app never heard, and the card kept offering Allow and Deny for a settled question
  until the approval timeout swept it up minutes later. The connection is now watched for a hangup,
  which clears the card at once and decides nothing on your behalf
- **A display where the notch simply didn't work** — each panel's clickable region was pushed to it
  through a publisher that only fired on change, and the first size was reported while the hosting
  view was still being installed, before anything was listening. Whichever display lost that race
  ended up with an empty click region: hovering did nothing, clicking fell through, and it stayed
  that way until opening the panel on the *other* screen resized the content and finally published a
  region — which is why using the second display appeared to fix the first. The region is now read
  when it is needed rather than pushed, so there is no event to miss
- **Panels hidden for fullscreen still swallowing clicks** — hiding faded the window to fully
  transparent, and a transparent window still hit-tests, so the pill's footprint kept eating clicks
  meant for the app underneath on a screen showing nothing
- **Quota badge never appearing** — being installed is two things, Claude's status line pointing at
  our script and the script existing, and only the first survived the support folder being cleared or
  replaced. The check looked at the setting alone, so a missing script still reported as installed:
  Claude ran a command that wasn't there, no usage was ever written, the badge silently stayed away,
  and the Usage pane insisted the bridge was fine. The script is now verified and redeployed on every
  launch, the same repair the hook bridge has always had

## 1.0.7 — 22 Jul 2026

### Fixed

- **The panel still opening from the empty space below the pill** — 1.0.5 fixed the re-open that
  happened right after a collapse, but not the open itself. The hover handler trusted whatever
  SwiftUI reported, and SwiftUI reports hover against the container's animated frame: while the
  panel shrinks, that frame sweeps across a stationary pointer and fires an enter event. The notch
  then opened over empty screen and swallowed clicks meant for the window underneath. Opening now
  checks the pointer against the pill's real footprint, both before the hover delay and after it,
  so an event from the outgoing panel can't open anything
- **A single-session project reading as part of the group above it** — with **Group cards by
  project** on, a project with one session correctly gets no heading, but it also sat flush under
  the previous project's last card with nothing to separate them. Multi-session groups now indent
  their cards behind a rail, which gives the group a visible end; lone cards stay full width

### Changed

- **Reveals stay up long enough to read** — a completion or warning reveal dwelled for 5 seconds and
  was capped at roughly two cards tall, so the update it had opened to show was often gone, or cut
  off, before you looked over. Dwell now defaults to 12 seconds and offers up to 60, plus **Until
  dismissed**; the reveal's height ceiling moves from 180pt to 400pt and is adjustable in
  **Display** → **Reveal max height**. Reveals are still capped below a full panel on purpose — a
  finished task should not blanket the window you are working in
- **New installs show the pill on every display** — the default was the built-in display, which on a
  desk with external monitors put the app on a screen you may not be looking at, with nothing on the
  one you are. It now defaults to **All Displays**. Existing preferences are untouched
- **Quit is in Settings** — Settings → **General** → **Quit**, next to the menu bar item, for when
  the menu bar is crowded

## 1.0.6 — 21 Jul 2026

### Fixed

- **The Dock icon never left after closing Settings** — the app runs as a menu bar accessory, and
  Settings promotes it to a regular app while it is open so the window can take focus. The code that
  put it back was written but never wired to anything: no window delegate was ever set, so nothing
  called it. The icon sat in the Dock until you quit. Onboarding had the same hole from the other
  direction — only the Start button demoted the app, so closing that window with the red X left the
  icon behind too. Both windows now report their own close, and the promotion is reference counted,
  so closing one while the other is still open no longer drops the Dock icon out from under a
  visible window
- **The session-start sound playing twice for one session** — Claude re-sends `SessionStart` for the
  same session id on resume, clear, and compact. The chime was gated on the store's return value,
  which is the session on both the create and the update path, so every one of those repeats rang
  again against a card that already existed. The gate now asks whether the card was already there

## 1.0.5 — 21 Jul 2026

### Fixed

- **Panel re-opening when the pointer was near, not on, the notch** — after the panel collapsed, it
  re-checked whether the pointer was still over the pill so it could re-open if you hadn't really
  left. That check used the panel's live size, which is still mid-shrink 120ms later, so the hit
  area was panel-sized: sitting anywhere in the space the panel had just vacated sprang it back
  open. The re-open now tests the pill's own footprint, which stays honest while the panel animates

## 1.0.4 — 21 Jul 2026

### Fixed

- **Panel scrollbar flickering** — the panel sizes itself to its content, and a fractional content
  height against an integer-rounded frame read as a one-pixel overflow, so the scroll indicator
  appeared even when the list was nowhere near the maximum height. Because the elapsed-time and
  activity text re-measure the panel every second, the phantom overflow came and went between
  hovers. The frame is now rounded up so it is never shorter than its content, and the indicator is
  shown only when the list genuinely exceeds the panel's maximum height

## 1.0.3 — 21 Jul 2026

Duplicate cards, stuck cards, session history and cost, and the first tests.

### Changed

- **App icon** — dropped the notch and the terminal prompt entirely. Three activity waves fade
  from pale to mint as they travel and settle into a single glowing dot — the signal, and the one
  thing in it that needs you

### Fixed

- **Duplicate session cards, and the session-start sound playing twice** — agents spawn helper
  sessions (title generators, memory writers) in your own project directory. They announce
  themselves with `SessionStart` before their prompt exists, so the prompt filters could not judge
  them yet, and once the prompt did arrive the store's update path never re-checked the filters. The
  helper's card stayed forever, without a model, looking exactly like a duplicate of your real
  session. Filters now run on every event, and the start chime waits to see whether the session
  survives them
- **Cards stuck at "working" after a session ended** — closing a terminal tab or killing the CLI
  skips its exit hooks, so `SessionEnd` never arrives and the card sat there for an hour. Sessions
  are now checked against the agent's own process and retire within 30 seconds, or instantly when
  you open the panel. A pid is only trusted as a liveness signal once the same one has been seen
  twice, so a CLI that runs hooks through a throwaway shell never has its live cards culled

### Added

- **Group cards by project** — an optional heading collects sessions from the same directory
  instead of a flat list of identically-titled cards. Off by default; toggle in Display
- **Session history** — finished sessions are logged with duration, model, token count, and an
  estimated cost, in a new History settings pane with a seven-day summary. Stored locally; toggle
  in History
- **Per-session token cost** — a card chip shows the session's token spend, with the input /
  output / cache breakdown on hover. Cost is estimated at published list prices, not a bill —
  subscription plans don't charge per token. Toggle in Display
- **Both quotas at once** — in Auto mode the usage badge now shows Claude and Codex side by side
  when both have reported, rather than only the most recent. The quiet provider is often the one
  about to run out
- **Usage badge names its provider** — a five-hour percentage means nothing without saying whose
  quota it is, and Claude's and Codex's numbers look identical
- **Approvals hand themselves back** — permission hooks are installed with a 24-hour timeout, so an
  unanswered card blocked the agent for the rest of the day. After a configurable wait (15 minutes
  by default) the hook is released and the agent asks in its own terminal instead. Nothing is ever
  approved or denied on your behalf
- **Sessions survive a restart** — agents keep working while the app is quit or updating, and their
  `SessionStart` has long passed, so the panel came back empty. Cards are restored for sessions
  whose process is still alive. Settings → General turns it off and deletes the file
- **Competing monitor detection** — Settings → Integrations flags hooks belonging to another agent
  monitor found in the same config, including one left behind by an app that was uninstalled, and
  removes just those entries on request
- **Test suite** — 88 tests over the adapters, hook response contracts, session filtering and
  liveness, approval timeouts, persistence, the config scanner, model pricing, session history, and
  project grouping. The Codex, Gemini, and Cursor adapters now have coverage without needing a
  live agent

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
