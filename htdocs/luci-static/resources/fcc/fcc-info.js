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

	function card(title, value, sub) {
		return FCC.el('div', { class: 'fcc-card' }, [
			FCC.el('h4', { text: title }),
			FCC.el('div', { class: 'fcc-mono', text: value }),
			sub ? FCC.el('div', { class: 'fcc-muted', text: sub }) : null
		]);
	}

	function renderSystem(s) {
		var box = FCC.$('#fcc-info-system');
		box.innerHTML = '';
		var total = s.memory_total_kb, avail = s.memory_available_kb;
		box.appendChild(card(FCC._('Memory'), FCC.fmtKB(total),
			avail !== null && avail !== undefined
				? FCC.fmtKB(avail) + ' ' + FCC._('available')
				: ''));
		box.appendChild(card(FCC._('Storage'), FCC.fmtBytes(s.storage_total_bytes),
			FCC.fmtBytes(s.storage_free_bytes) + ' ' + FCC._('free') +
			' (' + FCC.fmtPercent(s.storage_free_bytes, s.storage_total_bytes) + ')'));
		box.appendChild(card(FCC._('Architecture'), s.arch || '—', s.storage_path || ''));
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
			var state = a.running
				? FCC.el('span', { class: 'fcc-badge ok', text: FCC._('running') })
				: (a.installed
					? FCC.el('span', { class: 'fcc-badge', text: FCC._('installed') })
					: FCC.el('span', { class: 'fcc-badge off', text: FCC._('not installed') }));
			tbody.appendChild(FCC.el('tr', {}, [
				FCC.el('td', { text: a.name }),
				FCC.el('td', { class: 'fcc-mono', text: a.version || '—' }),
				FCC.el('td', {}, [state]),
				FCC.el('td', { class: 'fcc-mono', text: a.pid || '—' }),
				FCC.el('td', { text: a.uptime !== null && a.uptime !== undefined ? FCC.fmtDuration(a.uptime) : '—' }),
				FCC.el('td', { class: 'fcc-mono', text: a.memory_rss_kb !== null && a.memory_rss_kb !== undefined ? FCC.fmtKB(a.memory_rss_kb) : '—' })
			]));
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
	}

	function checkUpdates() {
		var box = FCC.$('#fcc-info-updates');
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Checking…') }));
		FCC.api('update_check', {}, { method: 'GET' })
			.then(renderUpdates)
			.catch(function (err) { FCC.notice(box, 'fail', err.message); });
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
		FCC.$('#fcc-info-log-load').addEventListener('click', loadLog);

		loadStatus(false).catch(function (err) {
			FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
		});
		checkUpdates();
		loadLog();

		// Keep the monitor live without hammering the router.
		timer = setInterval(function () {
			loadStatus(false).catch(function () {});
		}, 15000);
		window.addEventListener('beforeunload', function () {
			if (timer) { clearInterval(timer); }
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
