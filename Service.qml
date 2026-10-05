import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Drop Shelf's engine: the list of staged paths, the copy/move mode, recent
// targets, and every process. One instance for the whole shell, so a bar on
// each monitor shows the same shelf. Files are never touched until delivery,
// and then only by bin/dropshelf, which gets every path over stdin.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")
  readonly property string stateFile: stateHome + "/dropshelf/state.json"
  readonly property string helper: String(Qt.resolvedUrl("bin/dropshelf")).replace(/^file:\/\//, "")

  // Settings pushed in by the bar widget.
  property bool keepAfterCopy: false

  property var items: []
  property string mode: "copy"
  property var recents: []
  property bool loaded: false

  // Delivery in flight: { mode, target, count, index, bytes, total, results }.
  property var job: null
  readonly property bool busy: job !== null
  property string status: ""
  property bool picking: false
  property bool cancelRequested: false

  // A drag that started on the shelf itself; its own drop zone ignores it.
  property bool draggingOut: false

  readonly property var totals: Model.totals(items)
  readonly property string summary: Model.summary(items)

  function say(text) {
    status = String(text || "")
    statusTimer.restart()
  }

  // ---- staging ---------------------------------------------------------------

  property var pendingInspect: []

  function stageUrls(urls) {
    if (draggingOut) return false
    var r = Model.pathsFromUrls(urls)
    if (r.paths.length === 0) {
      say(r.skipped > 0 ? "Only local files and folders can be staged" : "Nothing to stage")
      return false
    }
    pendingInspect = pendingInspect.concat(r.paths).slice(0, Model.MAX_ITEMS)
    if (r.skipped > 0) say(r.skipped + " dropped item(s) were not local files")
    flushInspect()
    return true
  }

  function flushInspect() {
    if (inspectProcess.running || pendingInspect.length === 0) return
    inspectProcess.purpose = "stage"
    inspectProcess.payload = JSON.stringify(pendingInspect)
    pendingInspect = []
    inspectProcess.stdinEnabled = true
    inspectProcess.running = true
  }

  function recheck() {
    if (inspectProcess.running || items.length === 0) return
    inspectProcess.purpose = "refresh"
    inspectProcess.payload = JSON.stringify(items.map(function(i) { return i.path }))
    inspectProcess.stdinEnabled = true
    inspectProcess.running = true
  }

  function applyInspect(purpose, list) {
    if (purpose === "stage") {
      var r = Model.merge(items, list, Date.now())
      items = r.items
      var notes = []
      if (r.added) notes.push("Staged " + r.added)
      if (r.duplicates) notes.push(r.duplicates + " already on the shelf")
      if (r.invalid) notes.push(r.invalid + " not a file or folder")
      if (r.overflow) notes.push(r.overflow + " over the " + Model.MAX_ITEMS + "-item limit")
      if (notes.length) say(notes.join(" · "))
    } else {
      items = Model.refresh(items, list)
    }
    saveState()
  }

  function remove(path) {
    if (busy) return
    items = Model.removePaths(items, [path])
    saveState()
  }

  function removeMissing() {
    if (busy) return
    items = Model.removePaths(items, Model.missingPaths(items))
    saveState()
  }

  function clear() {
    if (busy) return
    items = []
    saveState()
    say("Shelf cleared")
  }

  function setMode(value) {
    if (busy || (value !== "copy" && value !== "move")) return
    mode = value
    saveState()
  }

  function toggleMode() { setMode(mode === "copy" ? "move" : "copy") }

  // What a drag out of the bar carries.
  function uriList() { return Model.uriList(Model.deliverable(items)) }

  // A drag-out never says where it landed or whether it did (Nautilus copies
  // without reporting back), so afterwards the shelf only re-reads what is
  // still there: in move mode the moved originals disappear from the shelf.
  function dragOutFinished() {
    draggingOut = false
    dragRecheck.restart()
  }

  Timer {
    id: dragRecheck
    interval: 1500
    onTriggered: if (inspectProcess.running) restart(); else root.recheckAfterDrag()
  }

  function recheckAfterDrag() {
    if (items.length === 0) return
    inspectProcess.purpose = mode === "move" ? "drag-move" : "refresh"
    inspectProcess.payload = JSON.stringify(items.map(function(i) { return i.path }))
    inspectProcess.stdinEnabled = true
    inspectProcess.running = true
  }

  // ---- delivery --------------------------------------------------------------

  function pickTarget() {
    if (busy || picking || Model.deliverable(items).length === 0) return false
    picking = true
    pickProcess.running = true
    return true
  }

  function deliver(target) {
    var path = Model.plainPath(String(target || ""))
    var ready = Model.deliverable(items)
    if (busy || path === "" || ready.length === 0) return false
    cancelRequested = false
    job = { mode: mode, target: path, count: ready.length, index: 0, bytes: 0, total: -1, results: [], paths: ready.map(function(i) { return i.path }) }
    deliverProcess.payload = JSON.stringify({ mode: mode, target: path, items: job.paths })
    deliverProcess.stdinEnabled = true
    deliverProcess.running = true
    return true
  }

  function cancel() {
    if (deliverProcess.running) { cancelRequested = true; deliverProcess.signal(15) }
    if (pickProcess.running) pickProcess.signal(15)
  }

  function onDeliverLine(line) {
    var o = Model.parseLine(line)
    if (!o || !job) return
    var j = job
    if (o.type === "start" && typeof o.total === "number") j.total = o.total
    else if (o.type === "begin" && typeof o.i === "number") j.index = o.i
    else if (o.type === "progress" && typeof o.bytes === "number") j.bytes = o.bytes
    else if (o.type === "item") {
      j.results.push({ path: typeof o.path === "string" ? o.path : "", ok: o.ok === true,
                       error: typeof o.error === "string" ? o.error.substring(0, 200) : "" })
      // A moved item has left its old place; take it off the shelf now, so
      // a cancel later in the run cannot leave it looking missing.
      if (o.ok === true && j.mode === "move" && typeof o.path === "string") items = Model.removePaths(items, [o.path])
    } else if (o.type === "done" || o.type === "cancelled") j.finished = o.type
    job = Object.assign({}, j)
  }

  function finishDelivery(exitCode, complaint) {
    var j = job
    job = null
    if (!j) return
    var ok = j.results.filter(function(r) { return r.ok }).length
    var failed = j.results.length - ok
    // A stop kills the whole pipeline, so its last line may never arrive.
    var cancelled = cancelRequested || j.finished === "cancelled" || exitCode === 130 || exitCode === 124
    cancelRequested = false
    if (j.finished === undefined && !cancelled && exitCode !== 0) {
      say(complaint !== "" ? complaint : "Delivery failed")
      if (ok > 0) items = Model.afterDelivery(items, j.results, j.mode, keepAfterCopy)
      saveState()
      recheck()
      return
    }
    items = Model.afterDelivery(items, j.results, j.mode, keepAfterCopy)
    recents = Model.rememberTarget(recents, j.target)
    saveState()
    say(Model.deliverySummary(j.mode, ok, failed, cancelled, j.target, home))
    var firstError = j.results.filter(function(r) { return !r.ok && r.error !== "" })[0]
    if (firstError && !cancelled) notifyProcess.send("Drop Shelf", (failed === 1 ? "1 item" : failed + " items") + " could not be delivered: " + firstError.error)
    if (cancelled) recheck()
  }

  // ---- state -----------------------------------------------------------------

  property string pendingWrite: ""

  function saveState() {
    if (!loaded) return
    pendingWrite = Model.serializeState({ items: items, mode: mode, recents: recents })
    if (!writeProcess.running) flushWrite()
  }

  function flushWrite() {
    if (pendingWrite === "") return
    writeProcess.payload = pendingWrite
    pendingWrite = ""
    writeProcess.stdinEnabled = true
    writeProcess.running = true
  }

  Timer {
    id: statusTimer
    interval: 6000
    onTriggered: root.status = ""
  }

  // A refused or unreadable file means an empty shelf; nothing is written
  // over it until something on the shelf changes.
  Process {
    id: readProcess
    running: true
    command: ["timeout", "10", "bash", "-c", '/usr/bin/python3 "$1" state read "$2" 2>/dev/null | head -c 600000; exit "${PIPESTATUS[0]}"', "bash", root.helper, root.stateFile]
    stdout: StdioCollector { id: readOut; waitForEnd: true }
    onExited: function(exitCode) {
      var state = exitCode === 0 ? Model.parseState(readOut.text) : null
      if (state) {
        root.items = state.items
        root.mode = state.mode
        root.recents = state.recents
      }
      root.loaded = true
      root.recheck()
    }
  }

  Process {
    id: writeProcess
    property string payload: ""
    running: false
    command: ["timeout", "10", "/usr/bin/python3", root.helper, "state", "write", root.stateFile]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.say("Could not save the shelf")
      root.flushWrite()
    }
  }

  Process {
    id: inspectProcess
    property string payload: ""
    property string purpose: "stage"
    running: false
    command: ["timeout", "20", "bash", "-c", '/usr/bin/python3 "$1" inspect 2>/dev/null | head -c 2000000; exit "${PIPESTATUS[0]}"', "bash", root.helper]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    stdout: StdioCollector { id: inspectOut; waitForEnd: true }
    onExited: function(exitCode) {
      var list = null
      if (exitCode === 0) {
        try { list = JSON.parse(String(inspectOut.text || "")) } catch (e) { list = null }
      }
      if (Array.isArray(list)) {
        if (purpose === "drag-move") {
          // Moved away by the drag: gone from where they were.
          var gone = list.filter(function(e) { return e && e.kind === "missing" }).map(function(e) { return e.path })
          root.items = Model.removePaths(root.items, gone)
          if (gone.length) root.say("Moved " + gone.length + " by drag")
          root.applyInspect("refresh", list)
        } else {
          root.applyInspect(purpose, list)
        }
      } else if (purpose === "stage") {
        root.say("Could not read the dropped files")
      }
      root.flushInspect()
    }
  }

  Process {
    id: pickProcess
    running: false
    command: ["timeout", "660", "bash", "-c", 'omarchy-file-select --title "Deliver the shelf to…" --directory 2>/dev/null | head -c 8192; exit "${PIPESTATUS[0]}"', "bash"]
    stdout: StdioCollector { id: pickOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.picking = false
      var target = exitCode === 0 ? Model.pickedFolder(pickOut.text) : ""
      if (target !== "") root.deliver(target)
      else if (exitCode !== 1 && exitCode !== 143) root.say("The folder picker did not open")
    }
  }

  Process {
    id: deliverProcess
    property string payload: ""
    running: false
    command: ["timeout", "-k", "10", "3600", "bash", "-c", '/usr/bin/python3 "$1" deliver 2> >(head -c 4000 >&2) | head -c 8000000; exit "${PIPESTATUS[0]}"', "bash", root.helper]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    stdout: SplitParser { onRead: function(line) { root.onDeliverLine(line) } }
    stderr: StdioCollector { id: deliverErr; waitForEnd: true }
    onExited: function(exitCode) {
      var complaint = String(deliverErr.text || "").trim().split("\n")[0].replace(/^dropshelf: /, "").substring(0, 160)
      root.finishDelivery(exitCode, complaint)
    }
  }

  // Failure notices name no file: the text of a failure stays in the panel.
  Process {
    id: notifyProcess
    running: false
    command: []
    function send(title, body) {
      if (running) return
      command = ["timeout", "10", "notify-send", "-a", "Drop Shelf", "-i", "folder", "--", title, body]
      running = true
    }
  }
}
