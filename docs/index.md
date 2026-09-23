---
layout: home
---

<div class="prose lede" markdown="1">
Some software is only current as a **Flatpak** or a **Snap**. Paste the link,
see what the app can reach, queue it, and apply. It ends up in your NixOS
configuration, not in a terminal's scrollback.
</div>

<div class="hero">
<a href="img/flatsnap-flatpak.gif"><img src="img/flatsnap-flatpak.gif" width="900" height="563"
   alt="The Flatpak and Snap panel on a Tokyo Night desktop: a Flathub link for GNOME Calculator is typed into the field, Enter shows Calculator's card with its publisher, license and sandbox permissions, and a second Enter queues it"></a>
<ul class="links">
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap#install">Install</a></li>
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap#keys">Keys</a></li>
  <li><a href="https://github.com/olafkfreund/nixarchy-flatsnap">Source</a></li>
</ul>
</div>

<h2>From a link to an installed app</h2>
<p>Open the Omarchy menu, then <em>Install → Flatpak &amp; Snap</em>. Everything
after that is keyboard.</p>

<section class="scene">
  <a href="img/02-flatpak-card.webp"><img src="img/02-flatpak-card.webp" width="1280" height="800" loading="lazy"
       alt="Calculator's card after pasting its Flathub link: publisher The GNOME Project, license GPL-3.0-or-later, and the permissions it asks for"></a>
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

<section class="scene">
  <a href="img/flatsnap-snap.gif"><img src="img/flatsnap-snap.gif" width="900" height="563" loading="lazy"
       alt="Searching the Snap Store for hello, opening hello-world's card, cycling its channel to candidate, and pressing x: the classic confirmation turns red"></a>
  <div>
    <div class="step">2 · Look</div>
    <h3>Before anything is queued</h3>
    <p>The card shows the publisher and license. For a Flatpak it lists the
    sandbox permissions, and for a Snap the confinement.
    Snaps get a channel (<code>c</code>). Classic confinement takes two
    presses of <code>x</code> and is marked in red, because it means no sandbox.</p>
  </div>
</section>

<section class="scene">
  <a href="img/flatsnap-apply.gif"><img src="img/flatsnap-apply.gif" width="900" height="563" loading="lazy"
       alt="Pressing a on the Declared list: the rebuild streams into the panel (build log shortened), the desktop reloads, and the panel reopens with both apps marked installed"></a>
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

<div class="grid3">
  <figure><a href="img/05-classic-confirm.webp"><img src="img/05-classic-confirm.webp" width="1280" height="800" loading="lazy" alt="hello-world's card with the red line: x again, run this snap WITHOUT a sandbox"></a>
    <figcaption>Classic confinement takes a second <code>x</code>.</figcaption></figure>
  <figure><a href="img/08-installed.webp"><img src="img/08-installed.webp" width="1280" height="800" loading="lazy" alt="The Declared list after apply: org.gnome.Calculator and hello-world both installed"></a>
    <figcaption>After apply: both installed.</figcaption></figure>
  <figure><a href="img/09-calculator.webp"><img src="img/09-calculator.webp" width="1280" height="800" loading="lazy" alt="GNOME Calculator running, installed as a Flatpak a moment earlier"></a>
    <figcaption>And it runs.</figcaption></figure>
</div>

<section class="scene">
  <a href="img/10-remove-confirm.webp"><img src="img/10-remove-confirm.webp" width="1280" height="800" loading="lazy"
       alt="The Declared list with org.gnome.Calculator marked to remove, and the red line: y removes org.gnome.Calculator at the next apply, any other key keeps it"></a>
  <div>
    <div class="step">4 · Take it away again</div>
    <h3>Un-declare, then apply</h3>
    <p><code>d</code> marks the row, <code>y</code> confirms, and any other key
    keeps it. The next <code>a</code> removes what nixarchy installed. A Snap
    you installed yourself is never touched.</p>
    <p><a href="img/11-removed.webp">The removal's apply</a>, as the panel shows it.</p>
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
