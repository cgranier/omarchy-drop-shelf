// Pure logic for Drop Shelf: no QML, no processes, so node can test it.

var MAX_ITEMS = 200
var MAX_RECENTS = 5
var MAX_PATH = 4096

function glyph(cp) { return String.fromCodePoint(cp) }

var GLYPHS = {
  shelf: glyph(0xF0120),   // md-tray_arrow_down
  target: glyph(0xF04FE),  // md-target
  file: glyph(0xF0214),    // md-file
  folder: glyph(0xF024B),  // md-folder
  link: glyph(0xF018F),    // md-content_copy (stands in for a link)
  missing: glyph(0xF0026), // md-alert
  remove: glyph(0xF0156),  // md-close
  busy: glyph(0xF01A4),    // md-crosshairs_gps
  pin: glyph(0xF0403),     // md-pin
  unpin: glyph(0xF0404)    // md-pin_off
}

function kindGlyph(item) {
  if (!item || item.kind === "missing") return GLYPHS.missing
  if (item.kind === "folder") return GLYPHS.folder
  if (item.kind === "link") return GLYPHS.link
  return GLYPHS.file
}

function plainPath(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_PATH) return ""
  if (value.charAt(0) !== "/" || value.indexOf("\0") !== -1 || value.indexOf("\n") !== -1) return ""
  var parts = value.split("/")
  var kept = []
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i]
    if (p === "" || p === ".") continue
    if (p === "..") return ""
    kept.push(p)
  }
  return kept.length === 0 ? "" : "/" + kept.join("/")
}

// Dropped URLs → local paths. Anything that is not a file:// URL (a link
// dragged out of a browser, a portal document) is counted, not staged.
function pathsFromUrls(urls) {
  var paths = []
  var skipped = 0
  var list = urls || []
  for (var i = 0; i < list.length; i++) {
    var s = String(list[i])
    var m = /^file:\/\/(localhost)?(\/.*)$/.exec(s)
    if (!m) { skipped++; continue }
    var decoded
    try { decoded = decodeURIComponent(m[2]) } catch (e) { skipped++; continue }
    var path = plainPath(decoded)
    if (path === "") { skipped++; continue }
    if (paths.indexOf(path) === -1) paths.push(path)
  }
  return { paths: paths, skipped: skipped }
}

function fileUrl(path) {
  return "file://" + path.split("/").map(encodeURIComponent).join("/")
}

// text/uri-list wants CRLF after every line.
function uriList(items) {
  var out = ""
  for (var i = 0; i < items.length; i++) out += fileUrl(items[i].path) + "\r\n"
  return out
}

function baseName(path) {
  var i = path.lastIndexOf("/")
  return i === -1 ? path : path.substring(i + 1)
}

function tildePath(path, home) {
  if (home && (path === home || path.indexOf(home + "/") === 0)) return "~" + path.substring(home.length)
  return path
}

function parentDir(path, home) {
  var i = path.lastIndexOf("/")
  var parent = i <= 0 ? "/" : path.substring(0, i)
  return tildePath(parent, home)
}

function formatSize(bytes) {
  if (typeof bytes !== "number" || bytes < 0) return ""
  if (bytes < 1024) return bytes + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var v = bytes / 1024
  var u = 0
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++ }
  return (v < 10 ? v.toFixed(1) : Math.round(v)) + " " + units[u]
}

// Merge freshly inspected entries into the shelf. Already-staged paths are
// counted as duplicates; anything past MAX_ITEMS is counted as overflow.
function merge(items, inspected, now) {
  var next = items.slice()
  var have = {}
  for (var i = 0; i < next.length; i++) have[next[i].path] = true
  var added = 0, duplicates = 0, overflow = 0, invalid = 0
  for (var j = 0; j < inspected.length; j++) {
    var e = inspected[j]
    var path = plainPath(e && e.path)
    if (path === "" || e.kind === "invalid" || e.kind === "missing" || e.kind === "other") { invalid++; continue }
    if (have[path]) { duplicates++; continue }
    if (next.length >= MAX_ITEMS) { overflow++; continue }
    have[path] = true
    next.push({ path: path, kind: e.kind, size: typeof e.size === "number" ? e.size : -1, addedAt: now })
    added++
  }
  return { items: next, added: added, duplicates: duplicates, overflow: overflow, invalid: invalid }
}

// Fresh inspection of what is already staged: kinds and sizes update, and a
// path that is gone is kept but marked missing.
function refresh(items, inspected) {
  var byPath = {}
  for (var i = 0; i < inspected.length; i++) if (inspected[i] && inspected[i].path) byPath[inspected[i].path] = inspected[i]
  return items.map(function(item) {
    var e = byPath[item.path]
    if (!e) return item
    return { path: item.path, kind: e.kind === "invalid" || e.kind === "other" ? "missing" : e.kind,
             size: typeof e.size === "number" ? e.size : -1, addedAt: item.addedAt }
  })
}

function removePaths(items, paths) {
  var drop = {}
  for (var i = 0; i < paths.length; i++) drop[paths[i]] = true
  return items.filter(function(item) { return !drop[item.path] })
}

function missingPaths(items) {
  return items.filter(function(item) { return item.kind === "missing" }).map(function(item) { return item.path })
}

function deliverable(items) {
  return items.filter(function(item) { return item.kind !== "missing" })
}

// After a drag-out in move mode the file manager moves things in its own
// time (it may stop to ask about conflicts), so the paths that left in the
// drag are watched: when one of them turns up missing it was moved, and it
// leaves the shelf instead of being flagged.
function takeMoved(items, inspected, watched) {
  var gone = []
  var still = {}
  for (var i = 0; i < inspected.length; i++) {
    var e = inspected[i]
    if (e && watched[e.path] && e.kind === "missing") gone.push(e.path)
  }
  var next = removePaths(items, gone)
  for (var j = 0; j < next.length; j++) if (watched[next[j].path]) still[next[j].path] = true
  return { items: next, moved: gone.length, watched: still }
}

function rememberTarget(recents, target) {
  var path = plainPath(target)
  if (path === "") return recents
  var next = [path]
  for (var i = 0; i < recents.length && next.length < MAX_RECENTS; i++) if (recents[i] !== path) next.push(recents[i])
  return next
}

function totals(items) {
  var bytes = 0, files = 0, folders = 0, missing = 0, sized = true
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    if (it.kind === "missing") { missing++; continue }
    if (it.kind === "folder") { folders++; sized = false; continue }
    files++
    if (it.size >= 0) bytes += it.size
  }
  return { count: items.length, files: files, folders: folders, missing: missing, bytes: bytes, sized: sized }
}

function plural(n, word) { return n + " " + word + (n === 1 ? "" : "s") }

function summary(items) {
  var t = totals(items)
  if (t.count === 0) return "Empty. Drag files onto the shelf in the bar."
  var parts = []
  if (t.files) parts.push(plural(t.files, "file") + (t.bytes > 0 ? " (" + formatSize(t.bytes) + ")" : ""))
  if (t.folders) parts.push(plural(t.folders, "folder"))
  var line = parts.join(", ")
  if (t.missing) line += (line ? " · " : "") + t.missing + " missing"
  return line
}

function progressLabel(job) {
  if (!job) return ""
  var verb = job.mode === "move" ? "Moving" : "Copying"
  var n = Math.min(job.index + 1, job.count)
  var pct = job.total > 0 ? " " + Math.min(100, Math.floor(job.bytes * 100 / job.total)) + "%" : ""
  return verb + " " + n + "/" + job.count + pct
}

function barLabel(count, job, hovering) {
  if (job) return progressLabel(job)
  if (hovering) return "Drop to stage"
  return count > 0 ? String(count) : ""
}

// What a finished delivery leaves on the shelf. Moved items always leave;
// copied ones leave unless the shelf is set to keep them.
function afterDelivery(items, results, mode, keepAfterCopy) {
  var delivered = []
  for (var i = 0; i < results.length; i++) if (results[i] && results[i].ok && results[i].path) delivered.push(results[i].path)
  if (mode === "copy" && keepAfterCopy) return items
  return removePaths(items, delivered)
}

function deliverySummary(mode, ok, failed, cancelled, target, home) {
  var verb = mode === "move" ? "Moved" : "Copied"
  var where = tildePath(target || "", home)
  if (cancelled) return "Stopped. " + verb + " " + ok + " before stopping."
  if (failed === 0) return verb + " " + plural(ok, "item") + " to " + where
  return verb + " " + ok + ", " + failed + " failed (they stay on the shelf)"
}

function parseState(text) {
  var empty = { items: [], mode: "copy", recents: [], pinned: false }
  var obj
  try { obj = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!obj || typeof obj !== "object") return null
  var items = []
  var seen = {}
  var list = Array.isArray(obj.items) ? obj.items : []
  for (var i = 0; i < list.length && items.length < MAX_ITEMS; i++) {
    var it = list[i]
    var path = plainPath(it && it.path)
    if (path === "" || seen[path]) continue
    seen[path] = true
    var kind = ["file", "folder", "link", "missing"].indexOf(it.kind) !== -1 ? it.kind : "file"
    items.push({ path: path, kind: kind, size: typeof it.size === "number" ? it.size : -1,
                 addedAt: typeof it.addedAt === "number" ? it.addedAt : 0 })
  }
  var recents = []
  var r = Array.isArray(obj.recents) ? obj.recents : []
  for (var j = 0; j < r.length && recents.length < MAX_RECENTS; j++) {
    var p = plainPath(r[j])
    if (p !== "" && recents.indexOf(p) === -1) recents.push(p)
  }
  return { items: items, mode: obj.mode === "move" ? "move" : empty.mode, recents: recents, pinned: obj.pinned === true }
}

function serializeState(state) {
  return JSON.stringify({ version: 1, mode: state.mode, pinned: state.pinned === true, recents: state.recents,
    items: state.items.map(function(it) { return { path: it.path, kind: it.kind, size: it.size, addedAt: it.addedAt } }) })
}

// One line of the helper's deliver output, or null.
function parseLine(line) {
  var s = String(line || "")
  if (s.length === 0 || s.length > 20000 || s.charAt(0) !== "{") return null
  try {
    var o = JSON.parse(s)
    return o && typeof o.type === "string" ? o : null
  } catch (e) { return null }
}

// The folder picker prints one path per line; take the first plain one.
function pickedFolder(text) {
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var p = plainPath(lines[i].trim())
    if (p !== "") return p
  }
  return ""
}

if (typeof module !== "undefined") module.exports = {
  MAX_ITEMS: MAX_ITEMS, GLYPHS: GLYPHS, kindGlyph: kindGlyph, plainPath: plainPath, pathsFromUrls: pathsFromUrls,
  fileUrl: fileUrl, uriList: uriList, baseName: baseName, tildePath: tildePath, parentDir: parentDir,
  formatSize: formatSize, merge: merge, refresh: refresh, removePaths: removePaths, missingPaths: missingPaths,
  deliverable: deliverable, takeMoved: takeMoved, rememberTarget: rememberTarget, totals: totals, summary: summary,
  progressLabel: progressLabel, barLabel: barLabel, afterDelivery: afterDelivery, deliverySummary: deliverySummary,
  parseState: parseState, serializeState: serializeState, parseLine: parseLine, pickedFolder: pickedFolder
}
