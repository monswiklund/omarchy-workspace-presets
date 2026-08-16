# Workspace Presets

A bar widget for Omarchy Quattro. Click it, pick a project, and every app in
that preset opens on the workspace you assigned it — without the screen
following along while they start.

## Install

```sh
omarchy plugin add https://github.com/monswiklund/omarchy-workspace-presets.git --enable
```

Installed by hand instead:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.monswiklund.workspace-presets
```

## Managing presets

A row is the project and a chevron. Clicking the row launches it; the chevron
opens everything you can do to it, with a readable label instead of a glyph to
guess at — six icons on a row made a toolbar out of a list.

```
▣  Service System                    ⌄
   · 󰖯 3   󰡨 1   󰖟 2   󰍹 1
   Docker                        2  ›
   Icon                            ›
   Pages                         2  ›
   Rename
   Update from this workspace
   Close project
   Delete
```

Docker, Pages and Icon swap the contents of the same slot rather than opening a level
below it — three levels deep in a bar popup is nobody's idea of navigable.

| Action | What it does                                                          |
|--------|------------------------------------------------------------------------|
| Launch | Click the row                                                          |
| Docker | Tick the Compose projects this preset should bring up                  |
| Pages  | Paste a URL and press Enter; click a page to remove it                 |
| Icon   | A grid of glyphs; the current one is marked                            |
| Order  | Move up and move down; the row follows the preset it moved             |
| Rename | Inline field on the row itself                                         |
| Update | Replaces the window rows with the current workspace, keeps the rest    |
| Close  | Closes the windows and brings the stacks down                          |
| Delete | Removes the preset, not the windows                                    |

### From a keybinding

A panel you have to open first cannot go on `Super+1`, so presets are also
addressable by name:

```sh
omarchy-shell workspace-presets launch "Service System"
omarchy-shell workspace-presets list     # the names, one per line
omarchy-shell workspace-presets toggle   # the panel
```

`launch` answers `ok` or `unknown`, matching case-insensitively on the trimmed
name. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + code:10", "Service System",
  hl.dsp.exec_cmd("omarchy-shell workspace-presets launch 'Service System'"))
```

Keyboard in the panel: `↑`/`↓` walk the list, `→` opens a row, `Enter` runs what is focused,
`←` and `Esc` back out one level at a time — a submode returns to the menu, the
menu closes the row, and only then does `Esc` reach the panel. An armed
confirmation is always one `Esc` from being called off.

Update, Close and Delete arm first: the row's own label becomes *"Click again to
confirm"* and says what will happen — for Close, how many windows and stacks it
found.

Rename, delete and every other edit rewrite the file in place and keep every key
this plugin does not model, so a preset carrying your own fields survives. The
panel adopts what it wrote in the same breath rather than waiting to be told —
a FileView raises no change for its own write, and relying on that once left the
list showing a preset that was already gone from disk.

### What the list tells you

The summary counts each kind apart as glyphs — `󰖯 3   󰡨 1   󰖟 2   󰍹 1` for
three windows, one Docker stack, two pages and workspace 1. A row of counts
reads at a glance where a sentence has to be read, and "3 apps" on a preset
holding two stacks and two pages was true and useless. Two numbers appear only
when something would actually be left out: `󰖯 2/3`.

Every glyph here was rendered in the bar's font and checked by eye before it
went in, the same as the icon set.

A leading `·` and a filled row mark the project you are standing in: every
window the preset can recognise is on screen. A preset made only of commands it
cannot recognise never claims to be up.

The list scrolls once it outgrows the panel. It has to — the panel clamps its
height rather than growing, so a plain column would draw the last presets
nowhere and leave them reachable by nothing. The actions below stay put while
the projects scroll under them.

## Presets

Presets live in `~/.config/omarchy/workspace-presets.json`. Saving the file
updates the panel immediately — no restart, no rescan.

```json
{
  "version": 1,
  "presets": [
    {
      "name": "Sportson web",
      "icon": "󰅩",
      "focus": 1,
      "apps": [
        { "cmd": "ghostty --working-directory=~/code/web", "workspace": 1, "class": "com.mitchellh.ghostty" },
        { "cmd": "cursor ~/code/web",                      "workspace": 2, "class": "Cursor" },
        { "cmd": "chromium --new-window localhost:3000",   "workspace": 3, "class": "chromium" }
      ]
    }
  ]
}
```

| Field       | Meaning                                                                 |
|-------------|-------------------------------------------------------------------------|
| `name`      | Row label. A preset without one is skipped.                             |
| `icon`      | Optional glyph for the row.                                             |
| `focus`     | Workspace to switch to once everything is launched. Omit to stay put.   |
| `apps[]`    | What to open.                                                            |
| `cmd`       | Command line, run by Hyprland through `sh`, so `~` and `$VAR` expand.   |
| `workspace` | Where the window lands. Omit and it opens wherever you are.             |
| `class`     | Window class used to tell whether the app is already running.           |

An app can also be a bare string when you only care that it runs:
`"apps": ["slack", "spotify"]`.

## Replaying a preset

Clicking a preset launches every app in it, on the workspace the preset gives
it. A preset is a layout, so replaying it rebuilds that layout whole — it does
not quietly leave out whatever happens to be up already, and an app whose
command no longer resolves costs only its own window while the rest still open.

If you would rather reuse windows you already have, turn on "Skip apps that are
already running" for the widget in Setup > Plugins, or set
`"skipRunning": true` on its entry in `shell.json`. Matching is by window
`class`, so an app without one always launches either way.
`hyprctl clients -j | jq -r '.[].class'` lists the exact strings.

## Docker stacks

A Compose stack has no window, so a snapshot can never find it — the link
between a project's containers and the workspace you run it on exists only in
your head. So you pick it, once: the container button on a preset's row folds
out every Compose project Docker knows about, with `up`/`down` telling you what
is running right now. Tick the ones that belong to the preset.

A ticked stack is stored as an ordinary app entry, tagged so the panel can find
it again:

```json
{ "cmd": "docker compose -f '/srv/web/compose.yml' up -d", "compose": "/srv/web/compose.yml" }
```

Replay never reads the tag — a stack is just a command, which is what keeps
launching dumb. Stacks are placed ahead of the apps, since they are the slowest
thing to come up and the thing the apps behind them want already listening.

Two things worth knowing:

- **`docker compose ls -a` only lists projects Docker has containers for.** A
  project you have never brought up will not appear; run it once and it shows.
- **Nothing waits.** Everything in a preset is dispatched at the same moment, so
  your editor opens before the stack is healthy. `up -d` returns immediately and
  is idempotent, so this is fine until you need a healthcheck gate — that is the
  point at which sequencing is worth building, and not before.

## Updating a preset

Re-snapshotting used to mean losing everything that was not a window: the stacks
ticked into the preset and the pages typed into it. The refresh button replaces
**only** the window rows with the workspace you are on, and leaves the name,
icon, focus workspace, stacks and pages exactly as they were.

The recorder is asked for the app list rather than a new preset —
`record-preset --print` writes it to stdout and touches no file. An empty
recording is refused rather than emptying the preset.

Armed like a delete, because it throws away the window rows that are there now
and a snapshot of the wrong workspace is a silent loss.

**It says what it did.** The row reads *Updating…* while the recorder runs, and
a notification names the result: *Updated Service System — 4 windows, kept 1
stack and 2 pages*. An update can leave the row looking untouched — the windows
may well be the same ones — so a silent success would be indistinguishable from
a silent failure. A recording that comes back empty leaves the preset standing
and says so rather than saying nothing.

## Closing a preset

The inverse of launching: put the project down. Windows are closed and stacks
are brought down with `docker compose … down`.

- **Matching is blunt on purpose:** the classes the preset recorded, on the
  workspaces the preset uses. A second Chromium window you opened yourself on
  the same workspace is caught too — which is why the row names what it found
  before the second click: *"Close 3 windows and 1 stack?"*
- **The same app on a workspace the preset does not use is left alone**, and so
  is anything the preset never mentions.
- **Windows are closed, never killed.** An editor with unsaved work gets to say
  so.

## Window geometry

- **Floating windows come back placed.** Position and size are recorded and
  handed to Hyprland as rules on the exec itself, so the window arrives where it
  was instead of jumping there afterwards.
- **Tiled windows get no geometry at all.** Hyprland has no dispatcher that
  rebuilds a split tree, so recording numbers for a tiled window would promise
  something replay cannot keep. What it does keep is the order things opened in,
  which is what decides the arrangement for the two or three windows a project
  usually has.

## Pages

A browser keeps its tabs to itself — nothing on the command line says what was
open, so a snapshot can never capture them. The pages a project needs are typed
in once instead: the link button on a preset's row folds out its list, and a
pasted address lands in the file the moment you press Enter.

```json
{ "cmd": "/usr/lib/chromium/chromium --profile-directory=Default 'https://jira…'", "url": "https://jira…" }
```

- **They open in the browser and profile the preset already launches.** A work
  URL landing in a personal profile is the profile-picker failure one step
  later, so the command is built from the preset's own browser line rather than
  guessed. A preset with no browser of its own defers to
  `omarchy-launch-browser` and the desktop default.
- **A pasted address without a scheme gets `https://`.** Handed to a browser
  without one it would be a search, not a page.
- **The same address twice is refused**, and the field keeps what you typed so
  you can see why nothing landed. Blank input is refused the same way.
- **Pages go last in the preset**, behind the apps that need the browser up.
- **They open as tabs in one window, not a window each.** Handed to a browser
  one at a time, every address gets its own window; handed over together they
  arrive as tabs. The file keeps them as separate entries so they stay
  individually editable — only the launch coalesces them into a single call.
- **A preset with pages does not launch its browser separately.** The page call
  opens the browser itself, so starting it alongside would only add an empty
  window. The browser entry's workspace comes along with the pages, so the tabs
  still land where the browser was recorded. Remove every page and the browser
  goes back to launching on its own.
- `Esc` closes the editor, the `×` on a row removes that page.

## Snapshotting a workspace

"Snapshot this workspace" turns the windows on the workspace you are looking at
into a preset, **named after the project directory its terminals were sitting
in** — a preset called "Workspace 1 2026-08-16 09:00" is a preset you rename
every time. The timestamp is the fallback for when there was no directory to go
on, and a name you pass yourself always wins.
The workspace is kept on every app and as the preset's `focus`, so replaying the
snapshot puts the windows back where you took them and leaves you on that
workspace.

> Keep an eye on editors left open on `workspace-presets.json`. Their buffer
> predates every panel edit made since, and writing it reverts renames and
> brings deleted presets back. Reload (`:e!` in nvim) before saving.

From a terminal:

```sh
scripts/record-preset          # the workspace you are on
scripts/record-preset "Web"    # named
scripts/record-preset --all    # every workspace at once
```

`--all` has no row in the panel on purpose: sweeping the whole desktop produces
a preset carrying your music player, your chat client, and yesterday's project,
which is a session restore rather than a project. It stays one flag away for the
once-in-a-while case.

Snapshots read each window's real
command line from `/proc/<pid>/cmdline`, which is more honest than guessing
from the window class, with two caveats worth knowing:

- Arguments are joined on spaces, so an argument containing a space comes back
  unquoted.
- **Single-instance apps report their daemon's command line**, which is started
  with the flags that tell it *not* to put a window on screen. Those are
  stripped on the way in — `--initial-window=false` and
  `--gtk-single-instance=…` — because replaying them gives a preset that runs
  and opens nothing, which looks exactly like a broken feature.
- What is left is still the running process, not a launcher. Browsers and
  Electron apps re-run into their existing instance and **focus** rather than
  open a second window. If you want a preset to open a *new* window, say so
  explicitly: `chromium --new-window https://…` instead of the recorded line.
  Terminal directories are handled for you — see below.

Special workspaces (scratchpad) are left out.

### Terminal working directories

A terminal that reopens in `/` is a terminal you have to `cd` in every morning,
which is most of what a project preset is supposed to save you. The directory is
not on the window — a terminal running every window in one process has a single
`/proc` entry — so windows are matched to the shells inside it **by title**:

| Window title | Matched shell |
|---|---|
| `claude` | the one whose child process is `claude` |
| `~` | the one sitting in `$HOME` |
| `sportson/sportson-view  SV-175` | the one whose path ends in `sportson/sportson-view` |

Everything from the first space onward is decoration — Omarchy's prompt appends
the git branch behind a Nerd Font glyph — so it is cut before matching. Elided
titles (`…/work/project`) match on the tail that survives. A matched shell is
consumed, so two windows never claim the same one, and the result is recorded as
`--working-directory=…`.

- **One entry per terminal window**, not per directory. Two terminals in the
  same directory is a normal layout — one tailing logs, one you work in — so
  both come back.
- **A window whose title matches nothing is recorded without a directory.** You
  still get the terminal, it just opens where your shell would normally start.
- **Every snapshot leaves a record of what it saw**, one line per window, in
  `~/.cache/omarchy-workspace-presets/last-snapshot.log`:

  ```
  ws1 ghostty title=~              dir=/home/you            run=<none>
  ws1 ghostty title=✳ Claude Code  dir=/home/you/Dev/api    run=claude --continue
  ws3 ghostty title=zsh            dir=/home/you/Dev/api    run=docker compose logs -f
  ```

  When a preset opens somewhere unexpected, the answer is in there rather than
  in a guess.
- **The snapshot notification names the directories it caught**, and counts the
  terminals it caught none for:

  ```
  Saved "Workspace 1" — 4 apps from workspace 1
  in: ~, ~/Dev/work/sportson, ~
  1 terminal with no directory
  ```

  A shell sits where you left it, which is not always where you believe you are
  working — a tool open on a project does not move the shell that started it.
  The terminal's own title bar is the same truth, read before you snapshot
  rather than after you replay.

### What the terminal was running

A terminal that comes back empty is only half the layout — the log tail and the
assistant session were the point of the window. Whatever the shell had in the
foreground is recorded and started again:

```json
{ "cmd": "ghostty --working-directory=~/Dev/api -e docker compose logs -f", "workspace": 2 }
```

- **Claude Code is recorded as `claude --continue`**, which reopens the
  conversation that window was in. Sessions are kept per directory, so the
  directory does the addressing. Two Claude windows in the same directory both
  resume the newest conversation — a running session's id is not readable from
  the outside.
- **The window closes when the command ends.** `-e` runs the command instead of
  a shell, so quitting the program closes the terminal with it. Drop the `-e …`
  from the line if you would rather have a shell that stays.
- **Whatever was in the foreground is what comes back**, so a preset taken mid
  build replays that build. Snapshot when the workspace looks the way you want
  it to return.
- **A title nobody can read is still matched.** A shell alias makes the window
  say `dc logs -f` while the process is plainly `docker`, and no amount of title
  reading bridges that. It does not have to: once the identifiable windows are
  bound, the windows left over and the sessions left over are the same set, so
  they are paired off. Done only when the two counts agree — otherwise something
  is unaccounted for, and a guess would be somebody's wrong project.
- **Restored windows re-record cleanly.** A window started as `-e claude` has
  no shell inside it, only the command, and Claude Code renames the window to
  "✳ Claude Code" — so neither the title nor a shell lookup finds it. A terminal
  holding exactly one window needs neither: the single session inside it is that
  window's, whatever the title says. An existing `-e …` on the line is cut
  before the current one is written, so re-recording never stacks commands.

### Browser profiles

Chromium with more than one profile and no `--profile-directory` opens the
profile chooser instead of a browser, which stops a preset dead. The profile is
not readable from the running process, so the recorder appends the last profile
you used — wrong sometimes, but a browser every time beats a picker every time.
Edit the line when it guesses wrong.

### What a snapshot cannot bring back

A snapshot restores *windows*, not *sessions*. A terminal that was running
`claude` or tailing `docker compose logs -f` comes back as an empty shell in the
right directory, and a browser comes back on its own session restore rather than
the tabs you had. When a preset should always start something, say so in the
command:

```json
{ "cmd": "ghostty --working-directory=~/Dev/api -e docker compose logs -f", "workspace": 2 }
```

## Other terminals and browsers

The half that reads your desktop is portable already: shells, working
directories, foreground commands and the window-to-session matching all come
from `/proc` and process trees, and every terminal runs a shell as a child.

The half that writes a command line is not, and the differences fail silently.

| Terminal | Directory flag | Verified |
|---|---|---|
| ghostty | `--working-directory=DIR` | yes |
| foot | `--working-directory=DIR` | yes |
| alacritty | `--working-directory DIR` | yes |

`-e` needs no table: ghostty and alacritty implement it, and foot accepts it for
xterm compatibility.

**An unrecognised terminal is recorded without a directory.** A preset that
opens a terminal in the wrong place is a nuisance; one that writes ghostty
syntax at kitty is broken. Adding a terminal is one line in
`working_directory_flag` in `scripts/record-preset`, and a line in
`scripts/test-terminals` to hold it there. kitty and wezterm are absent on
purpose — their flags were not verifiable on the machine this was built on, and
guessing is what this section exists to prevent.

Browser profiles work the same way: Chromium, Chrome, Brave, Edge and Vivaldi
take `--profile-directory=NAME` with the last-used profile in their own
`Local State`; Firefox names profiles with `-P` and keeps them in
`profiles.ini`, so it gets its own branch rather than a row that almost fits.

The icon set is fixed rather than free text, and every glyph in it was rendered
in the bar's font and checked by eye before it went in — the only way to know a
glyph is not a blank box on the machine it ships to.

Both tables are pure string work, so `scripts/test-terminals` checks them
without any of these programs installed — which is the point, since most of them
are not.

## How launching works

This Hyprland evaluates `hyprctl dispatch` as Lua, so the classic
`exec [workspace 3 silent] cmd` form no longer applies. Each app becomes:

```
hyprctl dispatch 'hl.dsp.exec_cmd("cursor ~/code/web", { workspace = "2 silent" })'
```

`silent` sits inside the workspace rule rather than being its own effect —
Hyprland rejects `silent = true` as an unknown effect — and it is what keeps a
five-app preset from dragging the screen through five workspaces on the way up.

## Development

```sh
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" BarWidget.qml Panel.qml
scripts/test-model                 # quoting, skip detection, file rewrites, stacks
scripts/test-terminals             # terminal and browser command-line shapes
```

Saving any file under `~/.config/omarchy/plugins/` hot-reloads the plugin. If a
panel stops drawing after several reloads in a row, that is the reload state and
not your code — `omarchy-restart-shell` clears it.

## Remove

```sh
omarchy plugin remove io.github.monswiklund.workspace-presets
```
