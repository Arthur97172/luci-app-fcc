/*
 * luci-app-fcc — one console session in a browser window of its own.
 *
 * The transport is the console's: pane output is a byte stream with an absolute
 * offset, polled; keystrokes go back as base64. What differs is the ending.
 *
 * This window owns the session. Closing it ends the session; reloading it does
 * not. That distinction cannot be made in the browser — `pagehide` fires for
 * both a close and a reload — so the close is only *armed* here and decided by
 * session.sh: the armed close records a generation counter, and a reattach
 * (session_capture) bumps it. When the grace period expires the backend closes
 * the session only if the counter still matches what was armed, which is true
 * for a closed window and false for a reloaded one, whatever order the two
 * requests happen to reach the router in.
 *
 * Every request the page sends is authenticated by the same LuCI session
 * cookie as the console itself; closing the window does not end the login.
 */
(function () {
	'use strict';

	var FCC = window.FCC;
	var session = window.FCC_SESSION || '';

	// Sentences translated by the template: this page has no LuCI header, so
	// FCC._() would fall back to English for all of them.
	var I18N = window.FCC_I18N || {};

	/* Seconds between the window going away and the session ending. Long
	 * enough for a reload to re-attach over a slow link, short enough that a
	 * closed window does not leave the agent running for a noticeable time. */
	var CLOSE_GRACE = 8;

	var term = null;
	var fit = null;
	var lastSize = null;    // last cols/rows sent to the session
	var paneSize = null;    // the pane's own grid, as the last output answer said
	var offset = 0;
	var polling = false;
	var pollAbort = null;

	/* ------------------------------------------------------------ status line */

	function note(text) {
		var box = FCC.$('#fcc-popout-status');
		if (!box) { return; }
		box.textContent = text || '';
		box.hidden = !text;
	}

	/* --------------------------------------------------------------- terminal */

	function ensureTerm() {
		if (term) { return; }

		term = new window.Terminal({
			cursorBlink: true,
			fontSize: 13,
			fontFamily: 'Menlo, Consolas, "DejaVu Sans Mono", monospace',
			scrollback: 5000,
			convertEol: false,
			theme: { background: '#1e1e1e', foreground: '#d4d4d4' }
		});
		fit = new window.FitAddon.FitAddon();
		term.loadAddon(fit);
		term.open(FCC.$('#fcc-popout'));

		term.onData(function (data) {
			if (!polling) { return; }        // the session has ended
			FCC.api('session_input', {
				name: session,
				data: FCC.strToB64(data)
			}, { method: 'POST' }).catch(function () { /* the session may have ended */ });
		});

		window.addEventListener('resize', fitNow);

		/* The box changes on its own too — a scrollbar appears, the first paint
		 * lands after this runs. Attach waits on fitNow(), so the pane is this
		 * window's size before its screen is captured. */
		if (window.ResizeObserver) {
			var ro = new window.ResizeObserver(function () {
				if (fitTimer) { return; }
				fitTimer = setTimeout(function () { fitTimer = null; fitNow(); }, 150);
			});
			ro.observe(FCC.$('#fcc-popout'));
		}
	}

	var fitTimer = null;

	function fitNow() {
		if (!fit || !term || !session) { return Promise.resolve(); }
		try { fit.fit(); } catch (e) { return Promise.resolve(); }
		/* Before the page has laid out, fit() proposes a size the backend
		 * refuses. Leave it to the observer, which fires once it has one. */
		if (term.cols < 20 || term.rows < 5) { return Promise.resolve(); }
		if (lastSize && lastSize.cols === term.cols && lastSize.rows === term.rows) {
			return Promise.resolve();
		}
		lastSize = { cols: term.cols, rows: term.rows };
		return FCC.api('session_resize', {
			name: session,
			cols: term.cols,
			rows: term.rows
		}, { method: 'POST' }).catch(function () { /* the session may have ended */ });
	}

	/* ---------------------------------------------------------------- attach */

	function attach() {
		note('');
		repaint();
	}

	/**
	 * Paint the pane's current screen into this terminal, then resume polling.
	 *
	 * `lastSize` is dropped first so the resize is sent even when this window's
	 * own size has not changed: the console tab shows the same session and may
	 * have taken the pane to its own grid while this window was in the
	 * background, and it is the pane's size that the captured screen and the
	 * agent's next paint are drawn for.
	 *
	 * The capture is taken before polling stops, so a failed capture leaves the
	 * poll running and this window live rather than frozen on its last frame.
	 */
	function repaint() {
		lastSize = null;
		return fitNow().then(function () {
			return FCC.api('session_capture', { name: session }, { method: 'GET' });
		}).then(function (r) {
			stopPolling();
			term.reset();
			term.write(FCC.captureBytes(r.data));
			term.write(FCC.captureCursor(r));
			return FCC.api('session_output', { name: session, offset: 0, wait: 0 },
				{ method: 'GET' });
		}).then(function (r) {
			offset = r.offset;
			notePaneSize(r);
			startPolling();
			fitNow();
			term.focus();
		}).catch(function (err) {
			note((I18N.attach || FCC._('Could not attach to the session:')) + ' ' +
				((err && err.message) ? err.message : ''));
			/* The screen was not repainted, so the offset still means what it
			 * meant: keep the window live from there. */
			if (!polling) { startPolling(); }
		});
	}

	/**
	 * The pane's own grid, as the last output answer reported it.
	 *
	 * The pane is shared with the console tab, and whichever page resized it
	 * last decides the size the agent draws for. An answer from a backend
	 * without the two fields leaves the last reading standing.
	 */
	function notePaneSize(r) {
		if (!r) { return; }
		var cols = r.cols, rows = r.rows;
		if (typeof cols !== 'number' || typeof rows !== 'number') { return; }
		if (cols < 20 || rows < 5) { return; }
		paneSize = { cols: cols, rows: rows };
	}

	var reclaiming = false;

	/**
	 * Take the pane back after the console tab resized it.
	 *
	 * Whether this window is the foreground one changes no window or box size,
	 * so like the console it hears only `visibilitychange`/`focus` and the
	 * output answers. `document.hasFocus()` is the condition that keeps the two
	 * from resizing the pane back and forth: only the window the user is
	 * actually in reclaims.
	 *
	 * Returns true when it started a repaint, so a poll that asked does not go
	 * on to start another request the repaint is about to abort.
	 */
	function reclaim() {
		if (reclaiming) { return false; }
		if (document.visibilityState === 'hidden' || !document.hasFocus()) { return false; }
		if (!polling || !term || !paneSize) { return false; }
		if (paneSize.cols === term.cols && paneSize.rows === term.rows) { return false; }
		reclaiming = true;
		repaint().then(function () { reclaiming = false; });
		return true;
	}

	function startPolling() {
		stopPolling();
		polling = true;
		pollLoop();
	}

	function stopPolling() {
		polling = false;
		if (pollAbort) {
			try { pollAbort.abort(); } catch (e) { /* already finished */ }
			pollAbort = null;
		}
	}

	function pollLoop() {
		if (!polling) { return; }

		pollAbort = ('AbortController' in window) ? new AbortController() : null;

		FCC.api('session_output', {
			name: session,
			offset: offset,
			wait: 20                      // long-poll: hold up to 20s for new bytes
		}, { method: 'GET', signal: pollAbort ? pollAbort.signal : undefined })
			.then(function (r) {
				if (!polling) { return; }

				if (r.reset) { term.reset(); }
				if (r.data) { term.write(FCC.b64ToBytes(r.data)); }
				offset = r.offset;
				notePaneSize(r);
				/* The console tab may have taken the pane to its own grid while
				 * this answer was on its way. If this window holds the focus,
				 * it speaks for the pane again now. */
				if (reclaim()) { return; }

				if (r.alive) {
					pollLoop();
				} else {
					// Section 74's two endings, with no controls to offer: this
					// window exists to show one session, and the console page is
					// where a new one is started.
					polling = false;
					note(r.exit_code === 0
						? (I18N.ended || FCC._('Session has exited.'))
						: (I18N.crashed || FCC._('Agent exited unexpectedly.')));
					loadSessionsState();
				}
			})
			.catch(function (err) {
				if (err && err.name === 'AbortError') { return; }
				if (!polling) { return; }
				// The session outlives the connection; say so and keep retrying
				// from the same offset, so nothing is lost.
				note(I18N.lost || FCC._('Terminal connection lost. Reconnecting…'));
				setTimeout(pollLoop, 2000);
			});
	}

	/* The name in the title bar, so the window says which agent it holds. */
	function loadSessionsState() {
		FCC.api('sessions', {}, { method: 'GET' }).then(function (list) {
			var match = (Array.isArray(list) ? list : []).filter(function (s) {
				return s.name === session;
			})[0];
			if (match && match.display_name) { document.title = 'FCC — ' + match.display_name; }
		}).catch(function () { /* cosmetic */ });
	}

	/* ----------------------------------------------------------- the ending */

	/**
	 * Arm the close when the window goes away.
	 *
	 * sendBeacon is what browsers meant to be used here: it is delivered even
	 * though the page is unloading. keepalive on fetch is the fallback for a
	 * browser without it, and the plain POST the last resort.
	 */
	function requestClose() {
		var body = 'name=' + encodeURIComponent(session) + '&grace=' + CLOSE_GRACE;
		var url = (window.FCC_API || '') + 'session_close_later';

		if (navigator.sendBeacon) {
			try {
				var blob = new Blob([body], { type: 'application/x-www-form-urlencoded' });
				if (navigator.sendBeacon(url, blob)) { return; }
			} catch (e) { /* fall through to fetch */ }
		}

		try {
			fetch(url, {
				method: 'POST',
				credentials: 'same-origin',
				keepalive: true,
				headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
				body: body
			}).catch(function () { /* the window is going away; nowhere to report */ });
		} catch (e) { /* no keepalive support; the session outlives the window */ }
	}

	window.addEventListener('pagehide', function (ev) {
		stopPolling();
		// A bfcache store is not a close: the page may come back exactly as it
		// was, and pageshow below resumes it.
		if (ev.persisted) { return; }
		requestClose();
	});

	window.addEventListener('pageshow', function (ev) {
		if (ev.persisted) { attach(); }
	});

	/* -------------------------------------------------------------------- init */

	function init() {
		ensureTerm();
		loadSessionsState();
		attach();
		/* The console tab shows the same session and may have resized the pane
		 * while this window was in the background. Returning here changes
		 * nothing this page watches, so the two events are the only signals. */
		document.addEventListener('visibilitychange', reclaim);
		window.addEventListener('focus', reclaim);
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
