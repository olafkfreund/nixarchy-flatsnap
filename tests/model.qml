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

    console.log("model: " + t.pass + " passed, " + t.fail + " failed")
    Qt.exit(t.fail === 0 ? 0 : 1)
  }
}
