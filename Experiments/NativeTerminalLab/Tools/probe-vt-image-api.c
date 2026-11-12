// Minimal client of the pinned precompiled VT. No Santty adapter, renderer,
// file transport, OS clipboard, or user terminal. This does not build the core.
#include <ghostty/vt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void checked(GhosttyResult result) {
    if (result != GHOSTTY_SUCCESS) {
        fprintf(stderr, "VT API failure: %d\n", (int)result);
        exit(1);
    }
}

static int count_images(GhosttyRenderState state, GhosttyRenderStateImageIterator iter, int *zero_source) {
    checked(ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &iter));
    int count = 0;
    *zero_source = 0;
    while (ghostty_render_state_image_iterator_next(iter)) {
        uint32_t w = 0, h = 0;
        checked(ghostty_render_state_image_get(iter, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, &w));
        checked(ghostty_render_state_image_get(iter, GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, &h));
        if (w == 0 || h == 0) ++*zero_source;
        ++count;
    }
    return count;
}

static int probe(const char *name, int side, int virtual_placement, int cursor_stationary, int flags) {
    GhosttyTerminal terminal = NULL;
    GhosttyRenderState state = NULL;
    GhosttyRenderStateImageIterator iter = NULL;
    checked(ghostty_terminal_new(NULL, &terminal, 12, 6));
    checked(ghostty_terminal_resize(terminal, 12, 6, 8, 8));
    checked(ghostty_render_state_new(NULL, &state));
    checked(ghostty_render_state_image_iterator_new(NULL, &iter));
    if (flags & 1) {
        GhosttyRenderStateOverscan overscan = { .above = 1, .below = 3 };
        checked(ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, &overscan));
    }
    if (flags & 2) {
        checked(ghostty_render_state_update(state, terminal));
        checked(ghostty_render_state_clean(state));
    }
    char pixels[4 * 16 + 1] = "";
    for (int i = 0; i < side * side; ++i) strcat(pixels, "/wAA");
    char wire[512];
    int length = snprintf(wire, sizeof(wire),
        "\033_Ga=T,U=%d,f=24,i=7,s=%d,v=%d,c=4,r=4,C=%d,q=2;%s\033\\",
        virtual_placement, side, side, cursor_stationary, pixels);
    if (length < 0 || (size_t)length >= sizeof(wire)) exit(1);
    ghostty_terminal_vt_write(terminal, (const uint8_t *)wire, (size_t)length);
    if (virtual_placement) {
        // U+10EEEE, row=0/column=0 diacritics; foreground palette index 7.
        const char placeholder[] = "\033[38;5;7m\xF4\x8E\xBB\xAE\xCC\x85\xCC\x85";
        ghostty_terminal_vt_write(terminal, (const uint8_t *)placeholder, sizeof(placeholder) - 1);
    }
    if (flags & 4) {
        GhosttyTerminalScrollViewport scroll = { .tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW, .value.row = 0 };
        checked(ghostty_terminal_scroll_viewport(terminal, scroll));
    }
    checked(ghostty_render_state_update(state, terminal));
    int bad_before = 0, bad_after = 0;
    int before = count_images(state, iter, &bad_before);
    checked(ghostty_render_state_clean(state));
    int after = count_images(state, iter, &bad_after);
    GhosttyKittyGraphics storage = NULL;
    checked(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(storage, 7);
    if (!image) exit(1);
    uint32_t width = 0;
    checked(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &width));
    printf("%s: stored_width=%u placements=%d zero_source_crop=%d after_clean=%d\n", name, width, before, bad_before, after);
    if (before != after || bad_before != bad_after) exit(1);
    ghostty_render_state_image_iterator_free(iter);
    ghostty_render_state_free(state);
    ghostty_terminal_free(terminal);
    return before - bad_before;
}

static int stored_state(GhosttyTerminal terminal, const char *name) {
    GhosttyKittyGraphics storage = NULL;
    checked(ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage));
    GhosttyKittyGraphicsImage image = ghostty_kitty_graphics_image(storage, 7);
    uint64_t generation = 0;
    GhosttyString pixels = {0};
    GhosttyResult result = GHOSTTY_NO_VALUE;
    if (image) {
        checked(ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, &generation));
        result = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels);
    }
    printf("%s: stored=%d generation=%llu pixels_result=%d\n", name, image != NULL,
        (unsigned long long)generation, (int)result);
    return result == GHOSTTY_SUCCESS;
}

static void replacement_probe(void) {
    GhosttyTerminal terminal = NULL;
    checked(ghostty_terminal_new(NULL, &terminal, 12, 6));
    checked(ghostty_terminal_resize(terminal, 12, 6, 8, 16));
    const char *steps[] = {
        "\033_Ga=T,f=24,s=1,v=1,i=7,p=3,c=2,r=2,C=1;/wAA\033\\",
        "\033[H\033_Ga=T,f=32,s=1,v=1,i=7,p=3,c=2,r=2,C=1,m=1;/wAA\033\\",
        "\033_Gm=0;/w==\033\\",
        "\033_Ga=T,f=32,s=1,v=1,i=7;/wAA\033\\",
    };
    const char *names[] = {"replacement_initial", "replacement_incomplete", "replacement_complete", "replacement_invalid"};
    int actual[4];
    for (int i = 0; i < 4; ++i) {
        ghostty_terminal_vt_write(terminal, (const uint8_t *)steps[i], strlen(steps[i]));
        actual[i] = stored_state(terminal, names[i]);
    }
    if (!actual[0] || actual[1] || !actual[2] || actual[3]) {
        fputs("Replacement storage behavior changed; revisit the pinned VT ledger.\n", stderr);
        exit(1);
    }
    puts("PINNED BEHAVIOR: same-ID transmission retires the old image before completion/validation; no atomic replacement promise.");
    ghostty_terminal_free(terminal);
}

int main(void) {
    replacement_probe();
    if (probe("fixed_1x1_control", 1, 0, 1, 0) != 1) return 1;
    if (probe("virtual_4x4_control", 4, 1, 1, 0) != 1) return 1;
    int small = probe("virtual_upscaled_1x1_first_slice", 1, 1, 1, 0);
    probe("virtual_upscaled_1x1_cursor_default", 1, 1, 0, 0);
    probe("virtual_upscaled_1x1_overscan", 1, 1, 0, 1);
    probe("virtual_upscaled_1x1_prior_capture", 1, 1, 0, 2);
    probe("virtual_upscaled_1x1_scroll", 1, 1, 0, 4);
    probe("virtual_upscaled_1x1_combined", 1, 1, 0, 7);
    if (small == 0) {
        puts("KNOWN LIMITATION: pinned VT reports a zero source crop for the first upscaled 1x1 virtual slice; not adapter-fixed or certified.");
    } else {
        puts("The small virtual slice is now present: revisit the pinned-engine limitation ledger.");
    }
    return 0; // positive API controls passed; NOT a declaration of full compatibility
}
