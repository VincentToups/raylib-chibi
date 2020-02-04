(define (init)
  (init-window 800 450 "Hello World")
  (set-target-fps 60)
  #f)

(define (draw)
  (begin-drawing)
  (clear-background (color 255 255 255 255))
  (draw-text "OMG - Raylib Chibi is Alive!" 190 200 20 (color 192 192 192 255))
  (draw-rectangle 220 220 40 40 (color 192 0 0 255))
  (end-drawing))

