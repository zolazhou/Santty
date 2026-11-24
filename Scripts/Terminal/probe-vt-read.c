// Independent client of the ORIGINAL precompiled VT archive, not a core build.
// Uses format_buf (not the Swift boundary's bounded streaming writer).
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void feed(GhosttyTerminal t, const char *s) {
    ghostty_terminal_vt_write(t, (const unsigned char *)s, strlen(s));
}
static char *copy(GhosttyTerminal t, bool unwrap) {
    GhosttyFormatter f = NULL;
    assert(ghostty_formatter_terminal_new(NULL, &f, t) == GHOSTTY_SUCCESS);
    assert(ghostty_formatter_set(f, GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap) == GHOSTTY_SUCCESS);
    size_t n = 0;
    GhosttyResult r = ghostty_formatter_format_buf(f, NULL, 0, &n);
    assert(r == GHOSTTY_SUCCESS || r == GHOSTTY_OUT_OF_SPACE);
    char *b = calloc(n + 1, 1); assert(b);
    assert(ghostty_formatter_format_buf(f, (unsigned char *)b, n, &n) == GHOSTTY_SUCCESS);
    ghostty_formatter_free(f);
    return b;
}
static void expect(GhosttyTerminal t, const char *label, const char *expected, bool unwrap) {
    char *b = copy(t, unwrap);
    if (strcmp(b, expected) != 0) { fprintf(stderr, "%s mismatch: [%s]\n", label, b); abort(); }
    printf("%s: exact_bytes=%zu\n", label, strlen(b)); free(b);
}
int main(void) {
    GhosttyTerminal t = NULL;
    assert(ghostty_terminal_new(NULL, &t, 4, 2) == GHOSTTY_SUCCESS);
    size_t bytes = 8 * 1024 * 1024;
    assert(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes) == GHOSTTY_SUCCESS);
    feed(t, "old0\r\nold1\r\nold2\r\nold3");
    expect(t, "full-history", "old0\nold1\nold2\nold3", true);
    feed(t, "\033cABCDEFGHI\r\n\r\nQ  ");
    expect(t, "logical-lines", "ABCDEFGHI\n\nQ", true);
    expect(t, "physical-lines-control", "ABCD\nEFGH\nI\n\nQ", false);
    feed(t, "\033cA\033[8mSECRET\033[0mZ");
    expect(t, "concealed-plaintext-not-AX", "ASECRETZ", true);
    feed(t, "\033[?1049h\033[HALT"); expect(t, "alternate-only", "ALT", true);
    feed(t, "\033[?1049l"); expect(t, "primary-restored", "ASECRETZ", true);
    ghostty_terminal_free(t);

    assert(ghostty_terminal_new(NULL, &t, 20, 2) == GHOSTTY_SUCCESS);
    size_t lines = 10;
    assert(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines) == GHOSTTY_SUCCESS);
    for (int i = 0; i < 100; i++) { char b[32]; snprintf(b, sizeof b, "prune-%d\r\n", i); feed(t, b); }
    char *small = copy(t, true);
    GhosttyTerminalScrollbar before = {0};
    assert(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before) == GHOSTTY_SUCCESS);
    // Keep the original failed premise visible: 10 is NOT a strict row cap.
    assert(strstr(small, "prune-0\n") && strstr(small, "prune-99"));
    printf("ORIGINAL-100-ROW-CONTROL: configured_lines=10 actual_rows=%llu first_row_retained=1\n", (unsigned long long)before.total);
    free(small);
    for (int i = 100; i < 10000; i++) { char b[32]; snprintf(b, sizeof b, "prune-%d\r\n", i); feed(t, b); }
    assert(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &before) == GHOSTTY_SUCCESS);
    char *pruned = copy(t, true);
    GhosttyTerminalScrollbar after = {0};
    assert(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &after) == GHOSTTY_SUCCESS);
    assert(!strstr(pruned, "prune-0\n") && strstr(pruned, "prune-9999"));
    assert(before.total == after.total && before.offset == after.offset && before.len == after.len);
    printf("page-pruned: actual_rows=%llu no_stale_first_row=1 viewport_unchanged=1\n", (unsigned long long)after.total);
    free(pruned); ghostty_terminal_free(t);
}
