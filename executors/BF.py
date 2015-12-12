import itertools
from .C import Executor as CExecutor
from error import CompileError

template = '''\
#include <stdio.h>

char array[16777216];

int main() {
    char *ptr = array;
    %s
}
'''

trans = {'>': '++ptr;', '<': '--ptr;',
         '+': '++*ptr;', '-': '--*ptr;',
         '.': 'putchar(*ptr);', ',': '*ptr=getchar();',
         '[': 'while(*ptr){', ']': '}'}


class Executor(CExecutor):
    name = 'BF'
    test_program = ',+[-.,+]'

    def __init__(self, problem_id, source_code):
        if source_code.count('[') != source_code.count(']'):
            raise CompileError('Unmatched brackets')
        code = template % (''.join(itertools.imap(trans.get, source_code, itertools.repeat(''))))
        super(Executor, self).__init__(problem_id, code)


initialize = Executor.initialize
