#!/usr/bin/env bash

NAME_RE='c[l]aude'
BANNED_CHAR_RE='[\x{2013}\x{2014}]'
BANNED_WORD_RE='\bd[a]sh(es|ed|ing)?\b'
CLEANUP_RE='\b(format|formatting|fmt|whitespace|d[a]sh|d[a]shes|punctuation|cleanup|tidy)\b|\bclean up\b'

_grep_name()        { grep -niIP "$NAME_RE" >/dev/null 2>&1; }
_grep_banned_char() { grep -nIP "$BANNED_CHAR_RE" >/dev/null 2>&1; }
_grep_banned_word() { grep -niIP "$BANNED_WORD_RE" >/dev/null 2>&1; }

is_cleanup_subject() { printf '%s' "$1" | grep -qiE "$CLEANUP_RE"; }

banned_char_selftest() {
    printf '\xe2\x80\x94' | _grep_banned_char || return 1
    printf 'ascii only' | _grep_banned_char && return 1
    return 0
}

banned_word_selftest() {
    printf '%s%s' 'd' 'ash' | _grep_banned_word || return 1
    printf 'gold vault' | _grep_banned_word && return 1
    return 0
}

name_selftest() {
    printf '%s%s' 'cl' 'aude' | _grep_name || return 1
    printf 'gold vault' | _grep_name && return 1
    return 0
}

cleanup_selftest() {
    is_cleanup_subject "$(printf '%s%s' 'chore: fix d' 'ash in readme')" || return 1
    is_cleanup_subject 'fix: correct oracle staleness bound' && return 1
    return 0
}

scan_tracked_banned_chars() {
    banned_char_selftest || { echo "  control: character detector failed its self test"; return 2; }
    banned_word_selftest || { echo "  control: word detector failed its self test"; return 2; }
    local rc=0 f
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -nIP "$BANNED_CHAR_RE" "$f" 2>/dev/null; then
            echo "  banned character U+2013 or U+2014 in $f"
            rc=1
        fi
        if grep -niIP "$BANNED_WORD_RE" "$f" 2>/dev/null; then
            echo "  banned word in $f"
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

scan_text_banned_chars() {
    banned_char_selftest || { echo "  control: character detector failed its self test"; return 2; }
    banned_word_selftest || { echo "  control: word detector failed its self test"; return 2; }
    printf '%s' "$1" | _grep_banned_char && return 1
    printf '%s' "$1" | _grep_banned_word && return 1
    return 0
}

scan_text_name() {
    name_selftest || { echo "  control: name detector failed its self test"; return 2; }
    printf '%s' "$1" | _grep_name && return 1
    return 0
}

scan_blob_banned_chars() {
    local blob
    blob=$(git show ":$1" 2>/dev/null)
    printf '%s' "$blob" | _grep_banned_char && return 0
    printf '%s' "$blob" | _grep_banned_word && return 0
    return 1
}
