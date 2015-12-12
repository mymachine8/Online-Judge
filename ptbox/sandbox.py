import os
import time
import resource
import gc
from signal import *
import threading
from platform import architecture

from ._ptrace import *
from ptbox import syscalls
from ptbox.syscalls import by_name


def _find_exe(path):
    if os.path.isabs(path):
        return path
    if os.sep in path:
        return os.path.abspath(path)
    for dir in os.environ.get('PATH', os.defpath).split(os.pathsep):
        p = os.path.join(dir, path)
        if os.access(p, os.X_OK):
            return p
    raise OSError()


class SecurePopen(object):
    def __init__(self, args, debugger, time, memory):
        self._args = args
        self._child = _find_exe(self._args[0])
        self._debugger = debugger
        self._time = time
        self._memory = memory
        self._returncode = None
        self._tle = False
        self._pid = None
        self._rusage = None
        self._start = None
        self._duration = None
        self._r_duration = None

        self._stdin_, self._stdin = os.pipe()
        self._stdout, self._stdout_ = os.pipe()
        self._stderr, self._stderr_ = os.pipe()
        self.stdin = os.fdopen(self._stdin, 'w')
        self.stdout = os.fdopen(self._stdout, 'r')
        self.stderr = os.fdopen(self._stderr, 'r')

        self._started = threading.Event()
        self._died = threading.Event()
        self._worker = threading.Thread(target=self.__spawn_execute)
        self._worker.start()
        if time:
            # Spawn thread to kill process after it times out
            self._shocker = threading.Thread(target=self.__shocker)
            self._shocker.start()

    @property
    def returncode(self):
        """
            The return code of the process, or None if the process has not exited yet.
        """
        return self._returncode

    def wait(self):
        """
            Waits for the process.
        """
        self._died.wait()
        return self._returncode

    def poll(self):
        return self._returncode

    @property
    def max_memory(self):
        """
            The max memory usage of the process, after the exit of the process.
        """
        # TODO: this can be done for when process hasn't exited yet
        if self._rusage is not None:
            return self._rusage.ru_maxrss

    @property
    def execution_time(self):
        """
            The total execution time of the process, after the exit of the process.
        """
        # TODO: this can be done for when process hasn't exited yet
        return self._duration

    @property
    def r_execution_time(self):
        return self._r_duration

    @property
    def mle(self):
        """
            Whether or not the process' memory limit was exceeded.
        """
        if self._memory is None:
            return False
        if self._rusage is not None:
            return self._rusage.ru_maxrss > self._memory

    @property
    def tle(self):
        """
            Whether or not the process' time limit was exceeded.
        """
        return self._tle

    @property
    def bitness(self):
        """
            The bitness of the process; an integer: either 32 or 64.
        """
        return int(architecture(self._child)[0][:2])

    def __shocker(self):
        self._started.wait()

        while self.returncode is None:
            duration = time.time() - self._start - (self._debugger is not None and self._debugger._tt)
            # 5 second grace for system load.
            if duration > self._time + 5:
                os.kill(self._pid, SIGKILL)
                self._tle = True
                break
            time.sleep(1)

    def kill(self):
        try:
            os.kill(self._pid, SIGKILL)
        except OSError:
            import traceback
            traceback.print_exc()

    def __spawn_execute(self):
        child_args = self._args

        gc_enabled = gc.isenabled()
        try:
            gc.disable()
            pid = os.fork()
        except:
            if gc_enabled:
                gc.enable()
            raise
        if not pid:
            if self._memory:
                resource.setrlimit(resource.RLIMIT_AS, (self._memory * 1024 + 16 * 1024 * 1024,) * 2)
            os.dup2(self._stdin_, 0)
            os.dup2(self._stdout_, 1)
            os.dup2(self._stderr_, 2)
            # Close all file descriptors that are not standard
            os.closerange(3, os.sysconf("SC_OPEN_MAX"))
            if self._debugger:
                ptrace(PTRACE_TRACEME, 0, None, None)
                os.kill(os.getpid(), SIGSTOP)
            # Replace current process with the child process
            # This call does not return
            os.execv(self._child, child_args)
            # Unless it does, of course, in which case you're screwed
            # We don't cover this in the warranty
            # When you reach here, you are screwed
            # As much as being handed control of a MySQL server without
            # ANY SQL knowledge or docs. ENJOY.
            os._exit(3306)
        else:
            if gc_enabled:
                gc.enable()
            try:
                status = None
                self._pid = pid

                os.close(self._stdin_)
                os.close(self._stdout_)
                os.close(self._stderr_)

                _debugger = self._debugger
                if _debugger:
                    _debugger.pid = pid
                    # Depending on the bitness, import a different ptrace
                    # Registers change depending on bitness, as do syscall ids
                    bitness = self.bitness
                    if bitness == 64:
                        import _ptrace64 as _ptrace
                    else:
                        import _ptrace32 as _ptrace
                    # Define the shells for reading syscall arguments in the debugger
                    _debugger.arg0 = lambda: _ptrace.arg0(pid)
                    _debugger.arg1 = lambda: _ptrace.arg1(pid)
                    _debugger.arg2 = lambda: _ptrace.arg2(pid)
                    _debugger.arg3 = lambda: _ptrace.arg3(pid)
                    _debugger.arg4 = lambda: _ptrace.arg4(pid)
                    _debugger.arg5 = lambda: _ptrace.arg5(pid)
                    # Reverse syscall ids
                    wrapped_ids = [None] * len(syscalls.translator)
                    for k, x in syscalls.translator.iteritems():
                        call = x[bitness == 64]
                        if call is not None:
                            wrapped_ids[call] = k

                    # Utility method for getting syscall number for call
                    get_syscall_number = lambda: wrapped_ids[_ptrace.get_syscall_number(pid)]
                    _debugger.get_syscall_number = get_syscall_number

                    # Let the debugger define its proxies
                    syscall_proxies = [None] * len(syscalls.by_id)
                    for call_id, handler in self._debugger.get_handlers().iteritems():
                        syscall_proxies[call_id] = handler

                    self._start = time.time()
                    self._started.set()
                    if _debugger:
                        _debugger._tt = 0
                        _debugger._st = 0

                    in_syscall = False
                    while True:
                        _, status, self._rusage = os.wait4(pid, 0)
                        if _debugger:
                            _debugger._st = time.time()

                        if os.WIFEXITED(status):
                            break

                        if os.WIFSIGNALED(status):
                            break

                        if os.WSTOPSIG(status) == SIGTRAP:
                            in_syscall = not in_syscall
                            if not in_syscall:
                                call = get_syscall_number()

                                handler = syscall_proxies[call]
                                if handler is not None:
                                    if not handler():
                                        os.kill(pid, SIGKILL)
                                        print "Killed on", call, syscalls.by_id[call]
                                    # The @*syscall decorators resume the syscall
                                    continue
                                else:
                                    # Our method is not proxied, so is assumed to be disallowed
                                    # TODO: perhaps add option to cancel the syscall instead?
                                    raise AssertionError("%d (%s)" % (call, syscalls.by_id[call]))
                        # Not handled by a decorator: resume syscall

                        ptrace(PTRACE_SYSCALL, pid, None, None)
                        if _debugger:
                            _debugger._tt += time.time() - _debugger._st
                else:
                    self._start = time.time()
                    self._started.set()
                    _, status, self._rusage = os.wait4(pid, 0)
                self._r_duration = time.time() - self._start
                self._duration = self._r_duration - (_debugger._tt if _debugger else 0)
                # CPU time, __shocker uses clock time in case a malicious user sleeps or what not.
                #self._duration = self._rusage.ru_utime
                if self._time and self._duration > self._time:
                    self._tle = True
                ret = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
                self._returncode = ret
                self._died.set()
            finally:
                if self.returncode is None:
                    os.kill(self._pid, SIGKILL)


def debug(args, debugger):
    return execute(args, debugger)


def execute(args, debugger=None, time=None, memory=None):
    return SecurePopen(args, debugger, time, memory)
