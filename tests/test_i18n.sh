#!/bin/sh
# luci-app-fcc — translation catalogue checks.
#
# The catalogue is generated (scripts/gen-po.sh) rather than hand-maintained, so
# the risk is not a typo but *drift*: a string added to a view that never
# reaches the .pot, or a .po that quietly stops matching it. These checks pin
# the two files to each other and to the source.
#
# One OpenWrt-specific trap is encoded here as well: po2lmo DROPS any entry
# whose msgstr equals its msgid. A .po that "translates" a string to itself
# therefore loses it entirely rather than falling back, which is why
# test_no_msgstr_equals_its_msgid exists.

TESTS_NAME="i18n"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$(dirname -- "$0")/lib.sh"

POT="$ROOT/po/templates/fcc.pot"
PO="$ROOT/po/zh_Hans/fcc.po"
VIEWS="$ROOT/luasrc/view/fcc"
JS="$ROOT/htdocs/luci-static/resources/fcc"

# Emit one "msgid<TAB>msgstr" line per catalogue entry, skipping the header
# entry (msgid ""). The parser lives in tests/po.awk so this file contains no
# awk `function` keyword, which the shell portability scan would read as a
# bashism.
po_pairs() {
	awk -f "$(dirname -- "$0")/po.awk" "$1"
}

msgids_of() {
	po_pairs "$1" | cut -f1
}

# ---------------------------------------------------------------------------
# The catalogue and its source
# ---------------------------------------------------------------------------

test_pot_is_not_stale() {
	# The generator is the only writer, so "up to date" is a real invariant: if
	# this fails, a string was added to a view or a script and never collected.
	_ts_out="$(sh "$ROOT/scripts/gen-po.sh" --check 2>&1)"
	assert_contains "$_ts_out" "up to date" "po/templates/fcc.pot matches the source"
}

test_every_translatable_string_reaches_the_pot() {
	# An independent extraction, deliberately not sharing code with gen-po.sh, so
	# a bug in the generator cannot hide itself.
	_ts_pot="$(msgids_of "$POT" | LC_ALL=C sort -u)"
	_ts_bad=""

	for _ts_f in "$VIEWS"/*.htm; do
		[ -f "$_ts_f" ] || continue
		_ts_s="$(grep -o '<%:[^%]*%>' "$_ts_f" | sed 's/^<%://; s/%>$//' \
			| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')"
		[ -n "$_ts_s" ] || continue
		while IFS= read -r _ts_one; do
			printf '%s\n' "$_ts_pot" | grep -Fxq -- "$_ts_one" \
				|| _ts_bad="$_ts_bad $(basename "$_ts_f"):[$_ts_one]"
		done <<EOF
$_ts_s
EOF
	done

	for _ts_f in "$JS"/*.js; do
		[ -f "$_ts_f" ] || continue
		_ts_s="$({ grep -o "FCC\._('[^']*')" "$_ts_f" | sed "s/^FCC\._('//; s/')$//"
		           grep -o 'FCC\._("[^"]*")' "$_ts_f" | sed 's/^FCC\._("//; s/")$//'; } \
			| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')"
		[ -n "$_ts_s" ] || continue
		while IFS= read -r _ts_one; do
			printf '%s\n' "$_ts_pot" | grep -Fxq -- "$_ts_one" \
				|| _ts_bad="$_ts_bad $(basename "$_ts_f"):[$_ts_one]"
		done <<EOF
$_ts_s
EOF
	done

	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" \
		"every <%:…%> and FCC._(…) string is in the template"
}

test_pot_has_no_orphans() {
	# The other direction: an entry nobody references means a string was deleted
	# from the UI but left in the template, which would ship a dead translation.
	_ts_src="$({
		for _ts_f in "$VIEWS"/*.htm; do
			[ -f "$_ts_f" ] || continue
			grep -o '<%:[^%]*%>' "$_ts_f" | sed 's/^<%://; s/%>$//'
		done
		for _ts_f in "$JS"/*.js; do
			[ -f "$_ts_f" ] || continue
			grep -o "FCC\._('[^']*')" "$_ts_f" | sed "s/^FCC\._('//; s/')$//"
			grep -o 'FCC\._("[^"]*")' "$_ts_f" | sed 's/^FCC\._("//; s/")$//'
		done
	} | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | LC_ALL=C sort -u)"

	_ts_bad=""
	while IFS= read -r _ts_one; do
		[ -n "$_ts_one" ] || continue
		printf '%s\n' "$_ts_src" | grep -Fxq -- "$_ts_one" || _ts_bad="$_ts_bad [$_ts_one]"
	done <<EOF
$(msgids_of "$POT" | LC_ALL=C sort -u)
EOF
	assert_eq "" "$(printf '%s' "$_ts_bad" | sed 's/^ //')" \
		"the template carries no string the source no longer uses"
}

# ---------------------------------------------------------------------------
# The .po and the .pot must describe the same catalogue
# ---------------------------------------------------------------------------

test_po_and_pot_share_the_same_msgids() {
	_ts_a="$(msgids_of "$POT" | LC_ALL=C sort -u)"
	_ts_b="$(msgids_of "$PO" | LC_ALL=C sort -u)"
	assert_eq "$_ts_a" "$_ts_b" "the zh_Hans catalogue covers exactly the template's strings"
}

test_msgids_are_unique() {
	_ts_n="$(msgids_of "$POT" | wc -l | tr -d ' ')"
	_ts_u="$(msgids_of "$POT" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
	assert_eq "$_ts_u" "$_ts_n" "no msgid appears twice in the template"

	_ts_n="$(msgids_of "$PO" | wc -l | tr -d ' ')"
	_ts_u="$(msgids_of "$PO" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
	assert_eq "$_ts_u" "$_ts_n" "no msgid appears twice in the catalogue"
}

test_catalogue_is_complete() {
	# An entry with an empty msgstr is untranslated: LuCI falls back to the
	# msgid, so the page shows English. That is a legitimate state during
	# development but not one to ship for a language the package declares.
	_ts_empty="$(po_pairs "$PO" | awk -F'\t' '$2 == "" { n++ } END { print n + 0 }')"
	assert_eq "0" "$_ts_empty" "every entry in the zh_Hans catalogue has a translation"

	_ts_n="$(msgids_of "$PO" | wc -l | tr -d ' ')"
	[ "$_ts_n" -ge 50 ] || fail "the catalogue looks truncated: only $_ts_n entries"
	[ "$_ts_n" -ge 50 ] && pass
}

test_no_long_string_is_translated_to_itself() {
	# po2lmo drops any entry whose msgstr equals its msgid. For a product name
	# like "FCC" that is harmless — LuCI falls back to the msgid and the user
	# sees the same text either way. For a sentence it is not: the entry would
	# vanish from the .lmo and the UI would render English, with nothing in the
	# build log to say so. Only short untranslatable labels may pass through.
	_ts_bad="$(po_pairs "$PO" | awk -F'\t' '$1 == $2 && length($1) > 12 { print $1 }')"
	assert_eq "" "$_ts_bad" "no sentence is translated to itself"

	# The permitted ones should be exactly the product names, so pin that too.
	_ts_same="$(po_pairs "$PO" | awk -F'\t' '$1 == $2 { print $1 }' | LC_ALL=C sort | tr '\n' ' ')"
	case "$_ts_same" in
		"FCC FCC Server "|"FCC "|"") pass ;;
		*) fail "an unexpected entry passes through untranslated: [$_ts_same]" ;;
	esac
}

test_translations_are_actually_translated() {
	# Guards against a .po that was copied from the .pot and "translated" by
	# pasting the same text back. Most strings in this UI are prose, so the
	# overwhelming majority of translations must contain non-ASCII bytes.
	_ts_total="$(po_pairs "$PO" | wc -l | tr -d ' ')"
	_ts_ascii="$(LC_ALL=C grep -c '^msgstr "[ -~]*"$' "$PO")"
	# Allow a handful of legitimately ASCII translations (product names, "OK").
	_ts_budget=$(( _ts_total / 10 ))
	[ "$_ts_ascii" -le "$_ts_budget" ] \
		|| fail "$_ts_ascii of $_ts_total translations are pure ASCII — looks untranslated"
	[ "$_ts_ascii" -le "$_ts_budget" ] && pass
}

# ---------------------------------------------------------------------------
# Header / build wiring
# ---------------------------------------------------------------------------

test_po_header_is_valid() {
	_ts_h="$(sed -n '1,/^$/p' "$PO")"
	assert_contains "$_ts_h" 'Language: zh_Hans' "the catalogue declares its language"
	assert_contains "$_ts_h" 'charset=UTF-8' "the catalogue is UTF-8"
	assert_contains "$_ts_h" 'Plural-Forms:' "the catalogue declares plural forms"
	assert_contains "$_ts_h" 'Content-Type: text/plain' "the catalogue declares a content type"
}

test_pot_header_is_valid() {
	_ts_h="$(sed -n '1,/^$/p' "$POT")"
	assert_contains "$_ts_h" 'charset=UTF-8' "the template is UTF-8"
	assert_contains "$_ts_h" 'Project-Id-Version: luci-app-fcc' "the template names the project"
}

test_entries_are_syntactically_wellformed() {
	# Every msgid/msgstr line must open and close its quote, and every
	# continuation line must be a quoted fragment. A stray unescaped quote would
	# make po2lmo fail at build time, which is late.
	_ts_bad="$(awk '
		/^#/ { next }
		/^[ \t]*$/ { next }
		/^msgid "/ { if ($0 !~ /"$/) print NR ": unterminated msgid"; next }
		/^msgstr "/ { if ($0 !~ /"$/) print NR ": unterminated msgstr"; next }
		/^"/ { if ($0 !~ /"$/) print NR ": unterminated continuation"; next }
		{ print NR ": unexpected line: " $0 }
	' "$PO")"
	assert_eq "" "$_ts_bad" "every line in the catalogue is a well-formed entry"

	_ts_bad="$(awk '
		/^#/ { next }
		/^[ \t]*$/ { next }
		/^msgid "/ { if ($0 !~ /"$/) print NR ": unterminated msgid"; next }
		/^msgstr "/ { if ($0 !~ /"$/) print NR ": unterminated msgstr"; next }
		/^"/ { if ($0 !~ /"$/) print NR ": unterminated continuation"; next }
		{ print NR ": unexpected line: " $0 }
	' "$POT")"
	assert_eq "" "$_ts_bad" "every line in the template is a well-formed entry"
}

test_makefile_compiles_to_lucis_language_code() {
	# Two names have to line up, and upstream luci.mk's LuciTranslation macro is
	# the reference for both:
	#
	#   po dir     zh_Hans                 the gettext/BCP-47 directory name
	#   alias      LUCI_LC_ALIAS.zh_Hans=zh-cn    -> $(1) in the macro
	#   .lmo       <pkg>.$(1).lmo          = fcc.zh-cn.lmo
	#
	# This package does not include luci.mk, so LUCI_LC_ALIAS itself is never
	# read — what matters is that the name it would have produced is the one
	# written out here by hand.
	_ts_mk="$(cat "$ROOT/Makefile")"
	assert_contains "$_ts_mk" 'po2lmo ./po/zh_Hans/fcc.po' "the catalogue is compiled from po/zh_Hans"
	assert_contains "$_ts_mk" 'fcc.zh-cn.lmo' "the .lmo uses the aliased language code zh-cn"
	assert_not_contains "$_ts_mk" 'fcc.zh_Hans.lmo' "the .lmo is not named after the po directory"

	# Upstream's luci-i18n-* packages also register their language in
	# luci.languages through uci-defaults. luci-i18n-fcc-zh-cn deliberately does
	# not, despite now carrying the name of one. Adding zh_cn to the global
	# language list would offer a half-translated interface to anyone who has not
	# installed luci-i18n-base-zh-cn as well — the theme, the menu and every other
	# page would still be English. LuCI loads this catalogue by itself whenever
	# the interface language already is zh-cn, which is the case that matters.
	assert_not_contains "$_ts_mk" 'luci.languages.zh_cn' \
		"the package does not change the global LuCI language list"
}

test_catalogue_compiles_if_po2lmo_is_available() {
	# po2lmo ships with luci-base/host, so it is normally absent from a plain
	# development machine. When it is present this is the real build check; when
	# it is not, the structural checks above stand in for it.
	if command -v po2lmo >/dev/null 2>&1; then
		_ts_tmp="$ROOT/tmp-test/lmo.$$"
		mkdir -p "$ROOT/tmp-test"
		if po2lmo "$PO" "$_ts_tmp" 2>/dev/null; then
			pass
			_ts_n="$(wc -c < "$_ts_tmp" | tr -d ' ')"
			[ "$_ts_n" -gt 0 ] || fail "po2lmo produced an empty catalogue"
			[ "$_ts_n" -gt 0 ] && pass
		else
			fail "po2lmo could not compile $PO"
		fi
		rm -f "$_ts_tmp"
	else
		skip "po2lmo is not installed — structural checks stand in"
		# The substitute: the file must still be a valid gettext catalogue by the
		# rules po2lmo applies, which is what the checks above verify.
		assert_contains "$(cat "$PO")" 'msgid "Actions"' "the catalogue is non-trivial"
	fi
}

tests_main
