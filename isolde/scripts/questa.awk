BEGIN {
    IGNORECASE = 1
    RED    = "\033[31m"
    YELLOW = "\033[33m"
    RESET  = "\033[0m"
    n_err  = 0
    n_warn = 0
}

function ts() {
    return strftime("[%Y-%m-%d %H:%M %Z]")
}

{
    line = ts() " " $0
}

# ---------------------------------------------------------------------------
# slang diagnostics:  path:line:col: error: msg [-Wflag]
#                     path:line:col: warning: msg [-Wflag]
# ---------------------------------------------------------------------------
/^[^ ].*:[0-9]+:[0-9]+:[[:space:]]*error:/ {
    n_err++
    print line >> warnings_file
    print RED line RESET
    next
}
/^[^ ].*:[0-9]+:[0-9]+:[[:space:]]*warning:/ {
    n_warn++
    print line >> warnings_file
    print YELLOW line RESET
    next
}

# ---------------------------------------------------------------------------
# slang summary line:  "Build failed: N errors, M warnings"
#                      "Build succeeded: ..."
# ---------------------------------------------------------------------------
/^Build (failed|succeeded)/ {
    print line >> warnings_file
    if ($0 ~ /failed/) print RED line RESET
    else               print YELLOW line RESET
    next
}

# ---------------------------------------------------------------------------
# Questa-style diagnostics (kept for compatibility)
# ---------------------------------------------------------------------------
/^\*\*[[:space:]]Warning:/ {
    n_warn++
    print line >> warnings_file
    print YELLOW line RESET
    next
}
/^\*\*[[:space:]]Error:/ {
    n_err++
    print line >> warnings_file
    print RED line RESET
    next
}

# ---------------------------------------------------------------------------
# Verilator-style diagnostics (kept for compatibility)
# ---------------------------------------------------------------------------
/^%Error/ {
    n_err++
    print line >> warnings_file
    print RED line RESET
    next
}
/^%Warning-/ {
    n_warn++
    print line >> warnings_file
    print YELLOW line RESET
    next
}

# ---------------------------------------------------------------------------
# Everything else: pass through unchanged
# ---------------------------------------------------------------------------
{
    print
}

END {
    printf("%s==== summary: %d error(s), %d warning(s) ====%s\n",
           (n_err ? RED : YELLOW), n_err, n_warn, RESET)
    printf("[%s] ==== summary: %d error(s), %d warning(s) ====\n",
           strftime("%Y-%m-%d %H:%M %Z"), n_err, n_warn) >> warnings_file
}
