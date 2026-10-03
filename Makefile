# luci-app-fcc — OpenWrt / ImmortalWrt package Makefile
#
# Compatible with both integration styles:
#   1. As a feed:      echo "src-git fcc https://github.com/Arthur97172/luci-app-fcc.git" >> feeds.conf.default
#   2. As a package:   git clone ... package/luci-app-fcc
#
# The Package/... definition is written out explicitly rather than delegating to
# luci.mk's implicit generation, so the package builds identically on the OpenWrt
# 24.10 and 25.12 feeds layouts and does not inherit buildroot-version-specific
# behaviour. This is what DESIGN_SPEC.md sections 36 and 57 require.
#
# This package is PKGARCH:=all: it is a pure LuCI control layer. The FCC Python
# runtime, Node.js, uv and the coding agents are NOT part of this package — they
# are managed at runtime under /opt/fcc. See DESIGN_SPEC.md sections 3 and 55.

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fcc
PKG_VERSION:=$(strip $(shell cat $(CURDIR)/VERSION 2>/dev/null || echo 0.1.1))
PKG_RELEASE:=1

PKG_MAINTAINER:=Arthur97172 <Arthur97172@users.noreply.github.com>
PKG_LICENSE:=GPL-3.0
PKG_LICENSE_FILES:=LICENSE

# po2lmo, from luci-base's host build, compiles po/zh_Hans/fcc.po into the .lmo
# the LuCI runtime loads. It is a host tool, so it costs the target nothing.
PKG_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

# There is no ./src to compile: everything shipped is interpreted (Lua, JS, ash).
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/luci-app-fcc
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=FCC AI Coding Agent Manager
  # No +tar, deliberately. Nothing in this package shells out to tar — the
  # runtime installer is fetched as a shell script and run, and backups are
  # directory renames — and the base image's busybox already provides /bin/tar.
  # It would also make the package unselectable on 25.12: upstream's tar now
  # carries DEPENDS:=+PACKAGE_TAR_XZ:xz, and the metadata generator copies that
  # variant gate onto every dependent as
  #   depends on !(PACKAGE_TAR_XZ) || PACKAGE_xz-utils
  # TAR_XZ defaults to y and xz-utils to n, so the gate is false and defconfig
  # silently drops the symbol. 24.10 expressed the same thing as EXTRA_DEPENDS,
  # which does not propagate to dependents, so only 25.12 is affected.
  DEPENDS:=+luci-base +luci-compat +curl +ca-bundle +tmux
  PKGARCH:=all
  URL:=https://github.com/Arthur97172/luci-app-fcc
endef

define Package/luci-app-fcc/description
  FCC (Free Claude Code) manager for OpenWrt / ImmortalWrt.

  Provides a Web Console (a real interactive terminal for Claude Code, Codex,
  Pi, OpenCode, Cline, Hermes, DeepSeek Harness, Grok Build, Muse Code and
  Aider), an FCC Server Manager (start/stop/restart, link to FCC Admin) and a
  Runtime Monitor (versions, PID, uptime, RSS memory, system memory, storage,
  update status).

  The FCC runtime itself is installed separately, on demand, under /opt/fcc.
endef

define Package/luci-app-fcc/conffiles
/etc/config/fcc
endef

# Install manifest — keep in sync with scripts/package-check.sh and the local
# build helpers. tests/test_packaging.sh enforces parity between this list and
# the files that actually exist in the source tree.
define Package/luci-app-fcc/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/fcc $(1)/etc/config/fcc
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-fcc $(1)/etc/uci-defaults/99-fcc
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/fcc $(1)/etc/init.d/fcc

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./root/usr/bin/fcc-env $(1)/usr/bin/fcc-env

	$(INSTALL_DIR) $(1)/usr/libexec/fcc
	$(INSTALL_BIN) ./root/usr/libexec/fcc/common.sh $(1)/usr/libexec/fcc/common.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/status.sh $(1)/usr/libexec/fcc/status.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/agent.sh $(1)/usr/libexec/fcc/agent.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/session.sh $(1)/usr/libexec/fcc/session.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/install.sh $(1)/usr/libexec/fcc/install.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/update.sh $(1)/usr/libexec/fcc/update.sh
	$(INSTALL_BIN) ./root/usr/libexec/fcc/doctor.sh $(1)/usr/libexec/fcc/doctor.sh
	# Section 50: the LAN-only firewall rule for the FCC Admin port.
	$(INSTALL_BIN) ./root/usr/libexec/fcc/firewall.sh $(1)/usr/libexec/fcc/firewall.sh
	# Section 39: procd cannot write a service's output to a file, so the
	# server is started through this wrapper, which redirects and execs.
	$(INSTALL_BIN) ./root/usr/libexec/fcc/server-run.sh $(1)/usr/libexec/fcc/server-run.sh

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/fcc.lua $(1)/usr/lib/lua/luci/controller/fcc.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/fcc
	$(INSTALL_DATA) ./luasrc/view/fcc/console.htm $(1)/usr/lib/lua/luci/view/fcc/console.htm
	$(INSTALL_DATA) ./luasrc/view/fcc/config.htm $(1)/usr/lib/lua/luci/view/fcc/config.htm
	$(INSTALL_DATA) ./luasrc/view/fcc/info.htm $(1)/usr/lib/lua/luci/view/fcc/info.htm
	# luasrc/ maps onto /usr/lib/lua/luci/, so luasrc/fcc/util.lua is the module
	# luci.fcc.util. Installing it anywhere else makes require() fail.
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/fcc
	$(INSTALL_DATA) ./luasrc/fcc/agents.lua $(1)/usr/lib/lua/luci/fcc/agents.lua
	$(INSTALL_DATA) ./luasrc/fcc/paths.lua $(1)/usr/lib/lua/luci/fcc/paths.lua
	$(INSTALL_DATA) ./luasrc/fcc/util.lua $(1)/usr/lib/lua/luci/fcc/util.lua

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-fcc.json $(1)/usr/share/rpcd/acl.d/luci-app-fcc.json

	$(INSTALL_DIR) $(1)/usr/share/luci-app-fcc
	$(INSTALL_DATA) ./VERSION $(1)/usr/share/luci-app-fcc/VERSION
	$(INSTALL_DATA) ./root/usr/share/luci-app-fcc/agents.conf $(1)/usr/share/luci-app-fcc/agents.conf

	$(INSTALL_DIR) $(1)/www/luci-static/resources/fcc
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/xterm.min.js $(1)/www/luci-static/resources/fcc/xterm.min.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/xterm.min.css $(1)/www/luci-static/resources/fcc/xterm.min.css
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/addon-fit.min.js $(1)/www/luci-static/resources/fcc/addon-fit.min.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/fcc-common.js $(1)/www/luci-static/resources/fcc/fcc-common.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/fcc-terminal.js $(1)/www/luci-static/resources/fcc/fcc-terminal.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/fcc-config.js $(1)/www/luci-static/resources/fcc/fcc-config.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/fcc-info.js $(1)/www/luci-static/resources/fcc/fcc-info.js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/fcc/fcc.css $(1)/www/luci-static/resources/fcc/fcc.css

	# The Simplified Chinese catalogue ships inside this package rather than as
	# a separate luci-i18n-fcc-zh-cn. LuCI's template parser looks for
	# <name>.<lang>.lmo here by itself when the interface language is zh-cn, so
	# a second package buys nothing but a second thing to install — and section
	# 62's release lists one package. English needs no catalogue: it is the
	# source language the _("...") strings are written in.
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/zh_Hans/fcc.po $(1)/usr/lib/lua/luci/i18n/fcc.zh-cn.lmo
endef

define Package/luci-app-fcc/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	( . /etc/uci-defaults/99-fcc ) && rm -f /etc/uci-defaults/99-fcc
	rm -f /tmp/luci-indexcache 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	# Best-effort: (re)load rpcd so the new ACL is picked up immediately.
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1
	exit 0
}
endef

define Package/luci-app-fcc/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	# Intentionally do NOT remove /opt/fcc (runtime + user data).
	# Removing the FCC runtime is an explicit user action (fcc-env uninstall).
	exit 0
}
endef

$(eval $(call BuildPackage,luci-app-fcc))
