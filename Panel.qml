import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Drop Zone in the bar: a drop zone that stages file locations, a target
// button that delivers them to a folder you pick, and a handle you can drag
// into any folder. The panel lists what is staged.
Panel {
  id: root
  moduleName: "cgranier.dropshelf"
  ipcTarget: "cgranier.dropshelf"
  manageIpc: false

  property var shelf: null
  property int lookups: 0
  readonly property bool unavailable: shelf === null && lookups >= 20

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string home: Quickshell.env("HOME") || ""

  readonly property var items: shelf ? shelf.items : []
  readonly property var recents: shelf ? shelf.recents : []
  readonly property var remotes: shelf ? shelf.remotes : []
  property bool sendFormOpen: false
  // "Open folder" is offered for ten minutes after a local delivery.
  property double now: Date.now()
  readonly property bool canOpenLast: shelf !== null && shelf.lastDelivery !== null && !busy && now - shelf.lastDelivery.at < 600000
  readonly property bool busy: shelf ? shelf.busy : false
  readonly property bool hovering: dropArea.containsDrag && dropArea.accepting
  readonly property int deliverableCount: Model.deliverable(items).length

  // Keyboard cursor rows: staged items, then recent targets, then "choose".
  readonly property var cursorRows: {
    var rows = []
    for (var i = 0; i < items.length; i++) rows.push({ type: "item", path: items[i].path })
    for (var j = 0; j < recents.length; j++) rows.push({ type: "recent", path: recents[j] })
    rows.push({ type: "pick", path: "" })
    rows.push({ type: "send", path: "" })
    for (var k = 0; k < remotes.length; k++) rows.push({ type: "remote", remote: remotes[k] })
    return rows
  }

  // The service is this plugin's other half and may mount a beat later. Under
  // a replacement bar there is none: after a few tries, say so and stop.
  function findShelf() {
    if (shelf || lookups >= 20) return
    lookups++
    if (bar && bar.shell && typeof bar.shell.serviceFor === "function") shelf = bar.shell.serviceFor(moduleName)
  }

  onShelfChanged: pushSettings()
  onSettingsChanged: pushSettings()
  function pushSettings() {
    if (!shelf) return
    shelf.keepAfterCopy = setting("keepAfterCopy", false) === true
    shelf.notifyOnDelivery = setting("notifyOnDelivery", true) !== false
    shelf.sshHostsSetting = String(setting("sshHosts", "") || "")
  }

  function clampCursor() {
    cursorIndex = Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorIndex += dy
    clampCursor()
  }

  function activate(row) {
    if (!row || !shelf) return
    if (row.type === "recent") { if (shelf.deliver(row.path)) root.close() }
    else if (row.type === "pick") pick()
    else if (row.type === "remote") { if (shelf.sendTo(row.remote.host, row.remote.dir)) root.close() }
    else if (row.type === "send") openSendForm()
  }

  property string selectedHost: ""

  function openSendForm() {
    if (!shelf) return
    shelf.loadHosts()
    sendFormOpen = !sendFormOpen
    if (sendFormOpen) Qt.callLater(revealSendForm)
    if (sendFormOpen) pickHost(selectedHost !== "" && shelf.hosts.indexOf(selectedHost) !== -1 ? selectedHost
      : remotes.length > 0 ? remotes[0].host : (shelf.hosts[0] || ""))
  }

  function revealSendForm() {
    var top = sendRow.mapToItem(panelFlick.contentItem, 0, 0).y
    var bottom = folderField.mapToItem(panelFlick.contentItem, 0, folderField.height).y + Style.space(8)
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    if (bottom > panelFlick.contentY + panelFlick.height) panelFlick.contentY = Math.min(maxY, bottom - panelFlick.height)
    if (top < panelFlick.contentY) panelFlick.contentY = Math.max(0, top - Style.space(8))
  }

  function pickHost(host) {
    selectedHost = host
    folderField.text = host === "" ? "" : Model.lastDirFor(remotes, host)
  }

  function sendNow(host, dir) {
    if (shelf && shelf.sendTo(host, dir)) { sendFormOpen = false; root.close() }
  }

  function pick() {
    if (shelf && shelf.pickTarget()) root.close()
  }

  function removeSelected() {
    var row = cursorRows[cursorIndex]
    if (cursorActive && row && row.type === "item" && shelf) shelf.remove(row.path)
  }

  implicitWidth: strip.implicitWidth
  implicitHeight: strip.implicitHeight

  onBarChanged: findShelf()
  onOpenedChanged: {
    Qt.callLater(updateHole)
    if (!opened) { sendFormOpen = false; return }
    cardSettle.restart()
    now = Date.now()
    findShelf()
    cursorActive = false
    if (shelf) shelf.recheck()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onCursorRowsChanged: clampCursor()

  Timer {
    interval: 500
    repeat: true
    running: root.shelf === null && root.lookups < 20
    triggeredOnStart: true
    onTriggered: root.findShelf()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function pick(): string { return root.shelf && root.shelf.pickTarget() ? "ok" : "nothing to deliver" }
    function clear(): string { if (root.shelf) root.shelf.clear(); return "ok" }
    function mode(): string { return root.shelf ? root.shelf.mode : "" }
    function toggleMode(): string { if (root.shelf) root.shelf.toggleMode(); return root.shelf ? root.shelf.mode : "" }
    // By index into the recent targets, so no path travels in argv.
    function deliverRecent(n: int): string {
      if (!root.shelf || n < 0 || n >= root.recents.length) return "no such recent target"
      return root.shelf.deliver(root.recents[n]) ? "ok" : "nothing to deliver"
    }
    function hostForm(): string { if (!root.opened) root.open(); if (!root.sendFormOpen) root.openSendForm(); return "ok" }
    function paste(): string { if (root.shelf) root.shelf.pasteFromClipboard(); return "ok" }
    function copyPaths(): string { return root.shelf && root.shelf.copyPaths() ? "ok" : "nothing staged" }
    function openFolder(): string { return root.shelf && root.shelf.openLastFolder() ? "ok" : "no recent delivery" }
    // By index into the remembered SSH targets, so no host or folder travels in argv.
    function sendRecent(n: int): string {
      if (!root.shelf || n < 0 || n >= root.remotes.length) return "no such remote target"
      return root.shelf.sendTo(root.remotes[n].host, root.remotes[n].dir) ? "ok" : "nothing to send"
    }
    function pin(): string { if (root.opened) root.togglePin(); return root.pinned ? "pinned" : "unpinned" }
    function cancel(): string { if (root.shelf) root.shelf.cancel(); return "ok" }
    function state(): string {
      if (!root.shelf) return JSON.stringify({ available: false })
      return JSON.stringify({ available: true, count: root.items.length, deliverable: root.deliverableCount,
        mode: root.shelf.mode, busy: root.busy, job: root.shelf.job ? Model.progressLabel(root.shelf.job) : "",
        status: root.shelf.status, recents: root.recents.length, opened: root.opened, pinned: root.pinned,
        card: [root.cardRect.x, root.cardRect.y, root.cardRect.width, root.cardRect.height],
        hole: [root.shelfHole.x, root.shelfHole.y, root.shelfHole.width, root.shelfHole.height] })
    }
  }

  // ---- the bar strip --------------------------------------------------------

  Item {
    id: strip
    anchors.fill: parent
    implicitWidth: stripRow.implicitWidth
    implicitHeight: stripRow.implicitHeight

    // Lights up while files are held over it.
    Rectangle {
      anchors.fill: parent
      anchors.topMargin: Style.space(4)
      anchors.bottomMargin: Style.space(4)
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: root.accent
      opacity: root.hovering ? 0.28 : 0
      border.width: root.hovering ? Math.max(1, Style.space(1)) : 0
      border.color: root.accent
      Behavior on opacity { NumberAnimation { duration: 120 } }
    }

    Row {
      id: stripRow
      anchors.centerIn: parent

      WidgetButton {
        id: pill
        bar: root.bar
        text: {
          var label = root.unavailable ? "" : Model.barLabel(root.items.length, root.shelf ? root.shelf.job : null, root.hovering)
          var icon = Model.GLYPHS.shelf
          return root.vertical || label === "" ? icon : icon + "  " + label
        }
        dimmed: !root.hovering && !root.busy && root.items.length === 0
        active: root.shelf !== null && Model.missingPaths(root.items).length > 0
        tooltipText: root.opened ? "" : root.unavailable
          ? "Drop Zone needs the built-in Omarchy bar"
          : root.items.length === 0 ? "Drop Zone: drag files here to stage them"
          : "Drop Zone: " + root.shelf.summary + "\nDrag this into a folder to " + (root.shelf.mode === "move" ? "move" : "copy") + " them there"
        onPressed: function(button) { if (!root.unavailable) root.toggle() }

        // Dragging the pill carries every staged path out of the bar.
        Drag.active: dragHandler.active && root.deliverableCount > 0 && !root.busy
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: root.shelf && root.shelf.mode === "move" ? Qt.MoveAction : Qt.CopyAction
        Drag.mimeData: ({ "text/uri-list": root.shelf ? (root.items, root.shelf.uriList(null)) : "" })
        Drag.onDragStarted: if (root.shelf) root.shelf.dragOutStarted(null)
        Drag.onDragFinished: function(action) { if (root.shelf) root.shelf.dragOutFinished() }

        // Above the button's own MouseArea, so it sees the press first and
        // takes over once the pointer really moves; a plain click still clicks.
        Item {
          anchors.fill: parent
          DragHandler {
            id: dragHandler
            target: null
            enabled: root.deliverableCount > 0 && !root.busy
          }
        }
      }

      WidgetButton {
        id: targetButton
        bar: root.bar
        visible: root.deliverableCount > 0 || root.busy
        text: root.busy ? Model.GLYPHS.remove : Model.GLYPHS.target
        tooltipText: root.busy ? "Stop delivering" : root.shelf && root.shelf.mode === "move"
          ? "Move the staged files to a folder…" : "Copy the staged files to a folder…"
        onPressed: function(button) {
          if (!root.shelf) return
          if (root.busy) root.shelf.cancel()
          else root.shelf.pickTarget()
        }
      }
    }

    DropArea {
      id: dropArea
      anchors.fill: parent
      keys: ["text/uri-list"]
      property bool accepting: false
      onEntered: function(drag) { accepting = root.acceptDrag(drag) }
      onExited: accepting = false
      onDropped: function(drop) { root.takeDrop(drop, accepting); accepting = false }
    }
  }

  function acceptDrag(drag) {
    var ok = shelf !== null && !shelf.draggingOut && drag.hasUrls
    drag.accepted = ok
    if (ok) drag.accept(Qt.CopyAction)
    return ok
  }

  function takeDrop(drop, accepting) {
    if (!accepting || !shelf) return
    if (shelf.stageUrls(drop.urls)) drop.accept(Qt.CopyAction)
  }

  // ---- the panel -------------------------------------------------------------

  // KeyboardPanel covers the whole screen, bar included, to catch outside
  // clicks, and forwards plain clicks to bar buttons. A drag needs more: the
  // press must reach the shelf in the bar, and the drop must reach the file
  // manager underneath. So the shelf's own spot is cut out of the panel's
  // input region while it is open, and during a drag-out the panel takes no
  // input at all.
  readonly property bool draggingOut: shelf ? shelf.draggingOut : false

  function stripRect() {
    var w = panel.anchorWindow
    if (!w || typeof w.itemPosition !== "function" || !root.opened) return Qt.rect(0, 0, 0, 0)
    var pos = w.itemPosition(strip)
    var pb = panel.barPos
    var x = pos.x + (pb === "right" ? panel.screenW - panel.barW : 0)
    var y = pos.y + (pb === "bottom" ? panel.screenH - panel.barH : 0)
    return Qt.rect(Math.floor(x), Math.floor(y), Math.ceil(strip.width), Math.ceil(strip.height))
  }

  property rect shelfHole: Qt.rect(0, 0, 0, 0)
  function updateHole() { shelfHole = stripRect(); updateCard() }

  // Pinned, the panel stops catching clicks outside itself: it takes input
  // only on its card and leaves the rest of the screen to the windows below,
  // so you can work in the file manager and drag files straight into it. It
  // closes from the shelf in the bar or by unpinning. The pin is remembered.
  readonly property bool pinned: shelf ? shelf.pinned : false
  property rect cardRect: Qt.rect(0, 0, 0, 0)
  function updateCard() {
    if (!root.opened || !keyCatcher.visible) { cardRect = Qt.rect(0, 0, 0, 0); return }
    var p = keyCatcher.mapToItem(null, 0, 0)
    var pad = panel.padding + Style.space(4)
    cardRect = Qt.rect(Math.floor(p.x - pad), Math.floor(p.y - pad),
                       Math.ceil(keyCatcher.width + pad * 2), Math.ceil(keyCatcher.height + pad * 2))
  }
  function togglePin() {
    if (!shelf) return
    shelf.setPinned(!shelf.pinned)
    Qt.callLater(updateCard)
  }

  // The card is placed a beat after the panel opens; measure again then.
  Timer {
    id: cardSettle
    interval: 200
    onTriggered: root.updateCard()
  }
  Connections {
    target: strip
    function onWidthChanged() { Qt.callLater(root.updateHole) }
    function onXChanged() { Qt.callLater(root.updateHole) }
  }

  Region {
    id: openMask
    width: panel.screenW
    height: panel.screenH
    Region {
      intersection: Intersection.Subtract
      x: root.shelfHole.x
      y: root.shelfHole.y
      width: root.shelfHole.width
      height: root.shelfHole.height
    }
  }

  Region {
    id: pinnedMask
    x: root.cardRect.x
    y: root.cardRect.y
    width: root.cardRect.width
    height: root.cardRect.height
  }

  Region { id: noInput }

  KeyboardPanel {
    id: panel
    anchorItem: strip
    owner: root
    bar: root.bar
    open: root.opened
    mask: root.draggingOut ? noInput : root.pinned ? pinnedMask : openMask
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + footer.implicitHeight + Style.space(12))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onWidthChanged: Qt.callLater(root.updateCard)
      onHeightChanged: Qt.callLater(root.updateCard)
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (!root.cursorActive) { root.cursorActive = true; root.clampCursor(); return }
        root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorRows[root.cursorIndex])
      onDeleteRequested: root.removeSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.shelf) return
        if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "d" || t === "x") root.removeSelected()
        else if (t === "m") root.shelf.toggleMode()
        else if (t === "o" || t === "t") root.pick()
        else if (t === "c") root.shelf.clear()
        else if (t === "s") root.shelf.cancel()
        else if (t === "p") root.togglePin()
        else if (t === "v") root.shelf.pasteFromClipboard()
        else if (t === "y") root.shelf.copyPaths()
        else if (t === "f") root.shelf.openLastFolder()
        else if (t === "h") root.openSendForm()
      }

      Flickable {
        id: panelFlick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(8)
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Drop Zone"
            trailingControl: Component {
              PanelActionButton {
                iconText: root.pinned ? Model.GLYPHS.unpin : Model.GLYPHS.pin
                tooltipText: root.pinned ? "Unpin: close on an outside click again (remembered)"
                  : "Keep open, so you can drag files into it from other windows (remembered)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: root.pinned
                onClicked: root.togglePin()
              }
            }
            meta: !root.shelf ? "Needs the built-in Omarchy bar"
              : root.busy ? Model.progressLabel(root.shelf.job)
              : root.shelf.status !== "" ? root.shelf.status : root.shelf.summary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.GLYPHS.shelf
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // Top row: the Copy / Move switch on the left, Clear shelf on the right.
          RowLayout {
            visible: root.shelf !== null
            width: parent.width
            spacing: Style.space(8)

            ButtonGroup {
              options: [{ value: "copy", label: "Copy" }, { value: "move", label: "Move" }, { value: "zip", label: "Zip" }]
              value: root.shelf ? root.shelf.mode : "copy"
              enabled: !root.busy
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              focusable: false
              onChanged: function(value) { if (root.shelf) root.shelf.setMode(value) }
            }

            Item { Layout.fillWidth: true }

            Button {
              text: "Paste"
              iconText: Model.GLYPHS.paste
              tooltipText: "Stage the files copied in your file manager (v)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.busy
              onClicked: if (root.shelf) root.shelf.pasteFromClipboard()
            }

            Button {
              visible: root.items.length > 0
              text: "Clear shelf"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.busy
              onClicked: if (root.shelf) root.shelf.clear()
            }
          }

          // Progress and a way out while a delivery runs.
          RowLayout {
            visible: root.busy
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(6)
              radius: height / 2
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
              Rectangle {
                readonly property var job: root.shelf ? root.shelf.job : null
                height: parent.height
                radius: parent.radius
                color: root.accent
                width: !job ? 0 : parent.width * (job.total > 0 ? Math.min(1, job.bytes / job.total)
                  : Math.min(1, (job.index + 0.5) / Math.max(1, job.count)))
              }
            }

            Button {
              text: "Stop"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.shelf) root.shelf.cancel()
            }
          }

          RowLayout {
            visible: root.canOpenLast
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.shelf && root.shelf.lastDelivery ? "Last delivery: " + Model.tildePath(root.shelf.lastDelivery.folder, root.home) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Button {
              text: "Open folder"
              iconText: Model.GLYPHS.open
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.shelf) root.shelf.openLastFolder()
            }
          }

          PanelSectionHeader {
            visible: root.items.length > 0
            text: "STAGED"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            visible: root.items.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.items

              CursorSurface {
                id: itemRow
                required property var modelData
                required property int index
                readonly property bool missing: modelData.kind === "missing"
                width: parent ? parent.width : 0
                implicitHeight: itemContent.implicitHeight + Style.space(12)
                hasCursor: root.cursorActive && root.cursorIndex === index
                foreground: root.foreground

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: itemRow.missing ? Qt.ArrowCursor : Qt.OpenHandCursor
                  onEntered: { root.cursorActive = true; root.cursorIndex = itemRow.index }
                }

                // Drag one row out on its own.
                Drag.active: rowDrag.active
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: root.shelf && root.shelf.mode === "move" ? Qt.MoveAction : Qt.CopyAction
                Drag.mimeData: ({ "text/uri-list": root.shelf ? root.shelf.uriList([itemRow.modelData.path]) : "" })
                Drag.onDragStarted: if (root.shelf) root.shelf.dragOutStarted([itemRow.modelData.path])
                Drag.onDragFinished: function(action) { if (root.shelf) root.shelf.dragOutFinished() }

                Item {
                  anchors.fill: parent
                  DragHandler {
                    id: rowDrag
                    target: null
                    enabled: !itemRow.missing && !root.busy
                  }
                }

                RowLayout {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.kindGlyph(itemRow.modelData)
                    color: itemRow.missing ? root.urgent : root.foreground
                    opacity: 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(18)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  ColumnLayout {
                    id: itemContent
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: Model.baseName(itemRow.modelData.path)
                      color: itemRow.missing ? root.urgent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideMiddle
                    }

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: Model.parentDir(itemRow.modelData.path, root.home)
                        + (itemRow.missing ? " · no longer there" : itemRow.modelData.size >= 0 ? " · " + Model.formatSize(itemRow.modelData.size) : "")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }

                  PanelActionButton {
                    iconText: Model.GLYPHS.remove
                    tooltipText: "Take off the shelf (the file stays where it is)"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    enabled: !root.busy
                    onClicked: if (root.shelf) root.shelf.remove(itemRow.modelData.path)
                  }
                }
              }
            }
          }

          PanelSectionHeader {
            visible: root.shelf !== null
            text: !root.shelf ? "" : root.shelf.mode === "move" ? "MOVE TO" : root.shelf.mode === "zip" ? "ZIP INTO" : "COPY TO"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            visible: root.shelf !== null
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.recents

              CursorSurface {
                id: recentRow
                required property string modelData
                required property int index
                readonly property int rowIndex: root.items.length + index
                width: parent ? parent.width : 0
                implicitHeight: recentText.implicitHeight + Style.space(14)
                hasCursor: root.cursorActive && root.cursorIndex === rowIndex
                foreground: root.foreground
                opacity: root.deliverableCount > 0 && !root.busy ? 1 : 0.45

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursorIndex = recentRow.rowIndex }
                  onClicked: root.activate({ type: "recent", path: recentRow.modelData })
                }

                RowLayout {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPHS.folder
                    color: root.foreground
                    opacity: 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(18)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    id: recentText
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.tildePath(recentRow.modelData, root.home)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideMiddle
                  }

                  PanelActionButton {
                    iconText: Model.GLYPHS.remove
                    tooltipText: "Forget this folder"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: if (root.shelf) root.shelf.forgetRecent(recentRow.modelData)
                  }
                }
              }
            }

            CursorSurface {
              id: pickRow
              readonly property int rowIndex: root.items.length + root.recents.length
              width: parent ? parent.width : 0
              implicitHeight: pickText.implicitHeight + Style.space(14)
              hasCursor: root.cursorActive && root.cursorIndex === rowIndex
              foreground: root.foreground
              opacity: root.deliverableCount > 0 && !root.busy ? 1 : 0.45

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.cursorIndex = pickRow.rowIndex }
                onClicked: root.pick()
              }

              RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: Model.GLYPHS.target
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.preferredWidth: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  id: pickText
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Choose a folder…"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }
          }

          PanelSectionHeader {
            visible: root.shelf !== null
            text: "SEND TO HOST"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            visible: root.shelf !== null
            width: parent.width
            spacing: Style.space(2)

            CursorSurface {
              id: sendRow
              readonly property int rowIndex: root.items.length + root.recents.length + 1
              width: parent ? parent.width : 0
              implicitHeight: sendText.implicitHeight + Style.space(14)
              hasCursor: root.cursorActive && root.cursorIndex === rowIndex
              foreground: root.foreground

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.cursorIndex = sendRow.rowIndex }
                onClicked: root.openSendForm()
              }

              RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: Model.GLYPHS.host
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  Layout.preferredWidth: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  id: sendText
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.sendFormOpen ? "Send to a host:" : "Send to a host…"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
            }

            // Host buttons, then the folder on that host ("~" is its home) and
            // Send. Plain buttons rather than a dropdown: a dropdown's list
            // opens past the panel's edge, where a pinned panel takes no clicks.
            Flow {
              visible: root.sendFormOpen
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.shelf ? root.shelf.hosts : []

                Button {
                  required property string modelData
                  text: modelData
                  iconText: Model.GLYPHS.host
                  selected: root.selectedHost === modelData
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.pickHost(modelData)
                }
              }
            }

            RowLayout {
              visible: root.sendFormOpen
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: folderField
                Layout.fillWidth: true
                placeholderText: "~/Downloads"
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Keys.onReturnPressed: function(event) { root.sendNow(root.selectedHost, text || "~/Downloads"); event.accepted = true }
                Keys.onEnterPressed: function(event) { root.sendNow(root.selectedHost, text || "~/Downloads"); event.accepted = true }
                Keys.onEscapePressed: function(event) { root.sendFormOpen = false; keyCatcher.forceActiveFocus(); event.accepted = true }
              }

              Button {
                text: root.selectedHost !== "" ? "Send to " + root.selectedHost : "Send"
                foreground: root.foreground
                fontFamily: root.fontFamily
                bordered: true
                enabled: !root.busy && root.deliverableCount > 0 && root.selectedHost !== ""
                onClicked: root.sendNow(root.selectedHost, folderField.text || "~/Downloads")
              }
            }

            Text {
              visible: root.sendFormOpen && root.shelf !== null && root.shelf.hosts.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: "No SSH hosts found in ~/.ssh/config"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.remotes

              CursorSurface {
                id: remoteRow
                required property var modelData
                required property int index
                readonly property int rowIndex: root.items.length + root.recents.length + 2 + index
                width: parent ? parent.width : 0
                implicitHeight: remoteText.implicitHeight + Style.space(14)
                hasCursor: root.cursorActive && root.cursorIndex === rowIndex
                foreground: root.foreground
                opacity: root.deliverableCount > 0 && !root.busy ? 1 : 0.45

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: { root.cursorActive = true; root.cursorIndex = remoteRow.rowIndex }
                  onClicked: root.activate({ type: "remote", remote: remoteRow.modelData })
                }

                RowLayout {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)

                  Text {
                    textFormat: Text.PlainText
                    text: Model.GLYPHS.host
                    color: root.foreground
                    opacity: 0.75
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.preferredWidth: Style.space(18)
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    id: remoteText
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: Model.remoteLabel(remoteRow.modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideMiddle
                  }

                  PanelActionButton {
                    iconText: Model.GLYPHS.remove
                    tooltipText: "Forget this host and folder"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: if (root.shelf) root.shelf.forgetRemote(remoteRow.modelData.host, remoteRow.modelData.dir)
                  }
                }
              }
            }

          }

          RowLayout {
            visible: root.items.length > 0
            width: parent.width
            spacing: Style.space(8)

            Item { Layout.fillWidth: true }

            Button {
              text: "Copy paths"
              tooltipText: "Copy the staged paths as text, one per line (y)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.shelf) root.shelf.copyPaths()
            }

            Button {
              visible: Model.missingPaths(root.items).length > 0
              text: "Remove missing"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              enabled: !root.busy
              onClicked: if (root.shelf) root.shelf.removeMissing()
            }
          }
        }
      }

      // Stays put while the list scrolls.
      Text {
        id: footer
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        horizontalAlignment: Text.AlignHCenter
        text: root.busy ? "s stop" : root.items.length === 0
          ? "drag files here or onto the bar · v paste · p keep open"
          : "drag the shelf or a row into a folder · enter deliver · o choose folder · h host · m mode · v paste · y copy paths · d remove · c clear · p keep open"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // The open panel is a drop zone too, over everything in it.
      DropArea {
        id: panelDrop
        anchors.fill: parent
        keys: ["text/uri-list"]
        property bool accepting: false
        onEntered: function(drag) { accepting = root.acceptDrag(drag) }
        onExited: accepting = false
        onDropped: function(drop) { root.takeDrop(drop, accepting); accepting = false }

        Rectangle {
          anchors.fill: parent
          visible: panelDrop.containsDrag && panelDrop.accepting
          radius: Style.cornerRadius > 0 ? Style.space(8) : 0
          // Opaque, so the hint reads cleanly over the list.
          color: Qt.tint(Color.popups.background, Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12))
          border.width: Math.max(1, Style.space(2))
          border.color: root.accent

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Model.GLYPHS.shelf + "  Drop to stage"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }
      }
    }
  }
}
