/*
 * luci-app-fcc — Basic Information page.
 *
 * Read-only runtime monitor. Everything comes from one batched status call, so
 * refreshing costs the router a single process rather than one per agent.
 */
(function () {
	'use strict';

	var FCC = window.FCC;
	var timer = null;
	var versionTimer = null;
	var jobTimer = null;
	var updateAvailable = false;

	function card(title, value, sub) {
		return FCC.el('div', { class: 'fcc-card' }, [
			FCC.el('h4', { text: title }),
			FCC.el('div', { class: 'fcc-mono', text: value }),
			sub ? FCC.el('div', { class: 'fcc-muted', text: sub }) : null
		]);
	}

	/* Frequency and core count are separate readings and either can be missing —
	 * a kernel with no cpufreq has no current rate, and a device that reports
	 * neither shows only what it does have rather than a line of blanks. The
	 * current rate is printed against the maximum only when the two differ: on a
	 * fixed-clock SoC they are the same number and repeating it reads as a bug. */
	function cpuDetail(s) {
		var bits = [];
		var cur = s.cpu_mhz, max = s.cpu_mhz_max;
		if (cur && max && String(cur) !== String(max)) {
			bits.push(cur + ' / ' + max + ' MHz');
		} else if (cur || max) {
			bits.push((cur || max) + ' MHz');
		}
		if (s.cpu_cores) {
			bits.push(s.cpu_cores + ' ' + (Number(s.cpu_cores) === 1 ? FCC._('core') : FCC._('cores')));
		}
		return bits.join(' · ');
	}

	/* The kernel reports the core temperature in thousandths of a degree, which
	 * is the unit sysfs itself uses; turning it into something a person reads is
	 * this page's job and nowhere else's. One decimal is all the precision there
	 * is to show — sensors are not accurate to a hundredth of a degree, and a
	 * number that twitches in its last digit on every poll reads as noise.
	 *
	 * A board with no sensor gets the dash rather than a zero. The backend sends
	 * null for exactly that case, and section 44 is why: 0.0 °C looks like a
	 * reading. */
	function tempText(s) {
		var mc = s.cpu_temp_mc;
		if (mc === null || mc === undefined || mc === '') { return '—'; }
		var c = Number(mc) / 1000;
		if (!isFinite(c)) { return '—'; }
		return c.toFixed(1) + ' °C';
	}

	function renderSystem(s) {
		var box = FCC.$('#fcc-info-system');
		box.innerHTML = '';
		var total = s.memory_total_kb, avail = s.memory_available_kb;
		/* Section 44: the dash is the last resort, not the first. The backend
		 * asks /proc/cpuinfo and then the CPU's device tree node, which is the
		 * only place the name exists on a board whose cpuinfo names no CPU
		 * (arm64), so a dash here means neither source had one. */
		box.appendChild(card(FCC._('CPU Info'), s.cpu_model || '—', cpuDetail(s)));
		/* The CPU's own heat, directly under the CPU. The sub-line names the
		 * sensor the reading came from, because a board can have several — a
		 * radio, a modem, a charger — and the backend prefers the one that names
		 * the CPU but falls back to whichever answers. A bare number would be a
		 * reading the page cannot say the origin of. */
		box.appendChild(card(FCC._('Temperature'), tempText(s), s.cpu_temp_source || ''));
		/* What the CPU sits on, then what the build targets. The two are
		 * different questions and the answers differ: one board's target covers
		 * a family of boards, and one architecture covers many targets. The
		 * board's own model is the sub-line because the target cannot name it. */
		box.appendChild(card(FCC._('Platform'), s.platform || '—', s.platform_model || ''));
		box.appendChild(card(FCC._('Architecture'), s.arch || '—', s.storage_path || ''));
		box.appendChild(card(FCC._('Memory'), FCC.fmtKB(total),
			avail !== null && avail !== undefined
				? FCC.fmtKB(avail) + ' ' + FCC._('available')
				: ''));
		box.appendChild(card(FCC._('Storage'), FCC.fmtBytes(s.storage_total_bytes),
			FCC.fmtBytes(s.storage_free_bytes) + ' ' + FCC._('free') +
			' (' + FCC.fmtPercent(s.storage_free_bytes, s.storage_total_bytes) + ')'));
	}

	function renderFcc(d) {
		var box = FCC.$('#fcc-info-fcc');
		box.innerHTML = '';
		var s = d.server || {}, f = d.fcc || {}, l = d.luci_fcc || {};

		box.appendChild(card(FCC._('LuCI App'), l.version || '—', 'luci-app-fcc'));
		box.appendChild(card(FCC._('FCC Runtime'), f.version || '—',
			f.installed ? FCC._('installed') : FCC._('not installed')));
		box.appendChild(card(FCC._('FCC Server'),
			s.running ? FCC._('Running') : FCC._('Stopped'),
			(s.bind || '—') + ':' + (s.port || '—')));
		// Section 49's three signals, shown live rather than only being applied
		// after an update. A server can be up but not listening (a crash loop)
		// or listening but not answering (hung), and those want different
		// reactions, so they are not collapsed into one badge.
		box.appendChild(card(FCC._('Health'),
			s.healthy ? FCC._('healthy') : FCC._('unhealthy'),
			s.listening
				? FCC._('listening') + (s.http_status ? ' · HTTP ' + s.http_status : '')
				: FCC._('not listening')));
		box.appendChild(card(FCC._('PID'), s.running ? String(s.pid) : '—',
			s.running ? FCC.fmtDuration(s.uptime) + ' ' + FCC._('uptime') : ''));
		box.appendChild(card(FCC._('Memory (RSS)'),
			s.running ? FCC.fmtKB(s.memory_rss_kb) : '—', ''));
	}

	function renderAgents(agents) {
		var tbody = FCC.$('#fcc-info-agents tbody');
		tbody.innerHTML = '';
		var ids = Object.keys(agents);
		if (!ids.length) {
			tbody.appendChild(FCC.el('tr', {}, [
				FCC.el('td', { colspan: '6', class: 'fcc-muted', text: FCC._('No agents in the registry.') })
			]));
			return;
		}
		ids.forEach(function (id) {
			var a = agents[id];
			/* Section 73: an agent that died is not merely "not running". The
			 * backend reports why, so show that instead of a bare state, and
			 * offer the two things that actually help — the log, and starting it
			 * again. Only the two states that say nothing on their own
			 * (installed-but-not-running and not-installed) fall through to the
			 * plain badge. */
			var cell;
			if (a.error) {
				cell = FCC.el('td', {}, [
					FCC.el('span', { class: 'fcc-badge warn', text: '⚠ ' + FCC._('Error') })
				]);
				if (a.error.message) {
					cell.appendChild(FCC.el('div', {
						class: 'fcc-muted fcc-agent-error', text: a.error.message
					}));
				}
				var viewLog = FCC.el('button', { class: 'cbi-button cbi-button-reset' }, [FCC._('View Log')]);
				viewLog.addEventListener('click', viewAgentLog);
				var retry = FCC.el('button', { class: 'cbi-button cbi-button-reset' }, [FCC._('Retry')]);
				retry.addEventListener('click', function () { retryAgent(id, retry); });
				cell.appendChild(FCC.el('div', { class: 'fcc-agent-error-actions' }, [viewLog, retry]));
			} else {
				var state = a.running
					? FCC.el('span', { class: 'fcc-badge ok', text: FCC._('running') })
					: (a.installed
						? FCC.el('span', { class: 'fcc-badge', text: FCC._('installed') })
						: FCC.el('span', { class: 'fcc-badge off', text: FCC._('not installed') }));
				cell = FCC.el('td', {}, [state]);
			}
			tbody.appendChild(FCC.el('tr', {}, [
				FCC.el('td', { text: a.name }),
				FCC.el('td', { class: 'fcc-mono', text: a.version || '—' }),
				cell,
				FCC.el('td', { class: 'fcc-mono', text: a.pid || '—' }),
				FCC.el('td', { text: a.uptime !== null && a.uptime !== undefined ? FCC.fmtDuration(a.uptime) : '—' }),
				FCC.el('td', { class: 'fcc-mono', text: a.memory_rss_kb !== null && a.memory_rss_kb !== undefined ? FCC.fmtKB(a.memory_rss_kb) : '—' })
			]));
		});
	}

	/* Section 73's [View Log]: the agent's own output is what the terminal
	 * session wrote, and this page already has a viewer for it — so point the
	 * viewer at that file and bring it into sight rather than adding a second
	 * log panel that would drift from the first. */
	function viewAgentLog() {
		var select = FCC.$('#fcc-info-log-select');
		if (select) { select.value = 'fcc-terminal.log'; }
		loadLog();
		var pre = FCC.$('#fcc-info-log');
		if (pre && pre.scrollIntoView) { pre.scrollIntoView({ block: 'nearest' }); }
	}

	/* Section 73's [Retry]: start the agent again. Agents run inside a tmux
	 * session (that is what the Web Console attaches to), so starting one is
	 * exactly what creating a session does. The button is disabled while the
	 * request is in flight so a double click cannot start two. */
	function retryAgent(id, btn) {
		btn.disabled = true;
		FCC.api('session_create', { agent: id }, { method: 'POST' }).then(function () {
			return loadStatus(false);
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
		}).then(function () {
			btn.disabled = false;
		});
	}

	function loadStatus(refresh) {
		var action = refresh ? 'status_refresh' : 'status';
		var method = refresh ? 'POST' : 'GET';
		return FCC.api(action, {}, { method: method }).then(function (d) {
			renderSystem(d.system || {});
			renderFcc(d);
			renderAgents(d.agents || {});
			return d;
		});
	}

	/* ------------------------------------------------------------- updates */

	function renderUpdates(u) {
		var box = FCC.$('#fcc-info-updates');
		box.innerHTML = '';
		var l = u.luci_fcc || {}, f = u.fcc_runtime || {};

		function row(label, o) {
			var status;
			if (o.checked === false || o.checked === 'false') {
				status = FCC.el('span', { class: 'fcc-badge off', text: FCC._('not checked') });
			} else if (o.update_available === true || o.update_available === 'true') {
				status = FCC.el('span', { class: 'fcc-badge warn', text: FCC._('update available') });
			} else {
				status = FCC.el('span', { class: 'fcc-badge ok', text: FCC._('up to date') });
			}
			return FCC.el('tr', {}, [
				FCC.el('td', { text: label }),
				FCC.el('td', { class: 'fcc-mono', text: o.installed || '—' }),
				FCC.el('td', { class: 'fcc-mono', text: o.latest || '—' }),
				FCC.el('td', {}, [status])
			]);
		}

		var table = FCC.el('table', { class: 'fcc-table' }, [
			FCC.el('thead', {}, [FCC.el('tr', {}, [
				FCC.el('th', { text: FCC._('Component') }),
				FCC.el('th', { text: FCC._('Installed') }),
				FCC.el('th', { text: FCC._('Latest') }),
				FCC.el('th', { text: FCC._('Status') })
			])]),
			FCC.el('tbody', {}, [
				row(FCC._('LuCI App'), l),
				row(FCC._('FCC Runtime'), f)
			])
		]);
		box.appendChild(table);

		if (u.upgrade_command) {
			box.appendChild(FCC.el('div', { class: 'fcc-note' }, [
				FCC.el('div', { text: FCC._('To upgrade luci-app-fcc itself, run on the router:') }),
				FCC.el('pre', { class: 'fcc-log', text: u.upgrade_command })
			]));
		}
		if (!l.checked && l.checked !== 'true') {
			box.appendChild(FCC.el('div', {
				class: 'fcc-note warn',
				text: FCC._('The LuCI app version could not be checked — the router could not reach the version source.')
			}));
		}

		/* Section 94's flow is Check Update -> Update FCC, both on this page.
		 * The button only lights up when the runtime is installed and the check
		 * says there is something to move to: an enabled "Update FCC" next to
		 * "up to date" invites a reinstall nobody asked for. */
		updateAvailable = f.installed === true || f.installed === 'true'
			? (f.update_available === true || f.update_available === 'true')
			: false;
		var btn = FCC.$('#fcc-info-update');
		if (btn) { btn.disabled = !updateAvailable; }
	}

	function checkUpdates() {
		var box = FCC.$('#fcc-info-updates');
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Checking…') }));
		FCC.api('update_check', {}, { method: 'GET' })
			.then(renderUpdates)
			.catch(function (err) { FCC.notice(box, 'fail', err.message); });
	}

	/* ------------------------------------------------------- update + jobs */

	/* The update runs as a job: it downloads, verifies and reinstalls, which is
	 * minutes on a router. The page shows the log and follows the lock, the
	 * same way the Configuration page does — the lock is the authoritative
	 * "still working" signal, since the log can go quiet while a download runs. */
	function watchUpdateJob() {
		var started = Date.now();
		var panel = FCC.$('#fcc-info-job');
		if (panel) { panel.style.display = ''; }
		if (jobTimer) { clearInterval(jobTimer); }

		var tick = function () {
			FCC.api('job', { lock: 'install', log: 'fcc-update.log', lines: 60 }, { method: 'GET' })
				.then(function (r) {
					var pre = FCC.$('#fcc-info-job-log');
					if (pre) {
						pre.textContent = (r.lines || []).join('\n');
						pre.scrollTop = pre.scrollHeight;
					}
					var bar = FCC.$('#fcc-info-job-bar');
					if (bar && r.running) {
						bar.style.width = Math.min(95, (Date.now() - started) / 300) + '%';
					}
					if (!r.running) {
						clearInterval(jobTimer);
						jobTimer = null;
						if (bar) { bar.style.width = '100%'; }
						checkUpdates();
						loadStatus(true).catch(function () {});
					}
				})
				.catch(function () { /* a blip is not a failure; keep polling */ });
		};

		tick();
		jobTimer = setInterval(tick, 2000);
	}

	function runUpdate() {
		var btn = FCC.$('#fcc-info-update');
		if (btn) { btn.disabled = true; }
		FCC.api('update_runtime', {}, { method: 'POST' }).then(function () {
			watchUpdateJob();
		}).catch(function (err) {
			if (btn) { btn.disabled = false; }
			FCC.notice(FCC.$('#fcc-info-updates'), 'fail', err.message);
		});
	}

	/* ---------------------------------------------------------------- logs */

	function loadLog() {
		var name = FCC.$('#fcc-info-log-select').value;
		var pre = FCC.$('#fcc-info-log');
		pre.textContent = FCC._('Loading…');
		FCC.api('log', { name: name, lines: 300 }, { method: 'GET' }).then(function (r) {
			if (r.missing || !r.lines || !r.lines.length) {
				pre.textContent = FCC._('No entries yet.');
				return;
			}
			pre.innerHTML = r.lines.map(function (l) {
				var cls = /error|fail|traceback/i.test(l) ? 'lvl-err'
					: (/warn/i.test(l) ? 'lvl-warn' : '');
				return cls ? '<span class="' + cls + '">' + FCC.esc(l) + '</span>' : FCC.esc(l);
			}).join('\n');
			pre.scrollTop = pre.scrollHeight;
		}).catch(function (err) {
			pre.textContent = err.message;
		});
	}

	/* ---------------------------------------------------------------- init */

	function init() {
		FCC.$('#fcc-info-refresh').addEventListener('click', function () {
			loadStatus(true).catch(function (err) {
				FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
			});
		});
		FCC.$('#fcc-info-check').addEventListener('click', checkUpdates);
		FCC.$('#fcc-info-update').addEventListener('click', function () {
			if (!updateAvailable) { return; }
			if (!window.confirm(FCC._('Update the FCC runtime now? The server is stopped during the update and your data is kept.'))) {
				return;
			}
			runUpdate();
		});
		FCC.$('#fcc-info-log-load').addEventListener('click', loadLog);

		loadStatus(false).catch(function (err) {
			FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
		});
		checkUpdates();
		loadLog();

		/* Section 20 splits the two cadences, and the split is the point: status
		 * is cheap because the backend reads /proc once and batches every agent
		 * into a single pass, so it can run every 2s; versions shell out to each
		 * agent's CLI, so they run every 60s and come from the backend's cache
		 * in between. Polling both at the fast rate would run --version ten
		 * times a minute; polling both at the slow rate would make the monitor
		 * feel dead. */
		timer = setInterval(function () {
			loadStatus(false).catch(function () {});
		}, 2000);
		versionTimer = setInterval(function () {
			loadStatus(true).catch(function () {});
		}, 60000);
		window.addEventListener('beforeunload', function () {
			if (timer) { clearInterval(timer); }
			if (versionTimer) { clearInterval(versionTimer); }
			if (jobTimer) { clearInterval(jobTimer); }
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
