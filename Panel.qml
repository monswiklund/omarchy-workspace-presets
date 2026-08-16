import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The preset list. One row per project: click it and every app in the preset
// opens on the workspace the preset assigns it, without the screen following
// along.
//
// The window list is re-read on every open rather than watched, because the
// only moment "is this already running?" has to be right is the moment the
// list is drawn.
Panel {
  id: root
  moduleName: "io.github.monswiklund.workspace-presets"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/workspace-presets.json"
  readonly property string recordScript: Qt.resolvedUrl("scripts/record-preset").toString().replace(/^file:\/\//, "")

  // Off by default: a preset is a layout, and replaying it should rebuild that
  // layout whole rather than quietly leave out whatever happens to be up. Turn
  // it on per widget when you would rather reuse the windows you already have.
  readonly property bool skipRunning: setting("skipRunning", false) === true
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var presets: []
  property var rawConfig: null
  property string parseError: ""
  property bool configMissing: false
  property var running: ({})
  property string clientsJson: "[]"

  // Cursor runs over presets first, then the action rows, so Enter on a fresh
  // open always lands on a preset rather than on "snapshot".
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int actionCount: 2
  readonly property int rowCount: presets.length + actionCount

  // A preset row is the project and a chevron. Everything you can do to it
  // lives one click down, with a readable label instead of a glyph to guess at:
  // six icons on a row made a toolbar out of a list.
  //
  //   collapsed  ->  click launches, chevron expands
  //   menu       ->  Stacks, Pages, Rename, Update, Close, Delete
  //   stacks     ->  the Compose picker, in the same slot
  //   pages      ->  the URL editor, in the same slot
  //
  // One expansion at a time, and its contents swap rather than nest — three
  // levels deep in a bar popup is nobody's idea of navigable.
  property int rowAction: 0
  readonly property int rowActionCount: cursorIndex < presets.length ? 3 : 1

  property int expandedIndex: -1
  property string expandedMode: "menu"
  property int menuCursor: 0
  readonly property bool expanded: expandedIndex !== -1

  readonly property var menuItems: ["contents", "stacks", "pages", "rename", "up", "down", "update", "close", "delete"]

  // Destructive and lossy actions arm first; the row's own label says what the
  // second click will do.
  // Dragging a row to reorder. The move is committed once, on release: writing
  // the file on every pixel of a drag would be a file write per frame.
  property int draggingIndex: -1
  property int dropIndex: -1
  property real dragRowStep: 1

  property int closeTarget: -1
  property int refreshTarget: -1
  property int refreshingIndex: -1
  property var composeProjects: []
  property int composeCursor: 0
  property int renamingIndex: -1
  property int armedDeleteIndex: -1

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function reloadConfig() {
    var parsed = Model.parseConfig(configFile.text())
    root.presets = parsed.presets
    root.rawConfig = parsed.raw
    root.parseError = parsed.error
    if (root.cursorIndex >= root.rowCount) root.cursorIndex = Math.max(0, root.rowCount - 1)
    if (root.rowAction >= root.rowActionCount) root.rowAction = 0

    // The file just changed shape, so a delete armed against the old one now
    // points at whatever slid into that slot. Disarm rather than let a
    // pending confirmation retarget itself.
    root.armedDeleteIndex = -1
    root.renamingIndex = -1

    // The stack picker deliberately survives a reload — every toggle writes
    // the file, and closing on its own write would make the list unusable.
    // It closes only when the preset it belongs to is no longer there.
    if (root.expanded && !root.presetBySourceIndex(root.expandedIndex)) root.collapse()
  }

  // ---- Update and delete. Both go through the parsed file and write it back
  //      whole.
  //
  //      The panel adopts the new config in the same breath rather than
  //      waiting to be told: a FileView does not raise a change for a write it
  //      made itself, so relying on the watcher left the list showing a preset
  //      that was already gone from disk. Deleting then looked like it did
  //      nothing, and clicking again deleted against a stale model.

  function adoptConfig(next) {
    var text = Model.serialize(next)
    configFile.setText(text)

    var parsed = Model.parseConfig(text)
    root.presets = parsed.presets
    root.rawConfig = parsed.raw
    root.parseError = ""
    root.configMissing = false

    root.armedDeleteIndex = -1
    root.renamingIndex = -1
    if (root.cursorIndex >= root.rowCount) root.cursorIndex = Math.max(0, root.rowCount - 1)
    if (root.rowAction >= root.rowActionCount) root.rowAction = 0
    if (root.expanded && !root.presetBySourceIndex(root.expandedIndex)) root.collapse()
  }

  function commitRename(preset, name) {
    var next = Model.renamedPreset(root.rawConfig, preset.sourceIndex, name)
    root.renamingIndex = -1
    if (next) root.adoptConfig(next)
  }

  function cancelRename() {
    root.renamingIndex = -1
  }

  function startRename(preset) {
    root.armedDeleteIndex = -1
    root.renamingIndex = preset.sourceIndex
  }

  // Two steps, because a preset is hand-tuned work that snapshotting does not
  // bring back: the first click arms the row, the second one deletes.
  function requestDelete(preset) {
    root.renamingIndex = -1
    if (!root.applyArm("delete", preset.sourceIndex)) return

    var next = Model.withoutPreset(root.rawConfig, preset.sourceIndex)
    if (!next) return
    root.adoptConfig(next)

    // Deleting closes a gap: the next preset slides up under a pointer that
    // has not moved, so without this a second delete could be two clicks away
    // on a row the user never aimed at. Dropping the cursor hides that row's
    // controls until the mouse actually moves again.
    root.cursorActive = false
    root.rowAction = 0
  }

  // Returns true when this click is the confirming one.
  function applyArm(action, sourceIndex) {
    var step = Model.armTransition({
      "delete": root.armedDeleteIndex,
      "close": root.closeTarget,
      "update": root.refreshTarget
    }, action, sourceIndex)

    root.armedDeleteIndex = step.armed["delete"]
    root.closeTarget = step.armed["close"]
    root.refreshTarget = step.armed["update"]
    return step.fire
  }

  function disarm() {
    root.armedDeleteIndex = -1
    root.refreshTarget = -1
    root.closeTarget = -1
  }

  // ---- The expansion

  // The icon is the thing you are changing, so it is the thing you press.
  function openIconPicker(preset) {
    root.disarm()
    root.renamingIndex = -1
    root.expandedIndex = preset.sourceIndex
    root.expandedMode = "icon"
    root.menuCursor = 0
  }

  function toggleExpanded(preset) {
    root.disarm()
    root.renamingIndex = -1
    if (root.expandedIndex === preset.sourceIndex) {
      root.expandedIndex = -1
      return
    }
    root.expandedIndex = preset.sourceIndex
    root.expandedMode = "menu"
    root.menuCursor = 0
  }

  function collapse() {
    root.expandedIndex = -1
    root.expandedMode = "menu"
  }

  // Back out one level at a time: a submode returns to the menu, the menu
  // closes the row, and only then does Escape reach the panel.
  function backOut() {
    switch (Model.backOutStep({
      renaming: root.renamingIndex !== -1,
      armed: root.armedDeleteIndex !== -1 || root.closeTarget !== -1 || root.refreshTarget !== -1,
      mode: root.expandedMode,
      expanded: root.expanded
    })) {
      case "cancel-rename": return root.cancelRename()
      case "disarm": return root.disarm()
      case "to-menu": root.expandedMode = "menu"; root.menuCursor = 0; return
      case "collapse": return root.collapse()
      default: return root.close()
    }
  }

  function openMode(mode, preset) {
    root.disarm()
    root.expandedMode = mode
    root.menuCursor = 0
    if (mode === "stacks") root.refreshComposeProjects()
    if (mode === "rename") root.startRename(preset)
  }

  function menuLength() {
    if (root.expandedMode === "menu") return root.menuItems.length
    if (root.expandedMode === "stacks") return root.composeProjects.length
    if (root.expandedMode === "pages") {
      var preset = root.presetBySourceIndex(root.expandedIndex)
      return preset ? Model.presetUrls(preset).length : 0
    }
    if (root.expandedMode === "icon") return Model.iconChoices().length
    if (root.expandedMode === "contents") return 0
    return 0
  }

  function moveMenuCursor(delta) {
    root.menuCursor = Model.cycleIndex(root.menuCursor, delta, root.menuLength())
  }

  function activateMenu() {
    var preset = root.presetBySourceIndex(root.expandedIndex)
    if (!preset) return

    if (root.expandedMode === "stacks") {
      var project = root.composeProjects[root.menuCursor]
      if (project) root.toggleCompose(preset, project)
      return
    }
    if (root.expandedMode === "pages") {
      var urls = Model.presetUrls(preset)
      if (urls[root.menuCursor]) root.removeUrl(preset, urls[root.menuCursor])
      return
    }
    if (root.expandedMode === "icon") {
      var icons = Model.iconChoices()
      if (icons[root.menuCursor]) root.setIcon(preset, icons[root.menuCursor])
      return
    }

    switch (root.menuItems[root.menuCursor]) {
      case "contents": return root.openMode("contents", preset)
      case "up": return root.movePreset(preset, -1)
      case "down": return root.movePreset(preset, 1)
      case "stacks": return root.openMode("stacks", preset)
      case "pages": return root.openMode("pages", preset)
      case "rename": return root.openMode("rename", preset)
      case "update": return root.requestRefresh(preset)
      case "close": return root.requestClose(preset)
      case "delete": return root.requestDelete(preset)
    }
  }

  // ---- Docker stacks

  function refreshComposeProjects() {
    if (composeProc.running) return
    composeProc.running = true
  }

  // Picking an icon keeps the row open: you want to see it land on the row you
  // are looking at, and probably try another.
  // ---- Pages

  function addUrl(preset, url) {
    var next = Model.withUrlAdded(root.rawConfig, preset.sourceIndex, url)
    // A blank or already-present address is not an error worth a dialog; the
    // field simply keeps what you typed so you can see why nothing landed.
    if (next) root.adoptConfig(next)
    return next !== null
  }

  function removeUrl(preset, url) {
    var next = Model.withUrlRemoved(root.rawConfig, preset.sourceIndex, url)
    if (next) root.adoptConfig(next)
  }

  // ---- Closing

  function closePlanFor(preset) {
    return Model.closePlan(preset, root.clientsJson)
  }

  function requestClose(preset) {
    root.renamingIndex = -1
    if (!root.applyArm("close", preset.sourceIndex)) {
      // The confirmation names how many windows it found, so the list it counts
      // has to be fresh when the row is armed rather than when it fires.
      root.refreshRunning()
      return
    }

    var plan = root.closePlanFor(preset)
    // close, never kill: an editor with unsaved work gets to say so.
    for (var w = 0; w < plan.windows.length; w++)
      Quickshell.execDetached(["hyprctl", "dispatch", Model.closeWindowExpr(plan.windows[w].address)])
    for (var s = 0; s < plan.stacks.length; s++)
      Quickshell.execDetached(["hyprctl", "dispatch",
        Model.execExpr({ cmd: Model.composeDownCommand(plan.stacks[s]), workspace: "" })])

    root.notify("Closed " + preset.name + " — " + Model.closeSummary(plan))
    root.close()
  }

  // ---- Refresh from the current workspace

  function requestRefresh(preset) {
    root.renamingIndex = -1
    if (!root.applyArm("update", preset.sourceIndex)) return
    if (refreshProc.running) return
    root.refreshingIndex = preset.sourceIndex
    refreshProc.running = true
  }

  function applyRefresh(json) {
    var index = root.refreshingIndex
    root.refreshingIndex = -1
    if (index === -1) return

    var preset = root.presetBySourceIndex(index)
    var name = preset ? preset.name : "preset"

    var recorded
    try {
      recorded = JSON.parse(json || "[]")
    } catch (e) {
      recorded = null
    }

    var next = recorded ? Model.withAppsReplaced(root.rawConfig, index, recorded) : null
    if (!next) {
      // A refusal is as important to say as a success: an empty recording
      // leaves the preset standing, and silence would read as a broken button.
      root.notify(name + " — nothing recorded, left as it was")
      return
    }

    root.adoptConfig(next)
    root.notify("Updated " + name + " — " + Model.refreshTally(recorded, preset))
  }

  function notify(message) {
    Quickshell.execDetached(["omarchy-notification-send", "-u", "low",
      "Workspace presets", message])
  }

  // The row follows the preset it moved, so a second press keeps moving the
  // same one instead of whatever slid into its place.
  function beginDrag(preset, rowIndex, step) {
    root.collapse()
    root.disarm()
    root.draggingIndex = rowIndex
    root.dropIndex = rowIndex
    root.dragRowStep = Math.max(1, step)
  }

  function endDrag(preset) {
    var from = root.draggingIndex
    var to = root.dropIndex
    root.draggingIndex = -1
    root.dropIndex = -1
    if (from === -1 || to === from) return
    root.movePreset(preset, to - from)
  }

  function movePreset(preset, delta) {
    var next = Model.withPresetMoved(root.rawConfig, preset.sourceIndex, delta)
    if (!next) return
    root.expandedIndex = preset.sourceIndex + delta
    root.cursorIndex = Math.max(0, Math.min(root.cursorIndex + delta, root.presets.length - 1))
    root.adoptConfig(next)
  }

  function setIcon(preset, icon) {
    var next = Model.withIconSet(root.rawConfig, preset.sourceIndex, icon)
    if (next) root.adoptConfig(next)
  }

  function toggleCompose(preset, project) {
    var next = Model.withComposeToggled(root.rawConfig, preset.sourceIndex, project.configFile)
    if (next) root.adoptConfig(next)
  }

  function presetBySourceIndex(sourceIndex) {
    for (var i = 0; i < root.presets.length; i++)
      if (root.presets[i].sourceIndex === sourceIndex) return root.presets[i]
    return null
  }

  function refreshRunning() {
    if (clientsProc.running) return
    clientsProc.running = true
  }

  function planFor(preset) {
    return Model.launchPlan(preset, root.running, root.skipRunning)
  }

  // Each app is its own detached dispatch: one that fails (a command that no
  // longer exists) costs its own window and not the rest of the preset.
  function launch(preset) {
    var pending = Model.pendingSteps(planFor(preset))
    // Pages are merged into one browser call here, not in the file: separate
    // invocations arrive as separate windows, one invocation as tabs.
    var steps = Model.mergedLaunchSteps(preset, pending)
    for (var i = 0; i < steps.length; i++)
      Quickshell.execDetached(["hyprctl", "dispatch", Model.execExpr(steps[i].app)])

    if (preset.focus !== "")
      Quickshell.execDetached(["hyprctl", "dispatch", Model.focusExpr(preset.focus)])

    // Windows announce themselves by appearing; a Compose stack coming up is
    // invisible, so without this there is nothing telling you the preset did
    // more than open some apps.
    root.notify(preset.name + " — " + Model.launchTally(steps))

    root.close()
  }

  // One workspace is the whole offer here. Sweeping every workspace produces a
  // preset carrying Spotify, chat, and yesterday's project, which is a session
  // restore rather than a project — it stays available as `record-preset --all`
  // for the once-in-a-while case, without costing a row that misleads daily.
  // Addressed by name so a keybinding can say what it means. Matching is
  // case-insensitive and trims, because the name came from a config file a
  // human typed into and a binding is typed separately.
  function presetByName(name) {
    var wanted = String(name || "").trim().toLowerCase()
    if (wanted === "") return null
    for (var i = 0; i < root.presets.length; i++)
      if (root.presets[i].name.trim().toLowerCase() === wanted) return root.presets[i]
    return null
  }

  function launchByName(name) {
    var preset = root.presetByName(name)
    if (!preset) return "unknown"
    root.launch(preset)
    return "ok"
  }

  function presetNames() {
    var names = []
    for (var i = 0; i < root.presets.length; i++) names.push(root.presets[i].name)
    return names.join("\n")
  }

  function snapshotWorkspace() {
    Quickshell.execDetached([root.recordScript])
    root.close()
  }

  function editConfig() {
    if (root.configMissing) configFile.setText(starterConfig())
    Quickshell.execDetached(["omarchy-launch-config-editor", root.configPath])
    root.close()
  }

  function starterConfig() {
    return JSON.stringify({
      version: 1,
      presets: [{
        name: "Example project",
        icon: "󰅩",
        focus: 1,
        apps: [
          { cmd: "ghostty", workspace: 1, "class": "com.mitchellh.ghostty" },
          { cmd: "chromium --new-window https://omarchy.org", workspace: 2, "class": "chromium" }
        ]
      }]
    }, null, 2) + "\n"
  }

  function activate(index) {
    if (root.expanded) return root.activateMenu()

    if (index < root.presets.length) {
      var preset = root.presets[index]
      if (root.rowAction === 1) return root.toggleExpanded(preset)
      if (root.rowAction === 2) return root.openIconPicker(preset)
      return root.launch(preset)
    }
    if (index === root.presets.length) return root.snapshotWorkspace()
    return root.editConfig()
  }

  function moveCursor(delta) {
    if (root.rowCount === 0) return
    root.cursorIndex = Model.cycleIndex(root.cursorIndex, delta, root.rowCount)
    root.rowAction = 0
    root.disarm()
  }

  function moveRowAction(delta) {
    var next = root.rowAction + delta
    if (next < 0 || next >= root.rowActionCount) return
    root.rowAction = next
    root.disarm()
  }

  function focusRow(index) {
    root.cursorActive = true
    if (root.cursorIndex !== index) {
      root.cursorIndex = index
      root.rowAction = 0
      root.disarm()
    }
  }

  onOpenedChanged: {
    if (!opened) return
    root.cursorActive = false
    root.cursorIndex = 0
    root.rowAction = 0
    root.renamingIndex = -1
    root.armedDeleteIndex = -1
    root.collapse()
    root.refreshRunning()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      root.configMissing = false
      root.reloadConfig()
    }
    onLoadFailed: {
      root.configMissing = true
      root.presets = []
      root.parseError = ""
    }
    onFileChanged: reload()
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.running = Model.runningClasses(text)
        root.clientsJson = text
      }
    }
  }

  // Only run when a picker is opened. Docker is not always up, and a panel
  // that shells out to it on every open would pay for a feature most opens
  // never touch.
  // Asked for the app list rather than a new preset, so the stacks and pages on
  // the preset being updated survive.
  Process {
    id: refreshProc
    command: [root.recordScript, "--print"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRefresh(text)
    }
  }

  Process {
    id: composeProc
    command: ["docker", "compose", "ls", "-a", "--format", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.composeProjects = Model.parseComposeProjects(text)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Six controls on a preset row need the room; a narrower panel elides the
    // name down to nothing the moment the cursor lands on it.
    // Back to a list width: the row carries a name and one chevron now.
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        // An open row owns the arrows; walking the list underneath would slide
        // the expansion out from under what you are reading.
        if (root.expanded) {
          if (dy !== 0) root.moveMenuCursor(dy)
          else if (dx < 0) root.backOut()
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveRowAction(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorIndex)
      onCloseRequested: root.backOut()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.xl

        PanelSectionHeader {
          text: "WORKSPACE PRESETS"
          foreground: root.barForeground
          fontFamily: root.fontFamily
        }

        // Empty and broken states are rows too, so the panel never opens to
        // nothing and leaves the user guessing where the presets live.
        Text {
          visible: root.parseError !== ""
          width: parent.width
          text: "Broken JSON: " + root.parseError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.presets.length === 0 && root.parseError === ""
          width: parent.width
          text: root.configMissing
            ? "No presets file yet. Record a session, or let Edit create one for you."
            : "No presets in the file yet."
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // A ListView rather than a Repeater in a Column: the panel clamps its
        // height instead of growing, so anything past the clamp in a plain
        // column is drawn nowhere and reachable by nothing. The actions below
        // stay put while the projects scroll under them.
        ListView {
          id: presetList
          width: parent.width
          height: Math.min(contentHeight, Style.space(300))
          spacing: Style.spacing.sm
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.presets

          // A reorder you can follow: the row you dropped settles instead of
          // teleporting, and the ones it displaced slide out of its way.
          displaced: Transition {
            NumberAnimation { properties: "y"; duration: 160; easing.type: Easing.OutCubic }
          }
          move: Transition {
            NumberAnimation { properties: "y"; duration: 160; easing.type: Easing.OutCubic }
          }
          remove: Transition {
            NumberAnimation { property: "opacity"; to: 0; duration: 120 }
          }
          add: Transition {
            NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 160 }
          }

          // Keyboard navigation moves the cursor, not the view, so the view has
          // to follow it — a selection you cannot see is a selection you lose.
          currentIndex: root.cursorIndex < root.presets.length ? root.cursorIndex : -1
          highlightFollowsCurrentItem: true
          preferredHighlightBegin: 0
          preferredHighlightEnd: height
          highlightRangeMode: ListView.ApplyRange

          delegate: PresetRow {
            required property var modelData
            required property int index
            width: presetList.width
            height: implicitHeight
            preset: modelData
            rowIndex: index
          }
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm

          ActionRow {
            width: parent.width
            icon: "󰄄"
            label: "Snapshot this workspace"
            detail: "Presets only the windows on the workspace you are on"
            rowIndex: root.presets.length
          }

          ActionRow {
            width: parent.width
            icon: "󰏫"
            label: "Edit presets"
            detail: root.configPath.replace(root.home, "~")
            rowIndex: root.presets.length + 1
          }
        }
      }
    }
  }

  component PresetRow: Item {
    id: presetRow
    required property var preset
    required property int rowIndex

    readonly property var plan: root.planFor(preset)
    readonly property bool onRow: root.cursorActive && root.cursorIndex === rowIndex
    readonly property bool open: root.expandedIndex === preset.sourceIndex
    readonly property bool renaming: root.renamingIndex === preset.sourceIndex
    readonly property var urls: Model.presetUrls(preset)
    // Which project you are standing in, answered at a glance rather than by
    // reading five rows and remembering what you opened.
    readonly property bool active: Model.looksActive(preset, root.clientsJson)

    implicitHeight: header.implicitHeight + (open ? body.implicitHeight + Style.spacing.sm : 0)
    // Clipped so the contents are revealed by the row rather than spilling out
    // of it while it grows. Durations follow the shell's own: 120ms on controls,
    // OutCubic throughout.
    clip: true

    Behavior on implicitHeight {
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    readonly property real dragStep: header.implicitHeight + Style.spacing.sm
    readonly property bool dragging: root.draggingIndex === rowIndex
    // Where this row would land if you let go now.
    readonly property bool dropTarget: root.draggingIndex !== -1
      && root.draggingIndex !== rowIndex
      && root.dropIndex === rowIndex

    CursorSurface {
      id: header
      x: 0
      width: parent.width
      y: 0
      implicitHeight: headerBody.implicitHeight + Style.spacing.md * 2
      z: presetRow.dragging ? 2 : 0
      opacity: presetRow.dragging ? 0.85 : 1

      Behavior on opacity { NumberAnimation { duration: 120 } }
      // Only after the drop: animating y while the pointer holds it would put
      // the row a frame behind the hand.
      Behavior on y {
        enabled: !presetRow.dragging
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }

      // Where the row would land. A line rather than shuffling the list under
      // the cursor: the list moving while you aim at it is how you miss.
      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: -Style.spacing.xxs
        height: Style.space(2)
        radius: height / 2
        visible: presetRow.dropTarget
        color: root.bar ? root.bar.foreground : Color.accent
      }
      hasCursor: presetRow.onRow && !presetRow.open
      current: presetRow.open || presetRow.active
      foreground: root.barForeground
      accent: root.bar ? root.bar.foreground : Color.accent

      MouseArea {
        id: headerMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        enabled: !presetRow.renaming

        // Only a deliberate pull counts. Below the threshold this is still the
        // click that launches the project, which is what the row is mostly for.
        drag.target: header
        drag.axis: Drag.YAxis
        drag.threshold: Style.space(8)
        drag.minimumY: -presetRow.rowIndex * presetRow.dragStep
        drag.maximumY: (root.presets.length - 1 - presetRow.rowIndex) * presetRow.dragStep

        onContainsMouseChanged: if (containsMouse) root.focusRow(presetRow.rowIndex)

        onPositionChanged: {
          if (!drag.active) return
          if (root.draggingIndex !== presetRow.rowIndex)
            root.beginDrag(presetRow.preset, presetRow.rowIndex, presetRow.dragStep)
          root.dropIndex = presetRow.rowIndex + Math.round(header.y / presetRow.dragStep)
        }

        onReleased: {
          if (root.draggingIndex === presetRow.rowIndex) {
            root.endDrag(presetRow.preset)
            header.y = 0
            return
          }
          // Clicking the row opens it. Starting a project opens windows and
          // brings containers up, which is too much for a click that only
          // meant to look.
          if (!drag.active) root.toggleExpanded(presetRow.preset)
        }
      }

      Row {
        id: headerBody
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Style.spacing.md
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.rightMargin: Style.spacing.rowPaddingX
        spacing: Style.spacing.xl

        PanelActionButton {
          id: presetIcon
          anchors.verticalCenter: parent.verticalCenter
          iconText: presetRow.preset.icon !== "" ? presetRow.preset.icon : "󱂬"
          fontSize: Style.font.iconLarge
          tooltipText: presetRow.open && root.expandedMode === "icon" ? "" : "Change icon"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          hasCursor: presetRow.onRow && root.rowAction === 2
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.focusRow(presetRow.rowIndex)
            root.rowAction = 2
          }
          onClicked: root.openIconPicker(presetRow.preset)
        }

        Column {
          width: parent.width - parent.spacing * 3 - presetIcon.width - chevron.width - play.width
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.labelGap

          Text {
            visible: !presetRow.renaming
            width: parent.width
            text: presetRow.preset.name
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          TextField {
            id: nameField
            visible: presetRow.renaming
            width: parent.width
            foreground: root.barForeground
            accent: root.bar ? root.bar.foreground : Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.xxs
            placeholderText: "Preset name"
            onAccepted: root.commitRename(presetRow.preset, text)
            Keys.onEscapePressed: root.cancelRename()
            onVisibleChanged: if (visible) {
              text = presetRow.preset.name
              Qt.callLater(function () { nameField.forceActiveFocus(); nameField.selectAll() })
            }
          }

          Text {
            width: parent.width
            text: (presetRow.active ? "· " : "") + Model.presetSummary(presetRow.preset, presetRow.plan)
            color: Qt.darker(root.barForeground, presetRow.active ? 1.2 : 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          id: play
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰐊"
          tooltipText: "Start"
          foreground: root.barForeground
          fontFamily: root.fontFamily
          hasCursor: presetRow.onRow && root.rowAction === 0 && !presetRow.open
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.focusRow(presetRow.rowIndex)
            root.rowAction = 0
          }
          onClicked: root.launch(presetRow.preset)
        }

        PanelActionButton {
          id: chevron
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰅀"
          rotation: presetRow.open ? 180 : 0
          tooltipText: presetRow.open ? "" : "Manage"

          Behavior on rotation {
            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
          }
          foreground: root.barForeground
          fontFamily: root.fontFamily
          hasCursor: presetRow.onRow && root.rowAction === 1
          onHovered: function (isHovered) {
            if (!isHovered) return
            root.focusRow(presetRow.rowIndex)
            root.rowAction = 1
          }
          onClicked: root.toggleExpanded(presetRow.preset)
        }
      }
    }

    // One slot, contents swapped by mode. Nesting a third level inside a bar
    // popup would be a maze; going back is always one Escape.
    Column {
      id: body
      visible: opacity > 0
      opacity: presetRow.open ? 1 : 0

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: header.bottom
      anchors.topMargin: Style.spacing.sm
      anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(24)
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.xxs

      // Where you are, and the way out. Escape and ← already went back; this is
      // the same thing for a hand on the mouse, and it names the submode so the
      // list below it is not context you have to remember.
      CursorSurface {
        id: backRow
        visible: presetRow.open && root.expandedMode !== "menu"
        width: parent.width
        implicitHeight: backLabel.implicitHeight + Style.spacing.sm * 2
        foreground: root.barForeground
        accent: root.bar ? root.bar.foreground : Color.accent

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.backOut()
        }

        Text {
          id: backLabel
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          text: "‹  " + (root.expandedMode === "stacks" ? "Docker"
            : root.expandedMode === "pages" ? "Pages"
        : root.expandedMode === "icon" ? "Icon"
        : root.expandedMode === "contents" ? "Contents" : "Back")
          color: Qt.darker(root.barForeground, 1.3)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      // ---- the menu
      Repeater {
        model: presetRow.open && root.expandedMode === "menu" ? root.menuItems : []

        MenuRow {
          required property var modelData
          required property int index
          width: parent.width
          action: modelData
          menuIndex: index
          preset: presetRow.preset
        }
      }

      // ---- stacks
      Text {
        visible: root.expandedMode === "stacks" && root.composeProjects.length === 0
        width: parent.width
        text: "No Compose projects found. Docker only lists projects it has containers for."
        color: Qt.darker(root.barForeground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Repeater {
        model: presetRow.open && root.expandedMode === "stacks" ? root.composeProjects : []

        CursorSurface {
          id: stackRow
          required property var modelData
          required property int index
          readonly property bool included: Model.hasCompose(presetRow.preset, modelData.configFile)

          width: parent.width
          implicitHeight: stackBody.implicitHeight + Style.spacing.sm * 2
          hasCursor: root.menuCursor === index
          current: included
          foreground: root.barForeground
          accent: root.bar ? root.bar.foreground : Color.accent

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.menuCursor = stackRow.index
            onClicked: root.toggleCompose(presetRow.preset, stackRow.modelData)
          }

          Row {
            id: stackBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Style.spacing.sm
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.lg
            spacing: Style.spacing.lg

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(16)
              horizontalAlignment: Text.AlignHCenter
              text: stackRow.included ? "󰄬" : "·"
              color: stackRow.included ? root.barForeground : Qt.darker(root.barForeground, 2.0)
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - parent.spacing * 2 - Style.space(16) - stackState.implicitWidth
              text: stackRow.modelData.name
              color: stackRow.included ? root.barForeground : Qt.darker(root.barForeground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: stackRow.included
              elide: Text.ElideRight
            }

            Text {
              id: stackState
              anchors.verticalCenter: parent.verticalCenter
              text: stackRow.modelData.running ? "up" : "down"
              color: Qt.darker(root.barForeground, 1.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ---- contents: what the preset holds, in the order it launches
      Repeater {
        model: presetRow.open && root.expandedMode === "contents"
          ? Model.presetContents(presetRow.preset, root.home) : []

        Item {
          id: contentRow
          required property var modelData
          width: parent.width
          implicitHeight: contentLabel.implicitHeight + Style.spacing.sm

          Text {
            id: contentGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(20)
            text: contentRow.modelData.glyph
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconSmall
          }

          Text {
            id: contentLabel
            anchors.left: contentGlyph.right
            anchors.leftMargin: Style.spacing.md
            anchors.right: contentDetail.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: contentRow.modelData.label
            color: root.barForeground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: contentDetail
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: [contentRow.modelData.detail, contentRow.modelData.right].filter(Boolean).join("   ")
            color: Qt.darker(root.barForeground, 1.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      // ---- icon
      Flow {
        visible: presetRow.open && root.expandedMode === "icon"
        width: parent.width
        spacing: Style.spacing.xs

        Repeater {
          model: presetRow.open && root.expandedMode === "icon" ? Model.iconChoices() : []

          CursorSurface {
            id: iconCell
            required property var modelData
            required property int index
            readonly property bool current_: presetRow.preset.icon === modelData

            width: Style.space(34)
            height: Style.space(30)
            hasCursor: root.menuCursor === index
            current: current_
            foreground: root.barForeground
            accent: root.bar ? root.bar.foreground : Color.accent

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.menuCursor = iconCell.index
              onClicked: root.setIcon(presetRow.preset, iconCell.modelData)
            }

            Text {
              anchors.centerIn: parent
              text: iconCell.modelData
              color: iconCell.current_ ? root.barForeground : Qt.darker(root.barForeground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
          }
        }
      }

      // ---- pages
      Repeater {
        model: presetRow.open && root.expandedMode === "pages" ? presetRow.urls : []

        CursorSurface {
          id: urlRow
          required property var modelData
          required property int index

          width: parent.width
          implicitHeight: urlText.implicitHeight + Style.spacing.sm * 2
          hasCursor: root.menuCursor === index
          foreground: root.barForeground
          accent: root.bar ? root.bar.urgent : Color.urgent

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) root.menuCursor = urlRow.index
            onClicked: root.removeUrl(presetRow.preset, urlRow.modelData)
          }

          Text {
            id: urlText
            anchors.left: parent.left
            anchors.right: dropHint.left
            anchors.leftMargin: Style.spacing.lg
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: urlRow.modelData
            color: Qt.darker(root.barForeground, 1.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            id: dropHint
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅖"
            color: Qt.darker(root.barForeground, 1.8)
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconSmall
          }
        }
      }

      TextField {
        id: urlField
        visible: presetRow.open && root.expandedMode === "pages"
        width: parent.width
        foreground: root.barForeground
        accent: root.bar ? root.bar.foreground : Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalPadding: Style.spacing.controlGap
        verticalPadding: Style.spacing.xxs
        placeholderText: "Paste a URL, press Enter"
        onAccepted: if (root.addUrl(presetRow.preset, text)) text = ""
        Keys.onEscapePressed: root.backOut()
        onVisibleChanged: if (visible) Qt.callLater(function () { urlField.forceActiveFocus() })
      }
    }
  }

  // A labelled row in a preset's menu. The label carries the whole meaning —
  // that was the point of getting rid of the icon strip.
  component MenuRow: CursorSurface {
    id: menuRow
    required property string action
    required property int menuIndex
    required property var preset

    readonly property bool armed: {
      if (action === "delete") return root.armedDeleteIndex === preset.sourceIndex
      if (action === "close") return root.closeTarget === preset.sourceIndex
      if (action === "update") return root.refreshTarget === preset.sourceIndex
      return false
    }
    readonly property bool destructive: Model.isDestructive(action)

    readonly property string label: action === "update" && root.refreshingIndex === preset.sourceIndex
      ? "Updating…"
      : Model.menuLabel(action, armed)

    readonly property string detail: {
      if (armed) {
        if (action === "close") return Model.closeSummary(root.closePlanFor(preset))
        if (action === "delete") return "the preset, not the windows"
        if (action === "update") return "replaces its windows"
      }
      if (action === "stacks") return String(Model.presetComposeFiles(preset).length)
      if (action === "pages") return String(Model.presetUrls(preset).length)
      return ""
    }

    implicitHeight: menuBody.implicitHeight + Style.spacing.sm * 2
    hasCursor: root.expandedMode === "menu" && root.menuCursor === menuIndex
    foreground: root.barForeground
    accent: destructive && armed
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : (root.bar ? root.bar.foreground : Color.accent)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.menuCursor = menuRow.menuIndex
      onClicked: {
        root.menuCursor = menuRow.menuIndex
        root.activateMenu()
      }
    }

    Row {
      id: menuBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.spacing.sm
      anchors.leftMargin: Style.spacing.lg
      anchors.rightMargin: Style.spacing.lg
      spacing: Style.spacing.md

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - parent.spacing - menuDetail.implicitWidth
        text: menuRow.label
        color: menuRow.armed && menuRow.destructive
          ? (root.bar ? root.bar.urgent : Color.urgent)
          : root.barForeground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: menuDetail
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.detail === "" ? "" : (menuRow.action === "stacks" || menuRow.action === "pages"
          ? menuRow.detail + "  ›" : menuRow.detail)
        color: Qt.darker(root.barForeground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    required property int rowIndex
    property string icon: ""
    property string label: ""
    property string detail: ""

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.barForeground
    accent: root.bar ? root.bar.foreground : Color.accent
    implicitHeight: actionBody.implicitHeight + Style.spacing.md * 2

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) { root.cursorActive = true; root.cursorIndex = actionRow.rowIndex }
      onClicked: root.activate(actionRow.rowIndex)
    }

    Row {
      id: actionBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      spacing: Style.spacing.xl

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: actionRow.icon
        color: Qt.darker(root.barForeground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        width: parent.width - parent.spacing - Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.labelGap

        Text {
          width: parent.width
          text: actionRow.label
          color: root.barForeground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: actionRow.detail !== ""
          text: actionRow.detail
          color: Qt.darker(root.barForeground, 1.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
