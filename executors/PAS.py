import subprocess

from executors.base_executor import CompiledExecutor
from judgeenv import env


class Executor(CompiledExecutor):
    ext = '.pas'
    name = 'PAS'
    fs = ['.*\.so']
    command = env['runtime'].get('fpc')
    test_program = '''\
var line : string;
begin
    readln(line);
    writeln(line);
end.
'''

    # def get_compile_popen_kwargs(self):
    #     return {'stdout': subprocess.PIPE, 'stderr': None}

    def get_compile_args(self):
        return [env['runtime']['fpc'], '-Fe/dev/stderr', '-So', '-O2', self._code, '-o' + self.get_compiled_file()]

    def get_compile_output(self, process):
        output = process.communicate()[1]
        return output if 'Fatal:' in output or 'Warning:' in output or 'Note:' in output else ''


initialize = Executor.initialize
