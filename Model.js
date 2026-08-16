.pragma library

// Pure logic for Workspace Presets: parsing the user's JSON, deciding which
// apps still need launching, and building the Lua expressions this Hyprland
// takes. No QML types in here, so every rule below is testable with plain
// node — see scripts/test-model.

// ---------------------------------------------------------------- parsing
//
// The config is a file the user edits by hand, so parsing stays forgiving:
// a broken preset is dropped rather than taking the whole panel down with
// it, and the syntax error is handed back for the panel to show.

function parseConfig(text) {
  var trimmed = String(text || "").trim()
  if (trimmed === "") return { presets: [], error: "", raw: null }

  var data
  try {
    data = JSON.parse(trimmed)
  } catch (e) {
    return { presets: [], error: String(e.message || e), raw: null }
  }

  var list = presetList(data)
  var presets = []
  for (var i = 0; i < list.length; i++) {
    var preset = normalizePreset(list[i])
    // Its position in the file, not in this array: entries that fail to
    // normalize are dropped here but still occupy a slot on disk, and a
    // rename that ignored that would edit the wrong preset.
    if (preset) {
      preset.sourceIndex = i
      presets.push(preset)
    }
  }
  return { presets: presets, error: "", raw: data }
}

function normalizePreset(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  var name = String(raw.name || "").trim()
  if (name === "") return null

  var apps = []
  if (Array.isArray(raw.apps)) {
    for (var i = 0; i < raw.apps.length; i++) {
      var app = normalizeApp(raw.apps[i])
      if (app) apps.push(app)
    }
  }

  return {
    name: name,
    icon: String(raw.icon || ""),
    focus: normalizeWorkspace(raw.focus),
    apps: apps
  }
}

// A bare string is the shorthand for "run this, wherever the window lands" —
// the shape a preset written in thirty seconds has before workspaces matter.
function normalizeApp(raw) {
  if (typeof raw === "string") {
    var bare = raw.trim()
    return bare === "" ? null : { cmd: bare, workspace: "", matchClass: "" }
  }
  if (!raw || typeof raw !== "object") return null

  var cmd = String(raw.cmd || "").trim()
  if (cmd === "") return null

  return {
    cmd: cmd,
    workspace: normalizeWorkspace(raw.workspace),
    matchClass: String(raw["class"] || "").trim().toLowerCase(),
    // Carried for the panel's benefit only. Replay never reads either tag — a
    // stack and a URL are ordinary commands, which is what keeps launching dumb.
    compose: String(raw.compose || "").trim(),
    url: String(raw.url || "").trim(),
    // Geometry is only ever recorded for a floating window; a tiled one gets
    // its place from the layout and the order things opened in.
    floating: raw.floating === true,
    at: String(raw.at || "").trim(),
    size: String(raw.size || "").trim()
  }
}

// Workspaces are strings all the way through: Hyprland accepts "3",
// "special:scratchpad", and "empty" in the same slot, and JSON hands us
// the numeric ones as numbers.
function normalizeWorkspace(value) {
  if (value === undefined || value === null) return ""
  return String(value).trim()
}

// --------------------------------------------------------------- compose
//
// A Docker stack has no window, so a snapshot can never find it — the link
// between a project's containers and the workspace you run it on exists only
// in your head. So it is picked, once, and then rides along in the preset as
// an ordinary command.

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

function composeCommand(configFile) {
  return "docker compose -f " + shellQuote(configFile) + " up -d"
}

// `docker compose ls -a` reports every project Docker still has containers
// for, running or exited. A project never brought up is not in the list and
// cannot be offered — noted in the README rather than papered over.
function parseComposeProjects(json) {
  var list
  try {
    list = JSON.parse(json || "[]")
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []

  var projects = []
  for (var i = 0; i < list.length; i++) {
    var entry = list[i]
    var configFile = String((entry && entry.ConfigFiles) || "").split(",")[0].trim()
    if (configFile === "") continue
    projects.push({
      name: String((entry && entry.Name) || configFile),
      configFile: configFile,
      running: String((entry && entry.Status) || "").indexOf("running") !== -1
    })
  }
  projects.sort(function (a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return projects
}

function presetComposeFiles(preset) {
  var files = []
  for (var i = 0; i < preset.apps.length; i++) {
    var compose = preset.apps[i].compose
    if (compose && files.indexOf(compose) === -1) files.push(compose)
  }
  return files
}

function hasCompose(preset, configFile) {
  return presetComposeFiles(preset).indexOf(configFile) !== -1
}

// Stacks go in front: they are the slowest thing to come up and the thing the
// apps behind them want already listening.
function withComposeToggled(raw, sourceIndex, configFile) {
  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = clonePresetEntry(list[sourceIndex])
  var apps = Array.isArray(entry.apps) ? entry.apps.slice() : []
  var at = -1
  for (var i = 0; i < apps.length; i++) {
    var app = apps[i]
    if (app && typeof app === "object" && String(app.compose || "") === configFile) { at = i; break }
  }

  if (at !== -1) apps.splice(at, 1)
  else apps.unshift({ cmd: composeCommand(configFile), compose: configFile })

  entry.apps = apps
  list[sourceIndex] = entry
  return withPresetList(raw, list)
}

// ------------------------------------------------------------------ urls
//
// A browser keeps its tabs to itself — nothing on the command line says what
// was open — so the pages a project needs are typed in once and then belong to
// the preset. They are stored as ordinary app entries, tagged so the panel can
// list them again.

function normalizeUrl(value) {
  var url = String(value || "").trim()
  if (url === "") return ""
  // A pasted address rarely carries its scheme, and a browser handed one
  // without it treats it as a search.
  if (url.indexOf("://") === -1) url = "https://" + url
  return url
}

// Opened by the same browser the preset already launches, carrying whatever
// profile that line carries. Landing a work URL in a personal profile is the
// same failure as the profile picker, one step later.
function browserAppFor(preset) {
  for (var i = 0; i < preset.apps.length; i++) {
    var app = preset.apps[i]
    if (app.url || app.compose) continue
    if (/(chromium|chrome|firefox|brave|vivaldi)/i.test(String(app.cmd).split(/\s+/)[0])) return app
  }
  return null
}

function browserBaseFor(preset) {
  var app = browserAppFor(preset)
  if (!app) return ""

  var parts = String(app.cmd).split(/\s+/)
  var base = parts[0]
  for (var p = 1; p < parts.length; p++) {
    if (parts[p].indexOf("--profile-directory=") === 0 || parts[p].indexOf("-P") === 0) {
      base += " " + parts[p]
    }
  }
  return base
}

function urlCommand(preset, url) {
  var base = browserBaseFor(preset)
  // Without a browser of its own the preset defers to whatever the desktop
  // considers the default, rather than guessing at one.
  return (base === "" ? "omarchy-launch-browser" : base) + " " + shellQuote(url)
}

// Handed to a browser one at a time, each address gets its own window. Handed
// over together they arrive as tabs in one — which is what a set of pages
// belonging to a single project is. The file keeps them as separate entries so
// they stay individually editable; only the launch coalesces them.
function mergedLaunchSteps(preset, steps) {
  var browserApp = browserAppFor(preset)
  var out = []
  var urls = []

  for (var i = 0; i < steps.length; i++) {
    if (steps[i].app.url) urls.push(steps[i].app.url)
    else out.push(steps[i])
  }
  if (urls.length === 0) return out

  // The page call opens the browser itself, so launching the browser beside it
  // only adds an empty window. Its workspace comes along, or the tabs would
  // land wherever you happen to be standing.
  var workspace = ""
  if (browserApp) {
    workspace = browserApp.workspace
    for (var d = 0; d < out.length; d++) {
      if (out[d].app === browserApp) { out.splice(d, 1); break }
    }
  }

  var base = browserBaseFor(preset)
  if (base === "") base = "omarchy-launch-browser"

  var quoted = []
  for (var u = 0; u < urls.length; u++) quoted.push(shellQuote(urls[u]))

  out.push({
    app: {
      cmd: base + " " + quoted.join(" "),
      workspace: workspace,
      matchClass: "",
      compose: "",
      url: urls[0],
      pages: urls.length
    },
    skipped: false
  })
  return out
}

function presetUrls(preset) {
  var urls = []
  for (var i = 0; i < preset.apps.length; i++) {
    var url = preset.apps[i].url
    if (url && urls.indexOf(url) === -1) urls.push(url)
  }
  return urls
}

// URLs go last: they are the cheapest thing to start and the thing that wants
// the browser already up.
function withUrlAdded(raw, sourceIndex, url) {
  var clean = normalizeUrl(url)
  if (clean === "") return null

  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = clonePresetEntry(list[sourceIndex])
  var apps = Array.isArray(entry.apps) ? entry.apps.slice() : []

  for (var i = 0; i < apps.length; i++) {
    if (apps[i] && typeof apps[i] === "object" && String(apps[i].url || "") === clean) return null
  }

  var preset = normalizePreset(entry)
  apps.push({ cmd: urlCommand(preset, clean), url: clean })
  entry.apps = apps
  list[sourceIndex] = entry
  return withPresetList(raw, list)
}

function withUrlRemoved(raw, sourceIndex, url) {
  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = clonePresetEntry(list[sourceIndex])
  var apps = Array.isArray(entry.apps) ? entry.apps.slice() : []

  for (var i = 0; i < apps.length; i++) {
    if (apps[i] && typeof apps[i] === "object" && String(apps[i].url || "") === url) {
      apps.splice(i, 1)
      entry.apps = apps
      list[sourceIndex] = entry
      return withPresetList(raw, list)
    }
  }
  return null
}

// ---------------------------------------------------------------- icons
//
// A fixed set rather than free text: every one of these was rendered in the
// bar's font and checked by eye before it went in, which is the only way to
// know a glyph is not a blank box on the machine it ships to.

function iconChoices() {
  return [
    "󰅩", "󰙅", "󱂬", "󰈹", "󰆍", "󰡨", "󰆼",
    "󰘦", "󰊤", "󰃤", "󱓞", "󰉋", "󰒓", "󰙨",
    "󰄨", "󰄄", "󰋩", "󰌾", "󰒋", "󰄛", "󰏗",
    "󰃣", "󰂺", "󰇮", "󰭹", "󰝚", "󰅶", "󰀹"
  ]
}

function withIconSet(raw, sourceIndex, icon) {
  var chosen = String(icon || "").trim()
  if (chosen === "") return null

  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = clonePresetEntry(list[sourceIndex])
  entry.icon = chosen
  list[sourceIndex] = entry
  return withPresetList(raw, list)
}

// ----------------------------------------------------------------- order
//
// The list is file order, so the project you run every day sinks under the one
// you ran once. Moving is by source index, like every other edit, and a move
// off either end is refused rather than wrapped — a list that wraps while you
// hold a key loses your place.

function withPresetMoved(raw, sourceIndex, delta) {
  var list = presetList(raw).slice()
  var target = sourceIndex + delta
  if (sourceIndex < 0 || sourceIndex >= list.length) return null
  if (target < 0 || target >= list.length) return null

  var moving = list[sourceIndex]
  list.splice(sourceIndex, 1)
  list.splice(target, 0, moving)
  return withPresetList(raw, list)
}

// ------------------------------------------------------------ navigation
//
// The panel's own state machine, kept here because it is where the tests are.
// Delete once lived in the QML with no coverage, and a user found it before a
// test did.

// Cursors wrap: a list you can walk off the end of makes you look at the
// screen to know where you are.
function cycleIndex(current, delta, count) {
  if (count <= 0) return 0
  var next = current + delta
  if (next < 0) return count - 1
  if (next >= count) return 0
  return next
}

// Backing out goes one level at a time, and never further than one press. An
// armed confirmation is always one Escape from being called off, which is the
// whole reason arming is worth anything.
function backOutStep(state) {
  if (state.renaming) return "cancel-rename"
  if (state.armed) return "disarm"
  if (state.mode !== "menu") return "to-menu"
  if (state.expanded) return "collapse"
  return "close-panel"
}

function menuLabel(action, armed) {
  if (armed) return "Click again to confirm"
  switch (action) {
    case "icon": return "Icon"
    case "up": return "Move up"
    case "down": return "Move down"
    case "stacks": return "Docker"
    case "pages": return "Pages"
    case "rename": return "Rename"
    case "update": return "Update from this workspace"
    case "close": return "Close project"
    case "delete": return "Delete"
  }
  return ""
}

function isDestructive(action) {
  return action === "delete" || action === "close"
}

// --------------------------------------------------------------- closing
//
// The inverse of launching: put the project down. Windows are matched by the
// class the preset recorded, on the workspaces the preset uses — blunt on
// purpose. A second chromium window you opened yourself on the same workspace
// will be caught too, which is why closing asks first and says what it found.

function closePlan(preset, clientsJson) {
  var classes = {}
  var workspaces = {}
  var stacks = []

  for (var i = 0; i < preset.apps.length; i++) {
    var app = preset.apps[i]
    if (app.compose) { if (stacks.indexOf(app.compose) === -1) stacks.push(app.compose); continue }
    if (app.matchClass) classes[app.matchClass] = true
    if (app.workspace) workspaces[app.workspace] = true
  }
  if (preset.focus) workspaces[preset.focus] = true

  var windows = []
  var list
  try {
    list = JSON.parse(clientsJson || "[]")
  } catch (e) {
    list = []
  }
  if (!Array.isArray(list)) list = []

  for (var c = 0; c < list.length; c++) {
    var client = list[c]
    var name = String((client && client["class"]) || "").toLowerCase()
    var ws = client && client.workspace ? String(client.workspace.id) : ""
    if (!classes[name] || !workspaces[ws]) continue
    windows.push({
      address: String(client.address || ""),
      title: String(client.title || ""),
      "class": String(client["class"] || ""),
      workspace: ws
    })
  }

  return { windows: windows, stacks: stacks }
}

function closeWindowExpr(address) {
  return "hl.dsp.window.close({ window = " + luaString("address:" + address) + " })"
}

function composeDownCommand(configFile) {
  return "docker compose -f " + shellQuote(configFile) + " down"
}

function closeSummary(plan) {
  var parts = []
  var windows = plan.windows.length
  var stacks = plan.stacks.length
  if (windows > 0) parts.push(windows + (windows === 1 ? " window" : " windows"))
  if (stacks > 0) parts.push(stacks + (stacks === 1 ? " stack" : " stacks"))
  return parts.length === 0 ? "nothing to close" : parts.join(" and ")
}

// ------------------------------------------------------------- refreshing
//
// Re-snapshotting a preset used to mean losing everything that was not a
// window: the stacks ticked into it and the pages typed into it. Those are
// hand-made and a snapshot can never rediscover them, so an update replaces
// only the windows and leaves the rest of the preset standing.

function withAppsReplaced(raw, sourceIndex, recorded) {
  if (!Array.isArray(recorded) || recorded.length === 0) return null

  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = clonePresetEntry(list[sourceIndex])
  var kept = []
  var existing = Array.isArray(entry.apps) ? entry.apps : []

  for (var i = 0; i < existing.length; i++) {
    var app = existing[i]
    if (app && typeof app === "object" && (app.compose || app.url)) kept.push(app)
  }

  // Stacks first, windows next, pages last — the order the launcher wants and
  // the order the preset had before it was touched.
  var stacks = []
  var pages = []
  for (var k = 0; k < kept.length; k++) {
    if (kept[k].compose) stacks.push(kept[k])
    else pages.push(kept[k])
  }

  entry.apps = stacks.concat(recorded, pages)
  list[sourceIndex] = entry
  return withPresetList(raw, list)
}

function clonePresetEntry(original) {
  var entry = {}
  if (original && typeof original === "object") {
    for (var key in original) entry[key] = original[key]
  }
  return entry
}

// ------------------------------------------------------------- rewriting
//
// Rename and delete edit the parsed file rather than re-emitting the panel's
// own model, so a preset keeps every key this plugin does not know about.
// Both accept either accepted file shape and hand back the same one.

function presetList(raw) {
  if (Array.isArray(raw)) return raw
  if (raw && typeof raw === "object" && Array.isArray(raw.presets)) return raw.presets
  return []
}

function withPresetList(raw, list) {
  if (Array.isArray(raw)) return list

  var next = { version: 1 }
  if (raw && typeof raw === "object") {
    for (var key in raw) next[key] = raw[key]
  }
  next.presets = list
  return next
}

function renamedPreset(raw, sourceIndex, name) {
  var trimmed = String(name || "").trim()
  if (trimmed === "") return null

  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null

  var entry = {}
  var original = list[sourceIndex]
  if (original && typeof original === "object") {
    for (var key in original) entry[key] = original[key]
  }
  entry.name = trimmed
  list[sourceIndex] = entry
  return withPresetList(raw, list)
}

function withoutPreset(raw, sourceIndex) {
  var list = presetList(raw).slice()
  if (sourceIndex < 0 || sourceIndex >= list.length) return null
  list.splice(sourceIndex, 1)
  return withPresetList(raw, list)
}

function serialize(raw) {
  return JSON.stringify(raw, null, 2) + "\n"
}

// ------------------------------------------------------- already running
//
// Matching is by window class because that is the only field that survives
// the round trip: a recorded command line drifts the moment the user edits
// it, but the class the app registers stays put. An app with no class
// declared can't be matched, so it always launches — stated in the README
// so a preset that keeps duplicating windows has an obvious cause.

function runningClasses(clientsJson) {
  var classes = {}
  var list
  try {
    list = JSON.parse(clientsJson || "[]")
  } catch (e) {
    return classes
  }
  if (!Array.isArray(list)) return classes

  for (var i = 0; i < list.length; i++) {
    var name = String((list[i] && list[i]["class"]) || "").toLowerCase()
    if (name !== "") classes[name] = true
  }
  return classes
}

function isRunning(app, running) {
  if (!app.matchClass) return false
  return running[app.matchClass] === true
}

// What a click would actually do, as data — so the panel can label a row
// "3 of 4" before anything is launched, and the launcher and the label can
// never disagree about which apps were skipped.
function launchPlan(preset, running, skipRunning) {
  var steps = []
  for (var i = 0; i < preset.apps.length; i++) {
    var app = preset.apps[i]
    steps.push({ app: app, skipped: skipRunning === true && isRunning(app, running) })
  }
  return steps
}

function pendingSteps(plan) {
  var pending = []
  for (var i = 0; i < plan.length; i++) if (!plan[i].skipped) pending.push(plan[i])
  return pending
}

// ------------------------------------------------------------- dispatch
//
// This Hyprland evaluates `hyprctl dispatch <args>` as Lua, so the old
// `exec [workspace 3 silent] cmd` string form is gone and every argument
// has to be a Lua literal. Quoting is ours to get right.

function luaString(value) {
  return '"' + String(value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n") + '"'
}

// `silent` rides along inside the workspace rule rather than as its own
// effect (which Hyprland rejects), and it is what keeps a five-app preset
// from dragging the screen through five workspaces on the way up.
function execExpr(app) {
  var rules = []
  if (app.workspace) rules.push("workspace = " + luaString(app.workspace + " silent"))

  // Hyprland takes float, size and move as rules on the exec itself, so a
  // floating window arrives already placed instead of jumping into position
  // afterwards.
  if (app.floating) {
    rules.push("float = true")
    if (app.size) rules.push("size = " + luaString(app.size.replace(/,/g, " ")))
    if (app.at) rules.push("move = " + luaString(app.at.replace(/,/g, " ")))
  }

  if (rules.length === 0) return "hl.dsp.exec_cmd(" + luaString(app.cmd) + ")"
  return "hl.dsp.exec_cmd(" + luaString(app.cmd) + ", { " + rules.join(", ") + " })"
}

function focusExpr(workspace) {
  return "hl.dsp.focus({ workspace = " + luaString(workspace) + " })"
}

// --------------------------------------------------------------- labels

// A snapshot is taken of the workspace you are standing on, so the preset it
// writes starts life with every app already running. "0 of 4" is accurate and
// reads like a fault; say what is actually true instead.
// Glyphs rather than words, and each one rendered in the bar's font and checked
// by eye before it went in. A row of counts reads at a glance; a sentence has
// to be read.
//
//   󰖯 3  󰡨 1  󰖟 2  󰍹 1     three windows, one stack, two pages, workspace 1
//
function presetSummary(preset, plan) {
  var windows = 0
  var stacks = 0
  var pages = 0
  for (var i = 0; i < preset.apps.length; i++) {
    if (preset.apps[i].compose) stacks++
    else if (preset.apps[i].url) pages++
    else windows++
  }
  if (windows + stacks + pages === 0) return "empty"

  var parts = []
  if (windows > 0) {
    // Only worth two numbers when something would actually be left out.
    var pending = pendingSteps(plan).length
    parts.push("󰖯 " + (pending < windows && plan.length > 0
      ? pending + "/" + windows
      : String(windows)))
  }
  if (stacks > 0) parts.push("󰡨 " + stacks)
  if (pages > 0) parts.push("󰖟 " + pages)

  var workspaces = workspaceRange(preset)
  if (workspaces !== "") parts.push("󰍹 " + workspaces)
  return parts.join("   ")
}

// Whether this project looks like the one you are in. Every window the preset
// can recognise is on screen, and there is at least one to recognise —
// otherwise a preset of unmatchable commands would always claim to be up.
function looksActive(preset, running) {
  var known = 0
  for (var i = 0; i < preset.apps.length; i++) {
    var app = preset.apps[i]
    if (app.compose || app.url || !app.matchClass) continue
    known++
    if (running[app.matchClass] !== true) return false
  }
  return known > 0
}

// What the launch notification says. Stacks and pages are counted apart from
// apps because they are the half you cannot see happen.
function launchTally(steps) {
  var apps = 0
  var stacks = 0
  var pages = 0
  for (var i = 0; i < steps.length; i++) {
    if (steps[i].app.compose) stacks++
    else if (steps[i].app.url) pages += steps[i].app.pages || 1
    else apps++
  }

  var parts = []
  if (apps > 0) parts.push(apps + (apps === 1 ? " app" : " apps"))
  if (stacks > 0) parts.push(stacks + (stacks === 1 ? " stack" : " stacks"))
  if (pages > 0) parts.push(pages + (pages === 1 ? " page" : " pages"))
  return parts.length === 0 ? "nothing to launch" : parts.join(", ")
}

function workspaceRange(preset) {
  var seen = []
  for (var i = 0; i < preset.apps.length; i++) {
    var ws = preset.apps[i].workspace
    if (ws !== "" && seen.indexOf(ws) === -1) seen.push(ws)
  }
  if (seen.length === 0) return ""
  return seen.join(",")
}
