CXX=g++
CXXFLAGS=-g -fPIC -Wall -O3 -march=native -I/usr/include/python$(PYVER) -D_FILE_OFFSET_BITS=64
LIBS=-lrt
SOURCES=ptbox.cpp ptdebug.cpp ptdebug32.cpp ptdebug64.cpp ptproc.cpp
OBJECTS=$(SOURCES:.cpp=.o)
EXECUTABLE=ptbox

all: $(SOURCES) $(EXECUTABLE) _cptbox.so

$(EXECUTABLE): $(OBJECTS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJECTS) $(LIBS)

strip: $(EXECUTABLE) _cptbox.so
	strip -s $(EXECUTABLE) _cptbox.so

ptbox.o: ptbox.cpp ptbox.h
ptdebug32.o: ptdebug32.cpp ptbox.h
ptdebug64.o: ptdebug64.cpp ptbox.h
ptdebug.o: ptdebug.cpp ptbox.h
ptproc.o: ptproc.cpp ptbox.h

.cpp.o:
	$(CXX) $(CXXFLAGS) -c -o $@ $<

_cptbox.so: _cptbox.o $(OBJECTS)
	$(CXX) -shared $(CXXFLAGS) -o $@ $(OBJECTS) _cptbox.o $(LIBS) -lpython$(PYVER)

_cptbox.cpp: _cptbox.pyx
	cython --cplus _cptbox.pyx

clean:
	-rm -f $(OBJECTS) _cptbox.so $(EXECUTABLE) _cptbox.cpp _cptbox.o