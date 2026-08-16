import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry point for Workspace Presets. Owns the icon in the bar and hosts
// the preset list; Panel.qml owns everything inside the popup.
//
// The forwarding below is the shape the bar requires of a widget that has a
// panel: Bar.findPanelWidget looks for open/close/opened on the widget root,
// not on the nested panel, so summon/hide/toggle routing and the open-panel
// dot both key off this object.
BarWidget {
  id: root
  moduleName: "io.github.monswiklund.workspace-presets"

  readonly property string icon: setting("icon", "󱂬")

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  function launchByName(name) {
    return panelLoader.item ? panelLoader.item.launchByName(name) : "unavailable"
  }

  function presetNames() {
    return panelLoader.item ? panelLoader.item.presetNames() : ""
  }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "workspace-presets"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }

    // Launching by name is what makes a keybinding possible: a panel you have
    // to open first is not something you can put on Super+1.
    function launch(name: string): string { return root.launchByName(name) }
    function list(): string { return root.presetNames() }

    // Whether the panel actually came up. Answering that over IPC is the only
    // way to tell a summon that was ignored from one that drew off-screen.
    function state(): string { return root.opened ? "open" : "closed" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    fontSize: Style.font.icon
    tooltipText: "Workspace presets"
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
    }
  }
}
