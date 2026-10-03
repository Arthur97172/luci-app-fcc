#!/bin/sh
# luci-app-fcc — packaging checks.
#
# The Makefile carries an explicit Package/... definition (DESIGN_SPEC.md
# sections 36 and 57 require it rather than delegating to luci.mk), which means
# the install manifest is hand-written and can drift from the source tree. These
# checks are what stops that: every path the manifest names must exist, and
# every file in the tree must be named by the manifest.

TESTS_NAME="packaging"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

MAKEFILE="$ROOT/Makefile"
WORKFLOW="$ROOT/.github/workflows/build.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The install block of the main package, with comment lines removed.
install_block() {
	sed -n '/^define Package\/luci-app-fcc\/install$/,/^endef$/p' "$MAKEFILE" \
		| grep -v '^[[:space:]]*#'
}

# Source paths the manifest installs from, as repo-relative paths.
manifest_sources() {
	install_block | grep -o '\./[^ 	]*' | sed 's#^\./##' | LC_ALL=C sort -u
}

# Every file in the tree that the package is expected to ship.
tree_files() {
	find "$ROOT/root" "$ROOT/htdocs" "$ROOT/luasrc" -type f 2>/dev/null \
		| sed "s#^$ROOT/##" | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# The manifest and the tree must describe the same package
# ---------------------------------------------------------------------------

test_manifest_sources_exist() {
	_ts_bad=""
	for _ts_f in $(manifest_sources); do
		[ -e "$ROOT/$_ts_f" ] || _ts_bad="$_ts_bad $_ts_f"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every manifest source exists"
}

test_tree_files_are_all_installed() {
	# A file added to the tree but not to the manifest would build and install
	# cleanly while silently doing nothing.
	_ts_bad=""
	# Space-separated, so the case patterns below can match whole path names.
	_ts_src="$(manifest_sources | tr '\n' ' ')"
	for _ts_f in $(tree_files); do
		case " $_ts_src " in
			*" $_ts_f "*) : ;;
			*) _ts_bad="$_ts_bad $_ts_f" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every shipped file is in the manifest"
}

test_manifest_has_no_duplicates() {
	_ts_n="$(install_block | grep -o '\./[^ 	]*' | sed 's#^\./##' | wc -l | tr -d ' ')"
	_ts_u="$(manifest_sources | wc -l | tr -d ' ')"
	assert_eq "$_ts_u" "$_ts_n" "no source is installed twice"
}

test_lua_install_paths_match_the_module_names() {
	# luasrc/ maps onto /usr/lib/lua/luci/, so luasrc/fcc/util.lua must land at
	# /usr/lib/lua/luci/fcc/util.lua. Any other destination makes require()
	# fail at runtime, which no build-time check would catch.
	_ts_bad=""
	for _ts_f in "$ROOT"/luasrc/fcc/*.lua; do
		_ts_rel="luasrc/fcc/$(basename "$_ts_f")"
		grep -q "\./$_ts_rel \$(1)/usr/lib/lua/luci/fcc/$(basename "$_ts_f")" "$MAKEFILE" \
			|| _ts_bad="$_ts_bad $(_ts_rel)"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "luasrc/fcc/*.lua installs to luci/fcc/"
}

# ---------------------------------------------------------------------------
# Package metadata
# ---------------------------------------------------------------------------

test_both_packages_are_declared() {
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-app-fcc' "the app package is declared"
	assert_contains "$(cat "$MAKEFILE")" 'define Package/luci-i18n-fcc-zh-cn' "the zh-cn i18n package is declared"
	assert_contains "$(cat "$MAKEFILE")" '$(eval $(call BuildPackage,luci-app-fcc))' "the app package is built"
	assert_contains "$(cat "$MAKEFILE")" '$(eval $(call BuildPackage,luci-i18n-fcc-zh-cn))' "the i18n package is built"
}

test_packages_are_architecture_independent() {
	# This package is a pure control layer: Lua, JS and ash. Anything it ships
	# is interpreted, so PKGARCH:=all is what lets one .ipk serve every target.
	_ts_n="$(grep -c '^[[:space:]]*PKGARCH:=all' "$MAKEFILE")"
	assert_eq "2" "$_ts_n" "both packages declare PKGARCH:=all"
}

test_does_not_use_luci_mk() {
	# DESIGN_SPEC sections 36 and 57: the Package definition is explicit, so the
	# build does not inherit buildroot-version-specific luci.mk behaviour.
	_ts_hits="$(grep -n 'luci\.mk' "$MAKEFILE" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v 'luci\.mk.s implicit')"
	assert_eq "" "$_ts_hits" "luci.mk is not included"
}

test_uses_the_shared_version_file() {
	# One VERSION file feeds the package version, the in-app version display and
	# the update check. A second copy would drift.
	assert_contains "$(cat "$MAKEFILE")" 'PKG_VERSION:=$(strip $(shell cat $(CURDIR)/VERSION' \
		"PKG_VERSION is read from ./VERSION"
	assert_contains "$(cat "$MAKEFILE")" '$(INSTALL_DATA) ./VERSION $(1)/usr/share/luci-app-fcc/VERSION' \
		"VERSION is installed for the runtime to read (section 37)"
}

test_version_file_is_wellformed() {
	assert_file "$ROOT/VERSION"
	_ts_v="$(tr -d ' \t\r\n' < "$ROOT/VERSION")"
	case "$_ts_v" in
		[0-9]*.[0-9]*.[0-9]*) pass ;;
		*) fail "VERSION is not a dotted version: [$_ts_v]" ;;
	esac
	assert_eq "$_ts_v" "$(cat "$ROOT/VERSION")" "VERSION has no stray whitespace"
}

test_conffile_is_declared() {
	# /etc/config/fcc must survive an upgrade, so it has to be a conffile.
	assert_contains "$(cat "$MAKEFILE")" '/etc/config/fcc' "the UCI config is a conffile"
	assert_contains "$(cat "$MAKEFILE")" '$(INSTALL_CONF) ./root/etc/config/fcc' \
		"the UCI config is installed with INSTALL_CONF"
}

# ---------------------------------------------------------------------------
# Section 87: the package must not drag a language runtime onto the router
# ---------------------------------------------------------------------------

test_no_runtime_dependencies() {
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	assert_ne "" "$_ts_depends" "the app package declares DEPENDS"
	for _ts_forbidden in node nodejs npm python python3 python3-light uv ruby php; do
		case "$_ts_depends" in
			*"$_ts_forbidden"*)
				fail "DEPENDS must not pull in $_ts_forbidden: [$_ts_depends]" ;;
			*) pass ;;
		esac
	done
}

test_declared_dependencies_are_used() {
	# Every dependency should be a thing the code actually calls. These five are
	# the ones the backend shells out to.
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	for _ts_d in luci-base luci-compat curl ca-bundle tmux; do
		case "$_ts_depends" in
			*"+$_ts_d"*) pass ;;
			*) fail "DEPENDS is missing +$_ts_d: [$_ts_depends]" ;;
		esac
	done
}

test_readmes_are_paired_and_cross_linked() {
	# README.md is the Chinese default and README.en.md the English one. Each
	# links to the other at the top, so whoever lands on either can switch. A
	# translation that silently drifts away is worse than none.
	assert_contains "$(cat "$ROOT/README.md")" "[English](README.en.md)" \
		"the Chinese README links to the English one"
	assert_contains "$(cat "$ROOT/README.en.md")" "[简体中文](README.md)" \
		"the English README links back to the Chinese one"
}

test_tar_is_not_a_dependency() {
	# On 25.12 upstream's tar carries DEPENDS:=+PACKAGE_TAR_XZ:xz, which the
	# metadata generator copies onto every dependent as
	#   depends on !(PACKAGE_TAR_XZ) || PACKAGE_xz-utils
	# TAR_XZ defaults to y and xz-utils to n, so the gate is false, kconfig drops
	# the symbol, and the build silently produces no package at all. Nothing here
	# calls tar — the installer is fetched as a shell script and run, backups are
	# directory renames — and busybox supplies /bin/tar anyway.
	_ts_depends="$(sed -n '/^define Package\/luci-app-fcc$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	case "$_ts_depends" in
		*"+tar"*) fail "+tar makes the package unselectable on 25.12: [$_ts_depends]" ;;
		*) pass ;;
	esac
}

test_tmux_dependency_matches_the_session_backend() {
	# The Web Console is tmux-backed. If tmux ever left DEPENDS the console
	# would break only on a router that did not happen to have it.
	assert_contains "$(cat "$ROOT/root/etc/config/fcc")" "option session_backend 'tmux'" \
		"the configured session backend is tmux"
	assert_contains "$(cat "$ROOT/root/usr/libexec/fcc/session.sh")" "tmux is required for the Web Console" \
		"session.sh states the tmux requirement"
}

# ---------------------------------------------------------------------------
# The i18n package
# ---------------------------------------------------------------------------

test_i18n_package_is_wired_up() {
	assert_file "$ROOT/po/zh_Hans/fcc.po"
	assert_file "$ROOT/po/templates/fcc.pot"
	assert_contains "$(cat "$MAKEFILE")" 'po2lmo ./po/zh_Hans/fcc.po' "the .po is compiled with po2lmo"
	assert_contains "$(cat "$MAKEFILE")" 'fcc.zh-cn.lmo' "the .lmo uses LuCI's zh-cn language code"
	assert_contains "$(cat "$MAKEFILE")" 'PKG_BUILD_DEPENDS:=luci-base/host' \
		"po2lmo is available as a host tool"
}

test_i18n_auto_selects_with_the_language() {
	# LuCI has no luci-i18n-<lang> meta package: the DEFAULT line is what makes
	# menuconfig's language selection pull this package in.
	assert_contains "$(cat "$MAKEFILE")" 'DEFAULT:=LUCI_LANG_zh_Hans' \
		"the i18n package is selected by the zh_Hans language option"
}

test_i18n_package_depends_on_the_app() {
	_ts_depends="$(sed -n '/^define Package\/luci-i18n-fcc-zh-cn$/,/^endef$/p' "$MAKEFILE" \
		| sed -n 's/^[[:space:]]*DEPENDS:=//p')"
	assert_eq "+luci-app-fcc" "$_ts_depends" "the translation depends on the app"
}

# ---------------------------------------------------------------------------
# ACL
# ---------------------------------------------------------------------------

test_acl_lists_only_real_scripts() {
	_ts_bad=""
	for _ts_p in $(grep -o '"/usr/[^"]*"' "$ROOT/root/usr/share/rpcd/acl.d/luci-app-fcc.json" \
		| tr -d '"' | LC_ALL=C sort -u); do
		[ -e "$ROOT/root$_ts_p" ] || _ts_bad="$_ts_bad $_ts_p"
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every ACL path exists in the package"
}

test_acl_covers_every_backend_script() {
	# A script the controller execs but the ACL does not list fails at runtime
	# with a permission error that looks like a bug in the app.
	_ts_acl="$(cat "$ROOT/root/usr/share/rpcd/acl.d/luci-app-fcc.json")"
	_ts_bad=""
	for _ts_f in "$ROOT"/root/usr/libexec/fcc/*.sh; do
		_ts_b="$(basename "$_ts_f")"
		[ "$_ts_b" = "common.sh" ] && continue   # sourced, never exec'd
		# procd execs this one as root to start the server; it is never an
		# rpcd endpoint, so listing it here would be dead configuration.
		[ "$_ts_b" = "server-run.sh" ] && continue
		case "$_ts_acl" in
			*"/usr/libexec/fcc/$_ts_b"*) : ;;
			*) _ts_bad="$_ts_bad $_ts_b" ;;
		esac
	done
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" "every backend script is in the ACL"
}

# ---------------------------------------------------------------------------
# What a release publishes (sections 62 and 93)
#
# Sections 62 and 93 name the assets a release carries: luci-app-fcc's own
# packages. The SDK builds the whole dependency chain alongside them, and the
# difference between "we publish our package" and "we publish sixty upstream
# packages as well" is one glob — which is exactly the kind of thing that
# changes without anyone noticing, because nothing downstream complains.
# ---------------------------------------------------------------------------

# The collect step of the build job, up to the step that follows it.
collect_step() {
	sed -n '/- name: Collect artifacts/,/- name: Verify the artifacts/p' "$WORKFLOW"
}

# The release job, from its name to the end of the file.
release_job() {
	sed -n '/^  release:/,$p' "$WORKFLOW"
}

test_the_build_collects_only_our_packages() {
	_ts_c="$(collect_step)"
	assert_ne "" "$_ts_c" "the build job has a collect step"
	# The glob that collects the entire chain. Spelled out literally so that an
	# edit reinstating it is caught rather than quietly republishing upstream
	# packages under this project's name.
	case "$_ts_c" in
		*'-name "*.${{ matrix.ext }}"'*)
			fail "the collect step copies every package the SDK built" ;;
		*) pass ;;
	esac
	for _ts_p in 'luci-app-fcc[-_]*' 'luci-i18n-fcc-*'; do
		assert_contains "$_ts_c" "$_ts_p" "the collect step is scoped to $_ts_p"
	done
}

test_the_release_does_not_merge_architectures_blindly() {
	# All four artifacts carry the same two packages — section 92's PKGARCH=all
	# makes them architecture-independent — so merging them lets one copy
	# overwrite another with nothing said. Two SDKs disagreeing about the same
	# package is worth failing on, not resolving by arrival order.
	_ts_r="$(release_job)"
	assert_ne "" "$_ts_r" "the workflow has a release job"
	case "$_ts_r" in
		*'merge-multiple: true'*)
			fail "the release job merges artifacts, so duplicates overwrite silently" ;;
		*) pass ;;
	esac
	assert_contains "$_ts_r" 'cmp -s' "the release job compares the copies it received"
}

test_the_release_publishes_only_our_packages() {
	_ts_r="$(release_job)"
	assert_contains "$_ts_r" 'luci-app-fcc*|luci-i18n-fcc*' \
		"the release job filters the assets it publishes"
	# The publish list must be the collected directory, not the raw download:
	# artifacts/ is what the job received, release/ is what it decided to ship,
	# and only the second one has been filtered.
	_ts_gh="$(printf '%s\n' "$_ts_r" | sed -n '/gh release create/,$p')"
	assert_contains "$_ts_gh" 'release/*' "the release publishes the filtered directory"
	assert_not_contains "$_ts_gh" 'artifacts/' "the release does not publish the raw download"
}

tests_main
