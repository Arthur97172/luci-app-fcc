# luci-app-fcc — read a gettext .po/.pot into "msgid<TAB>msgstr" lines.
#
# Usage: awk -f tests/po.awk <file>
#
# One line per catalogue entry, header entry (msgid "") omitted. Multi-line
# entries are joined, which matters because any string carrying a placeholder is
# wrapped by msgmerge.
#
# This lives in its own file rather than inline in test_i18n.sh because awk
# needs the `function` keyword, and the shell portability scan in test_shell.sh
# rejects any line that looks like it — correctly, since a shell `function`
# definition is a bashism. Keeping the awk separate means that scan stays
# switched on for the whole test file.

function unq(l) {
	sub(/^[a-z]+[ \t]+/, "", l)
	sub(/^"/, "", l)
	sub(/"$/, "", l)
	return l
}

function flush() {
	if (have) {
		printf "%s\t%s\n", id, str
		id = ""; str = ""; have = 0
	}
}

/^#/        { next }
/^[ \t]*$/  { flush(); mode = ""; next }
/^msgid /   { flush(); id = unq($0); have = 1; mode = "id"; next }
/^msgstr /  { str = unq($0); mode = "str"; next }
/^"/        { if (mode == "id") id = id unq($0); else if (mode == "str") str = str unq($0); next }

END { flush() }
