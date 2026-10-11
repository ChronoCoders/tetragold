#!/usr/bin/env bash
# Shared check library for the gate (scripts/gate) and the repo git hooks
# (.githooks/). One source of truth for the two sweeps that pass by finding
# nothing, so each one proves it can detect a seeded violation before it is
# trusted to report clean.
#
# The banned-name pattern is written c[l]aude so this file never matches
# itself. The dash pattern is written with hex escapes so this file holds no
# literal em dash or en dash.

NAME_RE='c[l]aude'
DASH_RE='[\x{2013}\x{2014}]'

# _grep_name and _grep_dash scan stdin. 0 = a match was found, 1 = none.
_grep_name() { grep -niIP "$NAME_RE" >/dev/null 2>&1; }
_grep_dash() { grep -nIP "$DASH_RE" >/dev/null 2>&1; }

# Positive controls. A seeded violation must be detected, or the detector is
# broken and must not be trusted. em dash bytes e2 80 94, en dash e2 80 93.
dash_selftest() {
    printf '\xe2\x80\x94' | _grep_dash || return 1
    printf 'ascii only' | _grep_dash && return 1
    return 0
}

name_selftest() {
    # assemble the seed from pieces so this function body is clean
    printf '%s%s' 'cl' 'aude' | _grep_name || return 1
    printf 'gold vault' | _grep_name && return 1
    return 0
}

# scan_tracked_dashes / scan_tracked_name scan every tracked file. They print
# each offender and return 1 if any is found, 0 if clean, after the control.
scan_tracked_dashes() {
    dash_selftest || { echo "  control: dash detector failed its self test"; return 2; }
    local rc=0 f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -nIP "$DASH_RE" "$f" 2>/dev/null; then
            echo "  dash in $f"
            rc=1
        fi
    done < <(git ls-files)
    return $rc
}

scan_tracked_name() {
    name_selftest || { echo "  control: name detector failed its self test"; return 2; }
    local rc=0 f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -niIP "$NAME_RE" "$f" 2>/dev/null; then
            echo "  banned name in $f"
            rc=1
        fi
    done < <(git ls-files)
    return $rc
}

# scan_text_dashes / scan_text_name scan a string (commit messages, push data).
scan_text_dashes() {
    dash_selftest || { echo "  control: dash detector failed its self test"; return 2; }
    printf '%s' "$1" | _grep_dash && return 1
    return 0
}

scan_text_name() {
    name_selftest || { echo "  control: name detector failed its self test"; return 2; }
    printf '%s' "$1" | _grep_name && return 1
    return 0
}

# scan_blob_dashes scans one staged blob by path (pre-commit).
scan_blob_dashes() {
    git show ":$1" 2>/dev/null | _grep_dash
}
