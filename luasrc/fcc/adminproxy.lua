-- luci-app-fcc — the LuCI reverse proxy that serves the FCC Admin UI.
--
-- Why this exists
-- ---------------
-- The FCC Admin UI is served by the FCC server on its own port (UCI
-- fcc.main.port, default 8082). Upstream refuses every admin route to a caller
-- that is not on the local machine: free_claude_code/api/admin_security.py's
-- require_loopback_admin() answers
--
--   403 {"detail":"Admin UI is local-only"}
--
-- unless
--
--   * the TCP peer address is a loopback address, and
--   * the Host header is a loopback authority, and
--   * the Origin header is absent, or is a loopback origin.
--
-- A browser on another machine fails the first check whatever the server is
-- bound to, so "set the bind address to this router's LAN address" — which the
-- Configuration page used to suggest — cannot work, and produced that bare 403
-- instead. DESIGN_SPEC.md section 13 names the LuCI reverse proxy as the answer
-- for exactly this case, and this module is it: the request reaches the FCC
-- server from the router itself, so all three checks pass, and the browser
-- never talks to the FCC port at all.
--
-- Access control is LuCI's. The route is registered inside the admin tree, so
-- only an authenticated LuCI session can reach it — a stronger gate than the
-- loopback check it stands in for, and the reason this is not simply a second
-- listener on a LAN port, which would publish the unauthenticated FCC admin
-- API to the whole LAN.
--
-- What it has to repair
-- ---------------------
-- The SPA is written for a server whose root is /admin: every URL it builds is
-- absolute and begins there, and it decides which view it is on by reading
-- window.location.pathname. Served from a LuCI path, the first would be asked
-- of the router and the second would report "luci" as the view.
--
-- The repair is deliberately split in two, because the two halves need
-- different treatment:
--
--   * In HTML, /admin/ URLs are rewritten to this proxy's own base. They are
--     parsed by the browser before any script of ours runs, so there is nowhere
--     else to do it. This is the <link> and <script src> set, and nothing else.
--
--   * In JavaScript, the SPA keeps its own convention untouched — every
--     literal stays "/admin/...". Instead the page is given a small shim, ahead
--     of the first asset, that translates at the browser boundary: fetch,
--     EventSource, history.pushState and history.replaceState have a leading
--     /admin mapped to the base, and window.location.pathname is read back
--     through __fccPath(), which maps the base back to /admin.
--
-- Rewriting the JavaScript's URL literals instead would have been shorter and
-- would have broken the page: the code-sessions module matches the current path
-- against /^\/admin\/code\/([0-9a-f-]+)$/ and compares it with the literals it
-- pushed, so half the file would have been in one convention and half in the
-- other. Translating at the boundary keeps one convention everywhere.
--
-- JSON is not rewritten at all: an API response may carry "/admin" as data, and
-- mangling it would corrupt the configuration being edited. The one JSON field
-- that does need it — admin_url, an absolute loopback URL the SPA navigates to
-- after a restart — is rewritten on its own, by name.
--
-- One thing cannot be relayed as written: the event feed behind the Code
-- Sessions view is a stream that never ends, and LuCI writes a controller's
-- whole response only after the action returns. The feed is relayed one event
-- at a time instead, and the shim hides the reconnection that follows. serve()
-- explains it, and section 104.24 records why the alternative is not available.

module("luci.fcc.adminproxy", package.seeall)

local http       = require "luci.http"
local httpclient = require "luci.httpclient"
local ltn12      = require "luci.ltn12"
local paths      = require "luci.fcc.paths"

--- The path this proxy is mounted at, as it appears after SCRIPT_NAME. It is a
--  constant because the controller registers the same route.
ROUTE = "/admin/services/fcc/adminproxy"

--- The FCC server's own root. Every URL the SPA uses begins here.
FCC_ROOT = "/admin"

DEFAULT_PORT = 8082

--- The largest request body the proxy will forward.
--
-- A router has little memory to spare and nothing the admin UI posts is large:
-- the biggest body it sends is a configuration document of a few kilobytes.
-- Refusing an outsized body outright is better than buffering it and finding
-- out afterwards.
MAX_REQUEST_BYTES = 1048576

--- How long to wait on the FCC server.
--
-- Sixty seconds rather than the handful a local request needs, because the
-- event stream behind the Code Sessions view is idle between updates, and a
-- read that times out ends it.
UPSTREAM_TIMEOUT = 60

local function env(name)
	return http.getenv(name) or ""
end

-- ---------------------------------------------------------------------------
-- Where the request came from, and where the FCC server is
-- ---------------------------------------------------------------------------

--- The path the browser asked for, without the query string.
--
-- REQUEST_URI is the real one and is what uhttpd sets. The CGI pair is the
-- fallback for a server that does not set it; there, SCRIPT_NAME is the mount
-- point of LuCI itself and PATH_INFO the rest of the path, so the two together
-- are the same string.
local function browser_path()
	local uri = env("REQUEST_URI")
	if uri ~= "" then
		local q = uri:find("?", 1, true)
		return q and uri:sub(1, q - 1) or uri
	end
	return env("SCRIPT_NAME") .. env("PATH_INFO")
end

--- Split the request path into the proxy's public base and the FCC-side path.
--
-- The base is located in the request path rather than assumed, so the proxy
-- works wherever LuCI is mounted. It is also what every rewritten URL is built
-- from, which is why it has to be the browser's spelling and not LuCI's.
--
-- @return base  the browser-facing prefix, e.g. /cgi-bin/luci/admin/services/fcc/adminproxy
-- @return rest  "" or "/..." — the path below the proxy root
function split_request()
	local full = browser_path()
	local i = full:find(ROUTE, 1, true)
	if i then
		local base = full:sub(1, i + #ROUTE - 1)
		local rest = full:sub(i + #ROUTE)
		-- A trailing slash would otherwise become /admin/ upstream, which
		-- FastAPI answers with a redirect back to /admin. Save the round trip.
		if rest == "/" then rest = "" end
		return base, rest
	end
	return env("SCRIPT_NAME") .. ROUTE, ""
end

--- The FCC server's port, from UCI.
function port()
	local c = paths.uci_cursor()
	local p = c and tonumber(c:get("fcc", "main", "port"))
	if not p or p < 1 or p > 65535 then return DEFAULT_PORT end
	return p
end

--- The upstream this proxy talks to.
--
-- Always loopback, and that is the whole point: it is what makes the forwarded
-- request satisfy the first of the three checks above. It also means the server
-- has to be listening on loopback, which is why a bind to one LAN address is
-- treated as loopback by the init script (section 104.23) — such a server is
-- one this proxy cannot reach.
function upstream()
	return "http://127.0.0.1:" .. port()
end

-- ---------------------------------------------------------------------------
-- Rewriting
-- ---------------------------------------------------------------------------

--- Rewrite the /admin/ URLs in an HTML document to this proxy's base.
--
-- Only HTML gets this. The URLs it carries — stylesheet and script sources, the
-- icon — are fetched by the browser from the markup itself, before any script
-- runs, so the boundary shim below cannot reach them.
--
-- The replacement is produced by a function rather than a string because the
-- base is a path and may contain characters Lua's replacement syntax treats
-- specially.
local function rewrite_html_urls(body, base)
	return (body:gsub("(/)admin(/[^\"']*)", function(_, rest)
		return base .. rest
	end))
end

--- Send every read of window.location.pathname through the injected helper.
--
-- The SPA reads it to decide which view it is on, to hand the path to the
-- code-sessions module, and to compare against the path it just pushed. All
-- three want the FCC-side path, and all three are otherwise untouched.
local function rewrite_pathname(body)
	return (body:gsub("window%.location%.pathname", "window.__fccPath()"))
end

--- Rewrite the one JSON field the browser navigates to.
--
-- After "Save & apply" the FCC server answers with an absolute admin_url built
-- from its own bind address (free_claude_code/config/server_urls.py), and the
-- SPA navigates to it. Left alone, that URL sends the browser to 127.0.0.1 —
-- which on the browser's machine is the browser's own machine. Only the value
-- of that one field is touched; every other byte is passed through.
local function rewrite_admin_url(body, base)
	return (body:gsub('("admin_url"%s*:%s*")([^"]*)(")', function(head, value, tail)
		-- The authority is taken whole and then compared, rather than written
		-- as one pattern: Lua 5.1 patterns have no alternation, so
		-- "(127%.0%.0%.1|localhost)" would be a search for that literal text
		-- and would quietly never match.
		local authority = value:match("^https?://([^/]+)/admin$")
		if authority then
			authority = authority:gsub(":%d+$", "")
			if authority == "127.0.0.1" or authority == "localhost"
				or authority == "[::1]" then
				return head .. base .. tail
			end
		end
		return head .. value .. tail
	end))
end

--- How long the shim waits before reopening the event feed, in milliseconds.
--
-- This is the refresh interval of the Code Sessions view, and the reason it is
-- not the sub-second push the SPA was written for is in serve(), below.
local EVENT_RECONNECT_MS = 2000

--- The boundary shim, injected ahead of the first asset.
--
-- __FCC_BASE__ and __FCC_POLL__ are substituted, and the substitution happens
-- after the HTML rewrite so that the "/admin" literals here are not themselves
-- rewritten.
--
-- Every URL patch maps a leading /admin to the base and passes anything else
-- through, so applying one twice is harmless: the base does not itself begin
-- with /admin unless LuCI is mounted there, which it is not.
--
-- EventSource is wrapped rather than merely redirected, for a reason that has
-- nothing to do with URLs. The event feed cannot be streamed through LuCI (see
-- serve()), so the proxy answers with one event and closes. A native
-- EventSource reports that close as an error, and the SPA's error handler tears
-- the feed down and shows "Reconnecting…" — twice a second, for as long as the
-- view is open. The wrapper reopens quietly instead, and only reports an error
-- when a connection comes back with nothing at all, which is what a stopped
-- server actually looks like. The SPA then sees one feed that never drops, and
-- the retry screen it already has still appears when it should.
local SHIM = [==[<script>
/* luci-app-fcc — the Admin UI is served under a LuCI path, so its absolute
   /admin URLs and its window.location.pathname reads are translated here, at
   the browser boundary, and nowhere else. */
(function () {
  var base = "__FCC_BASE__";
  var poll = __FCC_POLL__;
  function url(u) {
    return typeof u === "string" && u.slice(0, 6) === "/admin" ? base + u.slice(6) : u;
  }
  window.__fccPath = function () {
    var p = window.location.pathname;
    return p.indexOf(base) === 0 ? "/admin" + p.slice(base.length) : p;
  };
  var nativeFetch = window.fetch;
  if (nativeFetch) {
    window.fetch = function (input, init) {
      return nativeFetch.call(this, url(input), init);
    };
  }
  function patch(name) {
    var native = window.history[name];
    if (!native) return;
    window.history[name] = function (state, title, u) {
      return native.call(window.history, state, title,
        u === undefined || u === null ? u : url(u));
    };
  }
  patch("pushState");
  patch("replaceState");

  var Native = window.EventSource;
  if (!Native) return;

  function Feed(u) {
    var self = this;
    var listeners = {};
    var real = null;
    var closed = false;
    var misses = 0;

    this.url = u;
    this.readyState = 0;
    this.withCredentials = false;
    this.onerror = null;
    this.onopen = null;
    this.onmessage = null;

    function emit(type, event) {
      var group = listeners[type];
      if (group) for (var i = 0; i < group.length; i++) group[i].call(self, event);
      if (type === "error" && self.onerror) self.onerror.call(self, event);
      if (type === "open" && self.onopen) self.onopen.call(self, event);
      if (type === "message" && self.onmessage) self.onmessage.call(self, event);
    }

    // Every event type is forwarded, and the set is learned from the page's own
    // addEventListener calls rather than listed here, so an event the SPA adds
    // later needs no change in this file.
    function forward(src, type) {
      src.addEventListener(type, function (event) {
        if (real === src) emit(type, event);
      });
    }

    function open() {
      if (closed) return;
      var src = new Native(u);
      var answered = false;
      real = src;
      self.readyState = 0;
      for (var type in listeners) forward(src, type);
      // feed.ready is the one event watched here on its own account: it is the
      // proof that the server answered, and so what separates a feed the proxy
      // closed on purpose from a server that is not there.
      src.addEventListener("feed.ready", function () {
        answered = true;
        misses = 0;
        self.readyState = 1;
      });
      src.onerror = function () {
        if (closed || real !== src) return;
        src.close();
        real = null;
        self.readyState = 0;
        if (answered) return void setTimeout(open, poll);
        if (++misses >= 3) return void emit("error", { type: "error" });
        setTimeout(open, poll);
      };
    }

    this.addEventListener = function (type, fn) {
      if (!listeners[type]) {
        listeners[type] = [];
        if (real) forward(real, type);
      }
      listeners[type].push(fn);
    };
    this.removeEventListener = function (type, fn) {
      var group = listeners[type];
      if (!group) return;
      var at = group.indexOf(fn);
      if (at >= 0) group.splice(at, 1);
    };
    this.close = function () {
      closed = true;
      self.readyState = 2;
      if (real) { real.close(); real = null; }
    };

    open();
  }
  Feed.prototype = Native.prototype;
  Feed.CONNECTING = 0;
  Feed.OPEN = 1;
  Feed.CLOSED = 2;
  window.EventSource = Feed;
})();
</script>
]==]

local function inject_shim(body, base)
	local shim = SHIM
		:gsub("__FCC_BASE__", function() return base end)
		:gsub("__FCC_POLL__", function() return tostring(EVENT_RECONNECT_MS) end)
	local lower = body:lower()
	local i = lower:find("<script", 1, true)
	if i then
		return body:sub(1, i - 1) .. shim .. "\n" .. body:sub(i)
	end
	local h = lower:find("</head>", 1, true)
	if h then
		return body:sub(1, h - 1) .. shim .. "\n" .. body:sub(h)
	end
	return shim .. body
end

-- ---------------------------------------------------------------------------
-- Forwarding
-- ---------------------------------------------------------------------------

-- Headers that belong to one hop and must not be relayed. Content-Length is in
-- this list because the body may have been rewritten, and Content-Encoding
-- because the upstream was asked for an identity encoding, so a coding header
-- would be a lie.
local DROP_HEADERS = {
	["connection"] = true, ["keep-alive"] = true, ["content-length"] = true,
	["content-encoding"] = true, ["transfer-encoding"] = true,
	["proxy-authenticate"] = true, ["proxy-authorization"] = true,
	["te"] = true, ["trailer"] = true, ["upgrade"] = true,
}

--- A source for the upstream response body, one chunk at a time.
--
-- The request asks the upstream to close the connection when it is done, so a
-- response with no chunked framing ends when the socket does.
local function body_source(response, buffer, sock)
	if response.headers["Transfer-Encoding"] == "chunked" then
		return httpclient.chunksource(sock, buffer)
	end
	return ltn12.source.cat(ltn12.source.string(buffer), sock:blocksource())
end

--- An HTML page for the case where there is no answer to relay.
--
-- Plain English and no catalogue lookup: it is generated here rather than
-- rendered from a template, and the strings the translation machinery knows
-- about are the ones the templates and the controller ask for. The rest of the
-- API answers in the same shape, so a page that reads it is not a new idea.
local function gateway_error(detail)
	http.status(502, "Bad Gateway")
	http.header("Content-Type", "text/html; charset=utf-8")
	http.write([[
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>FCC Admin unavailable</title>
<style>body{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:44rem}
code{background:#f2f2f2;padding:.1rem .3rem;border-radius:3px}</style></head>
<body><h1>FCC Admin is not reachable</h1>
<p>LuCI could not reach the FCC server on <code>]] .. upstream() .. [[</code>.</p>
<p>]] .. detail .. [[</p>
<p>Start it from the <strong>Configuration</strong> page, or check
<strong>Basic Information</strong> for the server state and its log.</p>
</body></html>
]])
end

--- Forward one request and relay the answer.
function serve()
	local base, rest = split_request()

	local method = env("REQUEST_METHOD")
	if method == "" then method = "GET" end

	local body = nil
	if method == "POST" or method == "PUT" or method == "PATCH" then
		body = http.content() or ""
		if #body > MAX_REQUEST_BYTES then
			http.status(413, "Payload Too Large")
			http.header("Content-Type", "text/plain; charset=utf-8")
			http.write("request body too large for the FCC Admin proxy\n")
			return
		end
	end

	local uri = upstream() .. FCC_ROOT .. rest
	local query = env("QUERY_STRING")
	if query ~= "" then uri = uri .. "?" .. query end

	-- The headers the upstream checks are handled deliberately here.
	--
	-- Host is *set* to the upstream authority rather than forwarded: a LuCI
	-- hostname is not a loopback authority, so forwarding it would fail
	-- _authority_is_local. Origin and Referer are dropped rather than rewritten,
	-- because upstream treats an absent Origin as local — that is one fewer
	-- thing to get right, and it means the browser's real origin travels no
	-- further than this function.
	--
	-- Accept-Encoding is forced to identity so the body can be rewritten without
	-- first undoing a content coding. Connection: close is what tells the
	-- upstream to end a response that carries no length of its own.
	local headers = {
		Host = "127.0.0.1:" .. port(),
		["Accept-Encoding"] = "identity",
		Connection = "close",
	}
	local ctype = env("CONTENT_TYPE")
	if ctype ~= "" then headers["Content-Type"] = ctype end
	local accept = env("HTTP_ACCEPT")
	if accept ~= "" then headers["Accept"] = accept end

	local options = {
		method   = method,
		headers  = headers,
		-- Relay a redirect instead of chasing it: the Location header is
		-- rewritten below, and the browser has to see it for that to matter.
		depth    = 0,
		protocol = "HTTP/1.1",
		rcvtimeo = UPSTREAM_TIMEOUT,
		sndtimeo = UPSTREAM_TIMEOUT,
	}
	if body then options.body = body end

	local code, response, buffer, sock = httpclient.request_raw(uri, options)
	if not code then
		return gateway_error("The connection failed: " ..
			tostring(buffer or response or "unknown error") .. ".")
	end

	local mime = response.headers["Content-Type"]
	if type(mime) ~= "string" or mime == "" then
		mime = "application/octet-stream"
	end
	local lower = mime:lower()

	-- A redirect that points at the upstream has to point at the proxy instead,
	-- or the browser follows it to the router's own /admin.
	local location = response.headers["Location"]
	if type(location) == "string" and location:sub(1, 1) == "/" then
		if location == FCC_ROOT or location:sub(1, #FCC_ROOT + 1) == FCC_ROOT .. "/" then
			response.headers["Location"] = base .. location:sub(#FCC_ROOT + 1)
		end
	end

	local reason = response.status and response.status:match("^[%w./]+ %d+ (.*)$")
	http.status(code, reason)
	for key, value in pairs(response.headers) do
		-- A repeated header arrives as a table. Relaying one of those would
		-- need LuCI to emit it more than once, which its response API does not
		-- offer, and nothing the admin UI serves sends one.
		if type(value) == "string" and not DROP_HEADERS[key:lower()] then
			http.header(key, value)
		end
	end
	http.header("Content-Type", mime)

	local source = body_source(response, buffer, sock)
	local function finish()
		if sock then pcall(function() sock:close() end) end
	end

	-- A body is only written when there is meant to be one.
	if method == "HEAD" or code == 204 or code == 304 then
		finish()
		return
	end

	-- The event feed behind the Code Sessions view, relayed one event at a time.
	--
	-- It cannot be streamed, and the reason is not in this file: LuCI's
	-- dispatcher collects a controller action's whole response and writes it
	-- only once the action has returned (ucode/dispatcher.uc's render_action
	-- does `const data = render(fn); http.write_headers(); http.output(data)`).
	-- A relay that waited for this stream to end would therefore wait forever
	-- and answer nothing at all.
	--
	-- So the first event is relayed and the connection is closed. That event is
	-- always feed.ready — the server sends it before it starts streaming — and
	-- it carries the full session snapshot, so the SPA learns everything it
	-- needs from it. The EventSource wrapper in the shim reopens the feed, and
	-- the next feed.ready refreshes the view. What is lost is the sub-second
	-- granularity of a real push feed; what is kept is a view that stays
	-- current without the page ever flickering. Section 104.24.
	if lower:find("text/event-stream", 1, true) then
		local out = {}
		local stop = nil
		while true do
			local chunk = source()
			if not chunk then break end
			out[#out + 1] = chunk
			-- An event ends at a blank line. The payload's own newlines are
			-- sent as further data: lines, so a blank line only ever means the
			-- event is complete.
			stop = table.concat(out):find("\n\n", 1, true)
			if stop then break end
		end
		-- Only up to the end of that first event, not the whole read it arrived
		-- in. The two are usually the same — feed.ready is sent before the
		-- server starts watching for changes, so the read that carries it
		-- normally carries nothing else — but "usually" is not a reason to
		-- write a second event's worth of bytes after closing the connection
		-- that was meant to deliver it. An unterminated event is written as
		-- nothing: EventSource does not dispatch a frame that has no blank line
		-- after it, so sending the partial one would be a lie about what
		-- arrived. The shim's miss counter is what reports a server that
		-- answers and then dies mid-event.
		if stop then
			http.write(table.concat(out):sub(1, stop + 1))
		end
		finish()
		return
	end

	local out = {}
	while true do
		local chunk = source()
		if not chunk then break end
		out[#out + 1] = chunk
	end
	finish()
	out = table.concat(out)

	if lower:find("text/html", 1, true) then
		out = inject_shim(rewrite_html_urls(out, base), base)
	elseif lower:find("javascript", 1, true) then
		out = rewrite_pathname(out)
	elseif lower:find("json", 1, true) then
		out = rewrite_admin_url(out, base)
	end

	http.write(out)
end
