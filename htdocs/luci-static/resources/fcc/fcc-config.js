/*
 * luci-app-fcc — Configuration page.
 *
 * Settings, FCC server control, runtime lifecycle and the agent table.
 *
 * Installs and updates take minutes, so they are started through the API and
 * then polled: .../api/job reports whether the install lock is still held and
 * returns the tail of the log, which is what the progress panel renders.
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
			updateAdminLink(c.bind, c.port);
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
			FCC.notice(FCC.$('#fcc-config-status'), r.path_changed ? 'warn' : 'ok', msg);
			updateAdminLink(body.bind, body.port);
			refreshAll();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
	}

	/**
	 * The FCC Admin page is served by the FCC server itself, on the router. A
	 * browser can only reach it if the server is bound to an address the
	 * browser can route to — 127.0.0.1 means "the router's own loopback", which
	 * is not reachable from a client machine.
	 */
	function updateAdminLink(bind, port) {
		var link = FCC.$('#fcc-admin-link');
		if (!link) { return; }
		port = port || 8082;
		if (bind === '127.0.0.1' || bind === '::1') {
			link.removeAttribute('href');
			link.classList.add('fcc-disabled');
			link.title = FCC._('The server is bound to loopback. Bind it to this router\'s LAN address to open the Admin page from your computer.');
			link.setAttribute('aria-disabled', 'true');
		} else {
			link.href = location.protocol + '//' + location.hostname + ':' + port + '/';
			link.removeAttribute('aria-disabled');
			link.classList.remove('fcc-disabled');
			link.title = FCC._('Opens the FCC Admin page in a new tab.');
		}
	}

	/* --------------------------------------------------------- server state */

	function loadServer() {
		return FCC.api('status', {}, { method: 'GET' }).then(function (d) {
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
			return d;
		});
	}

	function serverOp(op) {
		FCC.notice(FCC.$('#fcc-server-status'), '', '');
		FCC.api('server', { op: op }, { method: 'POST' }).then(function (r) {
			if (!r.ok) {
				FCC.notice(FCC.$('#fcc-server-status'), 'fail',
					r.output || FCC._('The operation failed.'));
			} else {
				FCC.notice(FCC.$('#fcc-server-status'), 'ok', FCC._('Done.'));
			}
			setTimeout(function () { loadServer(); refreshRuntime(); }, 1500);
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-server-status'), 'fail', err.message);
		});
	}

	/* ------------------------------------------------------------- agents */

	function loadAgents() {
		return FCC.api('agents', {}, { method: 'GET' }).then(function (data) {
			var tbody = FCC.$('#fcc-agent-table tbody');
			tbody.innerHTML = '';
			Object.keys(data).forEach(function (id) {
				var a = data[id];
				var state = a.running
					? FCC.el('span', { class: 'fcc-badge ok', text: FCC._('running') })
					: (a.installed
						? FCC.el('span', { class: 'fcc-badge', text: FCC._('installed') })
						: FCC.el('span', { class: 'fcc-badge off', text: FCC._('not installed') }));

				var action = a.installed
					? FCC.el('button', {
						class: 'cbi-button cbi-button-remove',
						text: FCC._('Remove'),
						disabled: a.running ? 'disabled' : null,
						title: a.running ? FCC._('Close its session first.') : '',
						onclick: function () { agentOp('agent_remove', id); }
					})
					: FCC.el('button', {
						class: 'cbi-button cbi-button-apply',
						text: FCC._('Install'),
						onclick: function () { agentOp('agent_install', id); }
					});

				tbody.appendChild(FCC.el('tr', {}, [
					FCC.el('td', { text: a.name }),
					FCC.el('td', { class: 'fcc-mono', text: a.command }),
					FCC.el('td', { class: 'fcc-mono', text: a.version || '—' }),
					FCC.el('td', {}, [state]),
					FCC.el('td', { class: 'fcc-right' }, [action])
				]));
			});
		});
	}

	function agentOp(action, id) {
		FCC.notice(FCC.$('#fcc-agent-status'), '', '');
		FCC.api(action, { id: id }, { method: 'POST' }).then(function () {
			startJobWatch('install', 'fcc-runtime.log');
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-agent-status'), 'fail', err.message);
		});
	}

	function refreshVersions() {
		FCC.notice(FCC.$('#fcc-agent-status'), '', FCC._('Detecting versions…'));
		FCC.api('agent_versions', {}, { method: 'POST' }).then(function () {
			FCC.notice(FCC.$('#fcc-agent-status'), 'ok', FCC._('Versions updated.'));
			loadAgents();
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-agent-status'), 'fail', err.message);
		});
	}

	/* -------------------------------------------------------- runtime + jobs */

	function refreshRuntime() {
		return FCC.api('status', {}, { method: 'GET' }).then(function (d) {
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
		});
	}

	function startJobWatch(lock, log) {
		jobStart = Date.now();
		var panel = FCC.$('#fcc-job');
		if (panel) { panel.style.display = ''; }
		if (jobTimer) { clearInterval(jobTimer); }

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
					var bar = FCC.$('#fcc-job-bar');
					if (bar && r.running) {
						var secs = (Date.now() - jobStart) / 1000;
						bar.style.width = Math.min(95, (secs / 3)) + '%';
					}

					if (!r.running) {
						clearInterval(jobTimer);
						jobTimer = null;
						if (bar) { bar.style.width = '100%'; }
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
		loadServer().catch(function () {});
		refreshRuntime().catch(function () {});
		loadAgents().catch(function () {});
	}

	function init() {
		FCC.$('#fcc-save').addEventListener('click', saveConfig);

		Array.prototype.forEach.call(
			document.querySelectorAll('[data-op]'),
			function (b) {
				b.addEventListener('click', function () { serverOp(b.getAttribute('data-op')); });
			}
		);

		FCC.$('#fcc-runtime-install').addEventListener('click', function () {
			runJobAction('install_runtime', {}, 'install', 'fcc-runtime.log');
		});
		FCC.$('#fcc-runtime-update').addEventListener('click', function () {
			runJobAction('update_runtime', {}, 'install', 'fcc-update.log');
		});
		FCC.$('#fcc-runtime-uninstall').addEventListener('click', function () {
			if (!window.confirm(FCC._('Remove the FCC runtime? Your data under the install path is kept unless you purge it.'))) {
				return;
			}
			runJobAction('uninstall_runtime', {}, 'install', 'fcc-runtime.log');
		});

		FCC.$('#fcc-agent-refresh').addEventListener('click', refreshVersions);
		FCC.$('#fcc-doctor-run').addEventListener('click', runDoctor);

		loadConfig().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
		refreshAll();
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
