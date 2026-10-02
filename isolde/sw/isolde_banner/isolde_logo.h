/*
 * Copyleft 2025 ISOLDE
 *
 * The boot banner's art.  Two sets:
 *   ISOLDE_BANNER_UTF8 = 1 (default)  block letters and box drawing, UTF-8:
 *                                      GTKTerm, minicom -c on, PuTTY, screen
 *   ISOLDE_BANNER_UTF8 = 0            7-bit ASCII only, for any terminal
 * Colours are ANSI SGR escapes (256-colour palette), ISOLDE_BANNER_COLOR = 0
 * leaves them out.  Every line is at most 64 columns wide.
 */
#ifndef ISOLDE_LOGO_H
#define ISOLDE_LOGO_H

#ifndef ISOLDE_BANNER_UTF8
#define ISOLDE_BANNER_UTF8 1
#endif
#ifndef ISOLDE_BANNER_COLOR
#define ISOLDE_BANNER_COLOR 1
#endif

#if ISOLDE_BANNER_COLOR
#define C_RESET "\033[0m"
#define C_LABEL "\033[38;5;245m"      /* grey labels                       */
#define C_VALUE "\033[1;38;5;255m"    /* bright values                     */
#define C_RULE  "\033[38;5;238m"      /* rules and tree lines              */
#define C_HWE   "\033[1;38;5;45m"     /* RedMulE: cyan                     */
#define C_CORE  "\033[1;38;5;214m"    /* Ibex: amber, like the logo        */
#define C_TAG   "\033[38;5;252m"      /* the tag line                      */
#define C_LINK  "\033[4;38;5;111m"    /* underlined link                   */
/* Logo rows, top to bottom: orange to amber; the shadow row darker. */
static const char *const isolde_logo_color[] = {
    "\033[1;38;5;202m", "\033[1;38;5;208m", "\033[1;38;5;208m",
    "\033[1;38;5;214m", "\033[1;38;5;214m", "\033[38;5;130m",
};
#else
#define C_RESET ""
#define C_LABEL ""
#define C_VALUE ""
#define C_RULE  ""
#define C_HWE   ""
#define C_CORE  ""
#define C_TAG   ""
#define C_LINK  ""
static const char *const isolde_logo_color[] = {"", "", "", "", "", ""};
#endif

#if ISOLDE_BANNER_UTF8
#define ISOLDE_LOGO_HEIGHT 6
static const char *const isolde_logo_ascii[ISOLDE_LOGO_HEIGHT] = {
    "██╗███████╗ ██████╗ ██╗     ██████╗ ███████╗",
    "██║██╔════╝██╔═══██╗██║     ██╔══██╗██╔════╝",
    "██║███████╗██║   ██║██║     ██║  ██║█████╗  ",
    "██║╚════██║██║   ██║██║     ██║  ██║██╔══╝  ",
    "██║███████║╚██████╔╝███████╗██████╔╝███████╗",
    "╚═╝╚══════╝ ╚═════╝ ╚══════╝╚═════╝ ╚══════╝",
};
#define ISOLDE_RULE   "────────────────────────────────────────────────────────────"
#define ISOLDE_DOT    " · "
#define ISOLDE_TIMES  " × "
#define ISOLDE_BULLET "▸ "
#define ISOLDE_TREE_FIRST "─┬─ "
#define ISOLDE_TREE_MID   " ├─ "
#define ISOLDE_TREE_LAST  " └─ "
#define ISOLDE_TREE_ONLY  "─── "
#else
#define ISOLDE_LOGO_HEIGHT 6
static const char *const isolde_logo_ascii[ISOLDE_LOGO_HEIGHT] = {
    " ___ ____   ___  _     ____  _____ ",
    "|_ _/ ___| / _ \\| |   |  _ \\| ____|",
    " | |\\___ \\| | | | |   | | | |  _|  ",
    " | | ___) | |_| | |___| |_| | |___ ",
    "|___|____/ \\___/|_____|____/|_____|",
    "",
};
#define ISOLDE_RULE   "------------------------------------------------------------"
#define ISOLDE_DOT    " - "
#define ISOLDE_TIMES  " x "
#define ISOLDE_BULLET "> "
#define ISOLDE_TREE_FIRST "-+- "
#define ISOLDE_TREE_MID   " |- "
#define ISOLDE_TREE_LAST  " `- "
#define ISOLDE_TREE_ONLY  "--- "
#endif

#define ISOLDE_TAGLINE "R I S C - V   A U T O M O T I V E   D E M O N S T R A T O R"
#define ISOLDE_MOTTO   "Open-source DSP pipeline"
#define ISOLDE_URL     "https://github.com/ISOLDE-Project"

#endif /* ISOLDE_LOGO_H */