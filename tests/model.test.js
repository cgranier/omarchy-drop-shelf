// Run with: node tests/model.test.js
const assert = require("assert")
const M = require("../Model.js")
let passed = 0
function test(name, fn) { fn(); passed += 1; console.log("ok - " + name) }

test("file URLs become paths; others are skipped", () => {
  const r = M.pathsFromUrls([
    "file:///home/u/My%20Docs/a%23b.txt", "file://localhost/home/u/x", "https://example.com/a",
    "file:///home/u/../etc/passwd", "file:///home/u/My%20Docs/a%23b.txt", "file:///home/u/bad%E0%A4%A"
  ])
  assert.deepStrictEqual(r.paths, ["/home/u/My Docs/a#b.txt", "/home/u/x"])
  assert.strictEqual(r.skipped, 3)
})

test("plain paths", () => {
  assert.strictEqual(M.plainPath("/a//b/./c/"), "/a/b/c")
  assert.strictEqual(M.plainPath("rel/a"), "")
  assert.strictEqual(M.plainPath("/"), "")
  assert.strictEqual(M.plainPath("/a/../b"), "")
  assert.strictEqual(M.plainPath("/a\nb"), "")
})

test("uri-list round trips through the URL parser", () => {
  const items = [{ path: "/home/u/My Docs/50% off #1.txt" }, { path: "/home/u/ñandú.png" }]
  const list = M.uriList(items)
  assert.ok(list.endsWith("\r\n"))
  const back = M.pathsFromUrls(list.trim().split("\r\n"))
  assert.deepStrictEqual(back.paths, items.map(i => i.path))
})

test("merge dedupes, refuses missing, caps", () => {
  const base = [{ path: "/a", kind: "file", size: 1, addedAt: 1 }]
  const r = M.merge(base, [
    { path: "/a", kind: "file", size: 1 }, { path: "/b", kind: "folder", size: -1 },
    { path: "/c", kind: "missing", size: -1 }, { path: "/d", kind: "other", size: -1 }, { path: "x", kind: "invalid" }
  ], 5)
  assert.deepStrictEqual(r.items.map(i => i.path), ["/a", "/b"])
  assert.strictEqual(r.added, 1); assert.strictEqual(r.duplicates, 1); assert.strictEqual(r.invalid, 3)
  const many = []
  for (let i = 0; i < M.MAX_ITEMS + 3; i++) many.push({ path: "/f" + i, kind: "file", size: 0 })
  const capped = M.merge([], many, 0)
  assert.strictEqual(capped.items.length, M.MAX_ITEMS); assert.strictEqual(capped.overflow, 3)
})

test("refresh marks vanished items missing and keeps order", () => {
  const items = [{ path: "/a", kind: "file", size: 1, addedAt: 1 }, { path: "/b", kind: "file", size: 2, addedAt: 2 }]
  const r = M.refresh(items, [{ path: "/b", kind: "missing", size: -1 }, { path: "/a", kind: "file", size: 9 }])
  assert.deepStrictEqual(r.map(i => [i.path, i.kind, i.size]), [["/a", "file", 9], ["/b", "missing", -1]])
  assert.deepStrictEqual(M.missingPaths(r), ["/b"])
  assert.deepStrictEqual(M.deliverable(r).map(i => i.path), ["/a"])
})

test("after delivery: move clears delivered, copy follows keepAfterCopy", () => {
  const items = [{ path: "/a" }, { path: "/b" }, { path: "/c" }]
  const results = [{ path: "/a", ok: true }, { path: "/b", ok: false }]
  assert.deepStrictEqual(M.afterDelivery(items, results, "move", true).map(i => i.path), ["/b", "/c"])
  assert.deepStrictEqual(M.afterDelivery(items, results, "copy", false).map(i => i.path), ["/b", "/c"])
  assert.deepStrictEqual(M.afterDelivery(items, results, "copy", true).map(i => i.path), ["/a", "/b", "/c"])
})

test("a move drag takes vanished items off the shelf and keeps watching the rest", () => {
  const items = [{ path: "/a" }, { path: "/b" }, { path: "/c" }]
  const watched = { "/a": true, "/b": true }
  const r = M.takeMoved(items, [{ path: "/a", kind: "missing" }, { path: "/b", kind: "folder" }, { path: "/c", kind: "missing" }], watched)
  assert.deepStrictEqual(r.items.map(i => i.path), ["/b", "/c"])
  assert.strictEqual(r.moved, 1)
  assert.deepStrictEqual(r.watched, { "/b": true })
})

test("recent targets: newest first, deduped, capped", () => {
  let r = []
  for (const t of ["/1", "/2", "/3", "/2", "/4", "/5", "/6", "rel"]) r = M.rememberTarget(r, t)
  assert.deepStrictEqual(r, ["/6", "/5", "/4", "/2", "/3"])
})

test("state parse is defensive and round trips", () => {
  assert.strictEqual(M.parseState("{trunc"), null)
  const s = M.parseState(JSON.stringify({ mode: "move", recents: ["/t", "/t", "x"],
    items: [{ path: "/a", kind: "file", size: 3, addedAt: 1 }, { path: "/a" }, { path: "rel" }, { path: "/b", kind: "weird" }] }))
  assert.strictEqual(s.mode, "move")
  assert.deepStrictEqual(s.recents, ["/t"])
  assert.deepStrictEqual(s.items.map(i => [i.path, i.kind]), [["/a", "file"], ["/b", "file"]])
  assert.deepStrictEqual(M.parseState(M.serializeState(s)), s)
  assert.deepStrictEqual(M.parseState("{}"), { items: [], mode: "copy", recents: [], remotes: [], pinned: false })
  assert.strictEqual(M.parseState(M.serializeState({ items: [], mode: "copy", recents: [], pinned: true })).pinned, true)
  assert.strictEqual(M.parseState('{"pinned":"yes"}').pinned, false)
})

test("labels", () => {
  assert.strictEqual(M.formatSize(500), "500 B")
  assert.strictEqual(M.formatSize(1536), "1.5 KB")
  assert.strictEqual(M.formatSize(25 * 1024 * 1024), "25 MB")
  assert.strictEqual(M.parentDir("/home/u/Pictures/a.png", "/home/u"), "~/Pictures")
  assert.strictEqual(M.parentDir("/a.png", "/home/u"), "/")
  assert.strictEqual(M.summary([]), "Empty. Drag files onto the shelf in the bar.")
  assert.strictEqual(M.summary([{ kind: "file", size: 2048 }, { kind: "file", size: 0 }]), "2 files (2.0 KB)")
  assert.strictEqual(M.summary([{ kind: "folder" }, { kind: "missing" }]), "1 folder · 1 missing")
  assert.strictEqual(M.summary([{ kind: "file", size: 5 }, { kind: "folder" }]), "1 file (5 B), 1 folder")
  assert.strictEqual(M.barLabel(3, null, false), "3")
  assert.strictEqual(M.barLabel(0, null, true), "Drop to stage")
  assert.strictEqual(M.progressLabel({ mode: "move", index: 1, count: 4, bytes: 50, total: 200 }), "Moving 2/4 25%")
  assert.strictEqual(M.deliverySummary("copy", 2, 0, false, "/home/u/x", "/home/u"), "Copied 2 items to ~/x")
  assert.strictEqual(M.deliverySummary("move", 1, 1, false, "/x", ""), "Moved 1, 1 failed (they stay on the shelf)")
})

test("helper lines and picker output", () => {
  assert.deepStrictEqual(M.parseLine('{"type":"done","ok":1}'), { type: "done", ok: 1 })
  assert.strictEqual(M.parseLine('{"type":"do'), null)
  assert.strictEqual(M.parseLine("garbage"), null)
  assert.strictEqual(M.pickedFolder("\n/home/u/Docs\n/other\n"), "/home/u/Docs")
  assert.strictEqual(M.pickedFolder("relative\n"), "")
})

test("zip mode survives state and behaves like copy on the shelf", () => {
  assert.strictEqual(M.parseState('{"mode":"zip"}').mode, "zip")
  assert.strictEqual(M.parseState('{"mode":"rm -rf"}').mode, "copy")
  const items = [{ path: "/a" }, { path: "/b" }]
  assert.deepStrictEqual(M.afterDelivery(items, [{ path: "/a", ok: true }], "zip", false).map(i => i.path), ["/b"])
  assert.deepStrictEqual(M.afterDelivery(items, [{ path: "/a", ok: true }], "zip", true).map(i => i.path), ["/a", "/b"])
  assert.strictEqual(M.progressLabel({ mode: "zip", index: 0, count: 2, bytes: 0, total: 0 }), "Zipping 1/2")
  assert.strictEqual(M.deliverySummary("zip", 2, 0, false, "/x", ""), "Zipped 2 items to /x")
})

test("clipboard: uri-list, gnome copied files, plain paths; other text ignored", () => {
  assert.deepStrictEqual(M.clipboardPaths("file:///a/b%20c.txt\r\nfile:///d\r\n").paths, ["/a/b c.txt", "/d"])
  assert.deepStrictEqual(M.clipboardPaths("cut\nfile:///x/y\n").paths, ["/x/y"])
  assert.deepStrictEqual(M.clipboardPaths("/etc/hosts\nhunter2\n  /tmp/a b  \nrelative/x").paths, ["/etc/hosts", "/tmp/a b"])
  assert.deepStrictEqual(M.clipboardPaths("my password is hunter2").paths, [])
  assert.deepStrictEqual(M.clipboardPaths("# comment\nhttps://example.com").paths, [])
})

test("remote targets: hosts, folders, recents", () => {
  assert.deepStrictEqual(M.offeredHosts(["buildbox", "nas", "-bad"], ""), ["buildbox", "nas"])
  assert.deepStrictEqual(M.offeredHosts(["buildbox", "nas"], " nas, -x ,pi"), ["nas", "pi"])
  assert.strictEqual(M.validRemoteDir("~/in box"), true)
  assert.strictEqual(M.validRemoteDir("a\nb"), false)
  assert.strictEqual(M.validRemoteDir("  "), false)
  let r = []
  for (const [h, d] of [["a", "~/x"], ["b", "/y"], ["a", "~/x "], ["-o", "/z"]]) r = M.rememberRemote(r, h, d)
  assert.deepStrictEqual(r.map(M.remoteLabel), ["a:~/x", "b:/y"])
  assert.strictEqual(M.lastDirFor(r, "b"), "/y")
  assert.strictEqual(M.lastDirFor(r, "c"), "~/Downloads")
  const s = M.parseState(M.serializeState({ items: [], mode: "copy", recents: [], remotes: r.concat([{ host: "bad host", dir: "/" }]), pinned: false }))
  assert.deepStrictEqual(s.remotes, r)
  assert.strictEqual(M.deliverySummary("copy", 1, 0, false, "a:~/x", "", true), "Sent 1 item to a:~/x")
})

test("paths text for the clipboard", () => {
  assert.strictEqual(M.pathsText([{ path: "/a" }, { path: "/b c" }]), "/a\n/b c\n")
  assert.strictEqual(M.pathsText([]), "")
})

console.log(passed + " tests passed")
