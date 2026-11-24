// Independently compiled client of the frozen VT archive, not a core rebuild.
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int resets;
static void reset_cb(GhosttyTerminal terminal, void *userdata) {
    (void)terminal; (void)userdata; resets++;
}
static void require(int ok, const char *stage) {
    if (!ok) { fprintf(stderr, "VT settings probe failed: %s\n", stage); exit(1); }
}
static void feed(GhosttyTerminal terminal, const char *bytes) {
    ghostty_terminal_vt_write(terminal, (const unsigned char *)bytes, strlen(bytes));
}
static void colors(GhosttyTerminal terminal, unsigned char r, unsigned char g, unsigned char b) {
    GhosttyColorRgb fg, palette[256];
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &fg) == GHOSTTY_SUCCESS, "get fg");
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, palette) == GHOSTTY_SUCCESS, "get palette");
    require(fg.r == r && fg.g == g && fg.b == b, "foreground authority");
    require(palette[1].r == r && palette[1].g == g && palette[1].b == b, "palette authority");
}
int main(void) {
    GhosttyTerminal terminal;
    require(ghostty_terminal_new(NULL, &terminal, 10, 2) == GHOSTTY_SUCCESS, "terminal_new");
    require(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESET, (const void *)reset_cb) == GHOSTTY_SUCCESS, "reset callback");
    GhosttyColorRgb palette[256], color = {255, 0, 0};
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, palette) == GHOSTTY_SUCCESS, "builtin palette");
    palette[1] = color;
    require(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &color) == GHOSTTY_SUCCESS, "fg default A");
    require(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette) == GHOSTTY_SUCCESS, "palette default A");
    feed(terminal, "\033]2;title\007\033]7;file://remote.invalid/a%20b\007\033]10;#00ff00\007\033]4;1;#00ff00\007");
    colors(terminal, 0, 255, 0);
    color = (GhosttyColorRgb){0, 0, 255}; palette[1] = color;
    require(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &color) == GHOSTTY_SUCCESS, "fg default B");
    require(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette) == GHOSTTY_SUCCESS, "palette default B");
    colors(terminal, 0, 255, 0);
    feed(terminal, "\033]110\007\033]104;1\007");
    colors(terminal, 0, 0, 255);
    GhosttyString title, pwd;
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &pwd) == GHOSTTY_SUCCESS, "raw pwd");
    const char *expected = "file://remote.invalid/a%20b";
    require(pwd.len == strlen(expected) && memcmp(pwd.ptr, expected, pwd.len) == 0, "raw URI is not filesystem-decoded");
    feed(terminal, "\033c");
    require(resets == 1, "RIS callback");
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS && title.len == 0, "RIS clears title");
    ghostty_terminal_reset(terminal);
    require(resets == 1, "host reset DOES NOT invoke RESET callback on this pin");
    colors(terminal, 0, 0, 255);
    size_t length = 16 * 1024 + 1;
    unsigned char *large = malloc(length + 5);
    require(large != NULL, "owned title allocation");
    memcpy(large, "\033]2;", 4); memset(large + 4, 'x', length); large[length + 4] = '\007';
    ghostty_terminal_vt_write(terminal, large, length + 5);
    free(large);
    require(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &title) == GHOSTTY_SUCCESS, "large title");
    require(title.len == 0, "pinned OSC parser rejects this oversized title before the host boundary");
    printf("VT defaults: OSC green survives new blue defaults; OSC reset/RIS restore blue.\n");
    printf("Metadata: raw URI preserved; RIS reset_events=1, explicit host reset_events=1; oversized_OSC_title_stored=%zu (core refusal precedes host cap).\n", title.len);
    ghostty_terminal_free(terminal);
    return 0;
}
