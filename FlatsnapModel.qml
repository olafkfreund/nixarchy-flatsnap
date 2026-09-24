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
  property bool classicChosen: false  // x x on a channel the store publishes strict
  property string overrides: ""       // "Section.key=value ..." for Flatpaks
  // The next Enter queues: a classic snap or any override leaves or widens
  // a sandbox, so the first Enter only says what it will do.
  property bool queueArmed: false
  onOverridesChanged: queueArmed = false

  property string pendingDelete: ""   // "store:id" waiting for y
  property var willRemove: []         // from preflight, when uninstallUnmanaged is on
  property bool applyArmed: false

  property var applyLog: []
  property bool applying: false
  property bool showingLog: false
  property bool _applyDone: false

  readonly property var rows: tab === 0 ? results : declared
  readonly property var current: rows.length > 0 ? rows[Math.min(cursor, rows.length - 1)] : null

  // Which view has the keys, and the footer's keys for it: only what does
  // something there, so the line stays short in a small window.
  readonly property string view: showingLog ? "log" : tab === 1 ? "declared" : card ? "card" : "add"
  readonly property string keysHint: {
    if (view === "log") return "j k PgUp PgDn scroll   Esc stops watching (the build carries on)"
    var s = view === "declared" ? "j k move   d remove   a apply   Tab Add"
          : view === "add" ? "Enter look up / open   Ctrl+F Flathub   Ctrl+S Snap   j k move   Tab Declared   a apply"
          : card.store === "snap" ? "j k PgUp PgDn scroll   c channel   x classic   Enter queue   a apply"
          : "j k PgUp PgDn scroll   p overrides   Enter queue   a apply"
    return s + (applyLog.length > 0 ? "   l log" : "") + "   Esc back"
  }

  // Reopening during a build opens on its log: the build is still running.
  function reset() {
    tab = 0; results = []; card = null; cursor = 0; message = ""
    pendingDelete = ""; applyArmed = false; willRemove = []; showingLog = applying
    list()
  }

  // `l`: back to the log after Esc, while it runs or after it ended.
  function showLog() { if (applyLog.length > 0) showingLog = true }

  readonly property string _rebuilding: "a rebuild is running — wait for it to finish"

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
    classicChosen = false
    classicArmed = false
    overrides = ""
    queueArmed = false
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
    queueArmed = false
    channel = all[(all.indexOf(channel) + 1) % all.length]
    // Confinement is per channel. A classic channel forces --classic (snap
    // install refuses it otherwise); a strict one keeps only what x x chose.
    var conf = (card.confinements || {})[channel]
    if (conf) {
      var c = Object.assign({}, card); c.confinement = conf; card = c
      classic = conf === "classic" || classicChosen
    }
  }

  // Turning classic ON takes two presses: it removes the sandbox. Turning
  // it off is one. A snap the store publishes as classic cannot be turned
  // off at all -- snap install refuses it without --classic.
  function toggleClassic() {
    if (!card || card.store !== "snap") return
    queueArmed = false
    if (classic) {
      if (card.confinement === "classic") { message = "this snap is only published with classic confinement"; return }
      // message too: x does not pass through Menu's disarm, and an
      // "Enter again: … WITHOUT a sandbox" from queue() is now untrue.
      classic = false; classicChosen = false; classicArmed = false; message = ""; return
    }
    if (!classicArmed) { classicArmed = true; message = "x again: run this snap WITHOUT a sandbox"; return }
    classic = true; classicChosen = true; classicArmed = false; message = ""
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

  // Not while a build reads the file: apply holds its lock until it ends.
  function queue() {
    if (!card || busy) return
    if (applying) { message = _rebuilding; return }
    var args
    if (card.store === "snap") {
      args = ["add", "snap", card.id, "--channel", channel]
      // Classic, whether the store or x x chose it: Enter twice, as overrides.
      if (classic && !queueArmed) {
        queueArmed = true
        message = "Enter again: install " + card.id + " WITHOUT a sandbox (classic confinement)"
        return
      }
      if (classic) args.push("--classic")
    } else {
      args = ["add", "flatpak", card.id]
      var ov = overrides.trim().split(/\s+/).filter(function (s) { return s.length > 0 })
      // An override widens (or narrows) the sandbox, so it is confirmed the
      // way classic confinement is: the first Enter says what it will do,
      // and names the ones on the CLI's escape list with what they grant.
      if (ov.length > 0 && !queueArmed) {
        queueArmed = true
        var esc = ov.map(_escapes).filter(function (s) { return s !== "" })
        message = esc.length > 0
          ? "Enter again: " + card.id + " ESCAPES its sandbox — " + esc.join("; ")
          : "Enter again: change " + card.id + "'s sandbox with " + ov.join("  ")
        return
      }
      for (var i = 0; i < ov.length; i++) args.push("--override", ov[i])
    }
    queueArmed = false
    _after = card.name + " queued — a applies"
    _run(_writer, args)
  }

  // "<override>: <what it grants>" when the card's sandboxEscapes (from the
  // CLI) lists it, else "". A card without the list is an older CLI: every
  // override counts, so losing the list warns more, never less.
  function _escapes(o) {
    var list = card ? card.sandboxEscapes : undefined
    if (!Array.isArray(list)) return o + ": not checked (no list from nixarchy-flatsnap)"
    var m = /^([A-Za-z][A-Za-z ]{0,40})\.([A-Za-z0-9_.-]{1,100})=(.+)$/.exec(o)
    if (!m) return ""
    var v = m[3].replace(/:(ro|rw|create)$/, "")
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (e.section === m[1] && (e.key === "*" || e.key === m[2]) && e.values.indexOf(v) >= 0)
        return o + ": " + e.says
    }
    return ""
  }

  function remove() {
    var r = current
    if (tab !== 1 || !r || busy) return
    if (applying) { message = _rebuilding; return }
    var key = r.store + ":" + r.id
    // snap remove --purge (see the reconciler): the data goes with the snap.
    if (pendingDelete !== key) {
      pendingDelete = key
      message = r.store === "snap"
        ? "y removes " + r.id + " at the next apply and DELETES its data (no snapshot); any other key keeps it"
        : "y removes " + r.id + " at the next apply; any other key keeps it"
      return
    }
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

  // First `a` asks what the apply would do and says so; a second `a` builds
  // exactly that state (--expect), and any other key cancels.
  property Process _preflight: Process {
    stdout: StdioCollector {
      onStreamFinished: { root.busy = false; root._onPreflight(root._parse(text)) }
    }
  }
  property string _stateHash: ""

  function _onPreflight(d) {
    if (d.error || !d.ok) { message = d.error || d.message; return }
    willRemove = d.willRemove || []
    _stateHash = d.stateHash || ""
    var sign = { add: "+ ", remove: "− ", change: "~ " }
    var ch = (d.changes || []).map(function (c) {
      return sign[c.op] + c.id + (c.detail ? " (" + c.detail + ")" : "")
    })
    var lines = ch.slice(0, 6)
    if (ch.length > 6) lines.push("and " + (ch.length - 6) + " more")
    if (willRemove.length > 0)
      lines.push("this apply also REMOVES " + willRemove.join(", ") + " (uninstallUnmanaged is on)")
    applyArmed = true
    message = lines.length === 0
      ? "nothing changed since the last apply — a again rebuilds anyway"
      : lines.join("\n") + "\na again applies; any other key cancels"
  }

  function apply() {
    if (applying || busy) return
    if (applyArmed) { applyArmed = false; _startApply(); return }
    _run(_preflight, ["preflight"])
    message = "checking…"   // after _run, which clears it
  }

  function disarm() { applyArmed = false; classicArmed = false; queueArmed = false; pendingDelete = "" }

  function _startApply() {
    _applyDone = false
    applyLog = ["starting rebuild…  ESC stops watching; the build carries on"]
    applying = true; showingLog = true; message = ""
    _apply.command = [script, "apply", "--expect", _stateHash]
    _apply.running = true
  }

  // The end of an apply, also said in the message line when the log is hidden.
  function _ended(text) {
    _log("— " + text + " —")
    if (!showingLog) message = text + " — l shows the log"
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
              root._ended(r.ok ? "applied" : "apply failed: " + r.message)
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
        root._ended("the apply ended without a result; see the log")
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
