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
	/* The agent table is opt-in. Opening the tab costs nothing for agents: no
	 * version detection runs and the table stays empty until "Status and
	 * versions" is pressed. The status poll keeps the system and FCC cards
	 * live, but it must not refill the table after Clear information either,
	 * which is why this flag gates the render as well as the detection. */
	var agentShown = false;

	/* Which machine the Agents section describes, as Configuration → FCC
	 * Server set it. Local mode is this router and keeps the behaviour above.
	 * LAN mode is the other machine: it cannot be read from /proc, so it costs
	 * an SSH round trip. It is fetched when the page opens on that mode (or
	 * the mode changes under it) and again when "Version status" is pressed
	 * for a fresh version probe; between those, it is re-read every thirty
	 * seconds, the same clock Configuration's LAN panel uses. Those re-reads
	 * ask for state only — state, pid, uptime, memory — and keep the versions
	 * from the last full read, so a bare LAN machine is not made to start
	 * every agent's CLI twice a minute. Everything else on this page stays
	 * local, because that is what it describes. */
	var target = 'local';
	var lanHost = '';
	var targetTimer = null;
	var AGENT_POLL_MS = 30000;
	var agentsTimer = null;
	var agentsBusy = false;
	/* The last LAN answer, so a state-only re-read keeps its version column. */
	var lastAgents = {};

	/* What the LAN side calls each refusal, in the interface language.
	 *
	 * The codes are remote.sh's and the sentences are the console page's: the
	 * same words for the same setting, so a reader who met one on the console
	 * meets the same one here. fcc-terminal.js holds its copy for its own
	 * page; this page does not load that file, and a sentence that lives in
	 * one page's script cannot be reached from another's.
	 */
	function agentsReason(d) {
		d = d || {};
		switch (d.reason) {
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
		}
		return FCC._('The LAN machine’s state could not be read.') +
			(d.error ? ' (' + d.error + ')' : '');
	}

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

	function renderAgents(agents, remote) {
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
			 * plain badge.
			 *
			 * Those two controls act on this router — the log is a local file
			 * and starting an agent opens a local session — so they are not
			 * offered for a row that came from the LAN machine. An error there
			 * is reported as what it is, without buttons that would do
			 * something else. */
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
				if (!remote) {
					var viewLog = FCC.el('button', { class: 'cbi-button cbi-button-reset' }, [FCC._('View Log')]);
					viewLog.addEventListener('click', viewAgentLog);
					var retry = FCC.el('button', { class: 'cbi-button cbi-button-reset' }, [FCC._('Retry')]);
					retry.addEventListener('click', function () { retryAgent(id, retry); });
					cell.appendChild(FCC.el('div', { class: 'fcc-agent-error-actions' }, [viewLog, retry]));
				}
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

	/* Which machine the section is about, said rather than implied. The two
	 * modes show the same six columns, and a reader has to be able to tell a
	 * running agent on this router from one on the other machine without
	 * remembering what Configuration says. */
	function renderAgentSource() {
		var el = FCC.$('#fcc-info-agent-source');
		if (!el) { return; }
		if (target === 'lan') {
			el.textContent = FCC._('Showing the agents on the LAN machine') +
				(lanHost ? ' · ' + lanHost : '');
			return;
		}
		el.textContent = FCC._('Showing the agents on this router');
	}

	/* The version column on a state-only answer. A bare machine was not asked
	 * to probe its CLIs, so the line is absent; keeping the version from the
	 * last full read is what makes the thirty-second clock affordable. An
	 * agent that is no longer installed drops the old number instead: it
	 * described something that is not there any more. */
	function mergeAgentVersions(agents) {
		Object.keys(agents).forEach(function (id) {
			var a = agents[id] || {};
			var prev = lastAgents[id] || {};
			if (a.version == null && a.installed === true && prev.version != null) {
				a.version = prev.version;
			}
		});
		return agents;
	}

	/* The LAN table's clock, thirty seconds like Configuration's LAN panel.
	 * Started by a successful read, stopped by a refusal, by leaving LAN
	 * mode, by Clear information, and by leaving the page. A tick whose
	 * answer is still on its way is skipped rather than queued. */
	function keepAgentPolling(on) {
		if (!on) {
			if (agentsTimer) {
				clearInterval(agentsTimer);
				agentsTimer = null;
			}
			return;
		}
		if (agentsTimer) { return; }
		agentsTimer = setInterval(function () {
			if (target !== 'lan' || !agentShown) {
				keepAgentPolling(false);
				return;
			}
			if (agentsBusy) { return; }
			loadLanAgents(false, true).catch(function () {});
		}, AGENT_POLL_MS);
	}

	/* One fetch of the LAN machine's table, or a sentence saying why there is
	 * none. `refresh` is the button: it re-detects versions over there and
	 * arrives with the finished table, so nothing else is fetched afterwards.
	 * `state` is the thirty-second re-read: it asks for the columns a process
	 * changes by itself and leaves version detection to the button. Opening
	 * the page asks for the table as it stands — on a machine carrying this
	 * package that is a cached read, and on a bare machine the same probe the
	 * console's first answer already runs.
	 *
	 * A failure empties the table rather than leaving the last answer there:
	 * the section must never show one machine's numbers under the other
	 * machine's name. It also stops the clock, the way Configuration's panel
	 * stops when the machine stops answering; "Version status" is the way
	 * back on. */
	function loadLanAgents(refresh, state) {
		var status = FCC.$('#fcc-info-agent-status');
		var table = FCC.$('#fcc-info-agents');
		var btn = refresh ? FCC.$('#fcc-info-agent-versions') : null;
		agentsBusy = true;
		agentShown = true;
		if (table) { table.hidden = false; }
		if (btn) {
			btn.disabled = true;
			FCC.notice(status, '', FCC._('Detecting versions…'));
		}
		return FCC.api(refresh ? 'agent_versions' : 'agents',
				state ? { state: 1 } : {},
				{ method: refresh ? 'POST' : 'GET' }).then(function (d) {
			if (!d || d.ok !== true) {
				renderAgents({}, true);
				FCC.notice(status, 'fail', agentsReason(d));
				keepAgentPolling(false);
				return;
			}
			var agents = d.agents || {};
			if (state) { mergeAgentVersions(agents); }
			lastAgents = agents;
			renderAgents(agents, true);
			if (btn) { FCC.notice(status, 'ok', FCC._('Versions updated.')); }
			else if (!state) { FCC.notice(status, '', ''); }
			keepAgentPolling(target === 'lan' && agentShown);
		}).catch(function (err) {
			renderAgents({}, true);
			FCC.notice(status, 'fail', agentsReason((err && err.body) || err));
			keepAgentPolling(false);
		}).then(function () {
			agentsBusy = false;
			if (btn) { btn.disabled = false; }
		});
	}

	/* Configuration's mode is a setting, and the tab can be changed under this
	 * page. One UCI read says which mode is current; only a change costs the
	 * SSH round trip above. Local mode resumes its own poll-driven rendering
	 * on the next 2 s tick. */
	function checkTarget() {
		return FCC.api('console_target', {}, { method: 'GET' }).then(function (d) {
			var next = (d && d.target === 'lan') ? 'lan' : 'local';
			var host = (d && d.host) || '';
			if (next === target && host === lanHost) { return; }
			target = next;
			lanHost = host;
			renderAgentSource();
			var status = FCC.$('#fcc-info-agent-status');
			if (status) { FCC.notice(status, '', ''); }
			if (target === 'lan') {
				return loadLanAgents(false);
			}
			/* Back to this router: the LAN table's clock has nothing left to
			 * read, and the local table is the status document's, so the next
			 * fetch puts it back on screen. */
			keepAgentPolling(false);
			return loadStatus(false).catch(function () {});
		}).catch(function () {});
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
		/* Same hint the console sends: where this page was reached, so a
		 * session that serves a web page (DeepSeek Harness) can listen on an
		 * address this browser can open. The backend validates it. */
		FCC.api('session_create', { agent: id, host: location.hostname || '' },
			{ method: 'POST' }).then(function () {
			return loadStatus(false);
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
		}).then(function () {
			btn.disabled = false;
		});
	}

	/* Re-read every installed agent's version.
	 *
	 * The version column is a cache, written when an agent is installed, so an
	 * agent upgraded on the router by hand would keep showing the old number
	 * indefinitely. This is the only thing that rewrites that cache, and it is
	 * a POST because it shells out to each agent's --version — a GET that costs
	 * ten processes is one a proxy or a prefetch is entitled to repeat.
	 *
	 * It is also what brings the table into view: until it is pressed the
	 * section shows no agent information at all, so returning to the tab never
	 * pays for a detection nobody asked for. */
	function refreshAgentVersions(btn) {
		/* On the LAN machine the re-detect and the table's contents are the
		 * same request: remote.sh refreshes the version cache over there and
		 * answers with the finished document, so nothing else is fetched for
		 * it. The thirty-second clock below keeps reading state, not
		 * versions. */
		if (target === 'lan') { return loadLanAgents(true); }
		var status = FCC.$('#fcc-info-agent-status');
		var table = FCC.$('#fcc-info-agents');
		agentShown = true;
		if (table) { table.hidden = false; }
		FCC.notice(status, '', FCC._('Detecting versions…'));
		btn.disabled = true;
		FCC.api('agent_versions', {}, { method: 'POST' }).then(function () {
			return loadStatus(false);
		}).then(function () {
			/* Clear may have been pressed while the detection ran; it must not
			 * leave a fresh sentence behind on the empty section. */
			if (agentShown) { FCC.notice(status, 'ok', FCC._('Versions updated.')); }
		}).catch(function (err) {
			if (agentShown) { FCC.notice(status, 'fail', err.message); }
		}).then(function () {
			btn.disabled = false;
		});
	}

	/* Clear information puts the section back to how it opens: no table, no
	 * detection sentence, and no detection on the next status poll. It clears
	 * what the page is showing, not the version cache on the router. */
	function clearAgentInfo() {
		agentShown = false;
		/* A cleared table is not a reason to keep an SSH round trip going
		 * every thirty seconds; "Version status" turns the clock back on. */
		keepAgentPolling(false);
		var tbody = FCC.$('#fcc-info-agents tbody');
		if (tbody) { tbody.innerHTML = ''; }
		var table = FCC.$('#fcc-info-agents');
		if (table) { table.hidden = true; }
		FCC.$('#fcc-info-agent-status').textContent = '';
	}

	function loadStatus(refresh) {
		var action = refresh ? 'status_refresh' : 'status';
		var method = refresh ? 'POST' : 'GET';
		return FCC.api(action, {}, { method: method }).then(function (d) {
			renderSystem(d.system || {});
			renderFcc(d);
			/* The status document is this router's. On the LAN machine the
			 * table comes from its own fetch, and letting a poll write this
			 * document into it would put local numbers under a LAN heading. */
			if (agentShown && target === 'local') { renderAgents(d.agents || {}); }
			return d;
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
		FCC.$('#fcc-info-log-load').addEventListener('click', loadLog);
		FCC.$('#fcc-info-log-clear').addEventListener('click', function () {
			FCC.$('#fcc-info-log').textContent = '';
		});
		FCC.$('#fcc-info-agent-versions').addEventListener('click', function () {
			refreshAgentVersions(this);
		});
		FCC.$('#fcc-info-agent-clear').addEventListener('click', clearAgentInfo);

		loadStatus(false).catch(function (err) {
			FCC.notice(FCC.$('#fcc-info-fcc'), 'fail', err.message);
		});
		loadLog();
		renderAgentSource();
		/* If Configuration already targets the LAN machine, the section opens
		 * on its table: that first read carries the versions, and the
		 * thirty-second clock starts from it. */
		checkTarget();

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
			/* Version detection never reaches the LAN machine on this clock:
			 * a --version run there is the one expensive thing, and the
			 * thirty-second state clock above covers what moves. */
			if (target !== 'local') { return; }
			/* status_refresh shells out to every agent's --version, so it only
			 * runs while its result is on screen. A hidden table must not keep
			 * a detection going every minute. */
			if (!agentShown) { return; }
			loadStatus(true).catch(function () {});
		}, 60000);
		/* One UCI read, so a mode switched on the Configuration tab is noticed
		 * without a reload; only an actual change costs the fetch above. */
		targetTimer = setInterval(checkTarget, 5000);
		window.addEventListener('beforeunload', function () {
			if (timer) { clearInterval(timer); }
			if (versionTimer) { clearInterval(versionTimer); }
			if (targetTimer) { clearInterval(targetTimer); }
			if (agentsTimer) { clearInterval(agentsTimer); }
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
