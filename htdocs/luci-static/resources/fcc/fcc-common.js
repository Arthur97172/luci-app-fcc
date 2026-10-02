/*
 * luci-app-fcc — shared browser helpers.
 *
 * Loaded by all three pages. Exposes window.FCC: a small API client plus the
 * formatting and DOM helpers the pages share. No framework, no build step
 * (DESIGN_SPEC.md s.87).
 */
(function () {
	'use strict';

	/* ------------------------------------------------------------- API client */

	/**
	 * Call a JSON API action.
	 *
	 * @param {string} action  leaf name under .../fcc/api/
	 * @param {object} params  query/body parameters
	 * @param {object} [opts]  { method: 'GET'|'POST', timeout: ms }
	 * @returns {Promise<object>} resolves with the parsed body; rejects with an
	 *          Error carrying .status and .body on failure.
	 */
	function api(action, params, opts) {
		opts = opts || {};
		var method = (opts.method || 'POST').toUpperCase();
		var url = (window.FCC_API || '') + action;
		var init = {
			method: method,
			credentials: 'same-origin',
			headers: { 'Accept': 'application/json' }
		};

		var qs = new URLSearchParams();
		Object.keys(params || {}).forEach(function (k) {
			var v = params[k];
			if (v !== undefined && v !== null) { qs.append(k, String(v)); }
		});

		if (method === 'GET') {
			var s = qs.toString();
			if (s) { url += (url.indexOf('?') === -1 ? '?' : '&') + s; }
		} else {
			init.headers['Content-Type'] = 'application/x-www-form-urlencoded';
			init.body = qs.toString();
		}

		if (opts.signal) { init.signal = opts.signal; }

		return fetch(url, init).then(function (resp) {
			return resp.text().then(function (text) {
				var data = null;
				try { data = JSON.parse(text); } catch (e) { data = null; }
				if (!resp.ok) {
					var msg = (data && data.error) ? data.error : ('HTTP ' + resp.status);
					var err = new Error(msg);
					err.status = resp.status;
					err.body = data;
					throw err;
				}
				if (data === null) {
					var perr = new Error('Malformed response from the router');
					perr.status = resp.status;
					throw perr;
				}
				return data;
			});
		});
	}

	/* ------------------------------------------------------------ formatting */

	function fmtBytes(n) {
		if (n === null || n === undefined || isNaN(n)) { return '—'; }
		var units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
		var i = 0;
		n = Number(n);
		while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
		return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + ' ' + units[i];
	}

	function fmtKB(kb) {
		if (kb === null || kb === undefined || isNaN(kb)) { return '—'; }
		return fmtBytes(Number(kb) * 1024);
	}

	/** Seconds -> "3d 4h", "2h 5m", "12m 30s", "9s". */
	function fmtDuration(sec) {
		if (sec === null || sec === undefined || isNaN(sec)) { return '—'; }
		sec = Math.max(0, Math.floor(Number(sec)));
		var d = Math.floor(sec / 86400),
			h = Math.floor((sec % 86400) / 3600),
			m = Math.floor((sec % 3600) / 60),
			s = sec % 60;
		if (d > 0) { return d + 'd ' + h + 'h'; }
		if (h > 0) { return h + 'h ' + m + 'm'; }
		if (m > 0) { return m + 'm ' + s + 's'; }
		return s + 's';
	}

	function fmtPercent(part, total) {
		if (!total) { return '0%'; }
		return Math.round((part / total) * 100) + '%';
	}

	function esc(s) {
		return String(s === null || s === undefined ? '' : s)
			.replace(/&/g, '&amp;').replace(/</g, '&lt;')
			.replace(/>/g, '&gt;').replace(/"/g, '&quot;');
	}

	/* ------------------------------------------------------------------- DOM */

	function el(tag, attrs, children) {
		var node = document.createElement(tag);
		Object.keys(attrs || {}).forEach(function (k) {
			if (k === 'class') { node.className = attrs[k]; }
			else if (k === 'text') { node.textContent = attrs[k]; }
			else if (k === 'html') { node.innerHTML = attrs[k]; }
			else if (k.slice(0, 2) === 'on') { node.addEventListener(k.slice(2), attrs[k]); }
			else { node.setAttribute(k, attrs[k]); }
		});
		(children || []).forEach(function (c) {
			if (c === null || c === undefined) { return; }
			node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
		});
		return node;
	}

	function $(sel, root) { return (root || document).querySelector(sel); }

	/* ---------------------------------------------------------------- notices */

	/**
	 * Inline status line. LuCI's own notification API differs between releases,
	 * so this keeps a page-local element rather than depending on it.
	 */
	function notice(container, kind, message) {
		if (!container) { return; }
		container.innerHTML = '';
		if (!message) { return; }
		container.appendChild(el('div', {
			class: 'fcc-note ' + (kind || ''),
			text: message
		}));
	}

	/** Base64 -> Uint8Array, for feeding xterm.js arbitrary bytes. */
	function b64ToBytes(b64) {
		if (!b64) { return new Uint8Array(0); }
		var bin = atob(b64);
		var out = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) { out[i] = bin.charCodeAt(i); }
		return out;
	}

	/** String -> base64 of its UTF-8 bytes. */
	function strToB64(str) {
		var bytes = new TextEncoder().encode(str);
		var bin = '';
		for (var i = 0; i < bytes.length; i++) { bin += String.fromCharCode(bytes[i]); }
		return btoa(bin);
	}

	/**
	 * Translation. LuCI's client-side catalogue is not available to a plain
	 * script on every release, so this uses the page's own translator when it
	 * exists and otherwise returns the English source string unchanged — the
	 * strings are written to be readable either way.
	 */
	function tr(s) {
		if (typeof window._ === 'function') {
			try { return window._(s); } catch (e) { /* fall through */ }
		}
		return s;
	}

	window.FCC = {
		_: tr,
		api: api,
		fmtBytes: fmtBytes,
		fmtKB: fmtKB,
		fmtDuration: fmtDuration,
		fmtPercent: fmtPercent,
		esc: esc,
		el: el,
		$: $,
		notice: notice,
		b64ToBytes: b64ToBytes,
		strToB64: strToB64
	};
})();
