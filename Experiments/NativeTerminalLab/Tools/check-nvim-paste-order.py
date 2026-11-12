#!/usr/bin/env python3
"""Diagnostic, not a success-by-timeout test. Uses only owned PTYs/processes.

Reports nvim command-mode paste+CR ordering with no Santty/Herdr/VT adapter.
Burst failures are observations, not test passes; the gated control must work.
No user terminal, clipboard, configuration, input source or core is touched.
"""
import os, pty, subprocess, tempfile, pathlib, time, select, termios, fcntl, struct, shutil, json
nvim=shutil.which('nvim')
if not nvim:
    raise SystemExit('nvim is required')

def run(gated):
    with tempfile.TemporaryDirectory(prefix='santty-nvim-proof-') as tmp:
        root=pathlib.Path(tmp)
        paths={k:root/k for k in ['ready','entered','trace','leave','result']}
        def q(p):return "'"+str(p).replace("'","''")+"'"
        commands=[f"autocmd VimEnter * call writefile(['ready'],{q(paths['ready'])})",
            f"autocmd CmdlineEnter : call timer_start(0,{{-> writefile(['entered'],{q(paths['entered'])})}})",
            f"autocmd CmdlineChanged : call writefile([getcmdline()],{q(paths['trace'])})",
            f"autocmd CmdlineLeave : call writefile([getcmdline()],{q(paths['leave'])})"]
        argv=[nvim,'--clean','-n','-i','NONE']
        for cmd in commands:argv+=['--cmd',cmd]
        master,slave=pty.openpty()
        fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,120,0,0))
        env={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','HOME':tmp,'TERM':'xterm-256color','LANG':'en_US.UTF-8',
            'XDG_CONFIG_HOME':tmp+'/config','XDG_STATE_HOME':tmp+'/state','XDG_DATA_HOME':tmp+'/data','XDG_CACHE_HOME':tmp+'/cache','NVIM_LOG_FILE':tmp+'/log'}
        proc=subprocess.Popen(argv,stdin=slave,stdout=slave,stderr=slave,env=env,close_fds=True,start_new_session=True)
        os.close(slave); output=bytearray()
        def readfile(k):
            try:return paths[k].read_text()
            except FileNotFoundError:return None
        def wait(cond, seconds=3):
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                if cond():return True
                if select.select([master],[],[],.005)[0]:
                    try:output.extend(os.read(master,65536))
                    except OSError:break
            return cond()
        try:
            assert wait(lambda: paths['ready'].exists() and b'\x1b[?2004h' in output), 'not ready'
            os.write(master,b':')
            assert wait(lambda: paths['entered'].exists()), 'no cmdline'
            command=f"call writefile(['ok'],{q(paths['result'])})"
            paste=b'\x1b[200~'+command.encode()+b'\x1b[201~'
            if gated:
                os.write(master,paste)
                assert wait(lambda:readfile('trace')==command+'\n'), 'paste not applied'
                os.write(master,b'\r')
            else:os.write(master,paste+b'\r')
            success=wait(lambda:paths['result'].exists(), .6)
            if gated and not success:
                raise RuntimeError('The gated control did not execute its command')
            return {'mode':'gated' if gated else 'burst','executed':success,'empty_command_left':readfile('leave')=='\n','trace_applied':readfile('trace')==command+'\n'}
        finally:
            proc.terminate()
            try:proc.wait(timeout=2)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
            os.close(master)

if __name__ == '__main__':
    for gated in [False,True]:
        for _ in range(3):print(json.dumps(run(gated)))
