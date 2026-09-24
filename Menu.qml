import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Install a Flatpak or a Snap: paste, look, queue, apply. Keyboard only.
//
// The field has the keyboard when the menu opens, because the usual way in
// is a paste. Enter looks it up and hands the keyboard to the card, where
// the single letters live; Esc steps back one level at a time.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var targetScreen: null

  function focusedScreen() {
    var name = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  function open(payloadJson) {
    root.targetScreen = root.focusedScreen()
    field.text = ""
    fs.reset()
    root.opened = true
    // During a build the panel opens on its log, and the keys go to Esc/l.
    Qt.callLater(function () { if (fs.applying) root.focusKeys(); else field.forceActiveFocus() })
  }
  function close() { root.opened = false }
  function toggle() { if (root.opened) root.close(); else root.open("{}") }
  function focusKeys() { field.focus = false; ovField.focus = false; keys.forceActiveFocus() }

  FlatsnapModel { id: fs }

  // A line of Line text: the scroll step, so it follows the text size.
  FontMetrics {
    id: lineMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.title
  }

  // Flickable has no key scrolling of its own; this is it, clamped to the content.
  function scrollBy(view, dy) {
    view.contentY = Math.max(0, Math.min(view.contentHeight - view.height, view.contentY + dy))
  }
  // A page keeps the last line of the old one in sight.
  function pageOf(view) { return view.height - lineMetrics.lineSpacing }

  // One line of plain text in the menu's colours. Everything shown here
  // came from a store or a build log, so it is never markup.
  component Line: Text {
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    color: Color.menu.text
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nixarchy-flatsnap-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: surface
      width: Math.min(Style.space(1000), Math.round(panel.width * 0.7))
      height: Math.min(Math.round(panel.height * 0.78), panel.height - Style.gapsOut * 2)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
      padding: Style.spacing.panelPadding
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      FocusScope {
        id: keys
        anchors.fill: parent
        anchors.topMargin: surface.contentTopInset
        anchors.rightMargin: surface.contentRightInset
        anchors.bottomMargin: surface.contentBottomInset
        anchors.leftMargin: surface.contentLeftInset
        focus: true

        Keys.onPressed: function (event) {
          var k = event.key
          var bare = event.modifiers === Qt.NoModifier
          var typing = field.activeFocus || ovField.activeFocus
          var modifier = k === Qt.Key_Shift || k === Qt.Key_Control || k === Qt.Key_Alt || k === Qt.Key_Meta

          if (fs.showingLog) {
            // ESC leaves the build running: it is elevating and switching a
            // system, and stopping it half way is never what ESC meant.
            if (k === Qt.Key_Escape) { fs.showingLog = false; root.focusKeys(); event.accepted = true }
            return
          }

          // A pending confirmation is cancelled by any other real key.
          var enter = k === Qt.Key_Return || k === Qt.Key_Enter
          if (!modifier && k !== Qt.Key_Y && k !== Qt.Key_A && k !== Qt.Key_X
              && !(enter && fs.queueArmed)
              && (fs.pendingDelete !== "" || fs.applyArmed || fs.classicArmed || fs.queueArmed)) {
            fs.disarm(); fs.message = ""
          }

          if (event.modifiers & Qt.ControlModifier) {
            if (k === Qt.Key_F) { fs.search("flatpak", field.text); root.focusKeys(); event.accepted = true; return }
            if (k === Qt.Key_S) { fs.search("snap", field.text); root.focusKeys(); event.accepted = true; return }
          }

          switch (k) {
            case Qt.Key_Escape:
              if (ovField.activeFocus) { root.focusKeys() }
              else if (fs.card) { fs.card = null; field.forceActiveFocus() }
              else if (fs.tab === 0 && fs.results.length > 0) { fs.results = []; field.forceActiveFocus() }
              else if (field.text.length > 0) { field.text = ""; field.forceActiveFocus() }
              else root.close()
              event.accepted = true; return
            case Qt.Key_Return:
            case Qt.Key_Enter:
              // Enter in the overrides field is the first of the two presses:
              // it leaves the field and asks to queue, which arms the confirm.
              if (ovField.activeFocus) { root.focusKeys(); fs.queue() }
              else if (field.activeFocus) { fs.resolve(field.text); root.focusKeys() }
              else if (fs.card) fs.queue()
              else fs.pick()
              event.accepted = true; return
            case Qt.Key_Tab:
            case Qt.Key_Backtab:
              fs.setTab(fs.tab + 1); root.focusKeys(); event.accepted = true; return
            case Qt.Key_Down: fs.moveCursor(1); if (typing) root.focusKeys(); event.accepted = true; return
            case Qt.Key_Up: fs.moveCursor(-1); event.accepted = true; return
          }

          // Single letters only when no field has the keyboard, or they
          // could not be typed into an app ID.
          if (typing || !bare) return
          switch (k) {
            case Qt.Key_J: fs.moveCursor(1); break
            case Qt.Key_K: fs.moveCursor(-1); break
            case Qt.Key_Slash: field.forceActiveFocus(); break
            case Qt.Key_C: fs.cycleChannel(); break
            case Qt.Key_X: fs.toggleClassic(); break
            case Qt.Key_P: if (fs.card && fs.card.store === "flatpak") ovField.forceActiveFocus(); break
            case Qt.Key_D: fs.remove(); break
            case Qt.Key_Y: if (fs.pendingDelete !== "") fs.remove(); break
            case Qt.Key_A: if (!event.isAutoRepeat) fs.apply(); break
            case Qt.Key_L: fs.showLog(); break
            default: return
          }
          event.accepted = true
        }

        TextField {
          id: field
          anchors { top: parent.top; left: parent.left; right: parent.right }
          placeholderText: "paste a Flathub / Snapcraft link, an app ID, or a snap name…"
          font.pixelSize: Style.font.title
          foreground: Color.menu.text
        }

        Line {
          id: tabs
          anchors { top: field.bottom; topMargin: Style.space(10); left: parent.left }
          text: (fs.tab === 0 ? "[ Add ]   Declared" : "  Add   [ Declared ]")
                + (fs.busy ? "     …" : "")
                + (fs.applying && !fs.showingLog ? "     rebuilding… l shows it" : "")
        }

        // ---- the card: one app, before it is queued ---------------------
        Flickable {
          id: cardView
          visible: fs.tab === 0 && fs.card !== null && !fs.showingLog
          anchors { top: tabs.bottom; topMargin: Style.space(12); left: parent.left; right: parent.right; bottom: footer.top }
          contentHeight: cardCol.implicitHeight
          clip: true

          Column {
            id: cardCol
            width: cardView.width
            spacing: Style.space(6)
            readonly property var c: fs.card || ({})
            readonly property bool isSnap: c.store === "snap"

            Line { text: (cardCol.c.name || "") + "   (" + (cardCol.isSnap ? "Snap" : "Flatpak") + ": " + (cardCol.c.id || "") + ")"; font.pixelSize: Style.font.heading; width: parent.width }
            Line { text: cardCol.c.summary || ""; width: parent.width }
            // Verified by the store, or not, or unknown (null or missing,
            // e.g. an older CLI): only unknown is urgent. A label, never a gate.
            Line {
              width: parent.width
              readonly property var v: cardCol.c.verified
              color: v == null ? Color.urgent : Color.menu.text
              text: "publisher: " + (cardCol.c.publisher || "unknown") + " — "
                    + (v === true ? "verified" + (cardCol.c.verifiedAs ? " (" + cardCol.c.verifiedAs + ")" : "")
                       : v === false ? "not verified by " + (cardCol.isSnap ? "the Snap Store" : "Flathub")
                       : "verification UNKNOWN")
            }
            Line { text: "license: " + (cardCol.c.license || "unknown"); width: parent.width }

            // Flatpak: what the sandbox lets it reach. null is a failed
            // lookup: unknown, never "none listed".
            Line {
              visible: !cardCol.isSnap
              width: parent.width
              color: cardCol.c.permissions === null ? Color.urgent : Color.menu.text
              text: {
                if (cardCol.c.permissions === null) return "permissions: UNKNOWN (the Flathub lookup failed)"
                var p = cardCol.c.permissions || {}
                var out = []
                for (var key in p) out.push(key + ": " + (Array.isArray(p[key]) ? p[key].join(", ") : JSON.stringify(p[key])))
                return out.length ? "permissions\n  " + out.join("\n  ") : "permissions: none listed"
              }
            }
            Row {
              visible: !cardCol.isSnap
              spacing: Style.space(8)
              Line { text: "overrides (p):"; anchors.verticalCenter: parent.verticalCenter }
              TextField {
                id: ovField
                width: cardView.width * 0.7
                placeholderText: "Context.filesystems=xdg-pictures:ro  Environment.LC_ALL=C.UTF-8"
                font.pixelSize: Style.font.title
                foreground: Color.menu.text
                text: fs.overrides
                onTextChanged: fs.overrides = text
              }
            }

            // Snap: channel, confinement, and the truth about both.
            Line {
              visible: cardCol.isSnap
              width: parent.width
              text: "channel (c): " + fs.channel + "    available: " + (cardCol.c.channels || []).join(", ")
                    + "\nconfinement (x): " + (fs.classic ? "classic" : "strict")
            }
            Line {
              visible: cardCol.isSnap && fs.classic
              width: parent.width
              color: Color.urgent
              text: "Classic: this snap runs without a sandbox, with everything your user can reach."
            }
            Line {
              visible: cardCol.isSnap
              width: parent.width
              color: Color.urgent
              text: "Snap confinement on NixOS is weaker than on Ubuntu: no AppArmor."
            }
            Line { text: "\nEnter queues it.  Nothing is installed until a applies."; width: parent.width }
          }
        }

        // ---- the list: search hits, candidates, or what is declared -----
        ListView {
          id: list
          visible: !cardView.visible && !fs.showingLog
          anchors { top: tabs.bottom; topMargin: Style.space(12); left: parent.left; right: parent.right; bottom: footer.top }
          clip: true
          model: root.opened ? fs.rows : []
          currentIndex: fs.cursor
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: rowText.implicitHeight + Style.space(8)
            radius: Style.cornerRadius
            color: index === fs.cursor ? Color.menu.selectedBackground : "transparent"
            Line {
              id: rowText
              anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(8) }
              color: index === fs.cursor ? Color.menu.selectedText : Color.menu.text
              text: {
                var d = modelData
                var s = (d.store === "snap" ? "snap     " : "flatpak  ") + d.id
                if (d.name && d.name !== d.id) s += "  — " + d.name
                if (d.channel) s += "   [" + d.channel + (d.classic ? ", classic" : "") + "]"
                // Search hits and candidates; unknown says nothing here, the card spells it out.
                if (d.verified === true) s += "   verified"
                else if (d.verified === false) s += "   unverified"
                if (d.installed === true) s += "   installed"
                else if (d.installed === false) s += "   not installed yet"
                if (fs.pendingDelete === d.store + ":" + d.id)
                  s += d.store === "snap" ? "   ← y removes it and its data" : "   ← y to remove"
                return s
              }
            }
          }
          Line {
            anchors.centerIn: parent
            visible: list.count === 0
            text: fs.tab === 0
                  ? "Paste and press Enter.  Ctrl+F searches Flathub, Ctrl+S the Snap Store."
                  : "Nothing declared yet."
          }
        }

        // ---- the build log --------------------------------------------------
        Flickable {
          id: logView
          visible: fs.showingLog
          anchors { top: tabs.bottom; topMargin: Style.space(12); left: parent.left; right: parent.right; bottom: footer.top }
          contentHeight: logText.implicitHeight
          clip: true
          onContentHeightChanged: contentY = Math.max(0, contentHeight - height)
          Line { id: logText; width: logView.width; text: fs.applyLog.join("\n") }
        }

        Column {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          spacing: Style.space(4)
          Line {
            width: parent.width
            visible: fs.message.length > 0
            text: fs.message
            color: (fs.applyArmed || fs.classicArmed || fs.queueArmed || fs.pendingDelete !== "") ? Color.urgent : Color.menu.text
          }
          Line {
            width: parent.width
            opacity: 0.7
            text: fs.showingLog ? "Esc stops watching (the build carries on)"
                : "Enter look up / queue   Ctrl+F Flathub   Ctrl+S Snap   Tab Add/Declared   j k move   c channel   x classic   p overrides   d remove   a apply   l log   Esc back"
          }
        }
      }
    }
  }
}
