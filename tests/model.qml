// FlatsnapModel's confirmation and channel rules, without a window.
//
// Run: bash tests/model.sh
// Prints "model: N passed, M failed" and exits; nothing is drawn and the
// keyboard is never taken, so it is safe on a live desktop. Not in
// `nix flake check`: Quickshell needs a Wayland display to start at all.
import QtQuick
import Quickshell

ShellRoot {
  id: t
  property int pass: 0
  property int fail: 0
  function ok(cond, what) {
    if (cond) pass++
    else { fail++; console.log("FAIL:", what) }
  }

  FlatsnapModel { id: fs }

  Component.onCompleted: {
    // Channels: only what the snap publishes, in risk order.
    fs._showCard({ store: "snap", id: "code", name: "code", channels: ["stable"], confinement: "classic", classic: true })
    fs.cycleChannel()
    t.ok(fs.channel === "stable", "a stable-only snap stays on stable, got " + fs.channel)

    fs._showCard({ store: "snap", id: "hello-world", name: "Hello", channels: ["beta", "edge", "stable"] })
    fs.cycleChannel(); t.ok(fs.channel === "beta", "stable -> beta (candidate skipped), got " + fs.channel)
    fs.cycleChannel(); t.ok(fs.channel === "edge", "beta -> edge, got " + fs.channel)
    fs.cycleChannel(); t.ok(fs.channel === "stable", "edge wraps to stable, got " + fs.channel)

    fs._showCard({ store: "snap", id: "x-y", name: "XY" })
    fs.cycleChannel(); t.ok(fs.channel === "candidate", "no channel list: all four, got " + fs.channel)

    // Confinement follows the channel: classic on edge forces --classic,
    // back on a strict channel it goes -- unless x x chose it.
    fs._showCard({ store: "snap", id: "tool", name: "Tool", channels: ["edge", "stable"],
                   confinement: "strict", confinements: { stable: "strict", edge: "classic" } })
    t.ok(!fs.classic, "strict stable: not classic")
    fs.cycleChannel()
    t.ok(fs.channel === "edge" && fs.classic && fs.card.confinement === "classic", "edge is classic: forced, card updated")
    fs.cycleChannel()
    t.ok(fs.channel === "stable" && !fs.classic && fs.card.confinement === "strict", "back to strict stable: classic dropped")
    fs.toggleClassic(); fs.toggleClassic()
    t.ok(fs.classic, "x x on strict stable chooses classic")
    fs.cycleChannel(); fs.cycleChannel()
    t.ok(fs.channel === "stable" && fs.classic, "a chosen classic survives cycling back")

    // The CLI's sandboxEscapes (ESCAPES_JSON in bin/nixarchy-flatsnap), as a
    // flatpak card carries it. tests/cli.sh checks the CLI's own copy.
    var esc = [
      { section: "Context", key: "filesystems", values: ["host", "host-os", "host-etc"], says: "the host filesystem" },
      { section: "Context", key: "filesystems", values: ["home", "~"], says: "your whole home folder" },
      { section: "Context", key: "sockets", values: ["session-bus"], says: "the whole session bus" },
      { section: "Context", key: "sockets", values: ["system-bus"], says: "the whole system bus" },
      { section: "Context", key: "sockets", values: ["ssh-auth"], says: "your SSH agent and its keys" },
      { section: "Context", key: "sockets", values: ["gpg-agent"], says: "your GPG agent and its keys" },
      { section: "Context", key: "devices", values: ["all"], says: "every device" },
      { section: "Session Bus Policy", key: "org.freedesktop.Flatpak", values: ["talk", "own"], says: "running commands outside the sandbox" },
      { section: "System Bus Policy", key: "*", values: ["talk", "own"], says: "talking to system services" }
    ]

    // Overrides: the first Enter only arms and says what it will do.
    fs._showCard({ store: "flatpak", id: "org.gimp.GIMP", name: "GIMP", permissions: {}, sandboxEscapes: esc })
    fs.overrides = "Context.filesystems=home"
    fs.queue()
    t.ok(fs.queueArmed, "first Enter arms")
    // busy is set synchronously by every write; Process.running is not.
    t.ok(!fs.busy, "first Enter must not write")
    t.ok(fs.message.indexOf("Context.filesystems=home") >= 0 && fs.message.indexOf("ESCAPES") >= 0,
         "the message names the escaping override: " + fs.message)

    // Editing the overrides after arming disarms: confirm what you see.
    fs.overrides = "Context.filesystems=xdg-pictures:ro"
    t.ok(!fs.queueArmed, "editing the overrides disarms")

    // Any other key disarms too (Menu.qml calls disarm()).
    fs.queue(); fs.disarm()
    t.ok(!fs.queueArmed, "disarm() clears the override confirmation")

    // Arm, then confirm: now it writes, with the override on argv.
    fs.queue(); fs.queue()
    t.ok(fs.busy, "second Enter writes")
    t.ok(fs._writer.command.join(" ").indexOf("--override Context.filesystems=xdg-pictures:ro") >= 0,
         "argv carries the override: " + fs._writer.command.join(" "))

    // No overrides: one Enter, as before.
    fs.busy = false
    fs._showCard({ store: "flatpak", id: "org.gnome.Calculator", name: "Calculator", permissions: {} })
    fs.queue()
    t.ok(!fs.queueArmed, "no overrides: nothing to confirm")

    // ---- #12: every classic snap confirms on Enter -----------------------
    fs.busy = false
    fs._showCard({ store: "snap", id: "code", name: "code", channels: ["stable"], confinement: "classic", classic: true })
    fs.queue()
    t.ok(fs.queueArmed && !fs.busy && fs.message.indexOf("WITHOUT a sandbox") >= 0,
         "store classic: the first Enter arms and says so: " + fs.message)
    fs.queue()
    t.ok(fs.busy && fs._writer.command.indexOf("--classic") >= 0, "store classic: the second Enter writes --classic")
    fs.busy = false

    fs._showCard({ store: "snap", id: "hello-world", name: "Hello", channels: ["stable"], confinement: "strict" })
    fs.toggleClassic(); fs.toggleClassic()
    fs.queue()
    t.ok(fs.queueArmed && !fs.busy && fs.message.indexOf("WITHOUT a sandbox") >= 0, "x x then Enter arms the same way")
    fs.toggleClassic()
    t.ok(!fs.queueArmed && !fs.classic, "toggleClassic() clears the arm")
    fs.queue()
    t.ok(fs.busy && fs._writer.command.indexOf("--classic") < 0, "a strict snap queues on one Enter")
    fs.busy = false

    fs._showCard({ store: "snap", id: "tool", name: "Tool", channels: ["edge", "stable"], confinement: "classic",
                   confinements: { stable: "classic", edge: "classic" }, classic: true })
    fs.queue(); fs.cycleChannel()
    t.ok(!fs.queueArmed, "cycleChannel() clears the arm")
    fs.queue()
    fs._showCard({ store: "flatpak", id: "org.gnome.Calculator", name: "Calculator", permissions: {}, sandboxEscapes: esc })
    t.ok(!fs.queueArmed, "a new card clears the arm")

    // ---- #12: sandbox escapes are named; other overrides are not -------
    // No Bus Policy case: the field splits on spaces, so a section with a
    // space cannot be typed there (see plan/, step 6).
    var escaping = ["Context.filesystems=home", "Context.filesystems=host:ro", "Context.filesystems=~",
                    "Context.sockets=system-bus", "Context.sockets=ssh-auth", "Context.sockets=gpg-agent",
                    "Context.devices=all"]
    for (var e = 0; e < escaping.length; e++) {
      fs.overrides = escaping[e]; fs.queue()
      t.ok(fs.queueArmed && !fs.busy && fs.message.indexOf("ESCAPES") >= 0 && fs.message.indexOf(escaping[e]) >= 0,
           escaping[e] + " is named as an escape: " + fs.message)
      fs.disarm()
    }
    var ordinary = ["Context.filesystems=xdg-pictures:ro", "Context.filesystems=~/Games",
                    "Context.filesystems=!host", "Context.features=devel", "Environment.LC_ALL=C.UTF-8"]
    for (var o = 0; o < ordinary.length; o++) {
      fs.overrides = ordinary[o]; fs.queue()
      t.ok(fs.queueArmed && fs.message.indexOf("ESCAPES") < 0 && fs.message.indexOf(ordinary[o]) >= 0,
           ordinary[o] + " gets the ordinary prompt: " + fs.message)
      fs.disarm()
    }
    // Only the escaping one is named when both are typed.
    fs.overrides = "Context.filesystems=xdg-pictures:ro Context.sockets=ssh-auth"; fs.queue()
    t.ok(fs.message.indexOf("ESCAPES") >= 0 && fs.message.indexOf("ssh-auth") >= 0, "mixed: the escape is named: " + fs.message)
    fs.disarm()
    // No list on the card (an older CLI): every override is treated as one.
    fs._showCard({ store: "flatpak", id: "org.gnome.Calculator", name: "Calculator", permissions: {} })
    fs.overrides = "Context.filesystems=xdg-pictures:ro"; fs.queue()
    t.ok(fs.message.indexOf("ESCAPES") >= 0, "no sandboxEscapes: warn as an escape: " + fs.message)
    fs.disarm(); fs.overrides = ""

    // ---- #12: removing a snap says its data goes -------------------------
    fs.tab = 1; fs.cursor = 0; fs.pendingDelete = ""
    fs.declared = [{ store: "snap", id: "code" }]
    fs.remove()
    t.ok(fs.message.indexOf("DELETES its data") >= 0, "snap removal says the data goes: " + fs.message)
    fs.disarm()
    fs.declared = [{ store: "flatpak", id: "org.gnome.Calculator" }]
    fs.remove()
    t.ok(fs.pendingDelete !== "" && fs.message.indexOf("DELETES") < 0, "flatpak removal does not: " + fs.message)
    fs.disarm(); fs.tab = 0

    // ---- #10: a running apply blocks edits and stays visible ------------
    // model.sh runs this on a PATH where nixarchy-apply is a stub.
    fs.busy = false
    var before = fs._writer.command.join(" ")
    fs.applying = true
    fs._showCard({ store: "flatpak", id: "org.gnome.Calculator", name: "Calculator", permissions: {} })
    fs.queue()
    t.ok(!fs.busy && fs._writer.command.join(" ") === before && fs.message.indexOf("rebuild is running") >= 0,
         "queue refused while applying: " + fs.message)
    fs.tab = 1; fs.declared = [{ store: "snap", id: "code" }]; fs.cursor = 0
    fs.remove()
    t.ok(!fs.busy && fs.pendingDelete === "" && fs.message.indexOf("rebuild is running") >= 0,
         "remove refused while applying: " + fs.message)

    fs.reset()
    t.ok(fs.showingLog, "reopening during an apply opens on the log")
    fs.applying = false
    fs.reset()
    t.ok(!fs.showingLog, "reopening after it opens on the lists")

    // B4: "checking…" survives _run.
    fs.applyArmed = false
    fs.apply()
    t.ok(fs.busy && fs.message === "checking…", "apply says checking…, got " + fs.message)
    fs.busy = false

    // The first a always arms and lists the changes; nothing is started.
    var hash = "ab".repeat(32)
    fs._onPreflight({ ok: true, willRemove: [], stateHash: hash,
                      changes: [{ op: "add", store: "flatpak", id: "org.a.B", detail: "" },
                                { op: "change", store: "snap", id: "code", detail: "channel stable → edge" }] })
    t.ok(fs.applyArmed && !fs._apply.running, "a good preflight arms and does not start")
    t.ok(fs.message.indexOf("+ org.a.B") >= 0 && fs.message.indexOf("~ code (channel stable → edge)") >= 0,
         "the message lists the changes: " + fs.message)
    var many = []
    for (var n = 0; n < 8; n++) many.push({ op: "remove", store: "flatpak", id: "org.x.A" + n, detail: "" })
    fs._onPreflight({ ok: true, willRemove: [], stateHash: hash, changes: many })
    t.ok(fs.message.indexOf("− org.x.A5") >= 0 && fs.message.indexOf("org.x.A6") < 0 && fs.message.indexOf("and 2 more") >= 0,
         "six changes, then a count: " + fs.message)
    fs._onPreflight({ ok: true, willRemove: [], stateHash: hash, changes: [] })
    t.ok(fs.applyArmed && fs.message.indexOf("nothing changed") === 0, "no changes still arms: " + fs.message)

    // The second a builds exactly the state preflight showed.
    fs.apply()
    var cmd = fs._apply.command
    t.ok(cmd.slice(cmd.length - 3).join(" ") === "apply --expect " + hash, "apply --expect <hash>: " + cmd.join(" "))
    t.ok(fs.applying && fs.showingLog, "the apply shows its log")

    // l brings the log back; an end while it is hidden is said in the message.
    fs.showingLog = false
    fs.showLog()
    t.ok(fs.showingLog, "showLog() shows the log")
    fs.showingLog = false
    fs._ended("applied")
    t.ok(fs.message === "applied — l shows the log", "hidden end is announced: " + fs.message)

    console.log("model: " + t.pass + " passed, " + t.fail + " failed")
    Qt.exit(t.fail === 0 ? 0 : 1)
  }
}
