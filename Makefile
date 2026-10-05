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
# Bumped rather than PKG_VERSION: the package's contents changed while its
# upstream version did not. Section 62 names the release and its tag after both
# numbers — the release carrying luci-app-fcc_0.1.1-r4_all.ipk is called
# 0.1.1-r4 — so a release number is never reused, and every push is a new
# release rather than the same name over different bytes. Bumping this number is
# what cuts the next release.
#
# 版本约定：每次提交 PKG_RELEASE +1（0.1.1-r1 ~ r9）；
# 达到 r10 时 PKG_VERSION 末位 +1（0.1.1 -> 0.1.2），PKG_RELEASE 重置为 1。
#
# PKG_VERSION is the ./VERSION file, so "PKG_VERSION 末位 +1" means editing that
# file and setting this back to 1. scripts/version.sh composes the two into the
# package name, the git tag and the release name at once, which is why the
# number may not be reused.
PKG_RELEASE:=5

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

	# No .lmo here. The Simplified Chinese catalogue is built into
	# luci-i18n-fcc-zh-cn, below, so this package carries English only — English
	# is the source language the _("...") strings are written in and needs no
	# catalogue at all. The interface language still follows LuCI; what changed
	# is only which package the compiled zh-cn catalogue arrives in.
endef

# The uci-defaults script is deliberately NOT sourced here, and neither is
# /tmp/luci-indexcache removed.
#
# Neither package manager runs this text on its own. Both wrap it: the opkg
# build appends it to a generated `postinst`, and the apk build appends it to a
# generated `post-install`, and both wrappers call default_postinst() from
# /lib/functions.sh *before* this block. default_postinst() reads the package's
# own file list, runs every /etc/uci-defaults/ file the package ships — the
# whole point of shipping one — and deletes each one after it succeeds, then
# removes /tmp/luci-indexcache.*. So by the time the lines below run, there is
# no file left to source:
#
#   * /proc/self/fd/7: .: line 10: can't open /etc/uci-defaults/99-fcc: no such file
#
# That is the apk wrapper's line 10 — eight lines of wrapper (shebang, two
# guards, functions.sh, root, pkgname, add_group_and_user, default_postinst)
# then this block's first line. The opkg wrapper is four lines shorter, and the
# error is the same one under a different number. It is noise on a successful
# install, and on a failing one it is the last line a person sees.
define Package/luci-app-fcc/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
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

# ---------------------------------------------------------------------------
# luci-i18n-fcc-zh-cn — the compiled Simplified Chinese catalogue
# ---------------------------------------------------------------------------
#
# Separate from the app package on purpose: the app ships English and nothing
# else, and the translation is something you add. This is the layout upstream
# LuCI uses for every application, and it is what lets the two be installed,
# upgraded and removed independently — an English-only install no longer carries
# 40 KB of catalogue it will never load.
#
# It depends on luci-base and deliberately NOT on luci-app-fcc. A dependency on
# the app would be circular the moment anything wanted the translation selected
# by default, and nothing here needs it: the .lmo is a data file that LuCI's
# template parser loads by name, so installing it without the app is harmless —
# it simply sits unread. Adding the app afterwards needs no reinstall.
#
# The path is the whole of the wiring. LuCI looks for <name>.<lang>.lmo under
# /usr/lib/lua/luci/i18n when the interface language is zh-cn, where <name> is
# the view or controller module — fcc, here — and <lang> is the alias from
# LUCI_LC_ALIAS. That alias is zh-cn, which is not what the po directory is
# called: the catalogue is named after the language tag LuCI asks for, not after
# the gettext directory it was written in. Getting this wrong is silent — the
# file installs, and the interface stays English.
#
# po2lmo comes from luci-base's host build, which PKG_BUILD_DEPENDS already
# pulls in for the app package above; the variable is per-Makefile, so this
# package inherits it.
define Package/luci-i18n-fcc-zh-cn
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=Translations
  TITLE:=Chinese (Simplified) translation for luci-app-fcc
  DEPENDS:=+luci-base
  PKGARCH:=all
  URL:=https://github.com/Arthur97172/luci-app-fcc
endef

define Package/luci-i18n-fcc-zh-cn/description
  Simplified Chinese (zh-cn) translation for luci-app-fcc.

  Without this package the FCC pages render in English whatever the interface
  language is set to. Install it and LuCI loads the catalogue by itself; no
  configuration is needed and no service has to be restarted.
endef

define Package/luci-i18n-fcc-zh-cn/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/zh_Hans/fcc.po $(1)/usr/lib/lua/luci/i18n/fcc.zh-cn.lmo
endef

$(eval $(call BuildPackage,luci-app-fcc))
$(eval $(call BuildPackage,luci-i18n-fcc-zh-cn))
