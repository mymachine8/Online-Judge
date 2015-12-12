# distutils: language = c++
# distutils: sources = ptdebug.cpp, ptdebug32.cpp, ptdebug64.cpp, ptproc.cpp
from libc.stdio cimport FILE, fopen, fclose, fgets, sprintf
from libc.stdlib cimport atoi, malloc, free, strtoul
from libc.string cimport strncmp, strlen
from libc.signal cimport SIGSTOP
from posix.unistd cimport close, dup2, getpid, execve, chdir
from posix.resource cimport setrlimit, rlimit, rusage, \
    RLIMIT_AS, RLIMIT_DATA, RLIMIT_CPU, RLIMIT_STACK, RLIMIT_CORE, RLIM_INFINITY
from posix.signal cimport kill
from posix.types cimport pid_t

cdef extern from 'ptbox.h' nogil:
    ctypedef int (*pt_handler_callback)(void *context, int syscall)
    ctypedef void (*pt_syscall_return_callback)(void *context, int syscall)
    ctypedef int (*pt_fork_handler)(void *context)
    ctypedef int (*pt_event_callback)(void *context, int event, unsigned long param)

    cdef cppclass pt_debugger:
        int syscall()
        void syscall(int)
        long result()
        void result(long)
        long arg0()
        long arg1()
        long arg2()
        long arg3()
        long arg4()
        long arg5()
        void arg0(long)
        void arg1(long)
        void arg2(long)
        void arg3(long)
        void arg4(long)
        void arg5(long)
        char *readstr(unsigned long)
        void freestr(char*)
        pid_t getpid()
        int getpid_syscall()
        void on_return(pt_syscall_return_callback callback, void *context)

    cdef cppclass pt_debugger32(pt_debugger):
        pass

    cdef cppclass pt_debugger64(pt_debugger):
        pass

    cdef cppclass pt_process:
        pt_process(pt_debugger *) except +
        void set_callback(pt_handler_callback callback, void* context)
        void set_event_proc(pt_event_callback, void *context)
        int set_handler(int syscall, int handler)
        int spawn(pt_fork_handler, void *context)
        int monitor()
        int getpid()
        double execution_time()
        const rusage *getrusage()

    cdef int MAX_SYSCALL

    cdef int PTBOX_EVENT_ATTACH
    cdef int PTBOX_EVENT_EXITING
    cdef int PTBOX_EVENT_EXITED
    cdef int PTBOX_EVENT_SIGNAL
    cdef int PTBOX_EVENT_PROTECTION

    cdef int PTBOX_EXIT_NORMAL
    cdef int PTBOX_EXIT_PROTECTION
    cdef int PTBOX_EXIT_SEGFAULT

cdef extern from 'dirent.h' nogil:
    ctypedef struct DIR:
        pass

    cdef struct dirent:
        char* d_name

    dirent* readdir(DIR* dirp)

cdef extern from 'sys/types.h' nogil:
    DIR *opendir(char *name)
    int closedir(DIR* dirp)

cdef extern from 'sys/ptrace.h' nogil:
    long ptrace(int, pid_t, void*, void*)
    cdef int PTRACE_TRACEME

cdef extern from 'sys/resource.h' nogil:
    cdef int RLIMIT_NPROC

cdef extern from 'signal.h' nogil:
    cdef int SIGXCPU

SYSCALL_COUNT = MAX_SYSCALL

cdef struct child_config:
    unsigned long memory # affects only sbrk heap
    unsigned long address_space # affects sbrk and mmap but not all address space is used memory
    unsigned int cpu_time # ask linus how this counts the CPU time because it SIGKILLs way before the real time limit
    int nproc
    char *file
    char *dir
    char **argv
    char **envp
    int stdin
    int stdout
    int stderr
    int max_fd
    int *fds

cdef int pt_child(void *context) nogil:
    cdef child_config *config = <child_config*> context
    cdef DIR *d = opendir('/proc/self/fd')
    cdef dirent *dir
    cdef rlimit limit
    cdef int i

    if config.address_space:
        limit.rlim_cur = limit.rlim_max = config.address_space
        setrlimit(RLIMIT_AS, &limit)

    if config.memory:
        limit.rlim_cur = limit.rlim_max = config.memory
        setrlimit(RLIMIT_DATA, &limit)

    if config.cpu_time:
        limit.rlim_cur = config.cpu_time
        limit.rlim_max = config.cpu_time + 1
        setrlimit(RLIMIT_CPU, &limit)

    if config.nproc >= 0:
        limit.rlim_cur = limit.rlim_max = config.nproc
        setrlimit(RLIMIT_NPROC, &limit)

    if config.dir[0]:
        chdir(config.dir)

    limit.rlim_cur = limit.rlim_max = RLIM_INFINITY
    setrlimit(RLIMIT_STACK, &limit)
    limit.rlim_cur = limit.rlim_max = 0
    setrlimit(RLIMIT_CORE, &limit)

    if config.stdin >= 0:  dup2(config.stdin, 0)
    if config.stdout >= 0: dup2(config.stdout, 1)
    if config.stderr >= 0: dup2(config.stderr, 2)

    for i in xrange(3, config.max_fd + 1):
        dup2(config.fds[i - 3], i)

    while True:
        dir = readdir(d)
        if dir == NULL:
            break
        fd = atoi(dir.d_name)
        if fd > config.max_fd:
            close(fd)
    ptrace(PTRACE_TRACEME, 0, NULL, NULL)
    kill(getpid(), SIGSTOP)
    execve(config.file, config.argv, config.envp)
    return 3306

cdef int pt_syscall_handler(void *context, int syscall) nogil:
    return (<Process>context)._syscall_handler(syscall)

cdef void pt_syscall_return_handler(void *context, int syscall) with gil:
    (<Debugger>context)._on_return(syscall)

cdef int pt_event_handler(void *context, int event, unsigned long param) nogil:
    return (<Process>context)._event_handler(event, param)

cdef char **alloc_string_array(list):
    cdef char **array = <char**>malloc((len(list) + 1) * sizeof(char*))
    for i, elem in enumerate(list):
        array[i] = elem
    array[len(list)] = NULL
    return array

cpdef unsigned long get_memory(pid_t pid) nogil:
    cdef unsigned long memory = 0
    cdef char path[128]
    cdef char line[128]
    cdef char *start
    cdef FILE* file
    cdef int length

    sprintf(path, '/proc/%d/status', pid)
    file = fopen(path, 'r')
    if file == NULL:
        return 0
    while True:
        if fgets(line, 128, file) == NULL:
            break
        if strncmp(line, "VmHWM:", 6) == 0:
            start = line
            length = strlen(line)
            line[length-3] = '\0'
            while not 48 <= start[0] <= 57:
                start += 1
            memory = strtoul(start, NULL, 0)
            break
    fclose(file)
    return memory


cdef class Debugger:
    cdef pt_debugger *thisptr
    cdef object on_return_callback
    cdef int _getpid_syscall

    property getpid_syscall:
        def __get__(self):
            return self._getpid_syscall

    property syscall:
        def __get__(self):
            return self.thisptr.syscall()

        def __set__(self, value):
            self.thisptr.syscall(value)

    property result:
        def __get__(self):
            return self.thisptr.result()

        def __set__(self, value):
            self.thisptr.result(<long>value)

    property uresult:
        def __get__(self):
            return <unsigned long>self.thisptr.result()

        def __set__(self, value):
            self.thisptr.result(<long><unsigned long>value)

    property arg0:
        def __get__(self):
            return self.thisptr.arg0()

        def __set__(self, value):
            self.thisptr.arg0(<long>value)

    property arg1:
        def __get__(self):
            return self.thisptr.arg1()

        def __set__(self, value):
            self.thisptr.arg1(<long>value)

    property arg2:
        def __get__(self):
            return self.thisptr.arg2()

        def __set__(self, value):
            self.thisptr.arg2(<long>value)

    property arg3:
        def __get__(self):
            return self.thisptr.arg3()

        def __set__(self, value):
            self.thisptr.arg3(<long>value)

    property arg4:
        def __get__(self):
            return self.thisptr.arg4()

        def __set__(self, value):
            self.thisptr.arg4(<long>value)

    property arg5:
        def __get__(self):
            return self.thisptr.arg5()

        def __set__(self, value):
            self.thisptr.arg5(<long>value)

    property uarg0:
        def __get__(self):
            return <unsigned long>self.thisptr.arg0()

        def __set__(self, value):
            self.thisptr.arg0(<long><unsigned long>value)

    property uarg1:
        def __get__(self):
            return <unsigned long>self.thisptr.arg1()

        def __set__(self, value):
            self.thisptr.arg1(<long><unsigned long>value)

    property uarg2:
        def __get__(self):
            return <unsigned long>self.thisptr.arg2()

        def __set__(self, value):
            self.thisptr.arg2(<long><unsigned long>value)

    property uarg3:
        def __get__(self):
            return <unsigned long>self.thisptr.arg3()

        def __set__(self, value):
            self.thisptr.arg3(<long><unsigned long>value)

    property uarg4:
        def __get__(self):
            return <unsigned long>self.thisptr.arg4()

        def __set__(self, value):
            self.thisptr.arg4(<long><unsigned long>value)

    property uarg5:
        def __get__(self):
            return <unsigned long>self.thisptr.arg5()

        def __set__(self, value):
            self.thisptr.arg5(<long><unsigned long>value)

    def readstr(self, unsigned long address):
        cdef char* str = self.thisptr.readstr(address)
        pystr = <object>str
        self.thisptr.freestr(str)
        return pystr

    property pid:
        def __get__(self):
            return self.thisptr.getpid()

    def on_return(self, callback):
        self.on_return_callback = callback
        self.thisptr.on_return(pt_syscall_return_handler, <void*>self)

    cdef _on_return(self, int syscall) with gil:
        self.on_return_callback()
        self.on_return_callback = None


cdef class Process:
    cdef pt_debugger *_debugger
    cdef pt_process *process
    cdef public Debugger debugger
    cdef readonly bint _exited
    cdef readonly int _exitcode
    cdef public int _child_stdin, _child_stdout, _child_stderr
    cdef public unsigned long _child_memory, _child_address
    cdef public unsigned int _cpu_time
    cdef public int _nproc
    cdef unsigned long _max_memory

    def __cinit__(self, int bitness, *args, **kwargs):
        self._child_memory = self._child_address = 0
        self._child_stdin = self._child_stdout = self._child_stderr = -1
        self._cpu_time = 0
        self._nproc = -1
        if bitness == 32:
            self._debugger = new pt_debugger32()
        elif bitness == 64:
            self._debugger = new pt_debugger64()
        else:
            raise ValueError('Invalid bitness')
        self.debugger = Debugger()
        self.debugger.thisptr = self._debugger
        self.debugger._getpid_syscall = self._debugger.getpid_syscall()
        self.process = new pt_process(self._debugger)
        self.process.set_callback(pt_syscall_handler, <void*>self)
        self.process.set_event_proc(pt_event_handler, <void*>self)

    def __dealloc__(self):
        del self.process
        del self._debugger

    def _callback(self, syscall):
        return False

    cdef int _syscall_handler(self, int syscall) with gil:
        return self._callback(syscall)

    cdef int _event_handler(self, int event, unsigned long param) nogil:
        if event == PTBOX_EVENT_EXITING or event == PTBOX_EVENT_SIGNAL:
            self._max_memory = get_memory(self.process.getpid())
        if event == PTBOX_EVENT_PROTECTION:
            with gil:
                self._protection_fault(param)
        if event == PTBOX_EVENT_SIGNAL and param == SIGXCPU:
            with gil:
                import sys
                print>>sys.stderr, 'SIGXCPU in child'
                self._cpu_time_exceeded()
        return 0

    cpdef _handler(self, syscall, handler):
        self.process.set_handler(syscall, handler)

    cpdef _protection_fault(self, syscall):
        pass

    cpdef _cpu_time_exceeded(self):
        pass

    cpdef _spawn(self, file, args, env=(), chdir='', fds=None):
        cdef child_config config
        config.address_space = self._child_address
        config.memory = self._child_memory
        config.cpu_time = self._cpu_time
        config.nproc = self._nproc
        config.file = file
        config.dir = chdir
        config.stdin = self._child_stdin
        config.stdout = self._child_stdout
        config.stderr = self._child_stderr
        config.argv = alloc_string_array(args)
        config.envp = alloc_string_array(env)
        if fds is None or not len(fds):
            config.max_fd = 2
            config.fds = NULL
        else:
            config.max_fd = 2 + len(fds)
            config.fds = <int*>malloc(sizeof(int) * len(fds))
            for i in xrange(len(fds)):
                config.fds[i] = fds[i]
        with nogil:
            if self.process.spawn(pt_child, &config):
                with gil:
                    raise RuntimeError('Failed to spawn child')
        free(config.argv)
        free(config.envp)

    cpdef _monitor(self):
        cdef int exitcode
        with nogil:
            exitcode = self.process.monitor()
        self._exitcode = exitcode
        self._exited = True
        return self._exitcode

    property pid:
        def __get__(self):
            return self.process.getpid()

    property execution_time:
        def __get__(self):
            return self.process.execution_time()

    property cpu_time:
        def __get__(self):
            cdef const rusage *usage = self.process.getrusage()
            return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1000000.

    property max_memory:
        def __get__(self):
            if self._exited:
                return self._max_memory
            cdef unsigned long memory = get_memory(self.process.getpid())
            if memory > 0:
                self._max_memory = memory
            return self._max_memory

    property returncode:
        def __get__(self):
            if not self._exited:
                return None
            return self._exitcode
