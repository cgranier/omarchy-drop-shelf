import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Drop Zone's engine: the list of staged paths, the copy/move/zip mode,
// recent targets (local folders and SSH hosts), and every process. One
// instance for the whole shell, so a bar on each monitor shows the same
// shelf. Files are never touched until delivery, and then only by
// bin/dropshelf, which gets every path over stdin.
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
  property bool notifyOnDelivery: true
  property string sshHostsSetting: ""

  property var items: []
  property string mode: "copy"
  property var recents: []
  property var remotes: []
  // The panel's pin, remembered: once pinned it opens pinned until unpinned.
  property bool pinned: false
  property bool loaded: false

  // SSH aliases from ~/.ssh/config, read when the panel asks.
  property var foundHosts: []
  readonly property var hosts: Model.offeredHosts(foundHosts, sshHostsSetting)

  // Delivery in flight: { mode, target, remote, count, index, bytes, total, results }.
  property var job: null
  readonly property bool busy: job !== null
  property string status: ""
  property bool picking: false
  property bool cancelRequested: false

  // The last local delivery, for "Open folder": { folder, dests, at }.
  property var lastDelivery: null

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
    return stagePaths(Model.pathsFromUrls(urls), "dropped")
  }

  function stagePaths(r, how) {
    if (r.paths.length === 0) {
      say(r.skipped > 0 ? "Only local files and folders can be staged" : how === "pasted" ? "No files on the clipboard" : "Nothing to stage")
      return false
    }
    pendingInspect = pendingInspect.concat(r.paths).slice(0, Model.MAX_ITEMS)
    if (r.skipped > 0) say(r.skipped + " " + how + " item(s) were not local files")
    flushInspect()
    return true
  }

  // Files copied in the file manager (Ctrl+C) land on the shelf.
  function pasteFromClipboard() {
    if (clipProcess.running) return
    clipProcess.running = true
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
    dragWatched = ({})
    saveState()
    say("Shelf cleared")
  }

  function setMode(value) {
    if (busy || ["copy", "move", "zip"].indexOf(value) === -1) return
    mode = value
    saveState()
  }

  function forgetRecent(path) {
    recents = recents.filter(function(p) { return p !== path })
    saveState()
  }

  function forgetRemote(host, dir) {
    remotes = remotes.filter(function(r) { return r.host !== host || r.dir !== dir })
    saveState()
  }

  function setPinned(value) {
    pinned = value === true
    saveState()
  }

  function toggleMode() { setMode(mode === "copy" ? "move" : mode === "move" ? "zip" : "copy") }

  // The staged paths as text, one per line, over stdin to wl-copy.
  function copyPaths() {
    var ready = Model.deliverable(items)
    if (ready.length === 0 || copyProcess.running) return false
    copyProcess.payload = Model.pathsText(ready)
    copyProcess.stdinEnabled = true
    copyProcess.running = true
    return true
  }

  // What a drag out of the bar carries.
  // `paths` narrows it to some staged items (one row dragged from the panel).
  function uriList(paths) { return Model.uriList(dragItems(paths)) }

  function dragItems(paths) {
    var ready = Model.deliverable(items)
    if (!paths) return ready
    return ready.filter(function(i) { return paths.indexOf(i.path) !== -1 })
  }

  // A drag-out never says where it landed or whether it did (Nautilus copies
  // without reporting back), so afterwards the shelf only re-reads what is
  // still there. In move mode the dragged paths are watched for a while: the
  // file manager may sit on a conflict question long after the drop, and an
  // original that disappears in that window was moved, so it leaves the shelf.
  property var dragWatched: ({})
  property int dragWatchTicks: 0

  function dragOutStarted(paths) {
    draggingOut = true
    var watched = {}
    if (mode === "move") dragItems(paths).forEach(function(i) { watched[i.path] = true })
    dragWatched = watched
  }

  function dragOutFinished() {
    draggingOut = false
    dragWatchTicks = 0
    dragRecheck.restart()
  }

  Timer {
    id: dragRecheck
    interval: 2000
    onTriggered: {
      if (inspectProcess.running) { restart(); return }
      root.recheck()
      root.dragWatchTicks++
      if (Object.keys(root.dragWatched).length > 0 && root.dragWatchTicks < 60) restart()
      else root.dragWatched = ({})
    }
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
    if (path === "") return false
    return start({ mode: mode, target: path, remote: false }, { mode: mode, target: path })
  }

  // Copy, move or zip to a folder on an SSH host.
  function sendTo(host, dir) {
    if (!Model.validHost(host) || !Model.validRemoteDir(dir)) { say("Pick a host and a folder"); return false }
    var folder = String(dir).trim()
    return start({ mode: mode, target: host + ":" + folder, remote: true, host: host, dir: folder },
                 { mode: mode, host: host, dir: folder })
  }

  function start(spec, request) {
    var ready = Model.deliverable(items)
    if (busy || ready.length === 0) return false
    cancelRequested = false
    var paths = ready.map(function(i) { return i.path })
    job = Object.assign({ count: ready.length, index: 0, bytes: 0, total: -1, results: [], dests: [], paths: paths }, spec)
    request.items = paths
    deliverProcess.verb = spec.remote ? "send" : "deliver"
    deliverProcess.payload = JSON.stringify(request)
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
                       error: typeof o.error === "string" ? Model.plainText(o.error, 200) : "" })
      if (o.ok === true && typeof o.dest === "string" && j.dests.indexOf(o.dest) === -1) j.dests.push(o.dest.substring(0, 255))
      // A moved item has left its old place; take it off the shelf now, so
      // a cancel later in the run cannot leave it looking missing.
      if (o.ok === true && j.mode === "move" && typeof o.path === "string") items = Model.removePaths(items, [o.path])
    } else if (o.type === "done" || o.type === "cancelled") {
      j.finished = o.type
      if (typeof o.error === "string") j.error = Model.plainText(o.error, 200)
    }
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
    if ((j.finished === undefined && !cancelled && exitCode !== 0) || j.error) {
      say(j.error || (complaint !== "" ? complaint : "Delivery failed"))
      if (ok > 0) items = Model.afterDelivery(items, j.results, j.mode, keepAfterCopy)
      saveState()
      recheck()
      return
    }
    items = Model.afterDelivery(items, j.results, j.mode, keepAfterCopy)
    if (j.remote) remotes = Model.rememberRemote(remotes, j.host, j.dir)
    else recents = Model.rememberTarget(recents, j.target)
    saveState()
    var firstError = j.results.filter(function(r) { return !r.ok && r.error !== "" })[0]
    say(Model.deliverySummary(j.mode, ok, failed, cancelled, j.target, home, j.remote)
        + (firstError && !cancelled ? " · " + firstError.error : ""))
    if (!j.remote && ok > 0) lastDelivery = { folder: j.target, dests: j.dests.slice(0, 50), at: Date.now() }
    if (firstError && !cancelled)
      notifyProcess.send("Drop Zone", (failed === 1 ? "1 item" : failed + " items") + " could not be delivered: " + firstError.error)
    else if (!cancelled && ok > 0 && notifyOnDelivery)
      doneNotify.send(Model.verbPast(j.mode, j.remote) + " " + (ok === 1 ? "1 item" : ok + " items"), !j.remote)
    if (cancelled) recheck()
  }

  // Shows the last local delivery's folder with the delivered items selected.
  function openLastFolder() {
    if (!lastDelivery || openProcess.running) return false
    openProcess.payload = JSON.stringify({ folder: lastDelivery.folder, items: lastDelivery.dests })
    openProcess.stdinEnabled = true
    openProcess.running = true
    return true
  }

  function loadHosts() {
    if (!hostsProcess.running) hostsProcess.running = true
  }

  // ---- state -----------------------------------------------------------------

  property string pendingWrite: ""

  function saveState() {
    if (!loaded) return
    pendingWrite = Model.serializeState({ items: items, mode: mode, recents: recents, remotes: remotes, pinned: pinned })
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
        root.pinned = state.pinned
        root.recents = state.recents
        root.remotes = state.remotes
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
        if (purpose === "refresh" && Object.keys(root.dragWatched).length > 0) {
          var r = Model.takeMoved(root.items, list, root.dragWatched)
          root.items = r.items
          root.dragWatched = r.watched
          if (r.moved) root.say("Moved " + r.moved + " by drag")
        }
        root.applyInspect(purpose, list)
      } else if (purpose === "stage") {
        root.say("Could not read the files")
      }
      root.flushInspect()
    }
  }

  // The clipboard's file list, preferring the types a file manager offers.
  // Capped; only lines that look like file URIs or absolute paths are used.
  Process {
    id: clipProcess
    running: false
    command: ["timeout", "5", "bash", "-c",
      'types=$(wl-paste --list-types 2>/dev/null | head -c 8192); pick=; ' +
      'for m in text/uri-list x-special/gnome-copied-files; do ' +
      'if printf "%s\\n" "$types" | grep -qxF "$m"; then pick=$m; break; fi; done; ' +
      'wl-paste --no-newline ${pick:+--type "$pick"} 2>/dev/null | head -c 1000000; exit 0', "bash"]
    stdout: StdioCollector { id: clipOut; waitForEnd: true }
    onExited: function(exitCode) { root.stagePaths(Model.clipboardPaths(clipOut.text), "pasted") }
  }

  Process {
    id: copyProcess
    property string payload: ""
    running: false
    command: ["timeout", "10", "wl-copy"]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    onExited: function(exitCode) { root.say(exitCode === 0 ? "Paths copied to the clipboard" : "Could not copy the paths") }
  }

  Process {
    id: openProcess
    property string payload: ""
    running: false
    command: ["timeout", "15", "/usr/bin/python3", root.helper, "open-folder"]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    onExited: function(exitCode) { if (exitCode !== 0) root.say("Could not open the folder") }
  }

  Process {
    id: hostsProcess
    running: false
    command: ["timeout", "10", "bash", "-c", '/usr/bin/python3 "$1" hosts 2>/dev/null | head -c 65536; exit "${PIPESTATUS[0]}"', "bash", root.helper]
    stdout: StdioCollector { id: hostsOut; waitForEnd: true }
    onExited: function(exitCode) {
      var list = null
      if (exitCode === 0) {
        try { list = JSON.parse(String(hostsOut.text || "")) } catch (e) { list = null }
      }
      if (Array.isArray(list)) root.foundHosts = list.filter(Model.validHost)
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

  // `verb` is one of two fixed words; everything else goes over stdin.
  Process {
    id: deliverProcess
    property string payload: ""
    property string verb: "deliver"
    running: false
    // stdbuf -oL: head writes through stdio, which a pipe makes fully buffered,
    // and progress would then arrive in 4 KB bursts instead of line by line.
    command: ["timeout", "-k", "10", "3600", "bash", "-c", '/usr/bin/python3 "$1" "$2" 2> >(head -c 4000 >&2) | stdbuf -oL head -c 8000000; exit "${PIPESTATUS[0]}"', "bash", root.helper, verb === "send" ? "send" : "deliver"]
    stdinEnabled: true
    onStarted: { write(payload); payload = ""; stdinEnabled = false }
    stdout: SplitParser { onRead: function(line) { root.onDeliverLine(line) } }
    stderr: StdioCollector { id: deliverErr; waitForEnd: true }
    onExited: function(exitCode) {
      var complaint = Model.plainText(String(deliverErr.text || "").trim().split("\n")[0].replace(/^dropshelf: /, ""), 160)
      root.finishDelivery(exitCode, complaint)
    }
  }

  // Failure notices name no file: the text of a failure stays in the panel.
  Process {
    id: notifyProcess
    property string title: ""
    property string body: ""
    running: false
    command: ["timeout", "10", "notify-send", "-a", "Drop Zone", "-i", "folder", "--", title, body]
    function send(t, b) {
      if (running) return
      title = t
      body = b
      running = true
    }
  }

  // "Copied 3 items", with an Open folder action for local deliveries. It
  // names no file or folder; the action opens the folder it went to.
  Process {
    id: doneNotify
    property string title: ""
    property bool withAction: false
    running: false
    command: withAction
      ? ["timeout", "120", "notify-send", "--wait", "-A", "open=Open folder", "-a", "Drop Zone", "-i", "folder", "--", title]
      : ["timeout", "10", "notify-send", "-a", "Drop Zone", "-i", "folder", "--", title]
    stdout: StdioCollector { id: doneOut; waitForEnd: true }
    onExited: function(exitCode) { if (String(doneOut.text || "").trim() === "open") root.openLastFolder() }
    function send(t, action) {
      if (running) signal(15)
      title = t
      withAction = action
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 50
    onTriggered: if (doneNotify.running) restart(); else doneNotify.running = true
  }
}
