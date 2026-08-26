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
 * Two ways to read the host clipboard, because either can be unavailable: the
 * page's own `paste` event (no permission needed, but only fires if nothing
 * cancels the default action) and navigator.clipboard.readText (works whenever
 * the user has granted clipboard access to this origin). Whichever answers
 * first wins; the other is dropped.
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

  function deliver(text) {
    if (!pending) return; // a later answer for a gesture already served
    clearTimeout(pending.timer);
    window.removeEventListener('paste', onPaste, true);
    pending = null;
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
    if (!text) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    deliver(text);
  }

  function pasteIntoContainer(event) {
    if (pending) return; // key held down: one paste per press
    pending = { timer: 0 };

    /* noVNC focuses this textarea to drive an on-screen keyboard. Letting the
       browser paste into it would type the text a second time, so that one case
       gives up the permission-free route. */
    const inIme =
      document.activeElement &&
      document.activeElement.id === 'noVNC_keyboardinput';
    if (inIme) event.preventDefault();
    else window.addEventListener('paste', onPaste, true);

    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then(deliver, () => {
        /* the paste event may still arrive */
      });
    }

    /* Nothing answered: either the browser refused to read the clipboard and no
       paste event fired. Point at the panel that always works instead of failing
       silently, which is what this whole file exists to stop. */
    pending.timer = setTimeout(() => {
      window.removeEventListener('paste', onPaste, true);
      pending = null;
      say(
        'This browser will not hand over the clipboard — use the clipboard panel',
      );
    }, 1200);
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
      if (!accel) return;

      if (event.code === 'KeyV') {
        event.stopImmediatePropagation(); // noVNC would cancel the default paste
        swallowed.add(event.code);
        pasteIntoContainer(event);
        return;
      }

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
