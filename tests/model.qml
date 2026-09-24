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

    // Overrides: the first Enter only arms and says what it will do.
    fs._showCard({ store: "flatpak", id: "org.gimp.GIMP", name: "GIMP", permissions: {} })
    fs.overrides = "Context.filesystems=home"
    fs.queue()
    t.ok(fs.overridesArmed, "first Enter arms")
    // busy is set synchronously by every write; Process.running is not.
    t.ok(!fs.busy, "first Enter must not write")
    t.ok(fs.message.indexOf("Context.filesystems=home") >= 0, "the message names the override: " + fs.message)

    // Editing the overrides after arming disarms: confirm what you see.
    fs.overrides = "Context.filesystems=xdg-pictures:ro"
    t.ok(!fs.overridesArmed, "editing the overrides disarms")

    // Any other key disarms too (Menu.qml calls disarm()).
    fs.queue(); fs.disarm()
    t.ok(!fs.overridesArmed, "disarm() clears the override confirmation")

    // Arm, then confirm: now it writes, with the override on argv.
    fs.queue(); fs.queue()
    t.ok(fs.busy, "second Enter writes")
    t.ok(fs._writer.command.join(" ").indexOf("--override Context.filesystems=xdg-pictures:ro") >= 0,
         "argv carries the override: " + fs._writer.command.join(" "))

    // No overrides: one Enter, as before.
    fs.busy = false
    fs._showCard({ store: "flatpak", id: "org.gnome.Calculator", name: "Calculator", permissions: {} })
    fs.queue()
    t.ok(!fs.overridesArmed, "no overrides: nothing to confirm")

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
