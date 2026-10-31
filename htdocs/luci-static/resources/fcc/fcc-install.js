/*
 * luci-app-fcc — Install page.
 *
 * The FCC runtime lifecycle: install, reinstall, update and uninstall, the job
 * panel those runs write to, and the diagnostics report. Split out of
 * fcc-config.js in 1.1.0, together with the markup it drives.
 *
 * Installs and updates take minutes, so they are started through the API and
 * then polled: .../api/job reports whether the install lock is still held and
 * returns the tail of the log, which is what the progress panel renders.
 *
 * There is no agent table here any more. It was the picker (section 3.6.5) and
 * the reason the old Configuration page carried a selection, a registry, a
 * recommendation and a set of per-row actions; an install now takes the whole
 * registry and the backend builds that set, so none of it has anything left to
 * do. The agent list that remains is on Basic Information, which is a report
 * and not a control. Section 104.25.
 */
(function () {
	'use strict';

	var FCC = window.FCC;

	var jobTimer = null;
	var jobStart = 0;
	var updateAvailable = false;
	/* The runtime card's poll (see pollStatus). Kept apart from jobTimer: that
	 * one watches an install and stops with it, this one lives as long as the
	 * page does. */
	var statusTimer = null;
	var statusBusy = false;

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

	function startJobWatch(lock, log, onDone) {
		jobStart = Date.now();
		var panel = FCC.$('#fcc-job');
		if (panel) { panel.style.display = ''; }
		/* A new job makes any "record cleared" line stale: it describes the
		 * panel that is now showing this run. */
		FCC.notice(FCC.$('#fcc-runtime-status'), '', '');
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
							FCC.notice(FCC.$('#fcc-runtime-status'), 'fail',
								FCC._('Installation is blocked until the failed checks pass.'));
						}
						refreshAll();
						/* The diagnostics describe the device an install just
						 * wrote to, so the report drawn before it ran is
						 * stale the moment the job ends — whether it
						 * succeeded or failed, and a failure is exactly when
						 * it is least worth reading an old report. */
						runDoctor();
						if (onDone) { onDone(); }
					}
				})
				.catch(function () { /* keep polling; a blip is not a failure */ });
		};

		tick();
		jobTimer = setInterval(tick, 2000);
	}

	function runJobAction(action, params, lock, log, onDone) {
		FCC.api(action, params || {}, { method: 'POST' }).then(function () {
			startJobWatch(lock, log, onDone);
		}).catch(function (err) {
			/* The request failed, so no job was started — but the panel is still
			 * the right place to be, because the two things that explain a
			 * refusal are the lock and the log: a previous run that never
			 * released the lock, or a job that started and stopped before the
			 * response was read. Watching costs nothing when there is nothing to
			 * watch, and it means the failure is never a single sentence with
			 * the evidence hidden behind it. */
			startJobWatch(lock, log, onDone);
			FCC.notice(FCC.$('#fcc-runtime-status'), 'fail', err.message);
		});
	}

	/* -------------------------------------------------------------- doctor */

	/* The report is about a set of agents, not about the device — the checks ask
	 * what the agents being installed need, so an install of every agent can be
	 * blocked by something an install of Claude Code does not care about. The
	 * dropdown narrows the install, so it narrows the report with it: otherwise
	 * the panel says the install is blocked while the job, which asks the shell
	 * the same question about the id it was given, would run it. With nothing
	 * chosen the report is the whole registry, which is what it was before the
	 * dropdown existed. */
	function doctorParams() {
		var picker = FCC.$('#fcc-runtime-agent');
		var agent = picker ? picker.value : '';
		return agent ? { agent: agent } : {};
	}

	function runDoctor() {
		var box = FCC.$('#fcc-doctor');
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Running checks…') }));

		FCC.api('doctor', doctorParams(), { method: 'GET' }).then(function (d) {
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
			/* Two kinds of blocked, and they are not the same news. When every
			 * failure is something a package fixes, the installer adds it before
			 * it starts and the install will run; saying "blocked" there sends
			 * the user off to a terminal for a step they did not need to take.
			 * With any failure left over — storage, DNS, a CPU no Node build
			 * targets — the note stays the old one, because that one needs them. */
			if (!d.install_allowed) {
				var pkgs = d.packages || [];
				box.appendChild(FCC.el('div', {
					class: pkgs.length ? 'fcc-note' : 'fcc-note fail',
					text: pkgs.length
						? FCC._('The installer will add the missing packages before it starts:') +
						  ' ' + pkgs.join(', ')
						: FCC._('Installation is blocked until the failed checks pass.')
				}));
			}
		}).catch(function (err) {
			FCC.notice(box, 'fail', err.message);
		});
	}

	/* ------------------------------------------------------------- updates */

	/* The check result and the run that may follow it live here, beside the
	 * runtime they describe. Checking is manual: the block opens at "Not
	 * checked yet" and reaches the network only when the button is pressed. */

	function renderUpdates(u) {
		var box = FCC.$('#fcc-update-state');
		if (!box) { return; }
		box.innerHTML = '';
		var l = u.luci_fcc || {}, f = u.fcc_runtime || {};

		function row(label, o) {
			var status;
			/* Nothing installed means there is nothing to compare, and the
			 * backend reports checked=false for that too — "not installed" is
			 * the useful sentence, so it comes first. */
			if (!o.installed) {
				status = FCC.el('span', { class: 'fcc-badge off', text: FCC._('not installed') });
			} else if (o.checked === false || o.checked === 'false') {
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

		/* The button only lights up when the runtime is installed and the check
		 * says there is something to move to: an enabled "Update FCC" next to
		 * "up to date" invites a reinstall nobody asked for.
		 *
		 * Runtime "installed" is the version string, not a boolean — the check
		 * reports what it found and null when there is nothing. Testing it for
		 * `true` was what kept this button disabled after a successful check,
		 * so pressing it did nothing at all; that is the "no reaction" a click
		 * used to get. */
		var installed = f.installed !== null && f.installed !== undefined
			&& f.installed !== '' && f.installed !== false;
		updateAvailable = installed
			&& (f.checked === true || f.checked === 'true')
			&& (f.update_available === true || f.update_available === 'true');
		var btn = FCC.$('#fcc-update-run');
		if (btn) { btn.disabled = !updateAvailable; }
	}

	function checkUpdates() {
		var box = FCC.$('#fcc-update-state');
		if (!box) { return; }
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Checking…') }));
		FCC.api('update_check', {}, { method: 'GET' })
			.then(renderUpdates)
			.catch(function (err) { FCC.notice(box, 'fail', err.message); });
	}

	/* The result lives only in the page. Clearing it puts the block back to the
	 * state it has before the first check, and takes "Update FCC" with it: the
	 * button may only be lit by a check the user is looking at. */
	function clearUpdateRecord() {
		var box = FCC.$('#fcc-update-state');
		if (!box) { return; }
		box.innerHTML = '';
		box.appendChild(FCC.el('div', { class: 'fcc-muted', text: FCC._('Not checked yet.') }));
		updateAvailable = false;
		var btn = FCC.$('#fcc-update-run');
		if (btn) { btn.disabled = true; }
	}

	function runUpdate() {
		var btn = FCC.$('#fcc-update-run');
		if (btn) { btn.disabled = true; }
		/* The update holds fcc-update.lock, not the install lock; watching the
		 * wrong one reported "finished" on the first poll, before the update
		 * had done anything, which is what made the button look inert. */
		runJobAction('update_runtime', {}, 'update', 'fcc-update.log', clearUpdateRecord);
	}

	/* The record is both leftovers of a run: the job panel below the runtime
	 * toolbar, and the version table in the Updates block. They are one button
	 * because clearing one without the other left a page that described two
	 * different runs. Clearing empties the page and nothing on disk — the logs
	 * under the install path are the evidence an install leaves behind, and the
	 * same rule every other Clear on this page follows. Refused while a job is
	 * running, because that log is the live output, not a record. */
	function clearRecord() {
		var box = FCC.$('#fcc-runtime-status');
		if (jobTimer) {
			FCC.notice(box, 'warn',
				FCC._('A job is still running. Wait for it to finish before clearing the record.'));
			return;
		}
		var panel = FCC.$('#fcc-job');
		if (panel) { panel.style.display = 'none'; }
		var bar = FCC.$('#fcc-job-bar');
		if (bar) { bar.style.width = '0'; }
		var pre = FCC.$('#fcc-job-log');
		if (pre) { pre.textContent = ''; }
		clearUpdateRecord();
		FCC.notice(box, 'ok', FCC._('Record cleared.'));
	}

	/* ---------------------------------------------------------------- init */

	function refreshAll() {
		return FCC.api('status', {}, { method: 'GET' }).then(function (d) {
			renderRuntime(d);
			return d;
		});
	}

	/* The card used to be whatever the page found when it opened, so it could
	 * still say "Installed, v1.2.3" about a runtime an install had replaced in
	 * the meantime. Basic Information polls the same status call every two
	 * seconds, and that call is the cheap one — one status.sh reading /proc once
	 * for every agent — so the same cadence applies here. A hidden tab does not
	 * poll: a page left open in the background must not cost the router a
	 * process every two seconds. */
	function pollStatus() {
		if (statusBusy || document.hidden) { return; }
		statusBusy = true;
		/* Promise.resolve() first so a synchronous throw still reaches the
		 * catch: one failed refresh must not leave statusBusy set and stop the
		 * card for the rest of the page's life. */
		Promise.resolve().then(refreshAll)
			.catch(function () { /* a blip is not a failure */ })
			.then(function () { statusBusy = false; });
	}

	function startStatusPoll() {
		if (statusTimer) { return; }
		statusTimer = setInterval(pollStatus, 2000);
		/* Back from another tab, the number should be right before the first
		 * interval elapses rather than up to two seconds later. pollStatus
		 * itself ignores the events while the page is hidden. */
		document.addEventListener('visibilitychange', pollStatus);
		window.addEventListener('beforeunload', function () {
			if (statusTimer) { clearInterval(statusTimer); }
			statusTimer = null;
		});
	}

	function init() {
		var agentPicker = FCC.$('#fcc-runtime-agent');

		/* One button covers Install and Reinstall, and the two jobs it can start
		 * are not the same operation.
		 *
		 * With an agent chosen, it adds that agent to whatever runtime is there.
		 * That is the dropdown's whole purpose: the upstream installer stops at
		 * the first agent it cannot install and rolls the run back (§79), so on
		 * a device where one agent fails the others are only reachable one at a
		 * time.
		 *
		 * With "All agents" and no runtime, it is a plain install of the whole
		 * registry. With "All agents" and a runtime already present, it is the
		 * old Reinstall: remove the runtime, then install everything again. The
		 * upstream installer reconciles the agent set and never reinstalls an
		 * agent that is already there (section 104.25), so this is the only way
		 * to replace a damaged one — and because it removes the runtime first,
		 * it asks before it starts.
		 *
		 * Status is read at click time rather than taken from the last paint:
		 * the page may have been left open across an install, and the question
		 * in the dialog has to describe the job that is actually about to run. */
		FCC.$('#fcc-runtime-install').addEventListener('click', function () {
			var picker = FCC.$('#fcc-runtime-agent');
			var agent = picker ? picker.value : '';
			if (agent) {
				runJobAction('install_runtime', { agent: agent }, 'install', 'fcc-runtime.log');
				return;
			}
			FCC.api('status', {}, { method: 'GET' }).then(function (d) {
				if (!(d.fcc && d.fcc.installed)) {
					runJobAction('install_runtime', {}, 'install', 'fcc-runtime.log');
					return;
				}
				if (!window.confirm(FCC._('Remove the FCC runtime and install it again with every agent? Your configuration and data under the install path are kept.'))) {
					return;
				}
				runJobAction('reinstall_runtime', {}, 'install', 'fcc-runtime.log');
			}).catch(function (err) {
				FCC.notice(FCC.$('#fcc-runtime-status'), 'fail', err.message);
			});
		});
		/* The dropdown decides which set the report is about, so changing it
		 * re-runs the report: a panel still describing the whole registry would
		 * contradict the choice just made, and the contradiction is worst in the
		 * one case the dropdown exists for — a reader who has narrowed the
		 * install to an agent that does not need the failing thing, and is told
		 * their install is blocked. */
		if (agentPicker) { agentPicker.addEventListener('change', runDoctor); }
		/* Both ways of starting an update — the toolbar button and the one under
		 * the check result — watch the same lock, because the backend holds
		 * fcc-update.lock for this job and not fcc-install.lock. */
		FCC.$('#fcc-runtime-update').addEventListener('click', runUpdate);
		FCC.$('#fcc-runtime-clear').addEventListener('click', clearRecord);
		FCC.$('#fcc-update-check').addEventListener('click', checkUpdates);
		FCC.$('#fcc-update-run').addEventListener('click', runUpdate);
		/* A page restored from the back/forward cache keeps the DOM it left,
		 * disabled state included. The block opens at "Not checked yet" and
		 * with "Update FCC" inert on every entry, whatever the last visit
		 * left behind. */
		clearUpdateRecord();
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
		/* There is deliberately no button for the backups: an install removes the
		 * copy it made as soon as it ends, so what used to be a button here is
		 * now nothing to clear except the copy a rollback that could not
		 * complete left behind — and that one is evidence, not clutter. */
		FCC.$('#fcc-runtime-purge').addEventListener('click', function () {
			if (!window.confirm(FCC._('Remove the FCC runtime and all of its data? This deletes the runtime, the agents, your configuration and every backup. It cannot be undone.'))) {
				return;
			}
			runJobAction('uninstall_runtime', { purge: 1 }, 'install', 'fcc-runtime.log');
		});

		FCC.$('#fcc-doctor-run').addEventListener('click', runDoctor);
		/* The report is drawn into this page and nowhere else, so this clears
		 * what is on screen and nothing on disk. */
		FCC.$('#fcc-doctor-clear').addEventListener('click', function () {
			var box = FCC.$('#fcc-doctor');
			if (box) { box.innerHTML = ''; }
		});

		refreshAll().catch(function (err) {
			FCC.notice(FCC.$('#fcc-runtime-status'), 'fail', err.message);
		}).then(function () {
			/* That first answer is the first paint; from here on the card is
			 * kept current. Started after it, so the first interval cannot
			 * overlap the call that drew the page. */
			startStatusPoll();
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
