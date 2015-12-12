from executors.base_executor import CompiledExecutor
from judgeenv import env


class Executor(CompiledExecutor):
    ext = '.ml'
    name = 'OCAML'
    fs = ['.*\.so']
    command = env['runtime'].get('ocaml')
    test_program = 'print_endline (input_line stdin)'

    def get_compile_args(self):
        return [env['runtime']['ocaml'], self._code, '-o', self.problem]


initialize = Executor.initialize
