/*
 * luci-app-fcc — Configuration page.
 *
 * Settings, FCC server control and the runtime lifecycle.
 *
 * Installs and updates take minutes, so they are started through the API and
 * then polled: .../api/job reports whether the install lock is still held and
 * returns the tail of the log, which is what the progress panel renders.
 *
 * There is no agent table here any more. It was the picker (section 3.6.5) and
 * the reason this file carried a selection, a registry, a recommendation and a
 * set of per-row actions; an install now takes the whole registry and the
 * backend builds that set, so none of it has anything left to do. The agent
 * list that remains is on Basic Information, which is a report and not a
 * control. Section 104.25.
 */
(function () {
	'use strict';

	var FCC = window.FCC;

	var jobTimer = null;
	var jobStart = 0;

	/* ------------------------------------------------------------- settings */

	function loadConfig() {
		return FCC.api('config_get', {}, { method: 'GET' }).then(function (d) {
			var c = d.config || {};
			FCC.$('#fcc-enabled').checked = (c.enabled === '1');
			FCC.$('#fcc-auto-start').checked = (c.auto_start === '1');
			FCC.$('#fcc-install-path').value = c.install_path || '/opt';
			FCC.$('#fcc-bind').value = c.bind || '127.0.0.1';
			FCC.$('#fcc-port').value = c.port || 8082;
			FCC.$('#fcc-log-level').value = c.log_level || 'info';
			return d;
		});
	}

	function saveConfig() {
		var body = {
			enabled: FCC.$('#fcc-enabled').checked ? '1' : '0',
			auto_start: FCC.$('#fcc-auto-start').checked ? '1' : '0',
			install_path: FCC.$('#fcc-install-path').value,
			bind: FCC.$('#fcc-bind').value,
			port: FCC.$('#fcc-port').value,
			log_level: FCC.$('#fcc-log-level').value
		};
		FCC.notice(FCC.$('#fcc-config-status'), '', '');
		FCC.api('config_set', body, { method: 'POST' }).then(function (r) {
			var msg = FCC._('Settings saved.');
			if (r.path_changed) {
				msg += ' ' + FCC._('The install path changed — install the runtime at the new location to use it.');
			}
			/* Section 50: say what happened to the firewall, so a wildcard bind
			 * does not silently change a system setting the user never sees. */
			if (r.firewall === 'lan-allow') {
				msg += ' ' + FCC._('LAN access was opened in the firewall. The WAN is unaffected.');
			} else if (r.firewall === 'removed') {
				msg += ' ' + FCC._('The LAN access rule was removed; the port is no longer opened by this app.');
			} else if (r.firewall === 'failed') {
				msg += ' ' + FCC._('The firewall rule could not be added — the server is bound to every interface without one.');
			}
			FCC.notice(FCC.$('#fcc-config-status'), r.path_changed ? 'warn' : 'ok', msg);
			refreshAll();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
	}

		/* The Admin link needs no script at all now: it points at the LuCI reverse
	 * proxy (section 104.22), which reaches the server on 127.0.0.1 whatever
	 * the bind address is, so it works from any device that can reach LuCI.
	 * What used to live here — disabling the link and explaining how to bind
	 * the server to the LAN address — was built on the premise that a LAN bind
	 * makes the FCC port reachable. It does not: the server refuses every admin
	 * route to a non-loopback peer, so that advice ended in
	 * {"detail":"Admin UI is local-only"} and the link was never worth
	 * rewiring. */

	/* --------------------------------------------------------- server state */

	/* Every panel on this page is filled from the one batched status call, so
	 * the renderers take that document rather than each fetching their own —
	 * three panels polling separately would cost the router three processes per
	 * refresh for one answer. */
	function renderServer(d) {
		var box = FCC.$('#fcc-server-state');
		var s = d.server || {};
		var f = d.fcc || {};
		box.innerHTML = '';
		box.appendChild(FCC.el('div', {}, [
			FCC.el('span', { class: 'fcc-dot ' + (s.running ? 'on' : 'off') }),
			FCC.el('strong', {
				text: s.running ? FCC._('Running') : FCC._('Stopped')
			})
		]));
		var rows = [
			[FCC._('Version'), f.version || '—'],
			[FCC._('PID'), s.running ? String(s.pid) : '—'],
			[FCC._('Uptime'), s.running ? FCC.fmtDuration(s.uptime) : '—'],
			[FCC._('Memory (RSS)'), s.running ? FCC.fmtKB(s.memory_rss_kb) : '—'],
			[FCC._('Listening on'), (s.bind || '—') + ':' + (s.port || '—')]
		];
		box.appendChild(FCC.el('table', { class: 'fcc-table' },
			rows.map(function (r) {
				return FCC.el('tr', {}, [
					FCC.el('th', { text: r[0] }),
					FCC.el('td', { class: 'fcc-mono', text: r[1] })
				]);
			})
		));
	}

	/* Section 12: stopping the server has to say so before it happens, because
	 * the agent sessions are separate processes that the stop does not kill —
	 * they keep running, cut off from the server they were talking to. The
	 * warning is mandated; the count is what makes it more than a platitude,
	 * so it is fetched first and folded into the same dialog. */
	function serverOp(op) {
		var confirmText = (op === 'stop' || op === 'restart')
			? FCC._('Stopping FCC Server may affect active Coding Agent sessions.')
			: null;

		var pre = confirmText
			? FCC.api('status', {}, { method: 'GET' }).catch(function () { return {}; })
			: Promise.resolve({});

		pre.then(function (d) {
			if (confirmText) {
				var n = (d.sessions && d.sessions.active) || 0;
				var msg = confirmText + '\n\n'
					+ (n ? FCC._('%d agent session(s) are running and will be left as they are.').replace('%d', n)
					     : FCC._('No agent sessions are running.'));
				if (!window.confirm(msg)) { return; }
			}

			FCC.notice(FCC.$('#fcc-server-status'), '', '');
			return FCC.api('server', { op: op }, { method: 'POST' }).then(function (r) {
				if (!r.ok) {
					FCC.notice(FCC.$('#fcc-server-status'), 'fail',
						r.output || FCC._('The operation failed.'));
				} else {
					FCC.notice(FCC.$('#fcc-server-status'), 'ok', FCC._('Done.'));
				}
				setTimeout(refreshAll, 1500);
			});
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-server-status'), 'fail', err.message);
		});
	}

	/* -------------------------------------------------------- runtime + jobs */

	function renderRuntime(d) {
		var box = FCC.$('#fcc-runtime-state');
		box.innerHTML = '';
		var f = d.fcc || {};
		box.appendChild(FCC.el('div', {}, [
			FCC.el('span', { class: 'fcc-dot ' + (f.installed ? 'on' : 'off') }),
			FCC.el('strong', {
				text: f.installed ? FCC._('Installed') : FCC._('Not installed')
			}),
			FCC.el('span', {
				class: 'fcc-muted',
				text: f.installed ? '  v' + (f.version || '?') : ''
			})
		]));
	}

	/* The install script prints PRECHECK_FAILED as the machine-readable verdict
	 * for "the compatibility gate refused this". It is the one line in a job's
	 * output that is a decision rather than progress, which is what makes it
	 * worth matching on: everything else in that log is the work that led to it
	 * or the work that follows. */
	function jobWasBlocked(lines) {
		return (lines || []).some(function (l) {
			return String(l).indexOf('PRECHECK_FAILED') !== -1;
		});
	}

	function startJobWatch(lock, log) {
		jobStart = Date.now();
		var panel = FCC.$('#fcc-job');
		if (panel) { panel.style.display = ''; }
		if (jobTimer) { clearInterval(jobTimer); }

		/* A job that has just been asked for has not necessarily taken its lock
		 * yet. The POST's response is written by the CGI before the forked shell
		 * has run its first line, so the very first poll can find the lock
		 * unheld — and reading that as "the job is over" is what made the bar
		 * jump straight to 100% for an install that then ran for minutes.
		 *
		 * So two things have to be true before "not running" means "finished":
		 * the watch has seen the job running at least once, or the settle window
		 * has passed. The window covers the opposite case — a job that starts
		 * and stops between two polls, such as an install the compatibility gate
		 * refuses, which exits in well under a second — and it is short enough
		 * that a request that really did start nothing is not left spinning. */
		var seenRunning = false;
		var JOB_SETTLE_MS = 8000;

		var tick = function () {
			FCC.api('job', { lock: lock, log: log, lines: 60 }, { method: 'GET' })
				.then(function (r) {
					var pre = FCC.$('#fcc-job-log');
					if (pre) {
						pre.innerHTML = (r.lines || []).map(function (l) {
							var cls = /error|fail|traceback/i.test(l) ? 'lvl-err'
								: (/warn/i.test(l) ? 'lvl-warn' : '');
							return cls
								? '<span class="' + cls + '">' + FCC.esc(l) + '</span>'
								: FCC.esc(l);
						}).join('\n');
						pre.scrollTop = pre.scrollHeight;
					}
					// The lock is the authoritative "still working" signal; the
					// elapsed time only drives the indeterminate bar.
					/* The bar is an estimate, and an estimate that stops moving
					 * looks like a hang. The previous formula — a straight three
					 * seconds per percent, capped at 95 — reached the cap after
					 * five minutes and then sat there for the rest of the run,
					 * which is exactly what the person waiting on a ten-minute
					 * install saw: the work was still going and the bar said it
					 * had stopped. An asymptote instead: quick at the start,
					 * slowing as it approaches the cap but never arriving, so it
					 * is still visibly moving half an hour in. It deliberately
					 * never reaches 100% — only the lock being released means
					 * the job ended, and the branch below is what sets that. */
					var bar = FCC.$('#fcc-job-bar');
					if (r.running) { seenRunning = true; }
					if (bar && r.running) {
						var secs = (Date.now() - jobStart) / 1000;
						bar.style.width = (95 * (1 - Math.exp(-secs / 240))).toFixed(1) + '%';
					}

					if (!r.running && (seenRunning || Date.now() - jobStart > JOB_SETTLE_MS)) {
						clearInterval(jobTimer);
						jobTimer = null;
						if (bar) { bar.style.width = '100%'; }
						/* A job that stopped because the compatibility gate
						 * refused it has already written the failing checks —
						 * with their current values and the fix for each — into
						 * the log shown above. What it has not done is say so in
						 * the page's own words, and a log that simply stops
						 * scrolling looks like a crash. Section 3.6.4 wants the
						 * reason on screen, so the one-line summary goes beside
						 * the log that carries the detail. */
						if (jobWasBlocked(r.lines)) {
							FCC.notice(FCC.$('#fcc-config-status'), 'fail',
								FCC._('Installation is blocked until the failed checks pass.'));
						}
						refreshAll();
					}
				})
				.catch(function () { /* keep polling; a blip is not a failure */ });
		};

		tick();
		jobTimer = setInterval(tick, 2000);
	}

	function runJobAction(action, params, lock, log) {
		FCC.api(action, params || {}, { method: 'POST' }).then(function () {
			startJobWatch(lock, log);
		}).catch(function (err) {
			/* The request failed, so no job was started — but the panel is still
			 * the right place to be, because the two things that explain a
			 * refusal are the lock and the log: a previous run that never
			 * released the lock, or a job that started and stopped before the
			 * response was read. Watching costs nothing when there is nothing to
			 * watch, and it means the failure is never a single sentence with
			 * the evidence hidden behind it. */
			startJobWatch(lock, log);
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
	}

	/* -------------------------------------------------------------- doctor */

	function runDoctor() {
		var box = FCC.$('#fcc-doctor');
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Running checks…') }));

		FCC.api('doctor', {}, { method: 'GET' }).then(function (d) {
			box.innerHTML = '';
			var table = FCC.el('table', { class: 'fcc-table fcc-checks' });
			(d.checks || []).forEach(function (c) {
				var kind = c.status === 'OK' ? 'ok' : (c.status === 'WARN' ? 'warn' : 'fail');
				table.appendChild(FCC.el('tr', {}, [
					FCC.el('td', {}, [FCC.el('span', { class: 'fcc-badge ' + kind, text: c.status })]),
					FCC.el('td', { text: c.name }),
					FCC.el('td', { class: 'fcc-mono', text: c.value }),
					FCC.el('td', { class: 'fcc-muted', text: c.hint || '' })
				]));
			});
			box.appendChild(table);
			if (!d.install_allowed) {
				box.appendChild(FCC.el('div', {
					class: 'fcc-note fail',
					text: FCC._('Installation is blocked until the failed checks pass.')
				}));
			}
		}).catch(function (err) {
			FCC.notice(box, 'fail', err.message);
		});
	}

	/* ---------------------------------------------------------------- init */

	function refreshAll() {
		return FCC.api('status', {}, { method: 'GET' }).then(function (d) {
			renderServer(d);
			renderRuntime(d);
			return d;
		});
	}

	/* There is no ordering requirement left on the first paint. It used to have
	 * one — the recommended set had to be known before the table was drawn,
	 * because the table was where the tick boxes lived — and with the table gone
	 * the first paint is just the first refresh. Section 104.25. */

	function init() {
		FCC.$('#fcc-save').addEventListener('click', saveConfig);

		Array.prototype.forEach.call(
			document.querySelectorAll('[data-op]'),
			function (b) {
				b.addEventListener('click', function () { serverOp(b.getAttribute('data-op')); });
			}
		);

		/* Install takes the whole registry, and the backend builds that set: the
		 * button sends no agent list at all. It used to send the ticked boxes
		 * (section 3.6.5), which is why the page carried a selection — and an
		 * empty selection meant "install none", so a press before the table had
		 * been drawn had to be special-cased. Nothing to special-case now. */
		FCC.$('#fcc-runtime-install').addEventListener('click', function () {
			runJobAction('install_runtime', {}, 'install', 'fcc-runtime.log');
		});
		/* Reinstall is its own operation, not a flavour of Install: it removes
		 * the runtime first, because the upstream installer reconciles the agent
		 * set rather than reinstalling what is already there (section 104.25). */
		FCC.$('#fcc-runtime-reinstall').addEventListener('click', function () {
			if (!window.confirm(FCC._('Remove the FCC runtime and install it again with every agent? Your configuration and data under the install path are kept.'))) {
				return;
			}
			runJobAction('reinstall_runtime', {}, 'install', 'fcc-runtime.log');
		});
		FCC.$('#fcc-runtime-update').addEventListener('click', function () {
			runJobAction('update_runtime', {}, 'install', 'fcc-update.log');
		});
		/* Uninstall comes in two strengths, and the confirmation says which one
		 * you are getting rather than mentioning a purge the button does not
		 * perform. The destructive one names what is lost — the dialog is the
		 * only place that can still change the user's mind. */
		FCC.$('#fcc-runtime-uninstall').addEventListener('click', function () {
			if (!window.confirm(FCC._('Remove the FCC runtime? Your configuration and data under the install path are kept.'))) {
				return;
			}
			runJobAction('uninstall_runtime', {}, 'install', 'fcc-runtime.log');
		});
		FCC.$('#fcc-runtime-purge').addEventListener('click', function () {
			if (!window.confirm(FCC._('Remove the FCC runtime and all of its data? This deletes the runtime, the agents, your configuration and every backup. It cannot be undone.'))) {
				return;
			}
			runJobAction('uninstall_runtime', { purge: 1 }, 'install', 'fcc-runtime.log');
		});

		FCC.$('#fcc-doctor-run').addEventListener('click', runDoctor);

		loadConfig().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
		refreshAll().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
