// Independent client of the original precompiled VT archive. No core build.
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void feed(GhosttyTerminal t, const char *s) { ghostty_terminal_vt_write(t, (const unsigned char *)s, strlen(s)); }
static GhosttyPoint point(unsigned x, unsigned y) {
    GhosttyPoint p = {.tag=GHOSTTY_POINT_TAG_SCREEN};
    p.value.coordinate.x = (uint16_t)x; p.value.coordinate.y = y; return p;
}
static GhosttyGridRef ref(GhosttyTerminal t, unsigned x, unsigned y) {
    GhosttyGridRef r = {0}; assert(ghostty_terminal_grid_ref(t, point(x,y), &r) == GHOSTTY_SUCCESS); return r;
}
static void expect_copy(GhosttyTerminal t, const char *expected) {
    GhosttySelection s = {0}; GhosttyFormatter f = NULL;
    assert(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SELECTION,&s)==GHOSTTY_SUCCESS);
    assert(ghostty_formatter_terminal_new(NULL,&f,t)==GHOSTTY_SUCCESS);
    bool yes=true;
    assert(ghostty_formatter_set(f,GHOSTTY_FORMATTER_OPT_UNWRAP,&yes)==GHOSTTY_SUCCESS);
    assert(ghostty_formatter_set(f,GHOSTTY_FORMATTER_OPT_SELECTION,&s)==GHOSTTY_SUCCESS);
    size_t n=0; GhosttyResult result=ghostty_formatter_format_buf(f,NULL,0,&n);
    assert(result==GHOSTTY_SUCCESS || result==GHOSTTY_OUT_OF_SPACE);
    char *b=calloc(n+1,1); assert(b);
    assert(ghostty_formatter_format_buf(f,(unsigned char*)b,n,&n)==GHOSTTY_SUCCESS);
    assert(strcmp(b,expected)==0); free(b); ghostty_formatter_free(f);
}
int main(void) {
    GhosttyTerminal t=NULL;
    assert(ghostty_terminal_new(NULL,&t,8,2)==GHOSTTY_SUCCESS);
    feed(t,"a界🙂e\xcc\x81");
    GhosttyGridRef r=ref(t,1,0); GhosttyCell c=0; GhosttyCellWide wide=GHOSTTY_CELL_WIDE_NARROW;
    assert(ghostty_grid_ref_cell(&r,&c)==GHOSTTY_SUCCESS);
    assert(ghostty_cell_get(c,GHOSTTY_CELL_DATA_WIDE,&wide)==GHOSTTY_SUCCESS && wide==GHOSTTY_CELL_WIDE_WIDE);
    r=ref(t,2,0); assert(ghostty_grid_ref_cell(&r,&c)==GHOSTTY_SUCCESS);
    assert(ghostty_cell_get(c,GHOSTTY_CELL_DATA_WIDE,&wide)==GHOSTTY_SUCCESS && wide==GHOSTTY_CELL_WIDE_SPACER_TAIL);
    uint32_t scalars[8]={0}; size_t count=0; r=ref(t,5,0);
    assert(ghostty_grid_ref_graphemes(&r,scalars,8,&count)==GHOSTTY_SUCCESS);
    assert(count==2 && scalars[0]=='e' && scalars[1]==0x301);
    puts("VT cells: wide head=2, tail=0, combining scalars=[0065,0301]");
    ghostty_terminal_free(t);

    assert(ghostty_terminal_new(NULL,&t,10,2)==GHOSTTY_SUCCESS);
    feed(t,"ABCDEFGHIJKLMNO");
    GhosttyTrackedGridRef tracked=NULL;
    assert(ghostty_terminal_grid_ref_track(t,point(7,0),&tracked)==GHOSTTY_SUCCESS);
    assert(ghostty_terminal_resize(t,5,2,8,16)==GHOSTTY_SUCCESS);
    GhosttyPointCoordinate coordinate={0};
    assert(ghostty_tracked_grid_ref_point(tracked,GHOSTTY_POINT_TAG_SCREEN,&coordinate)==GHOSTTY_SUCCESS);
    assert(coordinate.x==2 && coordinate.y==1);
    assert(ghostty_tracked_grid_ref_snapshot(tracked,&r)==GHOSTTY_SUCCESS);
    assert(ghostty_grid_ref_graphemes(&r,scalars,8,&count)==GHOSTTY_SUCCESS && count==1 && scalars[0]=='H');
    puts("VT tracked H: (7,0) -> (2,1) after width 10 -> 5");
    ghostty_tracked_grid_ref_free(tracked); ghostty_terminal_free(t);

    assert(ghostty_terminal_new(NULL,&t,4,2)==GHOSTTY_SUCCESS);
    feed(t,"abcdEFGH");
    GhosttySelection selection={0}; selection.start=ref(t,0,0); selection.end=ref(t,3,0);
    assert(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SELECTION,&selection)==GHOSTTY_SUCCESS);
    expect_copy(t,"abcd");
    selection.start=ref(t,0,0); selection.end=ref(t,3,1);
    assert(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SELECTION,&selection)==GHOSTTY_SUCCESS);
    expect_copy(t,"abcdEFGH");
    puts("VT selection: endpoints inclusive, physical line selection + logical unwrap copy");
    assert(ghostty_terminal_grid_ref_track(t,point(0,0),&tracked)==GHOSTTY_SUCCESS);
    feed(t,"\033[?1049h\033[HALT\033[?1049l");
    GhosttyResult restored=ghostty_tracked_grid_ref_point(tracked,GHOSTTY_POINT_TAG_SCREEN,&coordinate);
    GhosttyResult selected=ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SELECTION,&selection);
    printf("same-write screen roundtrip: primary_ref_valid=%d selection_present=%d\n",restored==GHOSTTY_SUCCESS,selected==GHOSTTY_SUCCESS);
    ghostty_tracked_grid_ref_free(tracked); ghostty_terminal_free(t);

    assert(ghostty_terminal_new(NULL,&t,80,15)==GHOSTTY_SUCCESS);
    size_t bytes=8*1024*1024, lines=2000;
    assert(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,&bytes)==GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,&lines)==GHOSTTY_SUCCESS);
    for (int i=0;i<4000;i++) { char b[40]; snprintf(b,sizeof b,"history-%04d\r\n",i); feed(t,b); }
    GhosttyTerminalScrollbar before={0},after={0};
    assert(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&before)==GHOSTTY_SUCCESS);
    unsigned oldest=4001-(unsigned)before.total;
    GhosttyTrackedGridRef original=NULL,late=NULL;
    assert(2954>=oldest);
    assert(ghostty_terminal_grid_ref_track(t,point(0,2954-oldest),&original)==GHOSTTY_SUCCESS);
    assert(ghostty_terminal_grid_ref_track(t,point(0,3985-oldest),&late)==GHOSTTY_SUCCESS);
    for (int i=4000;i<4400;i++) { char b[40]; snprintf(b,sizeof b,"history-%04d\r\n",i); feed(t,b); }
    assert(ghostty_terminal_get(t,GHOSTTY_TERMINAL_DATA_SCROLLBAR,&after)==GHOSTTY_SUCCESS);
    GhosttyResult old_result=ghostty_tracked_grid_ref_point(original,GHOSTTY_POINT_TAG_SCREEN,&coordinate);
    assert(old_result==GHOSTTY_NO_VALUE);
    assert(ghostty_tracked_grid_ref_point(late,GHOSTTY_POINT_TAG_SCREEN,&coordinate)==GHOSTTY_SUCCESS);
    printf("ORIGINAL pointer premise: seed=2954 lost=1; retained seed=3985 new_row=%u; oldest=%u -> %u\n",coordinate.y,oldest,4401-(unsigned)after.total);
    ghostty_tracked_grid_ref_free(original); ghostty_tracked_grid_ref_free(late); ghostty_terminal_free(t);
}
