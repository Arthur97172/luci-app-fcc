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
		ro: null,           // ResizeObserver on the terminal's box
		size: null,         // last cols/rows sent to the active session
		offset: 0,
		polling: false,
		pollAbort: null,
		agents: [],
		console: null,      // last answer from api/console
		consoleAt: 0,       // when that answer arrived, for the stale re-read
		target: null,       // 'local' | 'lan', as last read from UCI
		listTimer: null
	};

	// Which banner is on screen, so re-rendering an identical one is skipped.
	var banner = null;

	// The text renderConsoleNotice() last wrote into #fcc-term-status, so it
	// can take back its own message without erasing anyone else's.
	var consoleNotice = '';

	/* --------------------------------------------------------------- the target */

	/*
	 * What the toolbar and the terminal are acting on.
	 *
	 * The Configuration tab's [This router] [LAN] switch is the only place the
	 * question is decided, and the backend reads the same UCI value when a pane
	 * is made — so this page follows that setting rather than offering a second
	 * switch that could disagree with it. All this side does is describe it.
	 */

	/*
	 * Each reason code remote.sh can emit, as the sentence a user can act on.
	 * Written out one by one rather than kept in a lookup table because the
	 * catalogue is built from the text inside FCC._(...) calls: a table of bare
	 * strings would translate at script load, before the page's catalogue is
	 * certain to be in place, and the strings would never reach an extractor.
	 */
	function consoleReason(r) {
		r = r || {};
		switch (r.reason) {
		case 'not-configured':
			return FCC._('The LAN machine is not configured yet. Set it up in Configuration → FCC Server.');
		case 'no-key':
			return FCC._('SSH has not been set up for the LAN machine yet. Generate its key in Configuration → FCC Server.');
		case 'key-invalid':
		case 'key-mismatch':
			return FCC._('The SSH key on this router is not one OpenSSH can read. Generate it again in Configuration → FCC Server, then add the new public key to the LAN machine.');
		case 'key-missing':
			return FCC._('The SSH key on this router is missing. Generate it again in Configuration → FCC Server, then add the new public key to the LAN machine.');
		case 'auth':
			return FCC._('The LAN machine refused the SSH key. Add the public key from Configuration → FCC Server to that account’s authorized_keys.');
		case 'host-key':
			return FCC._('The LAN machine’s host key no longer matches the one pinned on this router. Forget it and trust it again in Configuration → FCC Server.');
		case 'needs-root':
			return FCC._('Only an administrator on the LAN machine may control its FCC Server. Start it on that machine itself.');
		case 'no-host-key':
			return FCC._('The LAN machine’s host key has not been trusted yet. Trust it in Configuration → FCC Server.');
		case 'no-ssh-client':
			return FCC._('This router has no OpenSSH client. Install the openssh-client-utils package on this router.');
		case 'unreachable':
			return FCC._('The LAN machine could not be reached. Check that it is on and that SSH is enabled.');
		case 'no-agent-tools':
			return FCC._('The LAN machine does not run luci-app-fcc, so its agents cannot be listed.');
		case 'unreadable':
			return FCC._('The LAN machine answered with something unexpected.');
		case 'invalid-agent':
			return FCC._('That agent is not one this package knows.');
		case 'lan-unavailable':
			/* session.sh's own code: remote.sh is missing or not executable,
			 * which is a broken install rather than anything the user set. */
			return FCC._('This router is missing its SSH helper, so the LAN machine cannot be reached. Reinstall luci-app-fcc.');
		}
		return FCC._('The LAN machine’s state could not be read.') +
			(r.error ? ' (' + r.error + ')' : '');
	}

	/* Not a reason code: the LAN machine answered, and its FCC server is down.
	 * Starting an agent there would work, but it would have nothing to talk to. */
	function serverStoppedNotice() {
		return FCC._('The FCC Server on the LAN machine is not running. Start it on the Configuration tab.');
	}

	function loadConsole() {
		return FCC.api('console', {}, { method: 'GET' }).then(function (r) {
			state.console = r || {};
			state.consoleAt = Date.now();
			state.target = (r && r.target === 'lan') ? 'lan' : 'local';
			renderAgentLabel();
			var data = (r && r.agents) || {};
			state.agents = Object.keys(data).map(function (id) {
				return { id: id, name: data[id].name, installed: data[id].installed };
			});
			renderAgentSelect();
			renderConsoleNotice();
		}).catch(function () {
			/* The console still works with existing sessions. Count the attempt as
			 * the last read so the stale check does not retry it on every tick. */
			state.consoleAt = Date.now();
		});
	}

	function renderAgentLabel() {
		var label = FCC.$('#fcc-agent-label');
		if (!label) { return; }
		label.textContent = state.target === 'lan'
			? FCC._('Agent [LAN]')
			: FCC._('Agent [This router]');
	}

	/**
	 * The one thing standing between the page and a working session, if any.
	 *
	 * A LAN target adds two answers of its own: the target may be unreachable or
	 * half-configured (in which case there is no agent list at all), or it may
	 * answer while its FCC server is stopped — the agents exist, and a session
	 * would start one that cannot connect to anything.
	 */
	function renderConsoleNotice() {
		var box = FCC.$('#fcc-term-status');
		if (!box || !state.console) { return; }

		var kind = '', text = '';
		if (state.console.ok === false) {
			kind = 'fail';
			text = consoleReason(state.console);
		} else if (state.target === 'lan' && state.console.running === false) {
			kind = 'warn';
			text = serverStoppedNotice();
		}

		if (!kind) {
			/* Nothing to say. Clear the line only if it still holds what this
			 * function put there; a message an action just wrote (a session
			 * that failed to start, say) is not this function's to erase. */
			if (consoleNotice && box.textContent === consoleNotice) {
				FCC.notice(box, '', '');
			}
			consoleNotice = '';
			return;
		}

		FCC.notice(box, kind, text);
		consoleNotice = text;
	}

	/**
	 * Notice a mode switch made in the Configuration tab.
	 *
	 * Reading UCI is cheap and reading the other machine's agents is not, so the
	 * poll only compares the target. A change is what triggers the one SSH round
	 * trip, which keeps an idle console tab from asking the LAN machine anything.
	 *
	 * The answer goes stale all the same: the LAN machine's server may be started
	 * or stopped from the Configuration tab, or the machine may come back after
	 * being unreachable. So one re-read a minute keeps the notice honest without
	 * turning the poll into a stream of SSH connections.
	 */
	function refreshTarget() {
		return FCC.api('console_target', {}, { method: 'GET' }).then(function (r) {
			var t = (r && r.target === 'lan') ? 'lan' : 'local';
			if (t !== state.target || Date.now() - state.consoleAt > 60000) {
				loadConsole();
			}
		}).catch(function () { /* try again on the next tick */ });
	}

	function renderAgentSelect() {
		var sel = FCC.$('#fcc-agent-select');
		if (!sel) { return; }
		/* The console re-reads its state every minute, and a rebuild that reset
		 * the choice would undo what the user just picked. */
		var chosen = sel.value;
		sel.innerHTML = '';
		if (state.console && state.console.ok === false) {
			/* "Unavailable" alone would be a key another package can claim for
			 * something else entirely; the label names what is unavailable. */
			sel.appendChild(FCC.el('option', { value: '', text: FCC._('Agent list unavailable') }));
			return;
		}
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
		/* Only restore the choice if it survived: assigning a value no option
		 * carries would select nothing at all, where leaving the default stands
		 * shows the first entry. */
		if (chosen && list.some(function (a) { return a.id === chosen; })) {
			sel.value = chosen;
		}
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
			/* Each tab says which machine its agent runs on. The dropdown's
			 * label describes the next session; a tab has to describe its own,
			 * and a session made before a mode change keeps running where it
			 * was made — so the two can legitimately differ. */
			var where = (s.target === 'lan') ? FCC._('LAN') : FCC._('This router');
			var tab = FCC.el('button', {
				class: 'fcc-term-tab' + (s.name === state.active ? ' active' : ''),
				onclick: function () { attach(s.name); },
				title: FCC._('Runs on') + ': ' + where
			}, [
				FCC.el('span', { class: 'fcc-dot ' + (s.uptime !== null ? 'on' : 'off') }),
				FCC.el('span', { text: s.name }),
				FCC.el('span', { class: 'fcc-badge', text: where }),
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

		/* The terminal's box can change without the window changing: Argon's
		 * menu finishes laying out, a scrollbar appears, the page is painted
		 * after a fresh login. Only the window's resize was watched, so a
		 * terminal fitted against the old box kept its old column count — and
		 * a captured screen painted into it at the wrong width stayed wrong
		 * until the user zoomed, which fires a resize and forces a refit. */
		if (window.ResizeObserver) {
			state.ro = new window.ResizeObserver(scheduleFit);
			state.ro.observe(FCC.$('#fcc-term'));
		}
	}

	var fitTimer = null;

	/* A resize observer fires on every frame of a layout change, so the refit
	 * waits for it to settle rather than resizing tmux a dozen times. */
	function scheduleFit() {
		if (fitTimer) { return; }
		fitTimer = setTimeout(function () { fitTimer = null; fitNow(); }, 150);
	}

	/* Resolves when the pane has been told this window's size — which is what
	 * attach waits for before it asks for the screen. */
	function fitNow() {
		if (!state.fit) { return Promise.resolve(); }
		try { state.fit.fit(); } catch (e) { return Promise.resolve(); }
		if (!state.active || !state.term) { return Promise.resolve(); }

		var cols = state.term.cols, rows = state.term.rows;
		/* Before the page has laid out, fit() proposes a size the backend
		 * refuses. Leave it to the observer, which fires once it has one. */
		if (cols < 20 || rows < 5) { return Promise.resolve(); }
		if (state.size && state.size.cols === cols && state.size.rows === rows) {
			return Promise.resolve();
		}
		state.size = { cols: cols, rows: rows };

		/* The pane reflows to the same grid, and the agent repaints on the
		 * SIGWINCH that follows — which is what heals the screen after a zoom
		 * or a window resize. */
		return FCC.api('session_resize', {
			name: state.active,
			cols: cols,
			rows: rows
		}, { method: 'POST' }).catch(function () { /* session may have ended */ });
	}

	function attach(name) {
		state.active = name;
		state.size = null;      // the new session's pane may be a different size
		clearBanner();
		renderTabs();
		ensureTerm();

		// The pane is resized to this window first: a captured screen is the
		// pane's own grid, and painting a grid wider than the terminal wraps
		// every row at the wrong column. Then repaint from that screen and
		// continue from the end of the captured stream, so reconnecting shows
		// what is on screen now rather than replaying everything.
		fitNow().then(function () {
			return FCC.api('session_capture', { name: name }, { method: 'GET' });
		}).then(function (r) {
			if (state.active !== name) { return null; }   // the user switched tabs
			state.term.reset();
			state.term.write(FCC.captureBytes(r.data));
			return FCC.api('session_output', { name: name, offset: 0, wait: 0 }, { method: 'GET' });
		}).then(function (r) {
			if (!r || state.active !== name) { return; }
			state.offset = r.offset;
			startPolling();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-term-status'), 'fail',
				FCC._('Could not attach to the session:') + ' ' + err.message);
		});

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
					if (banner) { clearBanner(); }
					pollLoop();
				} else {
					state.polling = false;
					// Section 74: the exit code decides which ending this was.
					// Zero finished cleanly; anything else — including a code
					// tmux could not report — is shown as an unexpected exit.
					showBanner(r.exit_code === 0 ? 'exited' : 'crashed',
						{ code: r.exit_code, agent: agentOf(name) });
					loadSessions();
				}
			})
			.catch(function (err) {
				if (err && err.name === 'AbortError') { return; }
				if (!state.polling || state.active !== name) { return; }
				// The session outlives the connection: tmux is still holding it,
				// so say so and keep retrying from the same offset. Nothing is
				// lost, and the banner clears itself on the next success.
				showBanner('lost', {});
				setTimeout(pollLoop, 2000);
			});
	}

	/* -------------------------------------------------- section 74: endings */

	/** The agent a session belongs to, from the last session list we fetched. */
	function agentOf(name) {
		var match = state.sessions.filter(function (s) { return s.name === name; })[0];
		if (match && match.agent) { return match.agent; }
		/* The name carries the agent id — `fcc-<agent>-<nnn>` — so a session
		 * the list does not hold yet (just created, or a list that failed to
		 * load) still answers this question. */
		match = /^fcc-([a-z0-9]+)-[0-9]{3}$/.exec(name || '');
		return match ? match[1] : '';
	}

	/*
	 * The browser UI DeepSeek Harness prints when it boots.
	 *
	 * It is the one agent with no terminal interface: `fcc-dsh` runs `dsh web`,
	 * which serves a browser UI and prints its address — token included — once,
	 * on the pane's first screen. The token is new on every launch, so that
	 * screen is the only place the address exists. The escape character is
	 * excluded from the match so it cannot swallow a repaint sequence that
	 * follows the address.
	 */
	var DSH_URL = /https?:\/\/[^\s"'<>\x1b]+[?&]token=[A-Za-z0-9_-]+/g;

	function dshUrlIn(data) {
		var text;
		try { text = new TextDecoder('utf-8').decode(FCC.b64ToBytes(data)); }
		catch (e) { return ''; }
		var found = text.match(DSH_URL);
		return found ? found[found.length - 1] : '';
	}

	/**
	 * Ask a dsh session for its address until it has printed one.
	 *
	 * offset 0 asks for everything the pane has kept, so a session that was
	 * already running is answered on the first try, while one this click
	 * created needs a few seconds. `alive` ends the wait early: a pane that has
	 * died will never print an address, and the fallback shows why.
	 */
	function waitForDshUrl(name, deadline, cb) {
		FCC.api('session_output', { name: name, offset: 0, wait: 0 }, { method: 'GET' })
			.then(function (r) {
				var url = dshUrlIn(r && r.data);
				if (url) { cb(url); return; }
				if (!r || !r.alive || Date.now() > deadline) { cb(''); return; }
				setTimeout(function () { waitForDshUrl(name, deadline, cb); }, 700);
			})
			.catch(function () { cb(''); });
	}

	function bannerAction(label, style, fn) {
		return FCC.el('button', {
			class: 'cbi-button cbi-button-' + style,
			text: label,
			onclick: fn
		});
	}

	function exitCodeLine(code) {
		return FCC._('Exit code: %d').replace('%d', code);
	}

	function clearBanner() {
		var box = FCC.$('#fcc-term-banner');
		if (box) { box.innerHTML = ''; box.hidden = true; }
		banner = null;
	}

	/**
	 * Section 74. A dropped connection, a session that finished and an agent
	 * that died are three different events with three different remedies, so
	 * each gets its own banner. A single "Stopped" is exactly the outcome the
	 * section exists to prevent: the user cannot tell which happened or what to
	 * do next.
	 *
	 * The exit code picks between the last two. Zero is a clean finish. A
	 * non-zero code is a crash. No code at all means tmux could not account for
	 * the exit, which is reported as a plain exit rather than guessed at — the
	 * buttons still lead somewhere useful either way.
	 */
	function showBanner(kind, opts) {
		var box = FCC.$('#fcc-term-banner');
		if (!box) { return; }
		if (banner === kind && !box.hidden) { return; }

		opts = opts || {};
		var code = (typeof opts.code === 'number') ? opts.code : null;
		var lines, buttons;

		if (kind === 'lost') {
			lines = [
				FCC._('Terminal connection lost.'),
				FCC._('Session is still running.')
			];
			buttons = [bannerAction(FCC._('Reconnect'), 'apply', function () {
				clearBanner();
				startPolling();
			})];
		} else if (kind === 'exited') {
			lines = [FCC._('Session has exited.')];
			if (code !== null) { lines.push(exitCodeLine(code)); }
			buttons = [
				bannerAction(FCC._('Start New Session'), 'apply', function () {
					createSession(opts.agent);
				}),
				bannerAction(FCC._('View Log'), 'reset', showLog)
			];
		} else {
			lines = [code === null
				? FCC._('Session has exited.')
				: FCC._('Agent exited unexpectedly.')];
			if (code !== null) { lines.push(exitCodeLine(code)); }
			buttons = [
				bannerAction(FCC._('View Log'), 'reset', showLog),
				bannerAction(FCC._('Restart'), 'apply', function () {
					createSession(opts.agent);
				})
			];
		}

		box.innerHTML = '';
		lines.forEach(function (text) {
			box.appendChild(FCC.el('div', { class: 'fcc-term-banner-line', text: text }));
		});
		box.appendChild(FCC.el('div', { class: 'fcc-term-banner-actions' }, buttons));
		box.hidden = false;
		banner = kind;
	}

	/* The session log: what the backend records about this session's lifecycle.
	 * It is the log that exists — the agent's own output went to the pane, which
	 * is the terminal itself and still readable above. */
	function showLog() {
		var panel = FCC.$('#fcc-term-log');
		var body = FCC.$('#fcc-term-log-body');
		if (!panel || !body) { return; }
		panel.hidden = false;
		body.textContent = FCC._('Loading…');
		FCC.api('log', { name: 'fcc-terminal.log', lines: 200 }, { method: 'GET' })
			.then(function (r) {
				FCC.$('#fcc-term-log-name').textContent = r.path || 'fcc-terminal.log';
				body.textContent = (r.lines && r.lines.length)
					? r.lines.join('\n')
					: FCC._('This log is empty.');
			})
			.catch(function (err) { body.textContent = err.message; });
	}

	/* ----------------------------------------------------------------- actions */

	/** Open a new session, for `agent` or for whatever the toolbar has selected. */
	function createSession(agent) {
		if (!agent) {
			var sel = FCC.$('#fcc-agent-select');
			agent = sel ? sel.value : '';
		}
		if (!agent) {
			FCC.notice(FCC.$('#fcc-term-status'), 'warn',
				FCC._('Install an agent first (Configuration → Agents).'));
			return;
		}
		var cols = 80, rows = 24;
		if (state.term) { cols = state.term.cols; rows = state.term.rows; }

		FCC.api('session_create', { agent: agent, cols: cols, rows: rows }, { method: 'POST' })
			.then(function (r) {
				/* A LAN refusal arrives as a body with ok:false, not as an HTTP
				 * error: the reason codes are the only part worth translating,
				 * and the shell's own sentence for them is English. */
				if (r && r.ok === false) {
					FCC.notice(FCC.$('#fcc-term-status'), 'fail', consoleReason(r));
					return;
				}
				clearBanner();
				FCC.notice(FCC.$('#fcc-term-status'), '', '');
				return loadSessions().then(function () { attach(r.name); });
			})
			.catch(function (err) {
				FCC.notice(FCC.$('#fcc-term-status'), 'fail', err.message);
			});
	}

	function closeSession(name) {
		/* Section 10 requires the confirmation before the session dies, and it
		 * is not ceremony: closing kills the agent process, and whatever the
		 * agent was holding in the terminal is gone.
		 *
		 * The break between the two sentences is a literal join, not a "\n"
		 * inside one message. po2lmo does not process C escapes — it hashes the
		 * .po text verbatim — so a msgid containing "\n" is stored under a key
		 * built from a backslash and an "n", while the runtime holds the
		 * evaluated string, which has a real newline. The two can never match,
		 * so the entry is dead and this dialog stays English whatever the
		 * interface language is. Same shape as serverOp() in fcc-config.js. */
		if (!window.confirm(FCC._('Are you sure you want to close this session?') + '\n' +
				FCC._('All unsaved terminal state will be lost.'))) {
			return;
		}
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

	/**
	 * End every session at once.
	 *
	 * Same confirmation as closeSession(): this kills agents, and a browser
	 * dialog is the last chance to notice a misclick before several of them go.
	 * The two sentences are a literal join for the reason given there — po2lmo
	 * does not process C escapes, so a "\n" may not appear in a msgid.
	 */
	function endAllSessions() {
		if (!window.confirm(FCC._('Are you sure you want to end all sessions?') + '\n' +
				FCC._('Every running agent will be terminated and unsaved terminal state will be lost.'))) {
			return;
		}
		FCC.api('session_close_all', {}, { method: 'POST' }).then(function () {
			state.active = null;
			stopPolling();
			clearBanner();
			if (state.term) {
				state.term.reset();
				state.term.write('\r\n[ all sessions closed ]\r\n');
			}
			loadSessions();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-term-status'), 'fail', err.message);
		});
	}

	/**
	 * Show one session in a window of its own, outside the LuCI page.
	 *
	 * The window is opened synchronously and navigated afterwards. Opened after
	 * an await it would no longer be inside the click's user gesture, and the
	 * browser would take it for a popup and block it. Because the window must
	 * exist before a session can be chosen, it waits empty until one does.
	 *
	 * That window owns the session: closing it ends the session, reloading it
	 * does not (see fcc-popout.js). The console page is unaffected and can
	 * still attach to the same session while the window is open.
	 *
	 * DeepSeek Harness is the exception. It has no terminal — only a browser UI
	 * — so for it the window receives that UI instead of a second copy of a
	 * pane that can never take keystrokes.
	 */
	function openInBrowser() {
		var win = window.open('', '_blank');
		var status = FCC.$('#fcc-term-status');
		if (!win) {
			FCC.notice(status, 'warn', FCC._('The browser blocked the new window.'));
			return;
		}

		var popout = window.FCC_POPOUT || '';

		function goTerminal(name) {
			win.location.href = popout + '?session=' + encodeURIComponent(name);
		}

		/**
		 * Point the window at the harness's own UI once the pane has printed
		 * its address. The session stays alive while the UI is open and the
		 * window deliberately does not adopt the popout's ownership: closing
		 * the UI tab must not kill the harness the session is serving.
		 */
		function goDsh(name) {
			try {
				win.document.title = 'DeepSeek Harness';
				win.document.body.style.cssText = 'font:14px sans-serif;padding:2em';
				win.document.body.textContent = FCC._('Starting DeepSeek Harness…');
			} catch (e) { /* the window may already be closed */ }
			waitForDshUrl(name, Date.now() + 30000, function (url) {
				if (url) {
					try { win.location.href = url; } catch (e) { /* closed */ }
					return;
				}
				/* No address: the pane's own screen says why (an error, a
				 * missing integration) better than a blank window would. */
				FCC.notice(status, 'warn',
					FCC._('DeepSeek Harness did not print its address; showing its pane instead.'));
				goTerminal(name);
			});
		}

		function go(name, agent) {
			if ((agent || agentOf(name)) === 'dsh') { goDsh(name); return; }
			goTerminal(name);
		}

		if (state.active) { go(state.active); return; }
		if (state.sessions.length) { go(state.sessions[0].name, state.sessions[0].agent); return; }

		var sel = FCC.$('#fcc-agent-select');
		var agent = sel ? sel.value : '';
		function abort(msg) {
			try { win.close(); } catch (e) { /* already gone */ }
			FCC.notice(status, 'fail', msg);
		}
		if (!agent) {
			abort(FCC._('Install an agent first (Configuration → Agents).'));
			return;
		}

		FCC.api('session_create', { agent: agent, cols: 80, rows: 24 }, { method: 'POST' })
			.then(function (r) {
				if (r && r.ok === false) { abort(consoleReason(r)); return; }
				loadSessions();
				/* The list has not reloaded yet, so the agent the click chose is
				 * passed along rather than read back from it. */
				go(r.name, agent);
			})
			.catch(function (err) { abort(err.message); });
	}

	/* -------------------------------------------------------------------- init */

	function init() {
		var createBtn = FCC.$('#fcc-term-create');
		// Wrapped, not passed directly: addEventListener hands the handler a
		// MouseEvent, which createSession() would take for an agent id.
		if (createBtn) { createBtn.addEventListener('click', function () { createSession(); }); }

		var closeAllBtn = FCC.$('#fcc-term-close-all');
		if (closeAllBtn) { closeAllBtn.addEventListener('click', endAllSessions); }

		var popoutBtn = FCC.$('#fcc-term-popout');
		if (popoutBtn) { popoutBtn.addEventListener('click', openInBrowser); }

		var logHide = FCC.$('#fcc-term-log-hide');
		if (logHide) {
			logHide.addEventListener('click', function () {
				FCC.$('#fcc-term-log').hidden = true;
			});
		}

		ensureTerm();
		loadConsole();
		loadSessions().then(function () {
			// Re-attach to the most recent session after a page reload.
			if (state.sessions.length) { attach(state.sessions[0].name); }
		});

		// The existing ten-second tick refreshes the session list, and costs one
		// more UCI read to see whether the Configuration tab was switched while
		// this page was open. A change is the only thing that costs an SSH trip.
		state.listTimer = setInterval(function () { loadSessions(); refreshTarget(); }, 10000);
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
