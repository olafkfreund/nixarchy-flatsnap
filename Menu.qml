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

  // `typing`: the footer offers no letter key while a field would take it.
  FlatsnapModel { id: fs; typing: field.activeFocus || ovField.activeFocus }
  // A build found by the status query on open arrives after open() has
  // placed the keyboard: move it to Esc/l then.
  Connections {
    target: fs
    function onApplyingChanged() { if (root.opened && fs.applying && fs.showingLog) root.focusKeys() }
  }

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
  // j k, Up Down, PgUp PgDn: how far they scroll `view`, or 0 for any other key.
  function scrollKey(k, bare, view) {
    if (k === Qt.Key_Down || (bare && k === Qt.Key_J)) return lineMetrics.lineSpacing
    if (k === Qt.Key_Up || (bare && k === Qt.Key_K)) return -lineMetrics.lineSpacing
    if (k === Qt.Key_PageDown) return root.pageOf(view)
    if (k === Qt.Key_PageUp) return -root.pageOf(view)
    return 0
  }
  function scrollLog(dy) {
    root.scrollBy(logView, dy)
    logView.follow = logView.contentY >= logView.contentHeight - logView.height - 1
  }

  // Say `text` through the screen reader (#26). Assertive interrupts it:
  // kept for a pending confirmation. Qt before 6.8 has no announce(); the
  // menu then works as before, silently.
  function announce(item, text, urgent) {
    if (text.length === 0 || typeof item.Accessible.announce !== "function") return
    item.Accessible.announce(text, urgent ? Accessible.Assertive : Accessible.Polite)
  }
  function announceCard() { if (fs.card) root.announce(cardCol, cardCol.Accessible.name + ". " + cardCol.trustSummary, false) }

  // One line of plain text in the menu's colours. Everything shown here
  // came from a store or a build log, so it is never markup.
  component Line: Text {
    textFormat: Text.PlainText
    wrapMode: Text.Wrap
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    color: Color.menu.text
  }

  // There is more below the edge: say so, or a warning at the end of
  // a long card could go unseen. Over the content, on its own background.
  component MoreMarker: Rectangle {
    required property Flickable view
    visible: view.visible && view.contentY < view.contentHeight - view.height - 1
    anchors { right: view.right; bottom: view.bottom }
    width: moreText.implicitWidth + Style.space(12)
    height: moreText.implicitHeight
    radius: Style.cornerRadius
    color: Color.menu.background
    Line { id: moreText; anchors.centerIn: parent; opacity: 0.7; text: "↓ more (j)" }
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

          if (fs.showingLog) {
            // ESC leaves the build running: it is elevating and switching a
            // system, and stopping it half way is never what ESC meant.
            if (k === Qt.Key_Escape) { fs.showingLog = false; root.focusKeys(); event.accepted = true }
            else {
              var logDy = root.scrollKey(k, bare, logView)
              if (logDy !== 0) { root.scrollLog(logDy); event.accepted = true }
            }
            return
          }

          // A pending confirmation is cancelled by any other real key; the
          // rule, with its exceptions, is in the model.
          fs.keyPressed(k, bare, typing)

          // On a card, the move keys scroll it: the list they moved is hidden.
          // j k are letters, so they scroll only when no field has the
          // keyboard; the arrows and pages also take it back from a field,
          // which would otherwise scroll out of sight with the keyboard in it.
          if (fs.view === "card") {
            var dy = root.scrollKey(k, bare && !typing, cardView)
            if (dy !== 0) { root.scrollBy(cardView, dy); if (typing) root.focusKeys(); event.accepted = true; return }
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

          // One Flickable for every card: a new app starts at its top.
          // The keyboard stays on the keys, not the card: say which app it is (#26).
          Connections {
            target: fs
            function onCardChanged() {
              cardView.contentY = 0
              // Later: cardCol's bindings on fs.card may not have run yet.
              if (fs.card) Qt.callLater(root.announceCard)
            }
          }
          // A footer line appearing (the armed message) takes height from
          // the bottom: keep what was at the bottom edge in sight (#36).
          property real _lastHeight: 0
          onHeightChanged: { if (_lastHeight > 0) root.scrollBy(cardView, _lastHeight - height); _lastHeight = height }

          Column {
            id: cardCol
            width: cardView.width
            spacing: Style.space(6)
            readonly property var c: fs.card || ({})
            readonly property bool isSnap: c.store === "snap"

            // One named group per app; its description is what the urgent
            // lines below say, so it is heard without reading them all (#26).
            // The escape part reads escBlock's own state, never a copy of it.
            Accessible.role: Accessible.Grouping
            Accessible.name: (c.name || c.id || "") + ", " + (isSnap ? "Snap" : "Flatpak")
            Accessible.description: trustSummary
            readonly property string trustSummary: {
              var v = c.verified
              var s = v === true ? "publisher verified" : v === false ? "publisher not verified" : "publisher verification unknown"
              if (!isSnap && escBlock.escList.length > 0) s += ", escapes its sandbox"
              else if (!isSnap && escBlock.notChecked) s += ", sandbox escapes not checked"
              if (!isSnap && c.permissions === null) s += ", permissions unknown"
              if (isSnap && fs.classic) s += ", classic confinement, runs without a sandbox"
              return s
            }

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

            // Flatpak: what the app's own manifest asks for that is on the
            // CLI's escape list (manifestEscapes), with what each grants. A
            // label, not a second Enter. Only the heading is urgent: most
            // popular apps have one, and an all-red block teaches people to
            // skip red. null (failed lookup) is the UNKNOWN line below; a
            // card with permissions but no list is an older CLI, so say so.
            Column {
              id: escBlock
              readonly property var escList: Array.isArray(cardCol.c.manifestEscapes) ? cardCol.c.manifestEscapes : []
              readonly property bool notChecked: cardCol.c.manifestEscapes === undefined
                                                 && cardCol.c.permissions != null && typeof cardCol.c.permissions === "object"
              visible: !cardCol.isSnap && (escList.length > 0 || notChecked)
              width: parent.width
              Line {
                width: parent.width
                color: Color.urgent
                text: escBlock.notChecked ? "sandbox escapes: not checked (no list from nixarchy-flatsnap)" : "escapes its sandbox"
              }
              Line {
                visible: escBlock.escList.length > 0
                width: parent.width
                text: "  " + escBlock.escList.map(function (e) { return e.entry + ": " + e.says }).join("\n  ")
              }
            }

            // Flatpak: what the sandbox lets it reach. null is a failed
            // lookup: unknown, never "none listed".
            Line {
              visible: !cardCol.isSnap
              width: parent.width
              color: cardCol.c.permissions === null ? Color.urgent : Color.menu.text
              text: fs.permissionText(cardCol.c.permissions)
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
                // p may land here below the edge: scroll just enough to show it.
                onActiveFocusChanged: {
                  if (!activeFocus) return
                  var top = ovField.mapToItem(cardCol, 0, 0).y
                  var bottom = top + ovField.height
                  if (bottom > cardView.contentY + cardView.height) cardView.contentY = bottom - cardView.height
                  else if (top < cardView.contentY) cardView.contentY = top
                }
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

        MoreMarker { view: cardView }

        // ---- the list: search hits, candidates, or what is declared -----
        ListView {
          id: list
          visible: !cardView.visible && !fs.showingLog
          anchors { top: tabs.bottom; topMargin: Style.space(12); left: parent.left; right: parent.right; bottom: footer.top }
          clip: true
          model: root.opened ? fs.rows : []
          currentIndex: fs.cursor
          Accessible.role: Accessible.List
          Accessible.name: fs.tab === 0 ? "Add" : "Declared"
          delegate: Rectangle {
            required property var modelData
            required property int index
            // The row's own text, and the cursor, which is otherwise only colour (#26).
            Accessible.role: Accessible.ListItem
            Accessible.name: rowText.text
            Accessible.selected: index === fs.cursor
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
          // It follows new lines only while it is at its end: scrolled up to
          // read back, it stays put until scrolled back down.
          property bool follow: true
          function toEnd() { contentY = Math.max(0, contentHeight - height) }
          onContentHeightChanged: if (follow) toEnd()
          onHeightChanged: if (follow) toEnd()   // the footer grew: stay at the end (#36)
          Connections {
            target: fs
            function onShowingLogChanged() { if (fs.showingLog) { logView.follow = true; logView.toEnd() } }
          }
          Line { id: logText; width: logView.width; text: fs.applyLog.join("\n") }
        }
        MoreMarker { view: logView }

        Column {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          spacing: Style.space(4)
          Line {
            id: messageLine
            width: parent.width
            visible: fs.message.length > 0
            text: fs.message
            color: fs.armed ? Color.urgent : Color.menu.text
            // A prompt, not a status, by more than its colour (#26).
            Accessible.description: fs.armed ? "confirmation pending" : ""
          }
          // Every message is said; a pending confirmation interrupts (#26).
          // Each arming path sets its flag before its message (tests/model.qml).
          Connections {
            target: fs
            function onMessageChanged() { if (fs.message.length > 0) root.announce(messageLine, fs.message, fs.armed) }
          }
          Line {
            width: parent.width
            opacity: 0.7
            text: fs.keysHint   // only the keys for this view
          }
        }
      }
    }
  }
}
