raylib.c: raylib.stub
	./chibi-ffi.scm raylib.stub
raylib-chibi: raylib.c raylib-chibi.c
	cc raylib-chibi.c -o ./raylib-chibi `pkg-config --libs --cflags raylib` `pkg-config --libs --cflags chibi-scheme`
