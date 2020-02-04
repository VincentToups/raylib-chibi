(define exact->inexact inexact)
(define inexact->exact exact)
(define (coerce-to-int n)
  (inexact->exact (round n)))
(define (coerce-to-unsigned-char n)
  (inexact->exact (floor (* n 255))))

(define (rectangle x y w h)
  (--rectangle (exact->inexact x)
               (exact->inexact y)
               (exact->inexact w)
               (exact->inexact h)))

(define (color r g b a)
  (if (integer? r)
      (--color r g b a)
      (--color (coerce-to-unsigned-char r)
               (coerce-to-unsigned-char g)
               (coerce-to-unsigned-char b)
               (coerce-to-unsigned-char a))))

(define (display-nl x)
  (display x)
  (newline))

(define (get-next-codepoint str)
  (get-next-codepoint-- str))

(define (load-meshes filename)
  (let ((mesh-array (load-meshes-to-mesh-array filename)))
    (let loop ((i (- (mesh-array-get-length mesh-array) 1))
               (meshes (list)))
      (if (< i 0) meshes
          (loop (- i 1)
                (cons (mesh-array-get-mesh mesh-array i)
                      meshes))))))

(define (load-materials filename)
  (let ((material-array (load-materials-to-material-array filename)))
    (let loop ((i (- (material-array-get-length material-array) 1))
               (materials (list)))
      (if (< i 0) materials
          (loop (- i 1)
                (cons (material-array-get-material material-array i)
                      materials))))))

(define (load-model-animations filename)
  (let ((model-animation-array (load-model-animations-to-model-animation-array filename)))
    (let loop ((i (- (model-animation-array-get-length model-animation-array) 1))
               (model-animations (list)))
      (if (< i 0) model-animations
          (loop (- i 1)
                (cons (model-animation-array-get-model-animation model-animation-array i)
                      model-animations))))))

(define (check-collision-ray-sphere-ex ray position radius)
  (let ((result (check-collision-ray-sphere-ex-- ray position radius)))
    (list (ray-sphere-collision-info-get-collision result)
          (ray-sphere-collision-info-get-point result))))

