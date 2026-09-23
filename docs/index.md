---
layout: home
---

<div class="prose lede" markdown="1">
Some software is only current as a **Flatpak** or a **Snap**. Paste the link,
see what the app can reach, queue it, and apply. It ends up in your NixOS
configuration, not in a terminal's scrollback.
</div>

<div class="hero">
<!-- Text, not a screenshot, until the live-shell check in plan step 6 is done.
     The values are GIMP's real Flathub metadata, via `nixarchy-flatsnap resolve`. -->
<pre aria-label="The Flatpak and Snap panel with a Flathub link pasted and GIMP's card showing">
 https://flathub.org/apps/org.gimp.GIMP▏

 [ Add ]   Declared

 GNU Image Manipulation Program   (Flatpak: org.gimp.GIMP)
 High-end image creation and manipulation
 publisher: The GIMP team    license: GPL-3.0+ AND LGPL-3.0+
 permissions
   devices: all
   shared: ipc, network
   sockets: fallback-x11, wayland
   filesystems: xdg-config/GIMP:create, xdg-config/gtk-3.0:ro, /tmp, host, …
 overrides (p): Context.filesystems=xdg-pictures:ro

 Enter queues it.  Nothing is installed until a applies.

 Enter look up / queue   Ctrl+F Flathub   Ctrl+S Snap   Tab Add/Declared   a apply
</pre>
<ul class="links">
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap#install">Install</a></li>
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap#keys">Keys</a></li>
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap">Source</a></li>
</ul>
</div>

<h2>From a link to an installed app</h2>
<p>Open the Omarchy menu, then <em>Install → Flatpak &amp; Snap</em>. Everything
after that is keyboard.</p>

<section class="scene scene--text">
  <div>
    <div class="step">1 · Paste</div>
    <h3>Whatever you have in hand</h3>
    <p>A Flathub or Snapcraft page, a <code>.flatpakref</code>, an app ID like
    <code>com.spotify.Client</code>, a bare name like <code>spotify</code>,
    or the <code>flatpak install …</code> / <code>snap install …</code> line
    from a project's README. That last one is read, and never run. No link?
    <code>Ctrl+F</code> searches Flathub, <code>Ctrl+S</code> the Snap Store.</p>
  </div>
</section>

<section class="scene scene--text">
  <div>
    <div class="step">2 · Look</div>
    <h3>Before anything is queued</h3>
    <p>The card shows the publisher and license. For a Flatpak it lists the
    sandbox permissions, and for a Snap the confinement.
    Snaps get a channel (<code>c</code>). Classic confinement takes two
    presses of <code>x</code> and is marked in red, because it means no sandbox.</p>
  </div>
</section>

<section class="scene scene--text">
  <div>
    <div class="step">3 · Queue, then apply</div>
    <h3>A line in a Nix file, then a rebuild</h3>
    <p><code>Enter</code> writes the app into
    <code>~/.config/nixarchy/flatsnap.nix</code>. <code>a</code> runs
    <code>nixarchy-apply</code> and streams the build into the panel. Flatpaks
    become <code>services.flatpak.packages</code>. Snaps are kept installed by
    a small reconciler on top of
    <a href="https://github.com/nix-community/nix-snapd">nix-snapd</a>.
    Un-declaring with <code>d</code> <code>y</code> and applying removes the
    app again.</p>
  </div>
</section>

<h2>What it will not do</h2>
<p>These are deliberate.</p>

<section class="scene scene--text">
  <div>
    <ul>
      <li><strong>Run what you paste.</strong> Input is refused unless it
      matches the Flatpak or Snap ID grammar. That covers other hosts,
      <code>http://</code>, non-Flathub remotes and flags it doesn't know.</li>
      <li><strong>Remove software you installed yourself.</strong> The
      reconciler removes only Snaps it installed. Flatpaks follow nixarchy's
      <code>uninstallUnmanaged</code>, and when that is on the panel names
      what would go and asks twice.</li>
      <li><strong>Pretend Snaps are sandboxed like on Ubuntu.</strong> nix-snapd
      has no AppArmor, and the panel says so on every Snap. snapd runs only
      while you have a Snap declared.</li>
      <li><strong>Build behind your back.</strong> Queuing edits a file. Only
      <code>a</code> rebuilds.</li>
    </ul>
  </div>
</section>

<p class="home-foot">MIT · part of the <a href="https://olafkfreund.github.io/nixarchy/">nixarchy</a> family</p>
