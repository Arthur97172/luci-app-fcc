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
	var updateAvailable = false;
	/* The runtime panel's poll (see pollStatus). Kept apart from jobTimer:
	 * that one watches an install and stops with it, this one lives as long as
	 * the page does. */
	var statusTimer = null;
	var statusBusy = false;

	/* ------------------------------------------------------------- settings */

	function loadConfig() {
		return FCC.api('config_get', {}, { method: 'GET' }).then(function (d) {
			var c = d.config || {};
			FCC.$('#fcc-enabled').checked = (c.enabled === '1');
			FCC.$('#fcc-auto-start').checked = (c.auto_start === '1');
			FCC.$('#fcc-install-path').value = c.install_path || '/opt';
			FCC.$('#fcc-backup-path').value = c.backup_path || '/tmp/fcc';
			FCC.$('#fcc-bind').value = c.bind || '127.0.0.1';
			FCC.$('#fcc-port').value = c.port || 8082;
			FCC.$('#fcc-log-level').value = c.log_level || 'info';
			return d;
		});
	}

	/* One handler, two verbs. apply=true is Save & Apply: store the values and
	 * restart the server (and reconcile the firewall rule) so they take effect.
	 * apply=false is Save settings: store them and leave a running server
	 * alone, so a port or bind change can be staged without dropping the agent
	 * sessions attached to it. The backend defaults to applying when the flag
	 * is absent, which is what a page cached from before this button sees. */
	function saveConfig(apply) {
		var body = {
			enabled: FCC.$('#fcc-enabled').checked ? '1' : '0',
			auto_start: FCC.$('#fcc-auto-start').checked ? '1' : '0',
			install_path: FCC.$('#fcc-install-path').value,
			backup_path: FCC.$('#fcc-backup-path').value,
			bind: FCC.$('#fcc-bind').value,
			port: FCC.$('#fcc-port').value,
			log_level: FCC.$('#fcc-log-level').value,
			apply: apply ? '1' : '0'
		};
		FCC.notice(FCC.$('#fcc-config-status'), '', '');
		FCC.api('config_set', body, { method: 'POST' }).then(function (r) {
			var msg = FCC._('Settings saved.');
			if (!apply) {
				msg += ' ' + FCC._('They take effect when you choose Save & Apply.');
			}
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

	/* Reset changes, LuCI's third verb: throw away the edits and put the saved
	 * values back in the form. It reads them from UCI rather than from a copy
	 * taken when the page opened, so a value changed in another tab — or by a
	 * save that succeeded just before a failed one — is what comes back. */
	function resetConfig() {
		return loadConfig().then(function () {
			FCC.notice(FCC.$('#fcc-config-status'), 'ok',
				FCC._('Changes discarded. The saved settings are shown.'));
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

	/* The lines under a server's state dot, shared by the local panel and the
	 * LAN one. Both sides answer with the same document — the LAN machine's
	 * status.sh is this package's own — so a server reads the same way
	 * whichever machine is running it. A field the answer does not carry is a
	 * dash, which is what a stopped server's pid is. */
	function renderServerRows(box, s, version) {
		var rows = [
			[FCC._('Version'), version || '—'],
			[FCC._('PID'), s.pid != null ? String(s.pid) : '—'],
			[FCC._('Uptime'), s.uptime != null ? FCC.fmtDuration(s.uptime) : '—'],
			[FCC._('Memory (RSS)'), s.memory_rss_kb != null ? FCC.fmtKB(s.memory_rss_kb) : '—'],
			[FCC._('Listening on'), (s.bind || '—') + ':' + (s.port != null ? s.port : '—')]
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
		renderServerRows(box, s, f.version);
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
				} else if (r.remote_stopped) {
					FCC.notice(FCC.$('#fcc-server-status'), 'ok',
						FCC._('Done. The LAN FCC Server was stopped.'));
				} else {
					FCC.notice(FCC.$('#fcc-server-status'), 'ok', FCC._('Done.'));
				}
				/* A start or restart here makes this router the control target,
				 * so the switch has moved and the LAN panel's state is stale. */
				setTimeout(function () {
					refreshAll();
					loadRemote();
				}, 1500);
			});
		}).catch(function (err) {
			FCC.notice(FCC.$('#fcc-server-status'), 'fail', err.message);
		});
	}

	/* ------------------------------------------------- FCC Server: LAN target */

	/* The FCC Server section controls one machine at a time: this router, or
	 * one other machine on the LAN over SSH. Everything below is a copy of what
	 * remote.sh reports — a click never assumes its own success, because the
	 * answer comes from the machine that was asked. Nothing here holds a
	 * password: the router has an Ed25519 key under /etc/fcc/ssh and UCI stores
	 * only the address, the account and the pinned host fingerprint. */

	var remote = {
		target: 'local',
		host: '',
		user: '',
		ssh_port: '22',
		admin_port: '8082',
		platform: 'linux',
		service: 'fcc',
		fingerprint: '',
		public_key: '',
		key_ready: false,
		/* ok, missing, no-public, mismatch, invalid or unchecked. key_ready is
		 * the yes/no the controls follow; this word is what lets the page say
		 * why the answer is no. */
		key_state: '',
		trusted: false,
		ready: false,
		ssh_client: 'openssh',
		keygen_available: true,
		scan_available: true,
		tunnel_running: false,
		pending_fingerprint: '',
		/* null means "not known": never checked, being checked, or the check
		 * could not reach the machine. A false here is an answer from the
		 * remote service manager, not a default. */
		server_running: null,
		/* The LAN machine's own status.sh document — version, pid, uptime,
		 * RSS, bind and port — when it runs this package. null when the
		 * machine answered the state question only. */
		server_details: null,
		server_pending: false,
		server_error: ''
	};

	/* remote.sh is a shell script, and a shell script's sentences are not in the
	 * translation catalogue. Shown as they arrive, a Chinese page carries
	 * English failures — which is what made a state check on a machine without
	 * systemctl read "the state of the remote server could not be read". Every
	 * fixed sentence the script can return is translated here by its exact
	 * text; a message with a variable in it is logged and replaced by the
	 * caller's own fallback, and a reason code names the setting to change. */
	var REMOTE_ERROR_TEXT = {
		'remote control is not enabled':
			FCC._('The LAN side is not the selected FCC Server.'),
		'the remote configuration is incomplete':
			FCC._('The LAN connection settings are incomplete.'),
		'the SSH key has not been generated':
			FCC._('The SSH key has not been generated yet.'),
		'the remote host key has not been trusted':
			FCC._('The remote host key has not been trusted yet.'),
		'trust the remote host key first':
			FCC._('The remote host key has not been trusted yet.'),
		'invalid platform':
			FCC._('The platform selected for the LAN machine is not valid.'),
		'invalid fingerprint':
			FCC._('The host key fingerprint is not valid.'),
		'could not create a temporary directory':
			FCC._('A temporary directory could not be created on this router.'),
		'could not store the remote host key':
			FCC._('The remote host key could not be stored.'),
		'could not read the remote host key':
			FCC._('The remote host key could not be read.'),
		'could not read the existing SSH key':
			FCC._('The existing SSH key could not be read.'),
		'could not store the public key':
			FCC._('The public key could not be stored on this router.'),
		'could not move the unusable SSH key aside':
			FCC._('The unusable SSH key could not be moved aside.'),
		'the SSH key on this router is not a key OpenSSH can read; generate it again':
			FCC._('The SSH key on this router is not a key OpenSSH can read. Generate the key again, then add the new public key to the LAN machine.'),
		'the stored public key does not match the private key; generate the key again':
			FCC._('The public key does not belong to the private key on this router. Generate the key again.'),
		'setsid is not available':
			FCC._('This router has no setsid, so the LAN tunnel cannot be started.'),
		'the state of the remote server could not be read':
			FCC._('The LAN machine answered in a form that could not be read.'),
		'ssh-keygen is required on this router to create the key (package openssh-keygen)':
			FCC._('This router needs ssh-keygen to create the key (package openssh-keygen).'),
		'ssh-keyscan is required on this router to read the remote host key (package openssh-client-utils)':
			FCC._('This router needs ssh-keyscan to read the remote host key (package openssh-client-utils).'),
		'ssh on this router is Dropbear, which cannot use these options; install the OpenSSH client (package openssh-client-utils) on the router':
			FCC._('ssh on this router is Dropbear, which cannot use these options. Install the OpenSSH client (package openssh-client-utils) on the router.'),
		'this router has no SSH client; install the OpenSSH client (package openssh-client-utils) on the router':
			FCC._('ssh on this router is not a usable OpenSSH client. Install the OpenSSH client (package openssh-client-utils) on the router; the client on the remote machine is not used.'),
		'ssh on this router is not OpenSSH; install the OpenSSH client (package openssh-client-utils) on the router':
			FCC._('ssh on this router is not a usable OpenSSH client. Install the OpenSSH client (package openssh-client-utils) on the router; the client on the remote machine is not used.'),
		'the connection failed':
			FCC._('The connection failed.'),
		'invalid operation':
			FCC._('The operation failed.'),
		'unknown remote command':
			FCC._('The operation failed.')
	};

	/* The two failures that are a setting rather than a fault. Each sentence
	 * names the field, because retrying is what a person does next and it
	 * cannot help. */
	var REMOTE_REASON_TEXT = {
		'no-systemctl':
			FCC._('The LAN machine has no systemctl. If it runs OpenWrt, set its platform to OpenWrt in Advanced settings.'),
		'no-init-script':
			FCC._('The service was not found on the LAN machine. Check the service name in Advanced settings.'),
		/* A Linux, macOS or Windows machine carrying only the upstream install
		 * has no service at all — no unit, no launchd job, no Windows service.
		 * Start and stop then go to the launcher itself, so this is only what
		 * is left when even that cannot be reached. */
		'no-service':
			FCC._('The LAN machine has no fcc service and no launcher to start. Install the FCC Server on that machine, or check the service name in Advanced settings.'),
		/* The launcher is not on that machine's PATH. The page cannot put it
		 * there: the upstream install writes it into the account's own bin
		 * directory, which only an install on that machine can do. */
		'no-launcher':
			FCC._('The FCC Server is not installed on the LAN machine. Install it there, then try again.'),
		/* The launcher ran and did not come up, or did not go away. Its own log
		 * over there says which, and the page names the file to look at. */
		'start-failed':
			FCC._('The FCC Server did not start on the LAN machine. Its log on that machine, ~/.fcc/server.log, says why.'),
		'stop-failed':
			FCC._('The FCC Server did not stop on the LAN machine. Its process is still running there.'),
		'no-pgrep':
			FCC._('The LAN machine has no pgrep, so its FCC Server cannot be found to be started or stopped from here.'),
		/* The unit is there and this account may not touch it: systemd asked
		 * for a password nobody can type into an SSH command. */
		'needs-root':
			FCC._('Only an administrator on the LAN machine may control its FCC Server. Start it on that machine itself, or give this account the right to control the service.'),
		'unreadable':
			FCC._('The LAN machine answered in a form that could not be read.'),
		/* The key on this router, not the LAN machine: OpenSSH could not read
		 * it, so nothing was ever offered over there. Generating the key again
		 * is the only repair, and the new public half then has to be added to
		 * the LAN account before the connection can work. */
		'key-invalid':
			FCC._('The SSH key on this router is not a key OpenSSH can read. Generate the key again, then add the new public key to the LAN machine.'),
		'key-mismatch':
			FCC._('The public key shown here does not belong to the private key on this router. Generate the key again, then add the new public key to the LAN machine.'),
		'key-missing':
			FCC._('The SSH key on this router is missing. Generate the key again, then add the new public key to the LAN machine.'),
		/* The key was read and the LAN machine refused it — the ordinary state
		 * of a first setup, before the public half is in authorized_keys. */
		'auth':
			FCC._('The LAN machine refused the SSH key. Add the public key shown here to that account’s authorized_keys.'),
		'unreachable':
			FCC._('The LAN machine could not be reached over SSH. Check that it is switched on and that its SSH server is running.'),
		'host-key':
			FCC._('The LAN machine’s host key no longer matches the one pinned on this router. Forget the pinned key and trust it again.')
	};

	/* Start, stop and restart also put the sshd setting the Admin tunnel needs
	 * in place on that machine, or take it away again (remote.sh's
	 * fcc_remote_forwarding_script). The four ordinary answers — on, already,
	 * off, absent — are the operation working, and say nothing; these are the
	 * ones that leave the machine as it was. None of them is a failed start or
	 * stop: the FCC server over there is a separate thing from its SSH daemon,
	 * so the page warns and the state line still shows what the server does.
	 *
	 * "allowed" is silence too, and the best of these answers: the machine's
	 * own configuration already permits local forwarding — OpenSSH's default is
	 * to permit it — so nothing was written and no privilege was asked for.
	 *
	 * "unsupported" is silence as well: a machine whose sshd_config reads no
	 * drop-in directory cannot be helped this way, though it may well allow
	 * forwarding already. If the tunnel is refused, the Admin page names the
	 * setting. */
	var FORWARDING_TEXT = {
		'denied':
			FCC._('The LAN machine’s SSH daemon may still refuse the Admin tunnel: this account is not allowed to change its configuration. AllowTcpForwarding local has to be set there by an administrator — “One-time setup on the LAN machine” below has the command.'),
		'foreign':
			FCC._('A file named 00-fcc-local-forwarding.conf was already on the LAN machine and was left as it is. The Admin tunnel needs AllowTcpForwarding local in that machine’s SSH configuration.'),
		'invalid':
			FCC._('The LAN machine’s SSH daemon rejected the forwarding setting, so it was taken away again. The Admin tunnel needs AllowTcpForwarding local in that machine’s SSH configuration.'),
		'reload-failed':
			FCC._('The LAN machine’s SSH service did not reload, so the change to its forwarding setting has not taken effect.')
	};

	/* Stopping takes the same file away, so "denied" there means it is still
	 * in place — a different sentence, and one that does not talk about a
	 * tunnel nobody is opening. */
	var FORWARDING_STOP_TEXT = {
		'denied':
			FCC._('The forwarding file could not be removed from the LAN machine: this account is not allowed to change its SSH configuration. It was left in place.'),
		'foreign':
			FCC._('A file named 00-fcc-local-forwarding.conf on the LAN machine does not belong to FCC and was left as it is.'),
		'reload-failed':
			FCC._('The LAN machine’s SSH service did not reload, so the change to its forwarding setting has not taken effect.')
	};

	function forwardingWarning(d, op) {
		if (!d || !d.forwarding) { return ''; }
		var map = (op === 'stop') ? FORWARDING_STOP_TEXT : FORWARDING_TEXT;
		return map[d.forwarding] || '';
	}

	/* The command that settles the setting on a machine whose sshd refuses it,
	 * fetched the first time it is wanted and kept: it names the account this
	 * router is configured with, so a saved change to that account is the one
	 * thing that invalidates it (saveRemoteConfig clears it). */
	var remoteHelperBlock = '';

	function showRemoteHelper(open) {
		var panel = FCC.$('#fcc-remote-helper-panel');
		if (!panel) { return; }
		if (open === false) { panel.hidden = true; return; }
		panel.hidden = false;
		var text = FCC.$('#fcc-remote-helper-text');
		var state = FCC.$('#fcc-remote-helper-state');
		if (remoteHelperBlock) {
			if (text) { text.textContent = remoteHelperBlock; }
			return;
		}
		if (state) { state.textContent = FCC._('Reading the block from the router…'); }
		FCC.api('remote_helper', {}, { method: 'GET' }).then(function (d) {
			remoteHelperBlock = d.install || '';
			if (text) { text.textContent = remoteHelperBlock; }
			if (state) {
				state.textContent = d.installed
					? FCC._('The one-time setup is already in place on the LAN machine.')
					: FCC._('The one-time setup has not been installed on the LAN machine yet.');
			}
		}).catch(function (err) {
			if (state) {
				state.textContent = remoteCaught(err, FCC._('Could not read the one-time setup.'));
			}
		});
	}

	function remoteErrorText(text) {
		var t = String(text == null ? '' : text)
			.replace(/\s+/g, ' ')
			.replace(/^ | $/g, '');
		if (REMOTE_ERROR_TEXT[t]) { return REMOTE_ERROR_TEXT[t]; }
		if (t.indexOf('could not generate the SSH key') === 0) {
			return FCC._('The SSH key could not be generated.');
		}
		if (t) {
			try { console.warn('remote.sh said: ' + text); } catch (e) { /* no console */ }
		}
		return '';
	}

	/* What ssh prints about itself is not about the operation: OpenSSH 9.9 and
	 * later open every connection with a three-line post-quantum warning, and a
	 * Windows answer can leave a CR behind. Neither belongs on the page. */
	function remoteOutput(text) {
		var kept = [];
		String(text == null ? '' : text).replace(/\r/g, '').split(/\n/).forEach(function (line) {
			if (!/^\*\*/.test(line) && line.replace(/\s+/g, '') !== '') { kept.push(line); }
		});
		var out = kept.join(' ').replace(/\s+/g, ' ').replace(/^ | $/g, '');
		return out.length > 300 ? out.slice(0, 300) + '…' : out;
	}

	/* One sentence for a failed LAN operation. The reason, when the script sent
	 * one, wins: it is the only case where the page can say what to do. The
	 * script's own diagnostic follows in brackets only when nothing above
	 * explained it, so the common failures carry no English at all. */
	function remoteFailure(d, fallback) {
		if (d && d.reason && REMOTE_REASON_TEXT[d.reason]) {
			return REMOTE_REASON_TEXT[d.reason];
		}
		var text = remoteErrorText(d && d.error) || fallback;
		var detail = remoteOutput(d && d.output);
		return detail ? text + ' (' + detail + ')' : text;
	}

	function remoteCaught(err, fallback) {
		return remoteErrorText(err && err.message) || fallback;
	}

	function remoteStatus() { return FCC.$('#fcc-remote-status'); }

	/* Which panel is on screen. Both exist all the time: hiding the one not in
	 * use keeps every value and every pending fingerprint where it was when the
	 * mode is switched back. */
	function showRemoteMode(mode) {
		var local = FCC.$('#fcc-local-controls');
		var lan = FCC.$('#fcc-remote-controls');
		if (local) { local.hidden = (mode === 'lan'); }
		if (lan) { lan.hidden = (mode !== 'lan'); }
		Array.prototype.forEach.call(
			document.querySelectorAll('.fcc-mode-btn'),
			function (b) {
				var on = b.getAttribute('data-mode') === mode;
				b.setAttribute('aria-pressed', on ? 'true' : 'false');
				b.className = 'fcc-mode-btn' + (on ? ' on' : '');
			}
		);
		renderRemoteServerState();
	}

	function remoteFields() {
		return {
			host: FCC.$('#fcc-remote-host').value,
			user: FCC.$('#fcc-remote-user').value,
			ssh_port: FCC.$('#fcc-remote-ssh-port').value || '22',
			admin_port: FCC.$('#fcc-remote-admin-port').value || '8082',
			platform: FCC.$('#fcc-remote-platform').value,
			service: FCC.$('#fcc-remote-service').value || 'fcc'
		};
	}

	/* The three remote commands remote.sh would run for this configuration.
	 * The presets are duplicated here on purpose: the preview is the one place
	 * the user can read what a button sends without opening the script, and a
	 * preview built by asking the script would be a fourth round trip for a
	 * string the page can already spell. */
	var REMOTE_VERBS = {
		start: { linux: 'start', openwrt: 'start', windows: 'Start-Service' },
		stop: { linux: 'stop', openwrt: 'stop', windows: 'Stop-Service' },
		restart: { linux: 'restart', openwrt: 'restart', windows: 'Restart-Service' }
	};

	/* What Windows runs when no service of the configured name exists. The
	 * upstream installer registers no service, so this is the branch that runs
	 * on a machine that only ran install.ps1: the proxy is fcc-server, started
	 * hidden, or the process list is stopped. Both branches are shown because
	 * which one runs depends on the machine, not on a setting here. */
	var WIN_FALLBACK = {
		start: "Start-Process -WindowStyle Hidden -FilePath (Get-Command 'fcc-server' -ErrorAction Stop).Source",
		stop: "Stop-Process -Name 'fcc-server','fcc-desktop' -ErrorAction SilentlyContinue",
		restart: "Stop-Process -Name 'fcc-server','fcc-desktop' -ErrorAction SilentlyContinue; " +
			"Start-Sleep -Milliseconds 500; " +
			"Start-Process -WindowStyle Hidden -FilePath (Get-Command 'fcc-server' -ErrorAction Stop).Source"
	};

	function previewCommands() {
		var box = FCC.$('#fcc-remote-preview');
		if (!box) { return; }
		var v = remoteFields();
		var service = v.service || 'fcc';
		/* macOS writes no launchd job, so there is no preset to print — but the
		 * launcher itself is what the buttons act on there: started detached with
		 * its output in the FCC log, and stopped by the pid the process list
		 * yields. remote.sh runs exactly that over there, so the preview shows
		 * the three commands instead of a preset that would not run. */
		if (v.platform === 'macos') {
			var macRun = 'nohup fcc-server >>~/.fcc/server.log 2>&1 &';
			var macStop = 'kill $(pgrep -f fcc-server)';
			box.textContent = [macRun, macStop, macStop + '; ' + macRun].join('\n');
			return;
		}
		var lines = Object.keys(REMOTE_VERBS).map(function (op) {
			var verb = REMOTE_VERBS[op][v.platform] || REMOTE_VERBS[op].linux;
			if (v.platform === 'openwrt') { return '/etc/init.d/' + service + ' ' + verb; }
			if (v.platform === 'windows') {
				/* <PATH setup> stands for the directory list every one of these
				 * commands starts with — the launchers install.ps1 wrote, which
				 * sshd does not put on PATH. It is the same in all three, so it
				 * is abbreviated rather than repeated three times. */
				return 'powershell.exe -NoProfile -NonInteractive -Command "<PATH setup>; ' +
					"if (Get-Service -Name '" + service + "' -ErrorAction SilentlyContinue) { " +
					verb + " -Name '" + service + "' -ErrorAction Stop } else { " +
					WIN_FALLBACK[op] + ' }"';
			}
			return 'systemctl ' + verb + ' ' + service;
		});
		/* OpenWrt asks whether that init script exists first, and falls back to
		 * the launcher when it does not — a machine carrying only the upstream
		 * install has none. The note says so once rather than doubling each of
		 * the three lines. */
		if (v.platform === 'openwrt') {
			lines.push(FCC._('Without an init script of that name the launcher is used instead, as on a Linux machine without a unit.'));
		}
		box.textContent = lines.join('\n');
	}

	/* Where the public key has to go. The answer is not one path: Linux uses the
	 * account's ~/.ssh/authorized_keys, macOS keeps the account home under
	 * /Users, OpenWrt's default Dropbear reads /etc/dropbear/authorized_keys,
	 * and Windows keeps administrators' keys in ProgramData — sshd's default
	 * config ignores their per-user file. The path follows the platform and the
	 * account field, so the panel names the file the user actually has to edit
	 * instead of a Unix path that does not exist on Windows. */
	function remoteKeyPath() {
		var path = FCC.$('#fcc-remote-key-path');
		var note = FCC.$('#fcc-remote-key-note');
		if (!path || !note) { return; }
		var user = (FCC.$('#fcc-remote-user') || {}).value || remote.user || '';
		user = user.replace(/^\s+|\s+$/g, '');

		if (remote.platform === 'windows') {
			path.textContent =
				'C:\\Users\\' + (user || '<username>') + '\\.ssh\\authorized_keys\n' +
				'C:\\ProgramData\\ssh\\administrators_authorized_keys';
			note.textContent = FCC._('Use the first line for a standard account and the second for an administrator account. The second file must be writable only by Administrators and SYSTEM.');
		} else if (remote.platform === 'openwrt') {
			path.textContent = '/etc/dropbear/authorized_keys';
			note.textContent = FCC._('Dropbear, the default OpenWrt SSH server, reads this file. An OpenSSH server on the same machine reads ~/.ssh/authorized_keys instead.');
		} else if (remote.platform === 'macos') {
			/* Remote Login is off by default on macOS, and nothing else in this
			 * page can make the connection work until it is on — so the note
			 * says where the switch is, next to the file to edit. */
			path.textContent = (user ? '/Users/' + user : '~') + '/.ssh/authorized_keys';
			note.textContent = FCC._('Remote Login must be enabled on that Mac in System Settings → General → Sharing. The directory must be 700 and the file 600, and neither may be writable by anyone else.');
		} else {
			var home = user === 'root' ? '/root' : (user ? '/home/' + user : '~');
			path.textContent = home + '/.ssh/authorized_keys';
			note.textContent = FCC._('If the home directory is not under /home, ~ is that directory. The directory must be 700 and the file 600, and neither may be writable by anyone else.');
		}
	}

	function showTrustPanel(fingerprint) {
		remote.pending_fingerprint = fingerprint || '';
		var panel = FCC.$('#fcc-remote-trust-panel');
		var shown = FCC.$('#fcc-remote-trust-fingerprint');
		if (shown) { shown.textContent = remote.pending_fingerprint; }
		if (panel) { panel.hidden = false; }
	}

	function hideTrustPanel() {
		remote.pending_fingerprint = '';
		var panel = FCC.$('#fcc-remote-trust-panel');
		if (panel) { panel.hidden = true; }
	}

	function updateRemoteControls() {
		var can = remote.ready === true;
		Array.prototype.forEach.call(
			document.querySelectorAll('[data-remote-op]'),
			function (b) { b.disabled = !can; }
		);

		/* The Admin link is a link, so it cannot be disabled; it is made inert
		 * instead. A click that did nothing would be worse than a link that
		 * looks unavailable, and the proxy would answer 502 anyway. */
		var link = FCC.$('#fcc-remote-admin-link');
		if (link) {
			if (can) {
				link.classList.remove('fcc-locked');
				link.removeAttribute('aria-disabled');
			} else {
				link.classList.add('fcc-locked');
				link.setAttribute('aria-disabled', 'true');
			}
		}

		var test = FCC.$('#fcc-remote-test');
		if (test) { test.disabled = !(remote.host && remote.user); }

		var gen = FCC.$('#fcc-remote-keygen');
		if (gen) { gen.disabled = !remote.keygen_available; }
	}

	/* What the machine on the other side is doing.
	 *
	 * The switch position and the running server are two different facts. The
	 * position survives a logout because it is stored in UCI; whether the
	 * remote service is still up is only true for as long as nobody touched
	 * it, so the page asks instead of assuming. That is what makes a reload
	 * report the server that is actually running, the way the local panel
	 * already does from its own status call. */
	function renderRemoteServerState() {
		var box = FCC.$('#fcc-remote-server-state');
		if (!box) { return; }
		box.className = 'fcc-key-state';
		if (remote.target !== 'lan') {
			box.textContent = '';
			return;
		}
		if (remote.server_pending) {
			box.textContent = FCC._('Checking the LAN FCC Server state...');
			return;
		}
		if (remote.server_running === true) {
			/* The remote answers with its own status.sh document when it runs
			 * this package; without one there is nothing to show but the
			 * state, and a table of dashes would look like a server that
			 * reports nothing. */
			if (!remote.server_details) {
				box.className = 'fcc-key-state on';
				box.textContent = FCC._('The LAN FCC Server is running.');
				return;
			}
			/* The same card the local panel puts its six lines in: the two
			 * panels answer the same question, so they should not look like
			 * two different kinds of answer. */
			box.className = 'fcc-card';
			box.innerHTML = '';
			box.appendChild(FCC.el('div', {}, [
				FCC.el('span', { class: 'fcc-dot on' }),
				FCC.el('strong', { text: FCC._('Running') })
			]));
			renderServerRows(box, remote.server_details, remote.server_details.version);
			return;
		}
		if (remote.server_running === false) {
			box.className = 'fcc-key-state off';
			box.textContent = FCC._('The LAN FCC Server is not running.');
			return;
		}
		if (remote.server_error) {
			box.className = 'fcc-key-state fail';
			box.textContent = FCC._('The LAN FCC Server state could not be checked') +
				': ' + remote.server_error;
			return;
		}
		box.textContent = '';
	}

	/* One SSH round trip, made only when the LAN panel is the one on screen and
	 * the connection is ready. A page opened on the local side never waits for
	 * a machine it is not using. */
	function checkRemoteRunning() {
		remote.server_running = null;
		remote.server_details = null;
		remote.server_error = '';
		remote.server_pending = remote.target === 'lan' && remote.ready === true;
		renderRemoteServerState();
		if (!remote.server_pending) { return Promise.resolve(); }
		return FCC.api('remote_running', {}, { method: 'GET' }).then(function (d) {
			remote.server_pending = false;
			if (d && d.ok === true && d.checked === true) {
				remote.server_running = d.running === true;
				remote.server_details = d.details || null;
			} else {
				remote.server_error = remoteFailure(d, FCC._('the machine did not answer'));
			}
			renderRemoteServerState();
		}).catch(function (err) {
			remote.server_pending = false;
			remote.server_error = remoteCaught(err, FCC._('the machine did not answer'));
			renderRemoteServerState();
		});
	}

	/* The one thing standing between the place the page is in and a working
	 * connection, in the order the user would hit it. "OpenSSH is required"
	 * without saying where sent people to install it on the remote machine —
	 * the one place it cannot help — so every sentence here names the router
	 * and the package that fixes it. */
	function remoteBlocker() {
		if (remote.ssh_client === 'dropbear') {
			return FCC._('ssh on this router is Dropbear, which cannot use these options. Install the OpenSSH client (package openssh-client-utils) on the router.');
		}
		if (remote.ssh_client !== 'openssh') {
			return FCC._('ssh on this router is not a usable OpenSSH client. Install the OpenSSH client (package openssh-client-utils) on the router; the client on the remote machine is not used.');
		}
		if (!remote.keygen_available && !remote.key_ready) {
			return FCC._('This router needs ssh-keygen to create the key (package openssh-keygen).');
		}
		if (!remote.scan_available && !remote.trusted) {
			return FCC._('This router needs ssh-keyscan to read the remote host key (package openssh-client-utils).');
		}
		return '';
	}

	function renderRemoteState() {
		var state = FCC.$('#fcc-remote-key-state');
		if (state) {
			var blocker = remoteBlocker();
			state.className = 'fcc-key-state';
			if (blocker) {
				state.className += ' fail';
				state.textContent = blocker;
			} else if (remote.key_state === 'invalid' || remote.key_state === 'mismatch') {
				/* A key file is there and cannot be used. It must not be called
				 * configured, and the Generate button below has to be visible:
				 * it is the repair, and hiding it behind key_ready was what
				 * left this state with no way out of the page. */
				state.className += ' fail';
				state.textContent = remote.key_state === 'mismatch'
					? FCC._('The public key does not belong to the private key on this router. Generate the key again.')
					: FCC._('The SSH key on this router cannot be used by OpenSSH. Generate the key again.');
			} else if (remote.key_ready) {
				state.className += ' on';
				state.textContent = FCC._('SSH key configured');
			} else {
				state.className += ' off';
				state.textContent = FCC._('SSH key not configured');
			}
		}

		var gen = FCC.$('#fcc-remote-keygen');
		if (gen) { gen.hidden = remote.key_ready; }
		var show = FCC.$('#fcc-remote-showkey');
		if (show) { show.hidden = !remote.key_ready; }

		/* The one-time setup is the sshd_config.d drop-in, which only Linux
		 * reads: an OpenWrt or macOS machine is never offered it. */
		var helper = FCC.$('#fcc-remote-helper');
		if (helper) { helper.hidden = remote.platform !== 'linux'; }
		if (remote.platform !== 'linux') { showRemoteHelper(false); }

		var fp = FCC.$('#fcc-remote-fingerprint');
		if (fp && document.activeElement !== fp) { fp.value = remote.fingerprint || ''; }

		remoteKeyPath();
		previewCommands();
		updateRemoteControls();
	}

	function fillRemoteFields() {
		var map = {
			'#fcc-remote-host': remote.host,
			'#fcc-remote-user': remote.user,
			'#fcc-remote-ssh-port': remote.ssh_port,
			'#fcc-remote-admin-port': remote.admin_port,
			'#fcc-remote-platform': remote.platform,
			'#fcc-remote-service': remote.service
		};
		Object.keys(map).forEach(function (sel) {
			var el = FCC.$(sel);
			/* Not into the field being typed in: a refresh that arrives while
			 * the address is half-written would undo the edit. */
			if (el && el !== document.activeElement) { el.value = map[sel]; }
		});
	}

	function loadRemote() {
		return FCC.api('remote_get', {}, { method: 'GET' }).then(function (d) {
			var c = d.config || {};
			remote.target = c.target === 'lan' ? 'lan' : 'local';
			remote.host = c.host || '';
			remote.user = c.user || '';
			remote.ssh_port = c.ssh_port || '22';
			remote.admin_port = c.admin_port || '8082';
			remote.platform = c.platform || 'linux';
			remote.service = c.service || 'fcc';
			remote.fingerprint = c.fingerprint || '';
			remote.public_key = d.public_key || '';
			remote.key_ready = d.key_ready === true;
			remote.key_state = typeof d.key_state === 'string' ? d.key_state : '';
			remote.trusted = d.trusted === true;
			remote.ready = d.ready === true;
			remote.ssh_client = d.ssh_client || (d.ssh_available === false ? 'none' : 'openssh');
			remote.keygen_available = d.keygen_available !== false;
			remote.scan_available = d.scan_available !== false;
			remote.tunnel_running = d.tunnel_running === true;

			fillRemoteFields();
			renderRemoteState();
			showRemoteMode(remote.target);
			/* Not chained: the switch, the fields and the key state are already
			 * shown, and the SSH answer fills in behind them. */
			checkRemoteRunning();
			return d;
		});
	}

	/* The switch is disabled while the answer is on its way: it changes which
	 * server runs, and a second click during that would ask for the opposite
	 * of what the first one is still doing. */
	function setModeBusy(busy) {
		Array.prototype.forEach.call(
			document.querySelectorAll('.fcc-mode-btn'),
			function (b) { b.disabled = busy; }
		);
	}

	function setRemoteMode(mode) {
		showRemoteMode(mode);
		if (mode === remote.target) { return Promise.resolve(); }
		/* Read before the request: the answer's remote_stopped only says the
		 * remote stop ran, and a LAN that was never configured would otherwise
		 * be reported as one that could not be stopped. */
		var lanConfigured = remote.ready === true;
		FCC.notice(remoteStatus(), '', '');
		setModeBusy(true);
		return FCC.api('remote_mode', { mode: mode }, { method: 'POST' })
			.then(function (r) {
				remote.target = mode;
				/* One FCC Server at a time, and the switch is what enforces it,
				 * so the page says which side it stopped rather than leaving
				 * the user to find out from a process list. */
				if (mode === 'lan') {
					FCC.notice(remoteStatus(), 'ok', FCC._('Switched to the LAN. The FCC Server on this router was stopped.'));
				} else if (!lanConfigured) {
					FCC.notice(remoteStatus(), 'ok', FCC._('Switched to this router. No LAN server is configured.'));
				} else if (r.remote_stopped) {
					FCC.notice(remoteStatus(), 'ok', FCC._('Switched to this router. The LAN FCC Server was stopped.'));
				} else {
					FCC.notice(remoteStatus(), 'warn', FCC._('Switched to this router, but the LAN FCC Server could not be stopped.'));
				}
				return loadRemote();
			})
			.catch(function (err) {
				/* The stored mode is the truth, so put the switch back where it
				 * was rather than leaving the page describing a mode that was
				 * never saved. */
				showRemoteMode(remote.target);
				FCC.notice(remoteStatus(), 'fail',
					remoteCaught(err, FCC._('The mode could not be switched.')));
			})
			.then(function () { setModeBusy(false); });
	}

	function saveRemoteConfig() {
		return FCC.api('remote_set', remoteFields(), { method: 'POST' })
			.then(function (r) {
				/* The generated block carries the account name, so a saved
				 * settings change makes the copy stale. */
				remoteHelperBlock = '';
				/* A changed address or SSH port is a different host, and the
				 * controller has already discarded the pinned key. Saying so is
				 * the difference between "the buttons went grey for no reason"
				 * and the one action that brings them back. */
				if (r.trust_reset) {
					hideTrustPanel();
					FCC.notice(remoteStatus(), 'warn',
						FCC._('The address or SSH port changed — the pinned host key was forgotten.'));
				}
				/* The service field sits under the platform select, and the
				 * platform name had been typed into it. The controller kept the
				 * default, and the fields below were refilled from the fresh
				 * status: say why, so the correction does not look like the
				 * field losing what was typed. */
				if (r.service_reset) {
					FCC.notice(remoteStatus(), 'warn',
						FCC._('The service name was the platform name. It is now fcc — change it if the init script has another name.'));
				}
				return loadRemote().then(function () { return r; });
			})
			.catch(function (err) {
				FCC.notice(remoteStatus(), 'fail',
					remoteCaught(err, FCC._('The LAN connection settings could not be saved.')));
				return null;
			});
	}

	function remoteTest() {
		FCC.notice(remoteStatus(), '', '');
		saveRemoteConfig().then(function (saved) {
			if (!saved) { return; }
			return FCC.api('remote_test', {}, { method: 'POST' }).then(function (d) {
				if (d.needs_trust) {
					showTrustPanel(d.fingerprint);
					FCC.notice(remoteStatus(), 'warn',
						FCC._('The remote host key is not trusted yet. Confirm the fingerprint below.'));
					return;
				}
				if (d.fingerprint_changed) {
					/* A changed key is not a typo and retrying will not fix it.
					 * The trust panel is hidden rather than filled in: pinning
					 * the new key with one click is exactly what a machine that
					 * changed identity should not get. */
					hideTrustPanel();
					FCC.notice(remoteStatus(), 'fail',
						FCC._('The remote host key has changed. If you did not expect that, stop and check the machine.') +
						' ' + FCC._('Expected') + ': ' + (d.expected || '—') +
						' — ' + FCC._('Now') + ': ' + (d.fingerprint || '—'));
					return loadRemote();
				}
				if (d.ok) {
					hideTrustPanel();
					FCC.notice(remoteStatus(), 'ok', FCC._('Connection works.'));
				} else {
					FCC.notice(remoteStatus(), 'fail',
						remoteFailure(d, FCC._('The connection failed.')));
				}
				return loadRemote();
			});
		}).catch(function (err) {
			FCC.notice(remoteStatus(), 'fail',
				remoteCaught(err, FCC._('The connection failed.')));
		});
	}

	function remoteTrust() {
		if (!remote.pending_fingerprint) { return; }
		FCC.notice(remoteStatus(), '', '');
		FCC.api('remote_trust', { fingerprint: remote.pending_fingerprint }, { method: 'POST' })
			.then(function (d) {
				if (d.ok) {
					hideTrustPanel();
					FCC.notice(remoteStatus(), 'ok', FCC._('The remote host key is now trusted.'));
				} else {
					FCC.notice(remoteStatus(), 'fail',
						remoteFailure(d, FCC._('The host key could not be trusted.')));
				}
				return loadRemote();
			})
			.catch(function (err) {
				FCC.notice(remoteStatus(), 'fail',
					remoteCaught(err, FCC._('The host key could not be trusted.')));
			});
	}

	function remoteForget() {
		if (!window.confirm(FCC._('Forget the pinned host key? The remote host will have to be trusted again before the buttons work.'))) {
			return;
		}
		FCC.notice(remoteStatus(), '', '');
		FCC.api('remote_forget', {}, { method: 'POST' }).then(function () {
			hideTrustPanel();
			FCC.notice(remoteStatus(), 'ok', FCC._('The pinned host key was forgotten.'));
			return loadRemote();
		}).catch(function (err) {
			FCC.notice(remoteStatus(), 'fail',
				remoteCaught(err, FCC._('The pinned host key could not be forgotten.')));
		});
	}

	function remoteKeygen() {
		FCC.notice(remoteStatus(), '', '');
		FCC.api('remote_keygen', {}, { method: 'POST' }).then(function (d) {
			if (!d.ok) {
				FCC.notice(remoteStatus(), 'fail',
					remoteFailure(d, FCC._('The SSH key could not be created.')));
				return;
			}
			remote.public_key = d.public_key || '';
			var panel = FCC.$('#fcc-remote-key-panel');
			var text = FCC.$('#fcc-remote-pubkey');
			if (text) { text.textContent = remote.public_key; }
			if (panel) { panel.hidden = false; }
			FCC.notice(remoteStatus(), 'ok',
				d.repaired ? FCC._('The public key was rebuilt from the private key. It is shown below.')
				: d.replaced ? FCC._('The unusable key was replaced. Add the public key below to the LAN machine.')
				: d.existing ? FCC._('The existing key is shown below.')
				: FCC._('A new SSH key was generated.'));
			return loadRemote();
		}).catch(function (err) {
			FCC.notice(remoteStatus(), 'fail',
				remoteCaught(err, FCC._('The SSH key could not be created.')));
		});
	}

	function remoteControl(op) {
		/* The same warning as the local controls: stopping or restarting the
		 * server does not touch the agent sessions, which keep running cut off
		 * from the server they were talking to. The router cannot count the
		 * sessions on another machine, so the count is left out. */
		if ((op === 'stop' || op === 'restart') &&
			!window.confirm(FCC._('Stopping FCC Server may affect active Coding Agent sessions.'))) {
			return;
		}
		FCC.notice(remoteStatus(), '', '');
		FCC.api('remote_control', { op: op }, { method: 'POST' }).then(function (d) {
			/* The sshd setting the Admin tunnel needs is arranged by this same
			 * click. A failed operation keeps the page's one line — that is the
			 * thing to retry — and when it worked but the setting did not, the
			 * warning takes the place of "Done." so it is not read past. */
			var warn = forwardingWarning(d, op);
			/* The one refusal a person can fix from this page: open the block
			 * with the command that makes the setting, rather than leaving the
			 * warning as the end of the story. */
			if (d.forwarding === 'denied') { showRemoteHelper(true); }
			if (!d.ok) {
				FCC.notice(remoteStatus(), 'fail',
					remoteFailure(d, FCC._('The operation failed.')));
			} else if (warn) {
				FCC.notice(remoteStatus(), 'warn', warn);
			} else {
				FCC.notice(remoteStatus(), 'ok', FCC._('Done.'));
			}
			/* Ask again rather than infer from the verb: the state line is the
			 * one place that says what the remote machine is doing, and a stop
			 * that was already stopped answers ok too. */
			return checkRemoteRunning();
		}).catch(function (err) {
			FCC.notice(remoteStatus(), 'fail',
				remoteCaught(err, FCC._('The operation failed.')));
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
							FCC.notice(FCC.$('#fcc-config-status'), 'fail',
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
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
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
			renderServer(d);
			renderRuntime(d);
			return d;
		});
	}

	/* The panel under the toolbar used to be whatever the page found when it
	 * opened, so it could still say "Running, uptime 26s" about a process that
	 * had been restarted in the meantime. Basic Information polls the same
	 * status call every two seconds, and that call is the cheap one — one
	 * status.sh reading /proc once for every agent — so the same cadence
	 * applies here. Two things are deliberately left alone: a hidden tab does
	 * not poll (a page left open in the background must not cost the router a
	 * process every two seconds), and the LAN panel is not polled at all — its
	 * status costs an SSH connection, not a fork. */
	function pollStatus() {
		if (statusBusy || document.hidden) { return; }
		statusBusy = true;
		/* Promise.resolve() first so a synchronous throw still reaches the
		 * catch: one failed refresh must not leave statusBusy set and stop the
		 * panel for the rest of the page's life. */
		Promise.resolve().then(refreshAll)
			.catch(function () { /* a blip is not a failure */ })
			.then(function () { statusBusy = false; });
	}

	function startStatusPoll() {
		if (statusTimer) { return; }
		statusTimer = setInterval(pollStatus, 2000);
		/* Back from another tab, the numbers should be right before the first
		 * interval elapses rather than up to two seconds later. pollStatus
		 * itself ignores the events while the page is hidden. */
		document.addEventListener('visibilitychange', pollStatus);
		window.addEventListener('beforeunload', function () {
			if (statusTimer) { clearInterval(statusTimer); }
			statusTimer = null;
		});
	}

	/* There is no ordering requirement left on the first paint. It used to have
	 * one — the recommended set had to be known before the table was drawn,
	 * because the table was where the tick boxes lived — and with the table gone
	 * the first paint is just the first refresh. Section 104.25. */

	function init() {
		FCC.$('#fcc-save').addEventListener('click', function () { saveConfig(true); });
		FCC.$('#fcc-save-only').addEventListener('click', function () { saveConfig(false); });
		FCC.$('#fcc-reset').addEventListener('click', resetConfig);
		var agentPicker = FCC.$('#fcc-runtime-agent');

		/* Scoped to the local panel: the LAN panel has its own buttons with
		 * their own handler, and an unscoped [data-op] query would bind the
		 * local operation to a remote click the day the two toolbars share a
		 * data attribute by accident. */
		Array.prototype.forEach.call(
			document.querySelectorAll('#fcc-local-controls [data-op]'),
			function (b) {
				b.addEventListener('click', function () { serverOp(b.getAttribute('data-op')); });
			}
		);

		Array.prototype.forEach.call(
			document.querySelectorAll('.fcc-mode-btn'),
			function (b) {
				b.addEventListener('click', function () {
					setRemoteMode(b.getAttribute('data-mode'));
				});
			}
		);

		Array.prototype.forEach.call(
			document.querySelectorAll('[data-remote-op]'),
			function (b) {
				b.addEventListener('click', function () {
					remoteControl(b.getAttribute('data-remote-op'));
				});
			}
		);

		FCC.$('#fcc-remote-test').addEventListener('click', remoteTest);
		FCC.$('#fcc-remote-keygen').addEventListener('click', remoteKeygen);
		FCC.$('#fcc-remote-showkey').addEventListener('click', function () {
			var panel = FCC.$('#fcc-remote-key-panel');
			if (!panel) { return; }
			panel.hidden = !panel.hidden;
			if (!panel.hidden) {
				var text = FCC.$('#fcc-remote-pubkey');
				if (text) { text.textContent = remote.public_key; }
			}
		});
		FCC.$('#fcc-remote-helper').addEventListener('click', function () {
			var panel = FCC.$('#fcc-remote-helper-panel');
			showRemoteHelper(!panel || panel.hidden);
		});
		FCC.$('#fcc-remote-trust').addEventListener('click', remoteTrust);
		FCC.$('#fcc-remote-trust-cancel').addEventListener('click', hideTrustPanel);
		FCC.$('#fcc-remote-forget').addEventListener('click', remoteForget);

		/* Every remote field is saved when it changes rather than behind a Save
		 * button: the panel is one switch away from a control that acts on a
		 * machine, and a half-edited address that looks applied is the sort of
		 * thing that sends a stop to the wrong host. The preview follows the
		 * service and platform as they are typed, before the save. */
		['#fcc-remote-host', '#fcc-remote-user', '#fcc-remote-ssh-port',
			'#fcc-remote-admin-port', '#fcc-remote-service',
			'#fcc-remote-platform'].forEach(function (sel) {
			var field = FCC.$(sel);
			if (!field) { return; }
			field.addEventListener('change', function () {
				previewCommands();
				saveRemoteConfig();
			});
			if (sel === '#fcc-remote-service' || sel === '#fcc-remote-platform') {
				field.addEventListener('input', previewCommands);
			}
		});

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
				FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
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

		loadConfig().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		});
		refreshAll().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail', err.message);
		}).then(function () {
			/* That first answer is the first paint; from here on the panel is
			 * kept current. Started after it, so the first interval cannot
			 * overlap the call that drew the page. */
			startStatusPoll();
		});
		/* A second, independent call: the local status does not carry the mode
		 * or anything about the remote host, and the LAN panel still has to be
		 * drawn — disabled — on a device where nothing remote is configured. */
		loadRemote().catch(function (err) {
			FCC.notice(FCC.$('#fcc-config-status'), 'fail',
				remoteCaught(err, FCC._('The LAN connection state could not be read.')));
		});
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
