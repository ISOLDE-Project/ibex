BEGIN {
    IGNORECASE = 1
    RED    = "\033[31m"
    YELLOW = "\033[33m"
    RESET  = "\033[0m"
}

function ts() {
    return strftime("[%Y-%m-%d %H:%M %Z]")
}

{
    line = ts() " " $0
}


/^\*\*[[:space:]]Warning:/ {
    print line >> warnings_file
    print YELLOW line RESET
    next
}
/^\*\*[[:space:]]Error:/ {
    print line >> warnings_file
    print RED line RESET
    next
}

/^%Error/{
    print line >> warnings_file
    print RED line RESET
    next
}

/^%Warning-/{
    print line >> warnings_file
    print YELLOW line RESET
    next
}

{
    print
}