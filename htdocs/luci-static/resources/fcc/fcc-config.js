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

	/* The agent picker's last server-rendered state, so "Reset to
	 * recommended" can redraw without another round trip. */
	var agentRegistry = {};
	var agentRecommended = [];
	var agentPickerReady = false;

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
			/* Section 13's target is http://<LAN-IP>:8082/admin. Two details
			 * matter: the path is /admin, not /, and the scheme is http, not
			 * location.protocol — the FCC server speaks plain HTTP, so an
			 * https:// link would simply fail to connect. */
			link.href = 'http://' + location.hostname + ':' + port + '/admin';
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
				setTimeout(function () { loadServer(); refreshRuntime(); }, 1500);
			});
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
					/* Section 44: an installed agent whose version could not be
					 * read shows "Unknown", never a guessed number. The reason
					 * goes in the tooltip so the cell stays one word wide. */
					FCC.el('td', {
						class: 'fcc-mono',
						text: a.version || (a.version_error ? FCC._('Unknown') : '—'),
						title: a.version_error || ''
					}),
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

	/* ------------------------------------------------------ agent selection */

	/* Section 3.6.5: which agents to install is a decision the user makes
	 * before the install starts. The recommended set comes from the server,
	 * which knows each agent's size and memory floor, but the boxes stay
	 * editable — the recommendation is a guess about this device, not a rule.
	 *
	 * An empty selection is meaningful and is sent as such: the API takes an
	 * absent `agents` field to mean "use the defaults" and an empty one to mean
	 * "install none", so the picker must not fall back to defaults when the
	 * user has unchecked everything. */

	function selectedAgentIds() {
		var ids = [];
		Array.prototype.forEach.call(
			document.querySelectorAll('#fcc-install-agents input[type="checkbox"]'),
			function (b) { if (b.checked) { ids.push(b.value); } }
		);
		return ids;
	}

	function renderAgentPicker(agents, recommended) {
		var box = FCC.$('#fcc-install-agents');
		if (!box) { return; }

		agentRegistry = agents || {};
		agentRecommended = recommended || [];
		agentPickerReady = true;

		var rec = {};
		agentRecommended.forEach(function (id) { rec[id] = true; });

		box.innerHTML = '';
		var ids = Object.keys(agentRegistry).sort(function (a, b) {
			var an = String((agentRegistry[a] || {}).name || a).toLowerCase();
			var bn = String((agentRegistry[b] || {}).name || b).toLowerCase();
			return an < bn ? -1 : (an > bn ? 1 : 0);
		});
		if (!ids.length) {
			box.appendChild(FCC.el('div', {
				class: 'fcc-muted', text: FCC._('No agents are registered.')
			}));
			return;
		}

		ids.forEach(function (id) {
			var a = agentRegistry[id] || {};
			var input = FCC.el('input', { type: 'checkbox', value: id, id: 'fcc-pick-' + id });
			/* Set the property, not the attribute: setAttribute('checked', false)
			 * still checks the box. */
			input.checked = !!rec[id];

			var bits = [];
			if (a.approx_size_mb) {
				bits.push(FCC._('about %d MB').replace('%d', a.approx_size_mb));
			}
			if (a.min_ram_mb) {
				bits.push(FCC._('needs %d MB RAM').replace('%d', a.min_ram_mb));
			}

			box.appendChild(FCC.el('label', { class: 'fcc-pick', for: 'fcc-pick-' + id }, [
				input,
				FCC.el('span', { class: 'fcc-pick-name', text: a.name || id }),
				bits.length
					? FCC.el('span', { class: 'fcc-muted fcc-pick-meta', text: bits.join(' \u00b7 ') })
					: null
			]));
		});
	}

	function loadAgentPicker() {
		return FCC.api('status', {}, { method: 'GET' }).then(function (d) {
			var sys = (d && d.system) || {};
			var reg = (d && d.agents) || {};

			var params = {};
			if (sys.memory_total_kb) {
				params.ram_mb = Math.floor(sys.memory_total_kb / 1024);
			}
			if (sys.storage_free_bytes) {
				params.free_mb = Math.floor(sys.storage_free_bytes / 1048576);
			}

			/* If the policy endpoint is unreachable, fall back to the registry's
			 * own default flags rather than leaving the panel stuck on
			 * "Loading…" — an install must not be blocked by a nicety. */
			var fallback = Object.keys(reg).filter(function (id) {
				return reg[id] && reg[id].default;
			});

			return FCC.api('agent_defaults', params, { method: 'GET' })
				.then(function (r) { return (r && r.ids) || fallback; })
				.catch(function () { return fallback; })
				.then(function (ids) { renderAgentPicker(reg, ids); });
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
			var params = {};
			if (agentPickerReady) { params.agents = selectedAgentIds().join(','); }
			runJobAction('install_runtime', params, 'install', 'fcc-runtime.log');
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

		FCC.$('#fcc-install-agents-defaults').addEventListener('click', function () {
			renderAgentPicker(agentRegistry, agentRecommended);
		});

		FCC.$('#fcc-agent-refresh').addEventListener('click', refreshVersions);
		FCC.$('#fcc-doctor-run').addEventListener('click', runDoctor);

		loadConfig().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
		refreshAll();
		loadAgentPicker().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
