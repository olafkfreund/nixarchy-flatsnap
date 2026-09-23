import QtQuick
import Quickshell.Io

// State and the adapter. Every rule about what is allowed lives in
// bin/nixarchy-flatsnap; this only runs it with an argv array (never a
// shell string) and reads JSON back. Everything shown is plain text.
QtObject {
  id: root

  readonly property string script:
    Qt.resolvedUrl("bin/nixarchy-flatsnap").toString().replace(/^file:\/\//, "")

  property int tab: 0                 // 0 Add, 1 Declared
  property var results: []            // search hits or "which store?" candidates
  property var card: null             // one resolved app, ready to queue
  property var declared: []
  property int cursor: 0
  property string message: ""
  property bool busy: false

  // The card's editable choices.
  property string channel: "stable"
  property bool classic: false
  property bool classicArmed: false   // first x arms, second x confirms
  property string overrides: ""       // "Section.key=value ..." for Flatpaks
  property bool overridesArmed: false // overrides widen a sandbox: Enter twice
  onOverridesChanged: overridesArmed = false

  property string pendingDelete: ""   // "store:id" waiting for y
  property var willRemove: []         // from preflight, when uninstallUnmanaged is on
  property bool applyArmed: false

  property var applyLog: []
  property bool applying: false
  property bool showingLog: false
  property bool _applyDone: false

  readonly property var rows: tab === 0 ? results : declared
  readonly property var current: rows.length > 0 ? rows[Math.min(cursor, rows.length - 1)] : null

  function reset() {
    tab = 0; results = []; card = null; cursor = 0; message = ""
    pendingDelete = ""; applyArmed = false; willRemove = []; showingLog = false
    list()
  }

  function setTab(t) {
    tab = (t + 2) % 2; cursor = 0; pendingDelete = ""
    if (tab === 1) list()
  }

  function moveCursor(d) {
    if (rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + d))
  }

  // ---- adapter plumbing ----------------------------------------------

  function _parse(text) {
    try { return JSON.parse(text) }
    catch (e) { return { error: "no answer from nixarchy-flatsnap" } }
  }

  // Lookups and searches. One at a time: a new one replaces the old.
  property Process _query: Process {
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        var d = root._parse(text)
        if (d.error) { root.message = d.error; return }
        if (Array.isArray(d)) {
          root.results = d; root.card = null; root.cursor = 0
          root.message = d.length === 0 ? "nothing found" : ""
        } else if (d.store === "ask") {
          root.results = d.candidates; root.card = null; root.cursor = 0
          root.message = "found in more than one place — pick one"
        } else {
          root._showCard(d)
        }
      }
    }
  }

  function _run(p, args) {
    busy = true; message = ""
    p.command = [script].concat(args)
    p.running = true
  }

  function resolve(text) {
    if (text.trim().length === 0) return
    _run(_query, ["resolve", text])
  }

  function search(store, text) {
    if (text.trim().length === 0) { message = "type something to search for"; return }
    tab = 0
    _run(_query, ["search", store, text])
  }

  // A row from a search or a candidate list. Snap candidates arrive complete;
  // a Flathub hit has no permissions yet, so it is looked up first.
  function pick() {
    var r = current
    if (!r || tab !== 0) return
    if (r.permissions !== undefined || r.confinement !== undefined) _showCard(r)
    else resolve(r.store === "snap" ? "https://snapcraft.io/" + r.id : r.id)
  }

  function _showCard(d) {
    card = d
    channel = d.channel || "stable"
    classic = d.classic === true
    classicArmed = false
    overrides = ""
    message = ""
  }

  // Only the channels this snap actually publishes, in risk order; a
  // channel it does not have would queue fine and fail at apply. No list
  // from the store means no way to know, so all four are offered.
  function cycleChannel() {
    if (!card || card.store !== "snap") return
    var order = ["stable", "candidate", "beta", "edge"]
    var have = card.channels || []
    var all = have.length ? order.filter(function (c) { return have.indexOf(c) >= 0 }) : order
    if (all.length === 0) return
    channel = all[(all.indexOf(channel) + 1) % all.length]
  }

  // Turning classic ON takes two presses: it removes the sandbox. Turning
  // it off is one. A snap the store publishes as classic cannot be turned
  // off at all -- snap install refuses it without --classic.
  function toggleClassic() {
    if (!card || card.store !== "snap") return
    if (classic) {
      if (card.confinement === "classic") { message = "this snap is only published with classic confinement"; return }
      classic = false; classicArmed = false; return
    }
    if (!classicArmed) { classicArmed = true; message = "x again: run this snap WITHOUT a sandbox"; return }
    classic = true; classicArmed = false; message = ""
  }

  // ---- the file --------------------------------------------------------

  property Process _writer: Process {
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        var d = root._parse(text)
        if (d.error) { root.message = d.error; return }
        root.declared = d
        root.message = root._after
        root.card = null
        root.pendingDelete = ""
      }
    }
  }
  property string _after: ""

  function queue() {
    if (!card || busy) return
    var args
    if (card.store === "snap") {
      args = ["add", "snap", card.id, "--channel", channel]
      if (classic) args.push("--classic")
    } else {
      args = ["add", "flatpak", card.id]
      var ov = overrides.trim().split(/\s+/).filter(function (s) { return s.length > 0 })
      // An override widens (or narrows) the sandbox, so it is confirmed the
      // way classic confinement is: the first Enter says what it will do.
      if (ov.length > 0 && !overridesArmed) {
        overridesArmed = true
        message = "Enter again: change " + card.id + "'s sandbox with " + ov.join("  ")
        return
      }
      overridesArmed = false
      for (var i = 0; i < ov.length; i++) args.push("--override", ov[i])
    }
    _after = card.name + " queued — a applies"
    _run(_writer, args)
  }

  function remove() {
    var r = current
    if (tab !== 1 || !r || busy) return
    var key = r.store + ":" + r.id
    if (pendingDelete !== key) { pendingDelete = key; message = "y removes " + r.id + " at the next apply; any other key keeps it"; return }
    _after = r.id + " removed — a applies"
    _run(_writer, ["rm", r.store, r.id])
  }

  property Process _lister: Process {
    stdout: StdioCollector {
      onStreamFinished: {
        var d = root._parse(text)
        if (d.error) { root.message = d.error; return }
        root.declared = d
      }
    }
  }
  function list() { _lister.command = [script, "list"]; _lister.running = true }

  // ---- apply -------------------------------------------------------------

  // First `a` asks what the apply would do. If it removes Flatpaks nobody
  // declared (uninstallUnmanaged), that is said, and a second `a` goes ahead.
  property Process _preflight: Process {
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        var d = root._parse(text)
        if (d.error || !d.ok) { root.message = d.error || d.message; return }
        root.willRemove = d.willRemove || []
        if (root.willRemove.length > 0) {
          root.applyArmed = true
          root.message = "a again: this apply also REMOVES " + root.willRemove.join(", ")
            + " (uninstallUnmanaged is on)"
        } else {
          root._startApply()
        }
      }
    }
  }

  function apply() {
    if (applying || busy) return
    if (applyArmed) { applyArmed = false; _startApply(); return }
    message = "checking…"
    _run(_preflight, ["preflight"])
  }

  function disarm() { applyArmed = false; classicArmed = false; overridesArmed = false; pendingDelete = "" }

  function _startApply() {
    _applyDone = false
    applyLog = ["starting rebuild…  ESC stops watching; the build carries on"]
    applying = true; showingLog = true; message = ""
    _apply.command = [script, "apply"]
    _apply.running = true
  }

  property Process _apply: Process {
    stdout: SplitParser {
      onRead: function (line) {
        var s = String(line)
        // Only our own record ends the apply; a build can print JSON too.
        if (s.indexOf("{\"nixarchyFlatsnapApply\"") === 0) {
          try {
            var r = JSON.parse(s).nixarchyFlatsnapApply
            if (r && typeof r.ok === "boolean") {
              root._applyDone = true; root.applying = false
              root._log(r.ok ? "— applied —" : "— failed: " + r.message + " —")
              root.list()
              return
            }
          } catch (e) {}
        }
        if (s.indexOf("{\"error\"") === 0) {
          try { s = "— " + JSON.parse(s).error + " —" } catch (e) {}
        }
        root._log(s)
      }
    }
    onExited: function (exitCode, exitStatus) {
      Qt.callLater(function () {
        if (root._applyDone) return
        root.applying = false
        root._log("— the apply ended without a result; see above —")
      })
    }
  }

  function _log(s) {
    var l = applyLog.slice()
    l.push(s)
    if (l.length > 2000) l = l.slice(l.length - 2000)
    applyLog = l
  }
}
