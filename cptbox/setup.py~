from distutils.core import setup
from Cython.Build import cythonize

setup(ext_modules = cythonize(
       "_cptbox.pyx",            # our Cython source
       sources=["ptdebug.cpp","ptdebug32.cpp","ptdebug64.cpp","ptproc.cpp","ptbox.cpp"],  # additional source file(s)
       language="c++",             # generate C++ code
      ))
