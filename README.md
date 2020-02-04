Raylib-Chibi
============

Rudimentary (but almost 100% complete) bindings to [Raylib][raylib] for [Chibi Scheme][chibi].

Requirements
============

Raylib's headers somewhere accessible and Chibi Scheme.

Building
========

I've only tested the build on OSX, where you can say:

    make raylib-chibi
    
Running
=======

These bindings operate like Love2D - you start the raylib-chibi
executable and it reads a script which defines your game in
Chibi-Scheme. Eg:

    ./raylib-chibi main.scm
    
Where `main.scm` looks like:

    (define (init)
      (init-window 800 450 "Hello World")
      (set-target-fps 60)
      #f)

    (define (draw)
      (begin-drawing)
      (clear-background (color 255 255 255 255))
      (draw-text "Welcome to Raylib-Chibi" 190 200 20 (color 192 192 192 255))
      (draw-rectangle 220 220 40 40 (color 192 0 0 255))
      (end-drawing))

Will generate a nice little red box and a welcome message.

In general, your script needs an `init` and a `draw` method.

Completeness
============

Almost the entire Raylib API is bound in more or less the obvious way
(eg, `DrawCircle` becomes `draw-circle`).

Some exceptions:

`SetLogTraceCallback` is waiting on a stroke of inspiration about the
right way to do the reverse call.

Some of the file and directory functions are left out because they
return things tricky to bind and because chibi exposes alternatives.

`DrawTriangleFan` requires an array of Vector2's which I haven't
decided how to represent yet.

The most notable issues are with the Shader functions, some of which I
need to learn more about Shaders to bind properly.

I believe most of the pieces are in place to pass the appropriate
values in, but have to work it out.

I've also skipped all the VR functions for now as I don't have VR
equipment to work or test with.

`raylib.stub` is a Scheme program (despite the name) that works along
with the slightly modified `chibi-ffi.scm` from Chibi to generate the
bindings and is thus relatively good documentation about which
functions are bound.

[raylib]:https://www.raylib.com/
[chibi]:http://synthcode.com/scheme/chibi
