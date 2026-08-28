/* Clipboard bridge between the host browser and the container's desktop.
 *
 * Loaded into noVNC's own page by docker/Dockerfile. noVNC ships a clipboard
 * side panel and nothing more: the canvas grabs every keystroke, so Cmd-V or
 * Ctrl-V never reached the remote Chromium and text copied anywhere else on the
 * machine could only get in by being pasted into that panel by hand. That is
 * the one place the Docker edition stopped feeling like a browser.
 *
 * Both directions are handled:
 *
 *   in    the host's paste shortcut is caught before noVNC sees it, the text is
 *         pushed to the remote clipboard, and a synthetic Ctrl-V is sent so the
 *         remote application performs the paste itself.
 *   out   whatever the remote copies arrives as an RFB clipboard event and is
 *         written to the host clipboard, so Ctrl-C inside the container is
 *         enough to paste outside it.
 *
 * Three ways to read the host clipboard, because any of them can be
 * unavailable, and a paste that silently does nothing is the worst of the
 * outcomes:
 *
 *   1. a hidden textarea is focused for the length of the gesture, so the
 *      browser performs its own paste into something that can receive one. No
 *      permission, no prompt, and it is the only route that works when the
 *      focus is on a canvas - which on this page it always is. Chrome fires
 *      `paste` at the canvas as well; Safari and Firefox do not, and that is
 *      where Cmd-V used to do nothing at all.
 *   2. the page's own `paste` event, which route 1 is what guarantees.
 *   3. navigator.clipboard.readText, for whenever the browser has granted
 *      clipboard access to this origin. Kept because it is the only one that
 *      still answers when the gesture did not come from a real key press.
 *
 * Whichever answers first wins; the others are dropped.
 */
(function () {
  'use strict';

  /* X keysyms. Modifiers are the left-hand ones, which is what a keyboard sends. */
  const KEY = {
    ControlLeft: 0xffe3,
    KeyC: 0x63,
    KeyV: 0x76,
    KeyX: 0x78,
    KeyA: 0x61,
  };

  /* On a Mac the clipboard accelerator is Cmd, which noVNC forwards as Super -
     and no Linux application answers Super-V. Everywhere else Ctrl is already
     the right key and passes straight through, so only the paste needs catching. */
  const MAC = /Mac|iPhone|iPad/.test(
    navigator.platform || navigator.userAgent || '',
  );

  /* UI.connected and UI.rfb are what ui.js itself checks before touching the
     connection, so this asks the same question rather than reading RFB's private
     state. UI.rfb is cleared on disconnect and replaced on reconnect. */
  const rfb = () => (window.UI && window.UI.rfb) || null;
  const connected = () => (window.UI && window.UI.connected && rfb()) || null;

  function say(message) {
    if (window.UI && typeof window.UI.showStatus === 'function')
      window.UI.showStatus(message);
  }

  /* ---------- remote key presses ---------- */

  function remoteChord(codes) {
    const r = connected();
    if (!r) return false;
    for (const code of codes) r.sendKey(KEY[code], code, true);
    for (const code of [...codes].reverse()) r.sendKey(KEY[code], code, false);
    return true;
  }

  /* ---------- host clipboard -> container ---------- */

  let pending = null; // the paste gesture in flight, or null

  /* The textarea route 1 pastes into. Off-screen rather than hidden: an element
     that is not rendered cannot take focus, and without focus the browser has
     nowhere to paste and fires nothing. Created once, on first use. */
  let sink = null;

  function sinkNode() {
    if (sink && sink.isConnected) return sink;
    sink = document.createElement('textarea');
    sink.id = 'engineshelf_paste_sink';
    sink.setAttribute('aria-hidden', 'true');
    sink.tabIndex = -1;
    sink.style.cssText =
      'position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:0;' +
      'margin:0;opacity:0;pointer-events:none;z-index:-1;';
    document.body.appendChild(sink);
    return sink;
  }

  /* One way out of a gesture, whichever route ended it. Focus has to go back to
     whatever had it - the canvas, normally - or the next keystroke is typed into
     the sink and never reaches the container. */
  function finish() {
    if (!pending) return null;
    clearTimeout(pending.timer);
    window.removeEventListener('paste', onPaste, true);
    const back = pending.focus;
    pending = null;
    if (sink) sink.value = '';
    if (back && typeof back.focus === 'function') {
      try {
        back.focus({ preventScroll: true });
      } catch (e) {
        back.focus();
      }
    }
    return back;
  }

  function deliver(text) {
    if (!pending) return; // a later answer for a gesture already served
    finish();
    if (!text) return;

    const r = connected();
    if (!r) return;
    r.clipboardPasteFrom(text);
    /* The text has to reach x11vnc and land in the X selection before the remote
       application asks for it, and that is a round trip we cannot observe from
       here - hence the short wait rather than sending both in one go. */
    setTimeout(() => remoteChord(['ControlLeft', 'KeyV']), 150);
  }

  function onPaste(event) {
    if (!pending) return;
    const text =
      event.clipboardData && event.clipboardData.getData('text/plain');
    /* No clipboardData - some browsers withhold it outside an editable target.
       The paste itself is still happening, and route 1 aimed it at the sink, so
       the text is readable there one tick later. */
    if (!text) {
      const node = sink;
      if (node) setTimeout(() => deliver(node.value), 0);
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    deliver(text);
  }

  /* Said once per tab: a browser that refuses the clipboard refuses it every
     time, and the same toast on every key press is noise. */
  let hinted = false;

  /* The container's desktop is Linux, so Ctrl-V is what a good half of people
     press in here - and on a Mac that is not a paste as far as the host browser
     is concerned. No `paste` event fires, the hidden textarea stays empty, and
     the only route left is navigator.clipboard. When that is refused as well the
     key press is handed on to the container unchanged, so it pastes whatever its
     own clipboard holds, exactly as it did before this file existed.
     `host` is true when the key press is the host's own paste accelerator -
     Cmd-V on a Mac, Ctrl-V everywhere else - and the browser will perform a
     paste for it. */
  function pasteIntoContainer(event, host) {
    if (pending) return; // key held down: one paste per press
    pending = { timer: 0, focus: document.activeElement, host };

    /* The deadline for all of it, set before the routes rather than after them:
       one of those routes gives up the moment it is tried, and a handOn() that
       ran before this line existed cleared a gesture the next statement then
       wrote a timer into. */
    pending.timer = setTimeout(() => {
      /* Nothing answered. Read the sink once more in case the paste landed there
         without an event anyone saw, and only then say so out loud - failing
         silently is what this whole file exists to stop. */
      const landed = pending.host && sink ? sink.value : '';
      if (landed) {
        deliver(landed);
        return;
      }
      if (!pending.host) {
        handOn();
        return;
      }
      finish();
      say(
        'This browser will not hand over the clipboard — use the clipboard panel',
      );
    }, 1200);

    if (host) window.addEventListener('paste', onPaste, true);

    /* Route 1. The focus moves inside the keydown handler, so it is already the
       sink by the time the browser performs the paste this key press asked for -
       which is what makes the paste happen at all on a page whose focus is a
       canvas. Whatever had the focus is put back by finish().
       noVNC's own on-screen-keyboard textarea is one of the things that can have
       it; taking the paste off it is deliberate, since letting it land there
       would type the text into the container a second time. */
    if (host) {
      const node = sinkNode();
      node.value = '';
      try {
        node.focus({ preventScroll: true });
      } catch (e) {
        node.focus();
      }
      node.select();
    }

    /* Route 3, in parallel: on a browser that grants it, this answers before the
       paste event and saves a round trip through the DOM. */
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(deliver, () => {
        /* On the host accelerator the paste event may still arrive, so this
           waits. On the Linux chord nothing else is coming. */
        if (pending && !pending.host) handOn();
      });
    } else if (!host) {
      handOn();
    }

  }

  /* The Ctrl-V that was caught is sent on to the container, so the desktop in
     there pastes its own clipboard and the key press is not simply eaten. Then
     the one thing worth saying: the shortcut that reads this machine's clipboard
     is the host's own. */
  function handOn() {
    if (!pending) return;
    finish();
    remoteChord(['ControlLeft', 'KeyV']);
    if (hinted) return;
    hinted = true;
    say('Ctrl-V pastes inside the container — press Cmd-V to paste from your Mac');
  }

  /* ---------- container -> host clipboard ---------- */

  let bridged = null; // the RFB object whose clipboard event is already wired

  function onRemoteClipboard(event) {
    const text = event.detail && event.detail.text;
    if (!text || !navigator.clipboard || !navigator.clipboard.writeText) return;
    navigator.clipboard.writeText(text).catch(() => {
      /* unfocused tab, or no permission */
    });
  }

  /* UI.rfb is replaced on every reconnect, so this cannot be a one-time hook. */
  setInterval(() => {
    const r = rfb();
    if (!r || r === bridged) return;
    bridged = r;
    r.addEventListener('clipboard', onRemoteClipboard);
  }, 300);

  /* ---------- key handling ----------
     Capture on window runs before noVNC's own handler, which is attached further
     down the tree - that is the only reason these keys can be intercepted at all. */

  /* Whatever is taken on the way down has to be taken on the way up as well.
     noVNC tracks which keys it has sent down so it can release them; a keyup for
     a key it never saw pressed is a state it should not have to reason about. */
  const swallowed = new Set();

  window.addEventListener(
    'keyup',
    (event) => {
      if (swallowed.delete(event.code)) event.stopImmediatePropagation();
    },
    true,
  );

  window.addEventListener(
    'keydown',
    (event) => {
      if (event.altKey || !connected()) return;
      const accel = MAC
        ? event.metaKey && !event.ctrlKey
        : event.ctrlKey && !event.metaKey;

      /* The container is Linux, so Ctrl-V is the paste people expect to work in
         there, and on a Mac it is not the host's accelerator - it used to pass
         straight through to a container whose clipboard nothing had written to,
         which is a key press that does nothing at all. Caught here as well, and
         handOn() puts it back on the wire if this side cannot read the
         clipboard. */
      const linuxChord =
        MAC && event.ctrlKey && !event.metaKey && !event.shiftKey;
      if (!accel && !linuxChord) return;

      if (event.code === 'KeyV') {
        event.stopImmediatePropagation(); // noVNC would cancel the default paste
        swallowed.add(event.code);
        pasteIntoContainer(event, accel);
        return;
      }
      /* Nothing else on the Linux chord: Ctrl-C, Ctrl-X and the rest already
         mean in the container exactly what they say, and noVNC forwards them. */
      if (!accel) return;

      /* Cmd-C, Cmd-X and Cmd-A only, and only on a Mac: the rest of Cmd belongs to
       the host's own browser, and remapping it would take the shortcuts the user
       reaches for to manage tabs. */
      if (
        MAC &&
        (event.code === 'KeyC' ||
          event.code === 'KeyX' ||
          event.code === 'KeyA')
      ) {
        event.preventDefault();
        event.stopImmediatePropagation();
        swallowed.add(event.code);
        remoteChord(['ControlLeft', event.code]);
      }
    },
    true,
  );

  /* Cmd or Ctrl held while the tab loses focus leaves the remote modifier stuck
     down, and every following keystroke is read as a chord. noVNC releases its
     own tracked keys on blur; the ones synthesised here are not tracked. */
  window.addEventListener('blur', () => {
    const r = connected();
    if (r) r.sendKey(KEY.ControlLeft, 'ControlLeft', false);
  });
})();
