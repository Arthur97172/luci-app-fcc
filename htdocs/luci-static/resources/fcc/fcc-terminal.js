/*
 * luci-app-fcc — Web Console.
 *
 * A real interactive terminal in the browser, without a Node.js/Python
 * WebSocket server (DESIGN_SPEC.md s.87 forbids one, and uhttpd has no
 * WebSocket support anyway).
 *
 * How it works:
 *   * the session lives in tmux on the router, so it survives a page reload,
 *     a tab close and a browser restart (s.7/s.8)
 *   * pane output is appended to a file by `tmux pipe-pane`
 *   * this page long-polls .../api/session_output with an ABSOLUTE byte offset
 *     and gets back whatever is new, base64-encoded
 *   * keystrokes go back through .../api/session_input as base64
 *
 * The offset is absolute, so a dropped request, a slow network or a background
 * tab loses nothing: the next poll simply asks for everything after the last
 * byte actually received.
 */
(function () {
	'use strict';

	var FCC = window.FCC;

	var state = {
		sessions: [],
		active: null,       // session name
		term: null,         // xterm.Terminal
		fit: null,          // FitAddon
		offset: 0,
		polling: false,
		pollAbort: null,
		agents: [],
		listTimer: null
	};

	/* ------------------------------------------------------------ session list */

	function loadAgents() {
		return FCC.api('agents', {}, { method: 'GET' }).then(function (data) {
			state.agents = Object.keys(data).map(function (id) {
				return { id: id, name: data[id].name, installed: data[id].installed };
			});
			renderAgentSelect();
		}).catch(function () { /* the console still works with existing sessions */ });
	}

	function renderAgentSelect() {
		var sel = FCC.$('#fcc-agent-select');
		if (!sel) { return; }
		sel.innerHTML = '';
		var installed = state.agents.filter(function (a) { return a.installed; });
		var list = installed.length ? installed : state.agents;
		if (!list.length) {
			sel.appendChild(FCC.el('option', { value: '', text: FCC._('No agents installed') }));
			return;
		}
		list.forEach(function (a) {
			sel.appendChild(FCC.el('option', {
				value: a.id,
				text: a.name + (a.installed ? '' : ' (' + FCC._('not installed') + ')')
			}));
		});
	}

	function loadSessions() {
		return FCC.api('sessions', {}, { method: 'GET' }).then(function (list) {
			state.sessions = Array.isArray(list) ? list : [];
			renderTabs();
		}).catch(function () { state.sessions = []; renderTabs(); });
	}

	function renderTabs() {
		var box = FCC.$('#fcc-term-tabs');
		if (!box) { return; }
		box.innerHTML = '';

		if (!state.sessions.length) {
			box.appendChild(FCC.el('span', {
				class: 'fcc-muted',
				text: FCC._('No active sessions. Start one to open a terminal.')
			}));
			return;
		}

		state.sessions.forEach(function (s) {
			var close = FCC.el('button', {
				class: 'fcc-close', title: FCC._('Close session'), text: '×',
				onclick: function (ev) {
					ev.stopPropagation();
					closeSession(s.name);
				}
			});
			var tab = FCC.el('button', {
				class: 'fcc-term-tab' + (s.name === state.active ? ' active' : ''),
				onclick: function () { attach(s.name); }
			}, [
				FCC.el('span', { class: 'fcc-dot ' + (s.uptime !== null ? 'on' : 'off') }),
				FCC.el('span', { text: s.name }),
				close
			]);
			box.appendChild(tab);
		});
	}

	/* ---------------------------------------------------------------- terminal */

	function ensureTerm() {
		if (state.term) { return; }

		state.term = new window.Terminal({
			cursorBlink: true,
			fontSize: 13,
			fontFamily: 'Menlo, Consolas, "DejaVu Sans Mono", monospace',
			scrollback: 5000,
			convertEol: false,
			theme: { background: '#1e1e1e', foreground: '#d4d4d4' }
		});
		state.fit = new window.FitAddon.FitAddon();
		state.term.loadAddon(state.fit);
		state.term.open(FCC.$('#fcc-term'));

		// Keystrokes -> router. xterm gives us a string; send its UTF-8 bytes.
		state.term.onData(function (data) {
			if (!state.active) { return; }
			FCC.api('session_input', {
				name: state.active,
				data: FCC.strToB64(data)
			}, { method: 'POST' }).catch(function () { /* session may have ended */ });
		});

		window.addEventListener('resize', fitNow);
	}

	function fitNow() {
		if (!state.fit) { return; }
		try { state.fit.fit(); } catch (e) { /* element may be hidden */ }
		if (state.active && state.term) {
			FCC.api('session_resize', {
				name: state.active,
				cols: state.term.cols,
				rows: state.term.rows
			}, { method: 'POST' }).catch(function () { /* session may have ended */ });
		}
	}

	function attach(name) {
		state.active = name;
		renderTabs();
		ensureTerm();

		// Repaint from the pane's current screen, then continue from the end of
		// the captured stream. This makes reconnecting to an existing session
		// show what is on screen right now rather than replaying everything.
		FCC.api('session_capture', { name: name }, { method: 'GET' }).then(function (r) {
			state.term.reset();
			state.term.write(FCC.b64ToBytes(r.data));
			return FCC.api('session_output', { name: name, offset: 0, wait: 0 }, { method: 'GET' });
		}).then(function (r) {
			state.offset = r.offset;
			startPolling();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-term-status'), 'fail',
				FCC._('Could not attach to the session: ') + err.message);
		});

		fitNow();
		state.term.focus();
	}

	function startPolling() {
		stopPolling();
		state.polling = true;
		pollLoop();
	}

	function stopPolling() {
		state.polling = false;
		if (state.pollAbort) {
			try { state.pollAbort.abort(); } catch (e) { /* already finished */ }
			state.pollAbort = null;
		}
	}

	function pollLoop() {
		if (!state.polling || !state.active) { return; }

		var name = state.active;
		state.pollAbort = ('AbortController' in window) ? new AbortController() : null;

		FCC.api('session_output', {
			name: name,
			offset: state.offset,
			wait: 20                 // long-poll: hold up to 20s for new bytes
		}, { method: 'GET', signal: state.pollAbort ? state.pollAbort.signal : undefined })
			.then(function (r) {
				// The user may have switched tabs while this request was in flight.
				if (!state.polling || state.active !== name) { return; }

				if (r.reset) {
					// The scrollback file was trimmed past our offset; resync.
					state.term.reset();
				}
				if (r.data) { state.term.write(FCC.b64ToBytes(r.data)); }
				state.offset = r.offset;

				if (r.alive) {
					pollLoop();
				} else {
					state.polling = false;
					FCC.notice(FCC.$('#fcc-term-status'), 'warn',
						FCC._('The session has ended.'));
					loadSessions();
				}
			})
			.catch(function (err) {
				if (err && err.name === 'AbortError') { return; }
				if (!state.polling || state.active !== name) { return; }
				// Transient failure (router busy, network blip): back off and
				// retry from the same offset. Nothing is lost.
				setTimeout(pollLoop, 2000);
			});
	}

	/* ----------------------------------------------------------------- actions */

	function createSession() {
		var sel = FCC.$('#fcc-agent-select');
		var agent = sel ? sel.value : '';
		if (!agent) {
			FCC.notice(FCC.$('#fcc-term-status'), 'warn',
				FCC._('Install an agent first (Configuration → Agents).'));
			return;
		}
		var cols = 80, rows = 24;
		if (state.term) { cols = state.term.cols; rows = state.term.rows; }

		FCC.api('session_create', { agent: agent, cols: cols, rows: rows }, { method: 'POST' })
			.then(function (r) {
				FCC.notice(FCC.$('#fcc-term-status'), '', '');
				return loadSessions().then(function () { attach(r.name); });
			})
			.catch(function (err) {
				FCC.notice(FCC.$('#fcc-term-status'), 'fail', err.message);
			});
	}

	function closeSession(name) {
		FCC.api('session_close', { name: name }, { method: 'POST' }).then(function () {
			if (state.active === name) {
				state.active = null;
				stopPolling();
				if (state.term) { state.term.reset(); state.term.write('\r\n[ session closed ]\r\n'); }
			}
			loadSessions();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-term-status'), 'fail', err.message);
		});
	}

	function cleanupSessions() {
		FCC.api('session_cleanup', {}, { method: 'POST' }).then(function () {
			loadSessions();
		});
	}

	/* -------------------------------------------------------------------- init */

	function init() {
		var createBtn = FCC.$('#fcc-term-create');
		if (createBtn) { createBtn.addEventListener('click', createSession); }

		var cleanupBtn = FCC.$('#fcc-term-cleanup');
		if (cleanupBtn) { cleanupBtn.addEventListener('click', cleanupSessions); }

		ensureTerm();
		loadAgents();
		loadSessions().then(function () {
			// Re-attach to the most recent session after a page reload.
			if (state.sessions.length) { attach(state.sessions[0].name); }
		});

		state.listTimer = setInterval(loadSessions, 10000);
		window.addEventListener('beforeunload', function () {
			// The tmux session deliberately keeps running; only the polling stops.
			stopPolling();
			if (state.listTimer) { clearInterval(state.listTimer); }
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
