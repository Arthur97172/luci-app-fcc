-- luci-app-fcc — exercises luasrc/fcc/adminproxy.lua outside LuCI.
--
-- The proxy is the answer to "Open FCC Admin shows
-- {"detail":"Admin UI is local-only"}" (DESIGN_SPEC.md sections 13 and 104.22),
-- and the part of it that matters is not greppable: whether the forwarded
-- request carries a loopback peer, a loopback Host and no Origin is decided by
-- what serve() hands to the HTTP client. So this driver runs serve() against a
-- stubbed LuCI and a canned upstream, and reads back exactly what was sent and
-- what was written to the browser.
--
-- The stubs are the smallest that let the real code path run:
--
--   luci.http        getenv from a table this file sets, and write/status/header
--                    recorded rather than emitted
--   luci.httpclient  request_raw, answering with a response this file chose and
--                    recording the uri and options it was asked for
--   luci.ltn12       source.string and source.cat, which is what body_source
--                    builds a response body out of
--
-- Same contract as lua_driver.lua: one `ok <name>` / `fail <name>|<detail>` line
-- per check, always exit 0, so tests/test_proxy.sh reports through the shared
-- harness.

local ROOT = assert(os.getenv("FCC_TEST_ROOT"), "FCC_TEST_ROOT is not set")

-- ---------------------------------------------------------------------------
-- Module resolution — the same mapping tests/lua_driver.lua uses
-- ---------------------------------------------------------------------------
table.insert(package.loaders, 1, function(name)
	local short = name:match("^luci%.fcc%.([a-z_]+)$")
	if not short then return nil end
	local path = ROOT .. "/luasrc/fcc/" .. short .. ".lua"
	local fh = io.open(path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return assert(loadstring(src, "@" .. path))
end)

-- ---------------------------------------------------------------------------
-- nixio.fs — reached through luci.fcc.paths, which the proxy requires for the
-- UCI cursor and the port. Only existence is asked of it here.
-- ---------------------------------------------------------------------------
package.preload["nixio.fs"] = function()
	return {
		access = function(p)
			local fh = io.open(p, "r")
			if fh then fh:close() return true end
			return nil
		end,
		stat = function() return nil end,
	}
end

-- ---------------------------------------------------------------------------
-- luci.model.uci — the three values the proxy reads
--
-- port(), target() and remote_admin_port() all go through
-- luci.fcc.paths.uci_cursor(). A table-backed cursor lets a check switch the
-- control target the same way the Configuration page does, without a UCI
-- database on the test machine.
-- ---------------------------------------------------------------------------
local UCI = {
	port = "8082",
	control_target = "local",
	remote_admin_port = "8082",
	remote_host = "",
	remote_user = "",
}

package.preload["luci.model.uci"] = function()
	return {
		cursor = function()
			return {
				get = function(_, config, section, option)
					if config ~= "fcc" or section ~= "main" then return nil end
					return UCI[option]
				end,
			}
		end,
	}
end

-- ---------------------------------------------------------------------------
-- luci.http
-- ---------------------------------------------------------------------------
local ENV = {}
local OUT = {}
local STATUS = nil
local HEADERS = {}
local BODY = ""

package.preload["luci.http"] = function()
	return {
		getenv = function(name) return ENV[name] end,
		content = function() return BODY end,
		write = function(s) OUT[#OUT + 1] = s end,
		status = function(code, reason) STATUS = { code = code, reason = reason } end,
		header = function(k, v) HEADERS[k] = v end,
		prepare_content = function(t) HEADERS["Content-Type"] = t end,
	}
end

-- ---------------------------------------------------------------------------
-- luci.ltn12 — just the two constructors body_source() uses
-- ---------------------------------------------------------------------------
package.preload["luci.ltn12"] = function()
	local source = {}

	source.string = function(s)
		local done = false
		return function()
			if done then return nil end
			done = true
			return s
		end
	end

	source.cat = function(a, b)
		local current = a
		return function()
			while current do
				local chunk = current()
				if chunk ~= nil then return chunk end
				current = (current == a) and b or nil
			end
			return nil
		end
	end

	return { source = source }
end

-- ---------------------------------------------------------------------------
-- luci.httpclient
-- ---------------------------------------------------------------------------
-- What the next request_raw call will answer with, and what the last one was
-- asked for.
local ANSWER = nil
local SENT = nil
local CHUNKED = false

package.preload["luci.httpclient"] = function()
	return {
		request_raw = function(uri, options)
			SENT = { uri = uri, options = options }
			if not ANSWER then
				return nil, nil, "connection refused", nil
			end
			local chunks = ANSWER.chunks or {}
			local i = 0
			local sock = {
				blocksource = function()
					return function()
						i = i + 1
						return chunks[i]
					end
				end,
				close = function() end,
			}
			return ANSWER.code or 200, {
				status  = ANSWER.status or "HTTP/1.1 200 OK",
				headers = ANSWER.headers or {},
			}, ANSWER.buffer or "", sock
		end,
		chunksource = function(sock, buffer)
			-- Recorded rather than decoded: whether body_source() chose this is
			-- what the case-insensitive Transfer-Encoding read decides, and the
			-- decode itself is luci.httpclient's. Returning the buffer is the
			-- honest reduction rather than a fake dechunking.
			CHUNKED = true
			return require("luci.ltn12").source.cat(
				require("luci.ltn12").source.string(buffer or ""), sock.blocksource())
		end,
	}
end

local proxy = require "luci.fcc.adminproxy"

-- ---------------------------------------------------------------------------
-- Tiny assertion harness — same shape as lua_driver.lua
-- ---------------------------------------------------------------------------
local passed, failed = 0, 0

local function check(name, cond, detail)
	if cond then
		passed = passed + 1
		print("ok " .. name)
	else
		failed = failed + 1
		print("fail " .. name .. "|" .. tostring(detail or "assertion failed"))
	end
end

local function eq(name, got, want)
	check(name, got == want, "want [" .. tostring(want) .. "], got [" .. tostring(got) .. "]")
end

local function contains(name, haystack, needle)
	local ok = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
	check(name, ok, "[" .. tostring(haystack) .. "] does not contain [" .. needle .. "]")
end

local function absent(name, haystack, needle)
	local bad = type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
	check(name, not bad, "[" .. tostring(haystack) .. "] unexpectedly contains [" .. needle .. "]")
end

--- Put the environment back to a plain GET of the proxy root.
local function reset(env)
	ENV = {}
	OUT = {}
	STATUS = nil
	HEADERS = {}
	BODY = ""
	ANSWER = nil
	SENT = nil
	CHUNKED = false
	for k, v in pairs(env or {}) do ENV[k] = v end
	if not ENV.REQUEST_METHOD then ENV.REQUEST_METHOD = "GET" end
	if not ENV.REQUEST_URI then
		ENV.REQUEST_URI = "/cgi-bin/luci/admin/services/fcc/adminproxy"
	end
end

local function written() return table.concat(OUT) end

local function serve_ok(env, answer)
	reset(env)
	ANSWER = answer
	proxy.serve()
	return SENT, written()
end

-- ---------------------------------------------------------------------------
-- Where the request goes
--
-- This is the whole fix for the "Admin UI is local-only" report: the forwarded
-- request must arrive from the router's own loopback, whatever the server is
-- bound to and whatever address the browser used. Anything else — the bind
-- address, the browser's Host — reproduces the 403 exactly.
-- ---------------------------------------------------------------------------

eq("upstream/is_loopback", proxy.upstream(), "http://127.0.0.1:8082")

local sent = serve_ok({}, { headers = { ["Content-Type"] = "text/html" }, chunks = { "<html></html>" } })
eq("serve/upstream_uri", sent.uri, "http://127.0.0.1:8082/admin")

-- The Host header is *set*, not forwarded. A LuCI hostname is not a loopback
-- authority, so forwarding the browser's would fail the second upstream check.
eq("serve/host_is_loopback_authority", sent.options.headers["Host"], "127.0.0.1:8082")

-- Origin and Referer are dropped. Upstream treats an absent Origin as local, so
-- dropping is both simpler than rewriting and strictly narrower: the browser's
-- real origin does not travel past the router.
reset({ HTTP_ORIGIN = "http://192.168.5.3", HTTP_REFERER = "http://192.168.5.3/cgi-bin/luci" })
ANSWER = { headers = { ["Content-Type"] = "text/html" }, chunks = { "<html></html>" } }
proxy.serve()
check("serve/origin_not_forwarded", SENT.options.headers["Origin"] == nil)
check("serve/referer_not_forwarded", SENT.options.headers["Referer"] == nil)

-- Identity encoding, because the body may be rewritten and undoing a content
-- coding first would be a second thing to get wrong.
eq("serve/identity_encoding", SENT.options.headers["Accept-Encoding"], "identity")

-- depth = 0: a redirect is relayed, not chased, because the Location header is
-- rewritten for the browser and only matters if the browser sees it.
eq("serve/does_not_follow_redirects", sent.options.depth, 0)

-- The browser's path is forwarded below the FCC root. The query string is read
-- from QUERY_STRING rather than from the request URI, because that is what the
-- CGI environment carries it in — a proxy that parsed it out of the URI would
-- work under uhttpd and break under anything else.
sent = serve_ok({
	REQUEST_URI = "/cgi-bin/luci/admin/services/fcc/adminproxy/code/abc?x=1",
	QUERY_STRING = "x=1",
}, { headers = { ["Content-Type"] = "text/html" }, chunks = { "x" } })
eq("serve/path_and_query", sent.uri, "http://127.0.0.1:8082/admin/code/abc?x=1")

-- And an empty QUERY_STRING adds nothing: a trailing "?" is not a URL the
-- upstream would match.
sent = serve_ok({ QUERY_STRING = "" },
	{ headers = { ["Content-Type"] = "text/html" }, chunks = { "x" } })
eq("serve/no_query_no_question_mark", sent.uri, "http://127.0.0.1:8082/admin")

-- A bare trailing slash is dropped: FastAPI answers /admin/ with a redirect
-- back to /admin, so forwarding it would cost a round trip for nothing.
sent = serve_ok({ REQUEST_URI = "/cgi-bin/luci/admin/services/fcc/adminproxy/" },
	{ headers = { ["Content-Type"] = "text/html" }, chunks = { "x" } })
eq("serve/trailing_slash_dropped", sent.uri, "http://127.0.0.1:8082/admin")

-- The proxy owns the /admin prefix: the browser spells everything below its
-- base, and serve() puts /admin back before forwarding. The console's link to
-- the Integrations page is the case that got this wrong — it wrote the server's
-- own /admin into the href as well, and the page answered
-- {"detail":"Not Found"} because what reached the FCC server was
-- /admin/admin/integrations. This pins the spelling the link has to use.
sent = serve_ok({ REQUEST_URI = "/cgi-bin/luci/admin/services/fcc/adminproxy/integrations" },
	{ headers = { ["Content-Type"] = "text/html" }, chunks = { "x" } })
eq("serve/page_below_the_base", sent.uri, "http://127.0.0.1:8082/admin/integrations")

-- The base is found in the request path rather than assumed, so the proxy works
-- wherever LuCI is mounted. A root-mounted LuCI is the case that would break a
-- hardcoded /cgi-bin/luci prefix.
sent = serve_ok({ REQUEST_URI = "/admin/services/fcc/adminproxy/admin/x.js" },
	{ headers = { ["Content-Type"] = "application/javascript" }, chunks = { "x" } })
eq("serve/root_mounted_luci", sent.uri, "http://127.0.0.1:8082/admin/admin/x.js")

-- ---------------------------------------------------------------------------
-- LAN mode: the same proxy, one hop further away
--
-- A remote FCC server refuses a non-loopback peer exactly as a local one does,
-- so LAN mode cannot point the proxy at 192.168.5.20:8082 either. remote.sh
-- opens an ssh -L 127.0.0.1:18082:127.0.0.1:<admin-port>, and the proxy talks to
-- the local end of it; the remote server then sees its own loopback.
-- ---------------------------------------------------------------------------

UCI.control_target = "lan"

eq("lan/upstream_is_the_tunnel", proxy.upstream(), "http://127.0.0.1:18082")

-- With no tunnel and no way to start one, the request is refused — and it is
-- refused *instead of* falling back to the local port. Serving the router's own
-- Admin UI under a page that says LAN would be worse than an error, because the
-- buttons would then act on the wrong machine.
reset({})
ANSWER = { headers = { ["Content-Type"] = "text/html" }, chunks = { "<html></html>" } }
proxy.serve()
eq("lan/no_tunnel_is_502", STATUS and STATUS.code, 502)
contains("lan/failure_names_the_tunnel", written(), "SSH tunnel")
absent("lan/failure_does_not_name_the_local_port", written(), "127.0.0.1:8082")
check("lan/no_fallback_to_the_local_server", SENT == nil)

-- A tunnel that is up can still carry nothing. The router's end accepts the
-- connection; the far end answers each channel-open request, and it is the
-- browser's first click that opens one. sshd there answers
-- "administratively prohibited" when forwarding is switched off entirely, and
-- that line — in ssh's log, nowhere else — is the difference between a user
-- changing one line of sshd configuration and a user restarting a server that
-- was never the problem.
local kept_log = proxy.TUNNEL_LOG

local function refusal_for(text)
	local path = os.tmpname()
	local fh = assert(io.open(path, "w"))
	fh:write(text)
	fh:close()
	proxy.TUNNEL_LOG = path
	local said = proxy.tunnel_refusal()
	os.remove(path)
	proxy.TUNNEL_LOG = kept_log
	return said
end

contains("refusal/forwarding_off_is_named",
	refusal_for("channel 1: open failed: administratively prohibited: open failed\n"),
	"refuses port forwarding")
contains("refusal/forwarding_off_points_at_the_setting",
	refusal_for("channel 1: open failed: administratively prohibited: open failed\n"),
	"AllowTcpForwarding")

-- The forward worked and the far side's loopback answered nothing: the server
-- there is not running, or is bound somewhere its own loopback is not.
contains("refusal/nothing_listening_is_named",
	refusal_for("channel 1: open failed: connect failed: Connection refused\n"),
	"nothing there answers on 127.0.0.1:8082")

-- Only the newest line is an answer to the request that just failed — the older
-- one is history from before the user fixed whatever it described.
contains("refusal/newest_line_wins",
	refusal_for("channel 1: open failed: connect failed: Connection refused\n" ..
		"channel 1: open failed: administratively prohibited: open failed\n"),
	"refuses port forwarding")

-- A line this does not recognise is not a diagnosis, and inventing one would be
-- worse than the transport's own words.
eq("refusal/unrecognised_line_stays_quiet",
	refusal_for("Connection closed by 192.168.10.156 port 22\n"), nil)

proxy.TUNNEL_LOG = "/nonexistent/fcc-remote-tunnel.log"
eq("refusal/no_log_stays_quiet", proxy.tunnel_refusal(), nil)
proxy.TUNNEL_LOG = kept_log

UCI.control_target = "local"

-- ---------------------------------------------------------------------------
-- What comes back
-- ---------------------------------------------------------------------------

-- HTML: the /admin/ URLs are rewritten to the proxy's base, because the browser
-- parses them before any script of ours runs.
local _, body = serve_ok({}, {
	headers = { ["Content-Type"] = "text/html; charset=utf-8" },
	chunks = { '<link href="/admin/static/app.css"><script src="/admin/static/app.js"></script>' },
})
contains("html/css_url_rewritten", body, "/cgi-bin/luci/admin/services/fcc/adminproxy/static/app.css")
contains("html/js_url_rewritten", body, "/cgi-bin/luci/admin/services/fcc/adminproxy/static/app.js")
absent("html/no_bare_admin_url_left", body, '"/admin/static')

-- The shim goes in ahead of the first script, and it carries the two
-- substitutions: the base, and the reconnect interval.
contains("html/shim_injected", body, "__fccPath")
contains("html/shim_has_base", body, 'var base = "/cgi-bin/luci/admin/services/fcc/adminproxy"')
contains("html/shim_has_poll", body, "var poll = 2000")
absent("html/shim_placeholders_substituted", body, "__FCC_BASE__")
absent("html/shim_placeholders_substituted_poll", body, "__FCC_POLL__")

-- The shim is injected before the first <script, not appended: the SPA's own
-- bundle must load after the fetch/EventSource/history patches are in place.
local shim_at = body:find("__fccPath", 1, true)
local app_at = body:find("/static/app.js", 1, true)
check("html/shim_precedes_the_app", shim_at ~= nil and app_at ~= nil and shim_at < app_at)

-- JavaScript: the SPA keeps its own /admin convention and reads the current
-- path back through the shim instead.
_, body = serve_ok({}, {
	headers = { ["Content-Type"] = "application/javascript" },
	chunks = { 'if (window.location.pathname === "/admin/code") { go(); }' },
})
contains("js/pathname_goes_through_helper", body, "window.__fccPath()")
absent("js/pathname_read_removed", body, "window.location.pathname")
contains("js/literals_untouched", body, '"/admin/code"')

-- JSON is not rewritten in general — a config document may carry "/admin" as
-- data — with one named exception: admin_url, which the SPA navigates to.
_, body = serve_ok({}, {
	headers = { ["Content-Type"] = "application/json" },
	chunks = { '{"admin_url":"http://127.0.0.1:8082/admin","note":"see /admin/help"}' },
})
contains("json/admin_url_rewritten", body,
	'"admin_url":"/cgi-bin/luci/admin/services/fcc/adminproxy"')
contains("json/other_data_untouched", body, '"note":"see /admin/help"')

-- A non-loopback admin_url is left alone: it is the user's own setting and
-- rewriting it would send them somewhere they did not ask for.
_, body = serve_ok({}, {
	headers = { ["Content-Type"] = "application/json" },
	chunks = { '{"admin_url":"http://192.168.5.3:8082/admin"}' },
})
contains("json/foreign_admin_url_kept", body, '"admin_url":"http://192.168.5.3:8082/admin"')

-- A redirect that points at the upstream is rewritten, or the browser follows
-- it to the router's own /admin and out of LuCI.
reset({})
ANSWER = { code = 307, status = "HTTP/1.1 307 Temporary Redirect",
	headers = { ["Content-Type"] = "text/html", ["Location"] = "/admin/" },
	chunks = { "" } }
proxy.serve()
eq("redirect/location_rewritten", HEADERS["Location"],
	"/cgi-bin/luci/admin/services/fcc/adminproxy/")

-- The FCC server is uvicorn, and uvicorn lowercases every response header
-- name. The fixtures above spell them the conventional way, which is what hid
-- this bug: the exact-case reads worked here and failed on the router. The
-- checks below use the upstream's spelling, so a fallback to an exact-case
-- index fails here instead of in a browser that downloads "adminproxy".
reset({})
ANSWER = { headers = { ["content-type"] = "text/html; charset=utf-8" },
	chunks = { '<link href="/admin/static/app.css">' } }
proxy.serve()
eq("lowercase/content_type_kept", HEADERS["Content-Type"], "text/html; charset=utf-8")
contains("lowercase/html_still_rewritten", written(),
	"/cgi-bin/luci/admin/services/fcc/adminproxy/static/app.css")
check("lowercase/content_type_not_relayed_twice", HEADERS["content-type"] == nil)

reset({})
ANSWER = { code = 307, status = "HTTP/1.1 307 Temporary Redirect",
	headers = { ["content-type"] = "text/html", ["location"] = "/admin/" },
	chunks = { "" } }
proxy.serve()
eq("lowercase/location_rewritten", HEADERS["location"],
	"/cgi-bin/luci/admin/services/fcc/adminproxy/")
check("lowercase/location_not_relayed_twice", HEADERS["Location"] == nil)

-- A chunked response is read with the chunk framing whatever case the header
-- was spelled in; reading it as a plain stream would write the chunk sizes to
-- the browser as part of the body.
reset({})
ANSWER = { headers = { ["content-type"] = "text/plain", ["transfer-encoding"] = "chunked" },
	chunks = { "5\r\nhello\r\n0\r\n\r\n" } }
proxy.serve()
check("lowercase/transfer_encoding_recognised", CHUNKED)

-- ---------------------------------------------------------------------------
-- The event feed, which cannot be streamed through LuCI
--
-- LuCI writes a controller action's whole response only after the action
-- returns, so a relay that waited for this stream to end would answer nothing at
-- all. The first event is relayed and the connection closed; the shim's
-- EventSource wrapper hides the reopen. Section 104.24.
-- ---------------------------------------------------------------------------
local feed = "event: feed.ready\ndata: {\"sessions\":[]}\n\n"
	.. "event: session.updated\ndata: {\"id\":\"x\"}\n\n"

-- Two events arriving in one read still only relay the first. feed.ready is
-- sent before the server starts watching for changes, so the read that carries
-- it normally carries nothing else — but a first update that lands immediately
-- can be coalesced into the same read, and writing it would deliver an event
-- over a connection the browser is about to see close.
reset({})
ANSWER = {
	headers = { ["Content-Type"] = "text/event-stream" },
	chunks = { feed },
}
proxy.serve()
contains("feed/first_event_relayed", written(), "event: feed.ready")
contains("feed/first_event_payload_relayed", written(), '{"sessions":[]}')
absent("feed/coalesced_second_event_dropped", written(), "session.updated")
check("feed/connection_closed", STATUS == nil or STATUS.code == 200)

-- An event split across chunks is still relayed whole: the blank line that ends
-- it may not arrive in the same read as its start.
reset({})
ANSWER = {
	headers = { ["Content-Type"] = "text/event-stream" },
	chunks = { "event: feed.ready\n", "data: {\"a\":1}\n", "\n", "event: session.updated\n\n" },
}
proxy.serve()
contains("feed/split_event_reassembled", written(), 'data: {"a":1}')
absent("feed/split_event_stops_at_first", written(), "session.updated")

-- A stream that ends without ever completing an event writes nothing. An
-- unterminated frame is not an event — EventSource holds it until the blank
-- line arrives and dispatches nothing if it never does — so sending it would
-- claim the browser received something it did not. The shim's miss counter is
-- what turns this into "the server is not answering" after three tries.
reset({})
ANSWER = {
	headers = { ["Content-Type"] = "text/event-stream" },
	chunks = { "event: feed.ready\n" },
}
proxy.serve()
eq("feed/unterminated_event_not_written", written(), "")

-- ---------------------------------------------------------------------------
-- Failure and limits
-- ---------------------------------------------------------------------------

-- No upstream: an HTML page naming the address LuCI tried, and a 502. The page
-- is the difference between "the button did nothing" and "the server is not
-- running, here is where to start it".
reset({})
ANSWER = nil
proxy.serve()
eq("failure/status_is_502", STATUS and STATUS.code, 502)
contains("failure/names_the_upstream", written(), "http://127.0.0.1:8082")
contains("failure/points_at_the_config_page", written(), "Configuration")

-- A body over the cap is refused before it is buffered.
reset({ REQUEST_METHOD = "POST", CONTENT_TYPE = "application/json" })
BODY = string.rep("a", 1048577)
ANSWER = { headers = { ["Content-Type"] = "application/json" }, chunks = { "{}" } }
proxy.serve()
eq("limit/oversized_body_refused", STATUS and STATUS.code, 413)
check("limit/oversized_body_not_forwarded", SENT == nil)

-- A body at the cap is forwarded.
reset({ REQUEST_METHOD = "POST", CONTENT_TYPE = "application/json" })
BODY = string.rep("a", 1048576)
ANSWER = { headers = { ["Content-Type"] = "application/json" }, chunks = { "{}" } }
proxy.serve()
eq("limit/body_at_cap_forwarded", SENT and SENT.options.body and #SENT.options.body, 1048576)
eq("limit/post_method_forwarded", SENT.options.method, "POST")
eq("limit/content_type_forwarded", SENT.options.headers["Content-Type"], "application/json")

-- HEAD and 204/304 have no body to write.
reset({ REQUEST_METHOD = "HEAD" })
ANSWER = { headers = { ["Content-Type"] = "text/html" }, chunks = { "<html>should not be sent</html>" } }
proxy.serve()
eq("head/no_body_written", written(), "")

reset({})
ANSWER = { code = 304, status = "HTTP/1.1 304 Not Modified",
	headers = { ["Content-Type"] = "text/html" }, chunks = { "nope" } }
proxy.serve()
eq("not_modified/no_body_written", written(), "")

-- A hop-by-hop header is not relayed, and Content-Length is one of them because
-- the body may have been rewritten.
reset({})
ANSWER = { headers = {
	["Content-Type"] = "text/html",
	["Content-Length"] = "12",
	["Connection"] = "close",
	["Transfer-Encoding"] = "chunked",
}, chunks = { "<html></html>" } }
proxy.serve()
check("headers/content_length_dropped", HEADERS["Content-Length"] == nil)
check("headers/connection_dropped", HEADERS["Connection"] == nil)
check("headers/transfer_encoding_dropped", HEADERS["Transfer-Encoding"] == nil)
eq("headers/content_type_kept", HEADERS["Content-Type"], "text/html")

os.exit(0)
