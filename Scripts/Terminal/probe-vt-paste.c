// Diagnostic client of the original archive; never rebuilds the core.
#include <ghostty/vt.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static unsigned char output[4096];
static size_t length;
static void write_pty(GhosttyTerminal t, void *u, const uint8_t *p, size_t n) {
    (void)t; (void)u; assert(length+n <= sizeof output);
    memcpy(output+length,p,n); length+=n;
}
static bool read_text(void *u, GhosttyString mime, GhosttyWriter w) {
    const char *s=u;
    assert(mime.len==10 && memcmp(mime.ptr,"text/plain",10)==0);
    return w.write(w.userdata,(const uint8_t *)s,strlen(s));
}
static void expect(GhosttyTerminal t, const char *label, const char *text,
                   bool unsafe, GhosttyResult result, const char *expected) {
    GhosttyString mime={.ptr=(const uint8_t *)"text/plain",.len=10};
    GhosttyPaste p={.size=sizeof p,.source=GHOSTTY_PASTE_SOURCE_TEXT,
        .location=GHOSTTY_CLIPBOARD_LOCATION_STANDARD,.allow_unsafe=unsafe,
        .mimes=&mime,.mimes_len=1,.reader={.read=read_text,.userdata=(void *)text}};
    length=0; bool pasted=false;
    GhosttyResult r=ghostty_terminal_paste(t,&p,&pasted);
    if(r!=result || length!=strlen(expected) || memcmp(output,expected,length)) {
        fprintf(stderr,"%s: result=%d expected=%d bytes=%zu pasted=%d hex=",label,r,result,length,pasted);
        for(size_t i=0;i<length;i++) fprintf(stderr,"%02x",output[i]);
        fputc('\n',stderr); assert(false);
    }
    printf("%s: result=%d exact_bytes=%zu pasted=%d\n",label,r,length,pasted);
}
int main(void) {
    GhosttyTerminal t=NULL;
    assert(ghostty_terminal_new(NULL,&t,80,24)==GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(t,GHOSTTY_TERMINAL_OPT_WRITE_PTY,(const void *)write_pty)==GHOSTTY_SUCCESS);
    expect(t,"safe-no-grant","hello",false,GHOSTTY_SUCCESS,"hello");
    expect(t,"legacy-newline-refused","a\nb",false,GHOSTTY_REJECTED,"");
    expect(t,"legacy-confirmed-core-CR","a\nb",true,GHOSTTY_SUCCESS,"a\rb");
    expect(t,"original-un-normalized-CRLF","a\r\nb",true,GHOSTTY_SUCCESS,"a\r\rb");
    const char *mode="\033[?2004h";
    ghostty_terminal_vt_write(t,(const uint8_t *)mode,strlen(mode));
    expect(t,"bracketed-newline-no-dialog","a\r\nb",false,GHOSTTY_SUCCESS,"\033[200~a\r\nb\033[201~");
    expect(t,"bracket-terminator-refused","a\033[201~b",false,GHOSTTY_REJECTED,"");
    expect(t,"confirmed-terminator-sanitized","a\033[201~b",true,GHOSTTY_SUCCESS,"\033[200~a [201~b\033[201~");
    ghostty_terminal_free(t);
}
