#! /usr/bin/env chibi-scheme

;; Copyright (c) 2009-2018 Alex Shinn
;; All rights reserved.

;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met:
;; 1. Redistributions of source code must retain the above copyright
;;    notice, this list of conditions and the following disclaimer.
;; 2. Redistributions in binary form must reproduce the above copyright
;;    notice, this list of conditions and the following disclaimer in the
;;    documentation and/or other materials provided with the distribution.
;; 3. The name of the author may not be used to endorse or promote products
;;    derived from this software without specific prior written permission.

;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
;; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
;; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
;; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
;; NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
;; DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
;; THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
;; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
;; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

;; Note: this evolved as a throw-away script to provide certain core
;; modules, and so is a mess.  Tread carefully.

;; Simple C FFI.  "chibi-ffi file.stub" will read in the C function
;; FFI definitions from file.stub and output the appropriate C
;; wrappers into file.c.  You can then compile that file with:
;;
;;   cc -fPIC -shared file.c -lchibi-scheme
;;
;; (or using whatever flags are appropriate to generate shared libs on
;; your platform) and then the generated .so file can be loaded
;; directly with load, or portably using (include-shared "file") in a
;; module definition (note that include-shared uses no suffix).
;;
;; Passing the -c/--compile option will attempt to compile the .so
;; file in a single step.

;; The goal of this interface is to make access to C types and
;; functions easy, without requiring the user to write any C code.
;; That means the stubber needs to be intelligent about various C
;; calling conventions and idioms, such as return values passed in
;; actual parameters.  Writing C by hand is still possible, and
;; several of the core modules provide C interfaces directly without
;; using the stubber.

;; For bootstrapping purposes we depend only on the core language.
(import (chibi))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; globals

(define *ffi-version* "0.4")
(define *types* '())
(define *type-getters* '())
(define *type-setters* '())
(define *typedefs* '())
(define *funcs* '())
(define *methods* '())
(define *consts* '())
(define *inits* '())
(define *clibs* '())
(define *cflags* '())
(define *frameworks* '())
(define *tags* '())
(define *open-namespaces* '())
(define *c++?* #f)
(define wdir ".")
(define *post-init-hook* '())
(define auto-expand-limit (* 10 1024 1024))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; type objects

(define (make-type) (make-vector 18 #f))

(define (type-base type) (vector-ref type 0))
(define (type-free? type) (vector-ref type 1))
(define (type-const? type) (vector-ref type 2))
(define (type-null? type) (vector-ref type 3))
(define (type-pointer? type) (vector-ref type 4))
(define (type-reference? type) (vector-ref type 5))
(define (type-struct? type) (vector-ref type 6))
(define (type-link? type) (vector-ref type 7))
(define (type-result? type) (vector-ref type 8))
(define (type-array type) (vector-ref type 9))
(define (type-value type) (vector-ref type 10))
(define (type-default? type) (vector-ref type 11))
(define (type-template type) (vector-ref type 12))
(define (type-new? type) (vector-ref type 13))
(define (type-error type) (vector-ref type 14))
(define (type-address-of? type) (vector-ref type 15))
(define (type-no-free? type) (vector-ref type 16))
(define (type-index type) (vector-ref type 17))
(define (type-index-set! type i) (vector-set! type 17 i))

(define (add-post-init-hook fn)
  (set! *post-init-hook* (cons fn *post-init-hook*)))

(define (spec->type type . o)
  (let ((res (make-type)))
    (if (pair? o)
        (type-index-set! res (car o)))
    (let lp ((type type))
      (define (next) (if (null? (cddr type)) (cadr type) (cdr type)))
      (case (and (pair? type) (car type))
        ((free)
         (vector-set! res 1 #t)
         (lp (next)))
        ((const)
         (vector-set! res 2 #t)
         (lp (next)))
        ((maybe-null)
         (vector-set! res 3 #t)
         (lp (next)))
        ((pointer)
         (vector-set! res 4 #t)
         (lp (next)))
        ((reference)
         (vector-set! res 5 #t)
         (lp (next)))
        ((struct)
         (vector-set! res 6 #t)
         (lp (next)))
        ((link)
         (vector-set! res 7 #t)
         (lp (next)))
        ((result)
         (vector-set! res 8 #t)
         (lp (next)))
        ((array)
         (vector-set! res 9 (if (pair? (cddr type)) (car (cddr type)) #t))
         (lp (cadr type)))
        ((value)
         (vector-set! res 10 (cadr type))
         (lp (cddr type)))
        ((default)
         (vector-set! res 10 (cadr type))
         (vector-set! res 11 #t)
         (lp (cddr type)))
        ((template)
         (vector-set! res 12 (cadr type))
         (lp (cddr type)))
        ((new)
         (vector-set! res 13 #t)
         (lp (next)))
        ((error)
         (vector-set! res 8 #t)
         (vector-set! res 14 (cadr type))
         (lp (cddr type)))
        ((address-of)
         (vector-set! res 15 #t)
         (lp (next)))
        ((no-free)
         (vector-set! res 16 #t)
         (lp (next)))
        (else
         (let ((base (if (and (pair? type) (null? (cdr type)))
                         (car type)
                         type)))
           (vector-set! res 0 base)
           res))))))

(define (parse-type type . o)
  (cond
   ((vector? type)
    (if (and (pair? o) (car o))
        (let ((res (vector-copy type)))
          (type-index-set! res (car o))
          res)
        type))
   (else
    (apply spec->type type o))))

(define (type-auto-expand? type)
  (and (pair? (type-array type))
       (memq 'auto-expand (type-array type))))

(define (type-index-string type)
  (if (integer? (type-index type))
      (number->string (type-index type))
      ""))

(define (struct-fields ls)
  (let lp ((ls ls) (res '()))
    (cond ((not (pair? ls)) (reverse res))
          ((symbol? (car ls)) (lp (if (pair? (cdr ls)) (cddr ls) (cdr ls)) res))
          (else (lp (cdr ls) (cons (car ls) res))))))

(define (lookup-type type)
  (or (assq type *types*)
      (assq type *typedefs*)))

(define (type-field-type type field)
  (cond
   ((lookup-type (type-base (parse-type type)))
    => (lambda (x)
         (let lp ((ls (struct-fields (cdr x))))
           (cond
            ((null? ls) #f)
            ((eq? field (caar ls)) (car (cdar ls)))
            (else (lp (cdr ls)))))))
   (else
    #f)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; type predicates

(define *c-int-types* '())
(define *c-enum-types* '())

(define-syntax define-c-int-type
  (syntax-rules ()
    ((define-c-int-type type)
     (if (not (memq 'type *c-int-types*))
         (set! *c-int-types* (cons 'type *c-int-types*)))
     #f)))

(define-syntax define-c-enum
  ;; TODO: support conversion to/from symbolic names
  (syntax-rules ()
    ((define-c-enum (scheme-name c-name) . args)
     (if (not (assq 'scheme-name *c-enum-types*))
         (set! *c-enum-types*
               `((scheme-name . c-name) ,@*c-enum-types*)))
     #f)
    ((define-c-enum scheme-name . args)
     (let ((c-name (mangle 'scheme-name)))
       (if (not (assq 'scheme-name *c-enum-types*))
           (set! *c-enum-types*
                 `((scheme-name . ,c-name) ,@*c-enum-types*)))
       #f))))

(define (enum-type? type)
  (assq type *c-enum-types*))

(define (signed-int-type? type)
  (or (memq type '(signed-char short int long s8 s16 s32 s64))
      (memq type *c-int-types*)
      (enum-type? type)))

(define (unsigned-int-type? type)
  (memq type '(unsigned-char unsigned-short unsigned unsigned-int unsigned-long
               size_t off_t time_t clock_t dev_t ino_t mode_t nlink_t
               uid_t gid_t pid_t blksize_t blkcnt_t sigval_t
               u1 u8 u16 u32 u64)))

(define (int-type? type)
  (or (signed-int-type? type) (unsigned-int-type? type)))

(define (float-type? type)
  (memq type '(float double long-double long-long-double f32 f64)))

(define (string-type? type)
  (or (memq type '(char* string env-string non-null-string))
      (and (vector? type)
           (type-array type)
           (not (type-pointer? type))
           (eq? 'char (type-base type)))))

(define (port-type? type)
  (memq type '(port input-port output-port input-output-port)))

(define (error-type? type)
  (or (type-error type)
      (memq (type-base type)
            '(errno status-bool non-null-string non-null-pointer))))

(define (array-type? type)
  (and (type-array type) (not (eq? 'char (type-base type)))))

(define (basic-type? type)
  (let ((type (parse-type type)))
    (and (not (type-array type))
         (not (void-pointer-type? type))
         (not (lookup-type (type-base type))))))

(define (void-pointer-type? type)
  (or (and (eq? 'void (type-base type)) (type-pointer? type))
      (eq? 'void* (type-base type))))

(define (uniform-vector-type-code type)
  (case type
    ((u1vector) 'SEXP_U1)
    ((u8vector) 'SEXP_U8)
    ((s8vector) 'SEXP_S8)
    ((u16vector) 'SEXP_U16)
    ((s16vector) 'SEXP_S16)
    ((u32vector) 'SEXP_U32)
    ((s32vector) 'SEXP_S32)
    ((u64vector) 'SEXP_U64)
    ((s64vector) 'SEXP_S64)
    ((f32vector) 'SEXP_F32)
    ((f64vector) 'SEXP_F64)
    ((c64vector) 'SEXP_C64)
    ((c128vector) 'SEXP_C128)
    (else #f)))

(define (uniform-vector-type? type)
  (or (eq? type 'uvector)
      (and (uniform-vector-type-code type) #t)))

(define (uniform-vector-ctype type)
  (case type
    ((uvector) "sexp")
    ((u1vector) "char*")
    ((u8vector) "unsigned char*")
    ((s8vector) "signed char*")
    ((u16vector) "unsigned short*")
    ((s16vector) "signed short*")
    ((u32vector) "unsigned int*")
    ((s32vector) "signed int*")
    ((u64vector) "sexp_uint_t*")
    ((s64vector) "sexp_sint_t*")
    ((f32vector) "float*")
    ((f64vector) "double*")
    ((c64vector) "float*")
    ((c128vector) "double*")
    (else #f)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; function objects

(define (parse-func func . o)
  (if (not (and (= 3 (length func))
                (or (identifier? (cadr func))
                    (and (list? (cadr func))
                         (<= 1 (length (cadr func)) 3)
                         (every (lambda (x) (or (identifier? x) (not x) (string? x)))
                                (cadr func))))
                (list? (car (cddr func)))))
      (error "bad function definition" func))
  (let* ((method? (and (pair? o) (car o)))
         (ret-type (parse-type (car func)))
         (scheme-name (if (pair? (cadr func)) (car (cadr func)) (cadr func)))
         (c-name (if (pair? (cadr func))
                     (cadr (cadr func))
                     (mangle scheme-name)))
         (stub-name (if (and (pair? (cadr func)) (pair? (cddr (cadr func))))
                        (car (cddr (cadr func)))
                        (generate-stub-name scheme-name))))
    (let lp ((ls (if (equal? (car (cddr func)) '(void)) '() (car (cddr func))))
             (i 0)
             (results '())
             (c-args '())
             (s-args '()))
      (cond
       ((null? ls)
        (vector scheme-name c-name stub-name ret-type
                (reverse results) (reverse c-args) (reverse s-args)
                method?))
       (else
        (let ((type (parse-type (car ls) i)))
          (cond
           ((type-result? type)
            (lp (cdr ls) (+ i 1) (cons type results) (cons type c-args) s-args))
           ((and (type-value type) (not (type-default? type)))
            (lp (cdr ls) (+ i 1) results (cons type c-args) s-args))
           (else
            (lp (cdr ls) (+ i 1) results (cons type c-args) (cons type s-args)))
           )))))))

(define (func-scheme-name func) (vector-ref func 0))
(define (func-c-name func) (vector-ref func 1))
(define (func-stub-name func) (vector-ref func 2))
(define (func-ret-type func) (vector-ref func 3))
(define (func-results func) (vector-ref func 4))
(define (func-c-args func) (vector-ref func 5))
(define (func-scheme-args func) (vector-ref func 6))
(define (func-method? func) (vector-ref func 7))

(define (func-stub-name-set! func x) (vector-set! func 2 x))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; utilities

(define (cat . args)
  (for-each (lambda (x) (if (procedure? x) (x) (display x))) args))

(define (join ls . o)
  (if (pair? ls)
      (let ((sep (if (pair? o) (car o) " ")))
        (let lp ((ls ls))
          (if (pair? (cdr ls))
              (cat (car ls) sep (lambda () (lp (cdr ls))))
              (cat (car ls)))))
      ""))

(define (x->string x)
  (cond ((string? x) x)
        ((symbol? x) (symbol->string x))
        ((number? x) (number->string x))
        (else (error "non-stringable object" x))))

(define (filter pred ls)
  (cond ((null? ls) '())
        ((pred (car ls)) (cons (car ls) (filter pred (cdr ls))))
        (else (filter pred (cdr ls)))))

(define (remove pred ls)
  (cond ((null? ls) '())
        ((pred (car ls)) (remove pred (cdr ls)))
        (else (cons (car ls) (remove pred (cdr ls))))))

(define (strip-extension path)
  (let lp ((i (- (string-length path) 1)))
    (cond ((<= i 0) path)
          ((eq? #\. (string-ref path i)) (substring path 0 i))
          (else (lp (- i 1))))))

(define (string-concatenate-reverse ls)
  (cond ((null? ls) "")
        ((null? (cdr ls)) (car ls))
        (else (string-concatenate (reverse ls)))))

(define (string-replace str c r)
  (let ((len (string-length str)))
    (let lp ((from 0) (i 0) (res '()))
      (define (collect) (if (= i from) res (cons (substring str from i) res)))
      (cond
       ((>= i len) (string-concatenate-reverse (collect)))
       ((eqv? c (string-ref str i)) (lp (+ i 1) (+ i 1) (cons r (collect))))
       (else (lp from (+ i 1) res))))))

(define (string-split str c . o)
  (let ((test?
         (if (procedure? c)
             c
             (lambda (char) (eqv? char c))))
        (start (if (pair? o) (car o) 0))
        (end (string-length str)))
    (let lp ((from start) (i start) (res '()))
      (define (collect) (if (= i from) res (cons (substring str from i) res)))
      (cond
       ((>= i end) (reverse (collect)))
       ((test? (string-ref str i)) (lp (+ i 1) (+ i 1) (collect)))
       (else (lp from (+ i 1) res))))))

(define (string-scan c str . o)
  (let ((end (string-length str)))
    (let lp ((i (if (pair? o) (car o) 0)))
      (cond ((>= i end) #f)
            ((eqv? c (string-ref str i)) i)
            (else (lp (+ i 1)))))))

(define (string-downcase str)
  (list->string (map char-downcase (string->list str))))

(define (with-output-to-string thunk)
  (call-with-output-string
    (lambda (out)
      (let ((old-out (current-output-port)))
        (current-output-port out)
        (thunk)
        (current-output-port old-out)))))

(define (warn msg . args)
  (let ((err (current-error-port)))
    (display "WARNING: " err)
    (display msg err)
    (if (pair? args) (display ":" err))
    (for-each (lambda (x) (display " " err) (write x err)) args)
    (newline err)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; naming

(define (c-char? c)
  (or (char-alphabetic? c) (char-numeric? c) (memv c '(#\_ #\- #\! #\?))))

(define (c-escape str)
  (let ((len (string-length str)))
    (let lp ((from 0) (i 0) (res '()))
      (define (collect) (if (= i from) res (cons (substring str from i) res)))
      (cond
       ((>= i len) (string-concatenate-reverse (collect)))
       ((not (c-char? (string-ref str i)))
        (lp (+ i 1) (+ i 1)
            `("_" ,(number->string (char->integer (string-ref str i)) 16)
              ,@(collect))))
       (else (lp from (+ i 1) res))))))

(define (mangle x)
  (string-replace
   (string-replace (string-replace (c-escape (x->string x)) #\- "_") #\? "_p")
   #\! "_x"))

(define (generate-stub-name sym)
  (string-append "sexp_" (mangle sym) "_stub"))

(define (type-id-name sym)
  (string-append "sexp_" (mangle sym) "_type_obj"))

(define (make-integer x)
  (case x
    ((-1) "SEXP_NEG_ONE")  ((0) "SEXP_ZERO")   ((1) "SEXP_ONE")
    ((2) "SEXP_TWO")       ((3) "SEXP_THREE")  ((4) "SEXP_FOUR")
    ((5) "SEXP_FIVE")      ((6) "SEXP_SIX")    ((7) "SEXP_SEVEN")
    ((8) "SEXP_EIGHT")     ((9) "SEXP_NINE")   ((10) "SEXP_TEN")
    (else (string-append "sexp_make_fixnum(" (x->string x) ")"))))

(define (string-scan-right str ch)
  (let lp ((i (string-cursor-end str)))
    (let ((i2 (string-cursor-prev str i)))
      (cond ((string-cursor<? i2 0) 0)
            ((eqv? ch (string-cursor-ref str i2)) i)
            (else (lp i2))))))

(define (strip-namespace x)
  (string->symbol
   (let* ((x (x->string x))
          (i (string-scan-right x #\:)))
     (if (> i 0)
         (substring-cursor x i)
         x))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; .stub file interface

(define (ffi-include file)
  (load file (current-environment)))

(define (c-link lib)
  (set! *clibs* (cons lib *clibs*)))

(define (c-framework lib)
  (set! *frameworks* (cons lib *frameworks*)))

(define (c-flags-from-script cmd)
  (eval '(import (chibi process)) (current-environment))
  (let ((string-null?    (lambda (str) (equal? str "")))
        (process->string (eval 'process->string (current-environment))))
    (set! *cflags*
      (append *cflags*
              (filter
               (lambda (x) (not (string-null? x)))
               (string-split (process->string cmd) char-whitespace?))))))

(define (c-declare . args)
  (apply cat args)
  (newline))

(define (c-include header)
  (cat "\n#include \"" header "\"\n"))

(define (c-system-include header)
  (cat "\n#include <" header ">\n"))

(define (c-include-verbatim file)
  (call-with-input-file (if (eqv? #\/ (string-ref file 0))
                            file
                            (string-append wdir "/" file))
    (lambda (in)
      (let lp ()
        (let ((c (read-char in)))
          (cond
           ((not (eof-object? c))
            (write-char c)
            (lp))))))))

(define (c-init x)
  (set! *inits* (cons x *inits*)))

(define (parse-struct-like ls)
  (let lp ((ls ls) (res '()))
    (cond
     ((null? ls)
      (reverse res))
     ((symbol? (car ls))
      (lp (cddr ls) (cons (cadr ls) (cons (car ls) res))))
     ((pair? (car ls))
      (lp (cdr ls) (cons (cons (parse-type (caar ls)) (cdar ls)) res)))
     (else
      (lp (cdr ls) (cons (car ls) res))))))

(define-syntax define-struct-like
  (er-macro-transformer
   (lambda (expr rename compare)
     (set! *types*
           `((,(cadr expr)
              ,@(parse-struct-like (cddr expr)))
             ,@*types*))
     (set! *tags* `(,(type-id-name (cadr expr)) ,@*tags*))
     #f)))

(define-syntax define-c-struct
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: struct ,@(cddr expr)))))

(define-syntax define-c-class
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: class ,@(cddr expr)))))

(define-syntax define-c-union
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: union ,@(cddr expr)))))

(define-syntax define-c-type
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) ,@(cddr expr)))))

(define-syntax declare-c-struct
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: struct imported?: #t))))

(define-syntax declare-c-class
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: class imported?: #t))))

(define-syntax declare-c-union
  (er-macro-transformer
   (lambda (expr rename compare)
     `(define-struct-like ,(cadr expr) type: union imported?: #t))))

(define-syntax define-c
  (er-macro-transformer
   (lambda (expr rename compare)
     (set! *funcs* (cons (parse-func (cdr expr)) *funcs*))
     #f)))

(define-syntax define-c-const
  (er-macro-transformer
   (lambda (expr rename compare)
     (let ((type (parse-type (cadr expr))))
       (for-each (lambda (x) (set! *consts* (cons (list type x) *consts*)))
                 (cddr expr))))))

;; custom strerror which reports constants as their names
(define-syntax define-c-strerror
  (er-macro-transformer
   (lambda (expr rename compare)
     (let ((name (cadr expr))
           (errnos (cddr expr)))
       `(,(rename 'c-declare)
         ,(string-concatenate
           `("\nchar* " ,(x->string name) "(const int err) {
  static char buf[64];
  switch (err) {
"
             ,@(map (lambda (errno)
                      (let ((e (x->string errno)))
                        (string-append "    case " e ": return \"" e "\";\n")))
                    errnos)
             
             "  }
  sprintf(buf, \"unknown error: %d\", err);
  return buf;
}")))))))

(define-syntax c-typedef
  (er-macro-transformer
   (lambda (expr rename compare)
     (let ((type (parse-type (cadr expr)))
           (name (car (cddr expr))))
       (set! *typedefs* `((,name ,@type) ,@*typedefs*))
       `(,(rename 'cat) "typedef " ,(type-c-name type) " " ',name ";\n")))))

(define (c++)
  (set! *c++?* #t))

(define (ensure-c++ name)
  (cond
   ((not *c++?*)
    (display "WARNING: assuming c++ mode from " (current-error-port))
    (display name (current-error-port))
    (display " - use (c++) to make this explicit\n" (current-error-port))
    (c++))))

(define-syntax c++-namespace
  (er-macro-transformer
   (lambda (expr rename compare)
     (ensure-c++ 'c++-namespace)
     (let ((namespace (cadr expr)))
       (cond
        ((null? (cddr expr))
         (set! *open-namespaces* (cons namespace *open-namespaces*))
         `(,(rename 'cat) "namespace " ',namespace ";\n"))
        (else
         `(,(rename 'begin)
           (,(rename 'cat) "namespace " ',namespace " {\n")
           ,@(cddr expr)
           (,(rename 'cat) "}  // namespace " ',namespace "\n\n"))))))))

(define-syntax c++-using
  (er-macro-transformer
   (lambda (expr rename compare)
     (ensure-c++ 'c++-using)
     `(,(rename 'cat) "using " ',(cadr expr) ";\n"))))

(define-syntax define-c++-method
  (er-macro-transformer
   (lambda (expr rename compare)
     (ensure-c++ 'define-c++-method)
     (let* ((class (cadr expr))
            (ret-type (car (cddr expr)))
            (name (cadr (cddr expr)))
            (meths (map (lambda (x)
                          (parse-func `(,ret-type ,name (,class ,@x)) #t))
                        (cddr (cddr expr)))))
       (set! *methods* (cons (cons name meths) *methods*))))))

(define-syntax define-c++-constructor
  (er-macro-transformer
   (lambda (expr rename compare)
     (ensure-c++ 'define-c++-constructor)
     (set! *funcs*
           (cons (parse-func `((new ,(if (pair? (cadr expr))
                                         (cadr (cadr expr))
                                         (cadr expr)))
                               ,(cadr expr)
                               ,@(cddr expr)))
                 *funcs*))
     #f)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; C code generation

(define (type-predicate type)
  (let ((base (type-base (parse-type type))))
    (cond
     ((int-type? base) "sexp_exact_integerp")
     ((float-type? base) "sexp_flonump")
     ((string-type? base) "sexp_stringp")
     (else
      (case base
        ((bytevector u8vector) "sexp_bytesp")
        ((char) "sexp_charp")
        ((bool boolean status-bool) "sexp_booleanp")
        ((port) "sexp_portp")
        ((input-port) "sexp_iportp")
        ((output-port) "sexp_oportp")
        ((input-output-port) "sexp_ioportp")
        ((fileno fileno-nonblock) "sexp_filenop")
        ((uvector) "sexp_uvectorp")
        ((u1vector) "sexp_u1vectorp")
        ((s8vector) "sexp_s8vectorp")
        ((u16vector) "sexp_u16vectorp")
        ((s16vector) "sexp_s16vectorp")
        ((u32vector) "sexp_u32vectorp")
        ((s32vector) "sexp_s32vectorp")
        ((u64vector) "sexp_u64vectorp")
        ((s64vector) "sexp_s64vectorp")
        ((f32vector) "sexp_f32vectorp")
        ((f64vector) "sexp_f64vectorp")
        ((c64vector) "sexp_c64vectorp")
        ((c128vector) "sexp_c128vectorp")
        (else #f))))))

(define (type-name type)
  (let ((base (type-base (parse-type type))))
    (cond
     ((int-type? base) "integer")
     ((float-type? base) "flonum")
     ((memq base '(bool boolean status-bool)) (if *c++?* "bool" "int"))
     (else base))))

(define (type-id-number type . o)
  (let ((base (type-base type)))
    (cond
     ((int-type? base) "SEXP_FIXNUM")
     ((float-type? base) "SEXP_FLONUM")
     ((string-type? base) "SEXP_STRING")
     ((memq base '(bytevector u8vector)) "SEXP_BYTES")
     ((eq? base 'char) "SEXP_CHAR")
     ((memq base '(bool boolean status-bool)) "SEXP_BOOLEAN")
     ((eq? base 'string) "SEXP_STRING")
     ((eq? base 'symbol) "SEXP_SYMBOL")
     ((eq? base 'pair) "SEXP_PAIR")
     ((eq? base 'port) "SEXP_IPORT")
     ((eq? base 'input-port) "SEXP_IPORT")
     ((eq? base 'output-port) "SEXP_OPORT")
     ((eq? base 'input-output-port) "SEXP_IPORT")
     ((memq base '(fileno fileno-nonblock)) "SEXP_FILENO")
     ((uniform-vector-type? base)
      "SEXP_UNIFORM_VECTOR")
     ((void-pointer-type? type) "SEXP_CPOINTER")
     ((lookup-type base)
      ;; (string-append "sexp_type_tag(" (type-id-name base) ")")
      (let ((i (type-index type)))
        (cond
         ((not i)
          ;;(warn "type-id-number on unknown arg" type)
          (if (and (pair? o) (car o))
              "sexp_unbox_fixnum(sexp_opcode_return_type(self))"
              (string-append "sexp_type_tag(" (type-id-name base) ")")))
         ((< i 3)
          (string-append
           "sexp_unbox_fixnum(sexp_opcode_arg"
           (number->string (+ i 1)) "_type(self))"))
         (else
          (string-append
           "sexp_unbox_fixnum(sexp_vector_ref(sexp_opcode_argn_type(self), "
           (make-integer (- i 3)) "))")))))
     (else "SEXP_OBJECT"))))

(define (type-id-value type . o)
  (cond
   ((eq? 'void (type-base type))
    "SEXP_VOID")
   (else
    (make-integer (apply type-id-number type o)))))

(define (type-id-init-value type)
  (cond
   ((lookup-type (type-base type))
    (make-integer
     (string-append "sexp_type_tag(" (type-id-name (type-base type)) ")")))
   (else
    (type-id-value type))))

(define (c-array-length type)
  (if (memq 'result (type-array type))
      "sexp_unbox_fixnum(res)"
      "-1"))

(define (c-type-free? type)
  (or (type-free? type)
      (type-new? type)
      (and (type-result? type)
           (not (basic-type? type))
           (not (type-no-free? type)))))

(define (c->scheme-converter type val . o)
  (let ((base (type-base type)))
    (cond
     ((and (eq? base 'void) (not (type-pointer? type)))
      (cat "((" val "), SEXP_VOID)"))
     ((or (eq? base 'sexp) (error-type? type))
      (cat val))
     ((memq base '(bool boolean status-bool))
      (cat "sexp_make_boolean(" val ")"))
     ((eq? base 'time_t)
      (cat "sexp_make_integer(ctx, sexp_shift_epoch(" val "))"))
     ((unsigned-int-type? base)
      (cat "sexp_make_unsigned_integer(ctx, " val ")"))
     ((signed-int-type? base)
      (cat "sexp_make_integer(ctx, " val ")"))
     ((float-type? base)
      (cat "sexp_make_flonum(ctx, " val ")"))
     ((eq? base 'char)
      (if (type-array type)
          (cat "sexp_c_string(ctx, " val ", " (c-array-length type) ")")
          (cat "sexp_make_character(" val ")")))
     ((eq? 'env-string base)
      (cat "(p=strchr(" val ", '=') ? "
           "sexp_cons(ctx, str=sexp_c_string(ctx, " val
           ", p - " val "), str=sexp_c_string(ctx, p, -1))"
           " : sexp_cons(ctx, str=" val ", SEXP_FALSE)"))
     ((string-type? base)
      (if (and *c++?* (eq? 'string base))
          (cat "sexp_c_string(ctx, " val ".c_str(), " val ".size())")
          (cat "sexp_c_string(ctx, " val ", " (c-array-length type) ")")))
     ((memq base '(bytevector u8vector))
      (if *c++?*
          (cat "sexp_string_to_bytes(ctx, sexp_c_string(ctx, "
               val ".data(), " val ".size()))")
          (cat "sexp_string_to_bytes(ctx, sexp_c_string(ctx, " val ", "
               (c-array-length type val) "))")))
     ((eq? 'input-port base)
      (cat "sexp_make_non_null_input_port(ctx, " val ", SEXP_FALSE)"))
     ((eq? 'output-port base)
      (cat "sexp_make_non_null_output_port(ctx, " val ", SEXP_FALSE)"))
     ((eq? 'input-output-port base)
      (cat "sexp_make_non_null_input_output_port(ctx, " val ", SEXP_FALSE)"))
     ((memq base '(fileno fileno-nonblock))
      (cat "sexp_make_fileno(ctx, sexp_make_fixnum(" val "), SEXP_FALSE)"))
     ((eq? base 'uvector)
      val)
     ((uniform-vector-type? base)
      (cat "sexp_make_cuvector(ctx, " (uniform-vector-type-code base) ", "
           val ", " (if (c-type-free? type) 1 0) ")"))
     (else
      (let ((ctype (lookup-type base))
            (void*? (void-pointer-type? type)))
        (cond
         ((or ctype void*?)
          (cat "sexp_make_cpointer(ctx, "
               (if void*?
                   "SEXP_CPOINTER"
                   ;;(string-append "sexp_type_tag(" (type-id-name base) ")")
                   (type-id-number type #t))
               ", "
               val ", " (or (and (pair? o) (car o)) "SEXP_FALSE") ", "
               (if (c-type-free? type) 1 0)
               ")"))
         (else
          (error "unknown type" base))))))))

(define (scheme->c-converter type val)
  (let* ((type (parse-type type))
         (base (type-base type)))
    (cond
     ((eq? base 'sexp)
      (cat val))
     ((memq base '(bool boolean status-bool))
      (cat "sexp_truep(" val ")"))
     ((eq? base 'time_t)
      (cat "sexp_unshift_epoch(sexp_uint_value(" val "))"))
     ((enum-type? base)
      => (lambda (x) (cat "((" (cdr x) ")sexp_sint_value(" val "))")))
     ((signed-int-type? base)
      (cat "sexp_sint_value(" val ")"))
     ((unsigned-int-type? base)
      (cat "sexp_uint_value(" val ")"))
     ((float-type? base)
      (cat "sexp_flonum_value(" val ")"))
     ((eq? base 'char)
      (cat "sexp_unbox_character(" val ")"))
     ((eq? base 'env-string)
      (cat "sexp_concat_env_string(" val ")"))
     ((string-type? base)
      (cat (if (type-null? type)
            "sexp_string_maybe_null_data"
            "sexp_string_data")
           "(" val ")"))
     ((memq base '(bytevector u8vector))
      (cat (if (type-null? type)
            "sexp_bytes_maybe_null_data"
            "sexp_bytes_data")
           "(" val ")"))
     ((eq? base 'port-or-fileno)
      (cat "(sexp_portp(" val ") ? sexp_port_fileno(" val ")"
           " : sexp_filenop(" val ") ? sexp_fileno_fd(" val ")"
           " : sexp_unbox_fixnum(" val "))"))
     ((port-type? base)
      (cat "sexp_port_stream(" val ")"))
     ((memq base '(fileno fileno-nonblock))
      (cat "(sexp_filenop(" val ") ? sexp_fileno_fd(" val ")"
           " : sexp_unbox_fixnum(" val "))"))
     ((uniform-vector-type? base)
      (cat "((" (uniform-vector-ctype base) ") sexp_uvector_data(" val "))"))
     (else
      (let ((ctype (lookup-type base))
            (void*? (void-pointer-type? type)))
        (cond
         ((or ctype void*?)
          (cat (if (or (type-struct? type) (type-reference? type)) "*" "")
               "(" (type-c-name type) ")"
               (if (type-address-of? type) "&" "")
               (if (type-null? type)
                   "sexp_cpointer_maybe_null_value"
                   "sexp_cpointer_value")
               "(" val ")"))
         (else
          (error "unknown type" base))))))))

(define (base-type-c-name base)
  (case base
    ((string env-string non-null-string bytevector u8vector)
     (if *c++?* "string" "char*"))
    ((fileno fileno-nonblock) "int")
    ((u1 u8 u16 u32 u64 s8 s16 s32 s64 f32 f64)
     (let ((a
            (uniform-vector-ctype
             (string->symbol
              (string-append (x->string base) "vector")))))
       (substring a 0 (- (string-length a) 1))))
    (else
     (if (uniform-vector-type? base)
         (uniform-vector-ctype base)
         (string-replace (symbol->string base) #\- " ")))))

(define (type-struct-type type)
  (let ((type-spec (lookup-type (if (vector? type) (type-base type) type))))
    (cond ((and type-spec (memq 'type: type-spec)) => cadr)
          (else #f))))

(define (type-c-name-derefed type)
  (let* ((type (parse-type type))
         (base (type-base type))
         (type-spec (lookup-type base))
         (struct-type (type-struct-type type)))
    (string-append
     (if (type-const? type) "const " "")
     (if (and struct-type (not *c++?*))
         (string-append (symbol->string struct-type) " ")
         "")
     (base-type-c-name base)
     (if (type-template type)
         (string-append
          "<"
          (string-concatenate (map type-c-name (type-template type)) ", ")
          ">")
         ""))))

(define (type-c-name type)
  (let ((type (parse-type type)))
    (string-append
     (type-c-name-derefed type)
     (if (type-struct-type type) "*" "")
     (if (type-pointer? type) "*" ""))))

(define (type-finalizer-name type)
  (let ((name (type-c-name-derefed type)))
    (string-append "sexp_finalize_" (string-replace name #\: "_"))))

(define (check-type arg type)
  (let* ((type (parse-type type))
         (base (type-base type)))
    (cond
     ((eq? base 'env-string)
      (cat "(sexp_pairp(" arg ") && sexp_stringp(sexp_car(" arg
           ")) && sexp_stringp(sexp_cdr(" arg ")))"))
     ((memq base '(fileno fileno-nonblock))
      (cat "(sexp_filenop(" arg ") || sexp_fixnump(" arg "))"))
     ((string-type? base)
      (cat
       (if (type-null? type) "(" "")
       (type-predicate type) "(" arg ")"
       (lambda () (if (type-null? type) (cat " || sexp_not(" arg "))")))))
     ((or (eq? base 'char) (int-type? base) (float-type? base) (port-type? base)
          (memq base '(bytevector u8vector)) (uniform-vector-type? base))
      (cat (type-predicate type) "(" arg ")"))
     ((or (lookup-type base) (void-pointer-type? type))
      (cat
       (if (type-null? type) "(" "")
       "(sexp_pointerp(" arg  ")"
       " && (sexp_pointer_tag(" arg  ") == "
       (if (void-pointer-type? type)
           "SEXP_CPOINTER"
           (type-id-number type))
       "))"
       (lambda () (if (type-null? type) (cat " || sexp_not(" arg "))")))))
     (else
      (warn "don't know how to check" type)
      (cat "1")))))

(define (write-validator arg type)
  (let* ((type (parse-type type))
         (array (type-array type))
         (base-type (type-base type)))
    (cond
     ((and array (not (string-type? type)))
      (cond
       ((number? array)
        (cat "  if (!sexp_listp(ctx, " arg ")"
             "      || sexp_unbox_fixnum(sexp_length(ctx, " arg ")) != " array ")\n"
             "    return sexp_type_exception(ctx, self, SEXP_PAIR, " arg ");\n")))
      (cat "  for (res=" arg "; sexp_pairp(res); res=sexp_cdr(res))\n"
           "    if (! " (lambda () (check-type "sexp_car(res)" type)) ")\n"
           "      return sexp_xtype_exception(ctx, self, \"not a list of "
           (type-name type) "s\", " arg ");\n")
      (if (not (number? array))
          (cat "  if (! sexp_nullp(res))\n"
               "    return sexp_xtype_exception(ctx, self, \"not a list of "
               (type-name type) "s\", " arg ");\n")))
     ((eq? base-type 'port-or-fileno)
      (cat "  if (! (sexp_portp(" arg ") || sexp_filenop(" arg ") || sexp_fixnump(" arg ")))\n"
           "    return sexp_xtype_exception(ctx, self, \"not a port or file descriptor\"," arg ");\n"))
     ((or (int-type? base-type)
          (float-type? base-type)
          (string-type? base-type)
          (port-type? base-type)
          (uniform-vector-type? base-type)
          (memq base-type '(bytevector u8vector fileno fileno-nonblock))
          (and (not array) (eq? 'char base-type)))
      (cat
       "  if (! " (lambda () (check-type arg type)) ")\n"
       "    return sexp_type_exception(ctx, self, "
       (type-id-number type) ", " arg ");\n"))
     ((or (lookup-type base-type) (void-pointer-type? type))
      (cat
       "  if (! " (lambda () (check-type arg type)) ")\n"
       "    return sexp_type_exception(ctx, self, "
       (type-id-number type) ", " arg ");\n"))
     ((eq? 'sexp base-type))
     ((string-type? type)
      (write-validator arg 'string))
     ((memq base-type '(bool boolean status-bool)))
     (else
      (warn "don't know how to validate" type)))))

(define (write-parameters args)
  (lambda () (for-each (lambda (a) (cat ", sexp arg" (type-index a))) args)))

(define (take ls n)
  (let lp ((ls ls) (n n) (res '()))
    (if (zero? n) (reverse res) (lp (cdr ls) (- n 1) (cons (car ls) res)))))

(define max-gc-vars 7)

(define (write-gc-vars ls . o)
  (let ((num-gc-vars (length ls)))
    (cond
     ((zero? num-gc-vars))
     ((<= num-gc-vars max-gc-vars)
      (cat "  sexp_gc_var" num-gc-vars "(")
      (display (car ls))
      (for-each (lambda (x) (display ", ") (display x)) (cdr ls))
      (cat ");\n"))
     (else
      (write-gc-vars (take ls max-gc-vars))
      (let lp ((ls (list-tail ls max-gc-vars))
               (i (+ max-gc-vars 1)))
        (cond
         ((pair? ls)
          (cat "  sexp_gc_var(" (car ls) ", __sexp_gc_preserver" i ");\n")
          (lp (cdr ls) (+ i 1)))))))))

(define (write-gc-preserves ls)
  (let ((num-gc-vars (length ls)))
    (cond
     ((zero? num-gc-vars))
     ((<= num-gc-vars max-gc-vars)
      (cat "  sexp_gc_preserve" num-gc-vars "(ctx")
      (for-each (lambda (x) (display ", ") (display x)) ls)
      (cat ");\n"))
     (else
      (write-gc-preserves (take ls max-gc-vars))
      (let lp ((ls (list-tail ls max-gc-vars))
               (i (+ max-gc-vars 1)))
        (cond
         ((pair? ls)
          (cat "  sexp_gc_preserve(ctx, " (car ls)
               ", __sexp_gc_preserver" i ");\n")
          (lp (cdr ls) (+ i 1)))))))))

(define (write-gc-release ls)
  (if (pair? ls)
      (cat "  sexp_gc_release" (min max-gc-vars (length ls)) "(ctx);\n")))

(define (get-array-length func x)
  (let ((len (if (pair? (type-array x))
                 (car (reverse (type-array x)))
                 (type-array x))))
    (cond
     ((number? len)
      len)
     (else
      (and func
           (symbol? len)
           (let* ((str (symbol->string len))
                  (len2 (string-length str)))
             (and (> len2 3)
                  (string=? "arg" (substring str 0 3))
                  (let ((i (string->number (substring str 3 len2))))
                    (if i
                        (let ((y (list-ref (func-c-args func) i)))
                          (or (type-value y) len)))))))))))

(define (write-locals func)
  (define (arg-res x)
    (string-append "res" (type-index-string x)))
  (let* ((ret-type (func-ret-type func))
         (results (func-results func))
         (scheme-args (func-scheme-args func))
         (return-res? (not (error-type? ret-type)))
         (preserve-res? (> (+ (length results)) (if return-res? 0 1)))
         (single-res? (and (= 1 (length results)) (not return-res?)))
         (tmp-string? (any (lambda (a)
                             (and (type-array a)
                                  (string-type? (type-base a))))
                           (cons ret-type results)))
         (gc-vars (map arg-res results))
         (gc-vars (if tmp-string? (cons "str" gc-vars) gc-vars))
         (gc-vars (if preserve-res? (cons "res" gc-vars) gc-vars))
         (sexps (if preserve-res? '() '("res")))
         (ints (if (or return-res?
                       (memq (type-base ret-type)
                             '(status-bool non-null-string non-null-pointer)))
                   '()
                   '("err")))
         (ints (if (or (array-type? ret-type)
                       (any array-type? results)
                       (any array-type? scheme-args))
                   (cons "i" ints)
                   ints)))
    (case (type-base ret-type)
      ((status-bool) (cat "  bool err;\n"))
      ((non-null-string) (cat "  char *err;\n"))
      ((non-null-pointer) (cat "  void *err;\n")))
    (if (type-struct? ret-type)
        (cat "  struct " (type-base ret-type) " struct_res;\n"
             "  struct " (type-base ret-type) "* ptr_res;\n"))
    (cond
     ((pair? ints)
      (cat "  int " (car ints) " = 0"
           (lambda ()
             (for-each (lambda (x) (cat ", " x " = 0")) (cdr ints)))
           ";\n")))
    (if (any (lambda (a) (eq? 'env-string (type-base a)))
             (cons ret-type results))
        (cat "  char *p;\n"))
    (for-each
     (lambda (x)
       (let ((len (get-array-length func x)))
         (cat "  " (if (type-const? x) "const " "")
              (type-c-name (type-base x)) " ")
         (if (or (and (type-array x) (not (number? len))) (type-pointer? x))
             (cat "*"))
         (cat (if (type-auto-expand? x) "buf" "tmp") (type-index-string x))
         (if (number? len)
             (cat "[" len "]"))
         (cond
          ((type-reference? x)
           (cat " = NULL"))
          ((type-error x)
           (cat " = 0")))
         (cat ";\n")
         (if (or (vector? len) (type-auto-expand? x))
             (cat "  int len" (type-index x) ";\n"))
         (if (type-auto-expand? x)
             (cat "  " (type-c-name (type-base x))
                  " *tmp" (type-index-string x) ";\n"))))
     (append (if (or (type-array ret-type) (type-pointer? ret-type))
                 (list ret-type)
                 '())
             results
             (remove type-result? (filter type-array scheme-args))))
    (for-each
     (lambda (arg)
       (cond
        ((and (type-pointer? arg) (basic-type? arg))
         (cat "  " (if (type-const? arg) "const " "")
              (type-c-name (type-base arg))
              " tmp" (type-index arg) ";\n"))))
     scheme-args)
    (cond
     ((pair? sexps)
      (cat "  sexp " (car sexps))
      (for-each (lambda (x) (display ", ") (display x)) (cdr sexps))
      (cat ";\n")))
    ;; Declare the gc vars.
    (write-gc-vars gc-vars)
    ;; Shortcut returns should come before preserving.
    (write-validators (func-scheme-args func))
    (write-additional-checks (func-c-args func))
    ;; Preserve the gc vars.
    (write-gc-preserves gc-vars)))

(define (write-validators args)
  (for-each
   (lambda (a)
     (write-validator (string-append "arg" (type-index-string a)) a))
   args))

(define (write-additional-checks args)
  (for-each
   (lambda (a)
     (if (port-type? (type-base a))
         (cat "  if (!sexp_stream_portp(arg" (type-index a) "))\n"
              "    return sexp_xtype_exception(ctx, self,"
              " \"not a FILE* backed port\", arg" (type-index a) ");\n")))
   args)
  (for-each
   (lambda (a)
     (if (eq? 'input-port (type-base a))
         (cat "  sexp_check_block_port(ctx, arg" (type-index a) ", 0);\n")))
   args))

(define (scheme-procedure->c name)
  (cond
   ((eq? name 'length) 'sexp_length_unboxed)
   ((eq? name 'string-length) 'sexp_string_length)
   ((eq? name 'string-size) 'sexp_string_size)
   ((memq name '(bytevector-length u8vector-length)) 'sexp_bytes_length)
   ((eq? name 'uvector-length) 'sexp_uvector_length)
   (else name)))

(define (write-value func val)
  (cond
   ((find (lambda (x)
            (and (type-array x)
                 (type-auto-expand? x)
                 (eq? val (get-array-length func x))))
          (func-c-args func))
    => (lambda (x) (cat "len" (type-index x))))
   ((lookup-type val)
    (cat (or (type-struct-type val) "") " " val))
   ((and (pair? val) (list? val))
    (write (scheme-procedure->c (car val)))
    (cat
     "("
     (lambda ()
       (cond
        ((pair? (cdr val))
         (write-value func (cadr val))
         (for-each (lambda (x) (display ", ") (write-value func x)) (cddr val)))))
     ")"))
   (else
    (write val))))

(define (write-actual-parameter func arg)
  (cond
   ((or (type-result? arg) (type-array arg))
    (cat (if (or (type-free? arg) (type-reference? arg)
                 (type-address-of? arg) (basic-type? arg)
                 ;; a non-pointer, non-basic result needs indirection
                 (and (type-result? arg) (not (type-pointer? arg))
                      (not (type-struct-type arg)) (not (basic-type? arg))
                      (not (type-array arg))))
             "&"
             "")
         "tmp" (type-index arg)))
   ((and (not (type-default? arg)) (type-value arg))
    => (lambda (x) (write-value func x)))
   ((and (type-pointer? arg) (basic-type? arg))
    (cat "&tmp" (type-index arg)))
   (else
    (scheme->c-converter
     arg
     (string-append "arg" (type-index-string arg))))))

(define (write-temporaries func)
  (for-each
   (lambda (a)
     (let ((len (and (type-array a) (get-array-length func a))))
       (cond
        ((and (type-array a) (or (vector? len) (type-auto-expand? a)))
         (cat "  len" (type-index a) " = "
              (lambda ()
                (if (number? len) (cat len) (scheme->c-converter 'int len)))
              ";\n"
              "  tmp" (type-index a) " = buf" (type-index a) ";\n")))
       (cond
        ((and (not (type-result? a)) (type-array a) (not (string-type? a)))
         (if (not (number? (type-array a)))
             (if (and *c++?* (type-new? a))
                 (cat "  tmp" (type-index a)
                      " = new " (type-c-name-derefed (type-base a)) "();\n")
                 (cat "  tmp" (type-index a)
                      " = (" (if (type-const? a) "const " "")
                      (type-c-name (type-base a)) "*) "
                      "calloc((sexp_unbox_fixnum(sexp_length(ctx, arg"
                      (type-index a)
                      "))+1), sizeof(tmp" (type-index a) "[0]));\n")))
         (cat "  for (i=0, res=arg" (type-index a)
              "; sexp_pairp(res); res=sexp_cdr(res), i++) {\n"
              "    tmp" (type-index a) "[i] = "
              (lambda () (scheme->c-converter (type-base a) "sexp_car(res)"))
              ";\n"
              "  }\n")
         (if (not (number? (type-array a)))
             (cat "  tmp" (type-index a) "[i] = 0;\n")))
        ((and (type-result? a) (not (basic-type? a))
              (not (type-free? a)) ;;(not (type-pointer? a))
              (not (type-reference? a))
              (not (type-auto-expand? a))
              (or (not (type-array a))
                  (not (integer? len))))
         (if (and *c++?* (type-new? a))
             (cat "  tmp" (type-index a)
                  " = new " (type-c-name-derefed (type-base a)) "();\n")
             (cat "  tmp" (type-index a) " = "
                  (lambda () (cat "(" (type-c-name (type-base a))
                              (if (or (type-pointer? a)
                                      (and (not (int-type? a))
                                           (not (type-struct-type a))))
                                  "*"
                                  "")
                              ")"))
                  " calloc(1, 1 + "
                  (if (and (symbol? len) (not (eq? len 'null)))
                      (lambda () (cat (lambda () (scheme->c-converter 'unsigned-int len))
                                  "*sizeof(tmp" (type-index a) "[0])"))
                      (lambda () (cat "sizeof(tmp" (type-index a) "[0])")))
                  ");\n"
                  ;; (lambda ()
                  ;;   (if (and (symbol? len) (not (eq? len 'null)))
                  ;;       (cat "  tmp" (type-index a) "["
                  ;;            (lambda () (scheme->c-converter 'unsigned-int len))
                  ;;            "*sizeof(tmp" (type-index a) "[0])] = 0;\n")))
                  )))
        ((and (type-result? a) (type-value a))
         (cat "  tmp" (type-index a) " = "
              (lambda () (write-value func (type-value a))) ";\n"))
        ((and (type-pointer? a) (basic-type? a))
         (cat "  tmp" (type-index a) " = "
              (lambda ()
                (scheme->c-converter
                 a
                 (string-append "arg" (type-index-string a))))
              ";\n")))))
   (func-c-args func)))

(define (write-call func)
  (let ((ret-type (func-ret-type func))
        (c-name (func-c-name func))
        (c-args (func-c-args func)))
    (if (any type-auto-expand? (func-c-args func))
        (cat " loop:\n"))
    (cat (cond ((error-type? ret-type) "  err = ")
               ((type-array ret-type) "  tmp = ")
               ((type-struct? ret-type) "  struct_res = ")
               (else "  res = ")))
    ((if (or (type-array ret-type)
             (type-struct? ret-type))
         (lambda (t f x) (f))
         c->scheme-converter)
     ret-type
     (lambda ()
       (if (and *c++?* (type-new? ret-type))
           (cat "new "))
       (if (func-method? func)
           (cat "(" (lambda () (write-actual-parameter func (car c-args)))
                ")->" c-name)
           (cat c-name))
       (cat "(")
       (for-each
        (lambda (arg)
          (if (> (type-index arg) (if (func-method? func) 1 0)) (cat ", "))
          (write-actual-parameter func arg))
        (if (func-method? func) (cdr c-args) c-args))
       (cat ")"))
     (cond
      ((find type-link? (func-c-args func))
       => (lambda (a) (string-append "arg" (type-index-string a))))
      (else #f)))
    (cat ";\n")
    (if (type-array ret-type)
        (write-result ret-type)
        (write-result-adjustment ret-type))))

(define (write-result-adjustment result)
  (cond
   ;; new port results are automatically made non-blocking
   ((memq (type-base result) '(input-port output-port input-output-port))
    (let ((res (string-append "res" (type-index-string result))))
      (cat "#ifdef SEXP_USE_GREEN_THREADS\n"
           "  if (sexp_portp(" res "))\n"
           "    fcntl(fileno(sexp_port_stream(" res ")), F_SETFL, O_NONBLOCK "
           " | fcntl(fileno(sexp_port_stream(" res ")), F_GETFL));\n"
           "#endif\n")))
   ;; a file descriptor result can be automatically made non-blocking
   ;; by specifying a result type of fileno-nonblock
   ((memq (type-base result) '(fileno-nonblock))
    (let ((res (string-append "res" (type-index-string result))))
      (cat "#ifdef SEXP_USE_GREEN_THREADS\n"
           "  if (sexp_filenop(" res "))\n"
           "    fcntl(sexp_fileno_fd(" res "), F_SETFL, O_NONBLOCK "
           " | fcntl(sexp_fileno_fd(" res "), F_GETFL));\n"
           "#endif\n")))
   ;; non-pointer struct return types need to be copied to the heap
   ((type-struct? result)
    (cat
     "  ptr_res = (" (type-c-name result) ") malloc(sizeof("
     (type-c-name-derefed result) "));\n"
     "  memcpy(ptr_res, &struct_res, sizeof(" (type-c-name-derefed result) "));\n"
     "  res = sexp_make_cpointer(ctx, sexp_unbox_fixnum(sexp_opcode_return_type(self)), ptr_res, SEXP_FALSE, 0);\n"))
   ))

(define (write-result result . o)
  (let ((res (string-append "res" (type-index-string result)))
        (tmp (string-append "tmp" (type-index-string result))))
    (cond
     ((and (type-array result) (eq? 'char (type-base result)))
      (cat "  " res " = " (lambda () (c->scheme-converter result tmp)) ";\n"))
     ((type-array result)
      (cat "  " res " = SEXP_NULL;\n")
      (let ((auto-expand?
             (and (pair? (type-array result))
                  (memq 'auto-expand (type-array result))))
            (len (if (pair? (type-array result))
                     (car (reverse (type-array result)))
                     (type-array result))))
        (cond
         ((eq? 'null len)
          (cat "  for (i=0; " tmp "[i]; i++) {\n"
               "    sexp_push(ctx, " res ", "
               (if (eq? 'string (type-base result))
                   "str="
                   (lambda () (cat "SEXP_VOID);\n    sexp_car(" res ") = ")))
               (lambda () (c->scheme-converter result (lambda () (cat tmp "[i]"))))
               ");\n"
               "  }\n"
               "  " res " = sexp_nreverse(ctx, " res ");\n"))
         (else
          (cat "  for (i=" (if (and (symbol? len)
                                    (equal? "arg"
                                            (substring (symbol->string len)
                                                        0 3)))
                               (string-append
                                "sexp_unbox_fixnum(" (symbol->string len) ")")
                               len)
               "-1; i>=0; i--) {\n"
               "    sexp_push(ctx, " res ", SEXP_VOID);\n"
               "    sexp_car(" res ") = "
               (lambda () (c->scheme-converter result (lambda () (cat tmp "[i]"))))
               ";\n"
               "  }\n")))))
     (else
      (cat "  " res " = ")
      (apply
       c->scheme-converter
       result
       (string-append "tmp" (type-index-string result))
       o)
      (cat ";\n")))
    (write-result-adjustment result)))

(define (write-results func)
  (let* ((error-res (cond ((error-type? (func-ret-type func))
                           (func-ret-type func))
                          ((find type-error (func-c-args func)))
                          (else #f)))
         (error-return? (eq? error-res (func-ret-type func)))
         (void-res? (eq? 'void (type-base (func-ret-type func))))
         (results (remove type-error (func-results func))))
    (if error-res
        (cat "  if ("
             (if (memq (type-base error-res)
                       '(status-bool non-null-string non-null-pointer))
                 "!"
                 "")
             (if error-return?
                 "err"
                 (string-append "tmp" (type-index-string error-res)))
             ") {\n"
             (cond
              ((find type-auto-expand? (func-c-args func))
               => (lambda (a)
                    (lambda ()
                      (let ((len (get-array-length func a))
                            (i (type-index a)))
                        (cat "  if (len" i " > " auto-expand-limit ") {\n"
                             "    res = sexp_user_exception(ctx, self, "
                             "\"exceeded max auto-expand len in " (func-scheme-name func) "\", SEXP_NULL);\n"
                             "} else {\n")
                        (if (number? len)
                            (cat "  if (len" i " != " len ")\n"
                                 "    free(tmp" i ");\n"))
                        (cat "  len" i " *= 2;\n"
                             "  tmp" i " = "
                             (lambda () (cat "(" (type-c-name (type-base a))
                                         (if (or (type-pointer? a)
                                                 (and (not *c++?*)
                                                      (string-type? a)))
                                             "*"
                                             "")
                                         ")"))
                             " calloc(len" i ", sizeof(tmp" i "[0]));\n"
                             "  goto loop;\n"
                             "}\n")))))
              (error-return?
               ;; TODO: free other results
               "  res = SEXP_FALSE;\n")
              (else
               (lambda ()
                 (cat "  res = sexp_user_exception(ctx, self, "
                      (type-error error-res) "(tmp"
                      (type-index-string error-res)
                      "), SEXP_NULL);\n"))))
             "  } else {\n"))
    (if (null? results)
        (if (and error-res error-return?)
            (cat "  res = SEXP_TRUE;\n"))
        (let ((first-result-link
               ;; the `link' modifier applies to the first result when
               ;; there are multiple results
               (and
                (not (lookup-type (func-ret-type func)))
                (cond
                 ((find type-link? (func-c-args func))
                  => (lambda (a) (string-append "arg" (type-index-string a))))
                 (else #f)))))
          (write-result (car results) first-result-link)
          (for-each write-result (cdr results))))
    (cond
     ((> (length results) (if (or error-res void-res?) 1 0))
      (if (or error-res void-res?)
          (cat "  res = SEXP_NULL;\n")
          (cat "  res = sexp_cons(ctx, res, SEXP_NULL);\n"))
      (for-each
       (lambda (x)
         (if (or error-res void-res?)
             (cat "  sexp_push(ctx, res, res" (type-index x) ");\n")
             (cat "  sexp_push(ctx, res, sexp_car(res));\n"
                  "  sexp_cadr(res) = res" (type-index x) ";\n")))
       (reverse results)))
     ((pair? results)
      (cat "  res = res" (type-index (car results)) ";\n")))
    (if error-res
        (cat "  }\n"))))

(define (write-free type)
  (if (and (type-array type) (not (number? (type-array type))))
      (cat "  free(tmp" (type-index-string type) ");\n")))

(define (write-cleanup func)
  (for-each write-free (func-scheme-args func))
  (for-each
   (lambda (a)
     (cond
      ((type-auto-expand? a)
       (let ((len (get-array-length func a))
             (i (type-index a)))
         (if (number? len)
             (cat "  if (len" i " != " len ")\n"
                  "    free(tmp" i ");\n"))))
      ((memq (type-base a) '(input-port input-output-port))
       (cat "  sexp_maybe_unblock_port(ctx, arg" (type-index a) ");\n"))
      ((and (type-result? a) (not (basic-type? a))
            (not (lookup-type (type-base a)))
            (not (type-free? a)) (not (type-pointer? a))
            (or (not (type-array a))
                (not (integer? (get-array-length func a)))))
       ;; the above is hairy - basically this frees temporary strings
       (cat "  free(tmp" (type-index a) ");\n"))))
   (func-c-args func))
  (let* ((results (func-results func))
         (return-res? (not (error-type? (func-ret-type func))))
         (preserve-res? (> (+ (length results)) (if return-res? 0 1)))
         (single-res? (and (= 1 (length results)) (not return-res?)))
         (tmp-string? (any (lambda (a)
                             (and (type-array a)
                                  (string-type? (type-base a))))
                           (cons (func-ret-type func)
                                 (func-results func))))
         (gc-vars results)
         (gc-vars (if tmp-string? (cons "str" gc-vars) gc-vars))
         (gc-vars (if preserve-res? (cons "res" gc-vars) gc-vars)))
    (write-gc-release gc-vars)))

(define (write-func-declaration func)
  (cat "sexp " (func-stub-name func)
       " (sexp ctx, sexp self, sexp_sint_t n"
       (write-parameters (func-scheme-args func)) ")"))

(define (write-func func)
  (write-func-declaration func)
  (cat " {\n")
  (write-locals func)
  (write-temporaries func)
  (write-call func)
  (write-results func)
  (write-cleanup func)
  (cat "  return res;\n"
       "}\n\n"))

(define (adjust-method-name! func i)
  (func-stub-name-set!
   func
   (string-append (func-stub-name func) "__" (number->string i))))

(define (write-primitive-call func args)
  (cat (func-stub-name func)
       "(" (lambda () (join (append '(ctx self n) args) ", ")) ")"))

(define (write-fixed-arity-method meth)
  (define (write-dispatch func)
    (write-primitive-call
     func
     (map (lambda (a) (string-append "arg" (type-index-string a)))
          (func-scheme-args func))))
  (define (write-method-validators func)
    (cond
     ((not (pair? (cdr (func-scheme-args func))))
      (warn "no arguments to distinguish" func)
      (cat "1"))
     (else
      (let lp ((ls (cdr (func-scheme-args func))))
        (check-type (string-append "arg" (type-index-string (car ls))) (car ls))
        (cond
         ((pair? (cdr ls))
          (cat " && ")
          (lp (cdr ls))))))))
  (case (length meth)
    ((0 1)
     (error "invalid method" meth))
    ((2)
     (write-func (cadr meth)))
    (else
     (let ((orig-stub-name (func-stub-name (cadr meth))))
       (do ((ls (cdr meth) (cdr ls)) (i 0 (+ i 1)))
           ((null? ls))
         (adjust-method-name! (car ls) i)
         (write-func (car ls)))
       (let ((new-stub-name (func-stub-name (cadr meth))))
         (func-stub-name-set! (cadr meth) orig-stub-name)
         (write-func-declaration (cadr meth))
         (func-stub-name-set! (cadr meth) new-stub-name)
         (cat " {\n"
              "  sexp orig_self = self;\n")
         (write-validator "arg0" (car (func-scheme-args (cadr meth))))
         (let lp ((ls (cdr meth)) (i 0))
           (cat "  self = sexp_vector_ref(sexp_opcode_methods(orig_self), "
                (make-integer i) ");\n")
           (cond
            ((null? (cdr ls))
             (cat "  return " (lambda () (write-dispatch (car ls))) ";\n"))
            (else
             (cat "  if ("
                  (lambda () (write-method-validators (car ls))) ") {\n"
                  "    return " (lambda () (write-dispatch (car ls))) ";\n"
                  "  }\n" (lambda () (lp (cdr ls) (+ i 1)))))))
         (cat "}\n\n")
         (func-stub-name-set! (cadr meth) orig-stub-name))))))

(define (write-method meth)
  (let ((args (map func-scheme-args (cdr meth))))
    (if (and (> (length args) 1)
             (not (apply = (map length args))))
        (error "methods must have the same arity")))
  (write-fixed-arity-method meth))

(define (parameter-default? x)
  (and (pair? x)
       (member x '((current-input-port)
                   (current-output-port)
                   (current-error-port)))))

(define (write-default x) ;; this is a hack but very convenient
  (lambda ()
    (let ((value (type-value x)))
      (cond
       ((equal? value '(current-input-port))
        (cat "\"current-input-port\""))
       ((equal? value '(current-output-port))
        (cat "\"current-output-port\""))
       ((equal? value '(current-error-port))
        (cat "\"current-error-port\""))
       ((equal? value 'NULL)
        (cat "SEXP_FALSE"))
       (else
        (c->scheme-converter x value))))))

(define (write-func-creation var func . o)
  (let ((default (and (pair? (func-scheme-args func))
                      (type-default? (car (reverse (func-scheme-args func))))
                      (car (reverse (func-scheme-args func)))))
        (no-bind? (and (pair? o) (car o))))
    (cat "  " var " = "
         (cond
          (no-bind?
           "sexp_make_foreign(ctx, ")
          ((not default)
           "sexp_define_foreign(ctx, env, ")
          ((parameter-default? (type-value default))
           "sexp_define_foreign_param(ctx, env, ")
          (else
           "sexp_define_foreign_opt(ctx, env, "))
         (lambda () (write (symbol->string (func-scheme-name func))))
         ", " (length (func-scheme-args func))  ", "
         (if no-bind?
             (lambda ()
               (cat (cond ((not default) 0)
                          ((parameter-default? (type-value default)) 3)
                          (else 1))
                    ", "))
             "")
         (func-stub-name func)
         (cond
          (default (lambda () (cat ", " (write-default default))))
          (no-bind? ", SEXP_VOID")
          (else ""))
         ");\n")))

(define (write-func-types var func)
  (cond
   ((or (not (eq? 'sexp (type-base (func-ret-type func))))
        (and (pair? (func-c-args func))
             (any (lambda (a) (not (eq? 'sexp (type-base a))))
                  (func-c-args func))))
    (cat
     "  if (sexp_opcodep(" var ")) {\n"
     "    sexp_opcode_return_type(" var ") = "
     (type-id-init-value (func-ret-type func)) ";\n"
     (lambda ()
       (do ((ls (func-c-args func) (cdr ls))
            (i 1 (+ i 1)))
           ((null? ls))
         (cond
          ((eq? 'sexp (type-base (car ls))))
          ((<= i 3)
           (cat "    sexp_opcode_arg" i "_type(" var ") = "
                (type-id-init-value (car ls)) ";\n"))
          (else
           (if (= i 4)
               (cat "    sexp_opcode_argn_type(" var ") = "
                    "sexp_make_vector(ctx, "
                    (make-integer (- (length (func-c-args func)) 3)) ", "
                    (make-integer "SEXP_OBJECT") ");\n"))
           (cat "    sexp_vector_set(sexp_opcode_argn_type(" var "), "
                (make-integer (- i 4)) ", "
                (type-id-init-value (car ls)) ");\n")))))
     ;; "  } else {\n"
     ;; "    sexp_warn(ctx, \"couldn't generated opcode\", " var ");\n"
     "  }\n")))
  (cond
   ((assq (func-scheme-name func) *type-getters*)
    => (lambda (x)
         (let ((name (cadr x))
               (i (car (cddr x))))
           (cat "  if (sexp_vectorp(sexp_type_getters(" (type-id-name name)
                "))) sexp_vector_set(sexp_type_getters("
                (type-id-name name) "), "
                (make-integer i) ", " var ");\n"))))
   ((assq (func-scheme-name func) *type-setters*)
    => (lambda (x)
         (let ((name (cadr x))
               (i (car (cddr x))))
           (cat "  if (sexp_vectorp(sexp_type_setters(" (type-id-name name)
                "))) sexp_vector_set(sexp_type_setters("
                (type-id-name name) "), "
                (make-integer i) ", " var ");\n"))))))

(define (write-func-binding func . o)
  (let ((var (if (pair? o) (car o) "op")))
    (write-func-creation var func)
    (write-func-types var func)))

(define (write-method-binding meth)
  (write-func-binding (cadr meth))
  (cat "  if (sexp_opcodep(op)) {\n"
       (lambda ()
         (cat "    sexp_opcode_methods(op) = "
              "sexp_make_vector(ctx, " (make-integer (length (cdr meth)))
              ", SEXP_VOID);\n")
         (do ((ls (cdr meth) (cdr ls)) (i 0 (+ i 1)))
             ((null? ls))
           (let ((var (string-append
                       "sexp_vector_ref(sexp_opcode_methods(op), "
                       (make-integer i) ")")))
             (write-func-creation var (car ls) #t)
             (write-func-types var (car ls)))))
       "  }\n"))

(define (write-type orig-type)
  (let* ((name (car orig-type))
         (scheme-name (strip-namespace (type-name name)))
         (type (cdr orig-type))
         (imported? (cond ((member 'imported?: type) => cadr) (else #f))))
    (cond
     (imported?
      (cat "  name = sexp_intern(ctx, \"" scheme-name "\", -1);\n"
           "  " (type-id-name name) " = sexp_env_ref(ctx, env, name, SEXP_FALSE);\n"
           "  if (sexp_not(" (type-id-name name) ")) {\n"
           "    sexp_warn(ctx, \"couldn't import declared type: \", name);\n"
           "  }\n"))
     (else
      (cat "  name = sexp_c_string(ctx, \"" scheme-name "\", -1);\n"
           "  " (type-id-name name)
           " = sexp_register_c_type(ctx, name, "
           (cond ((or (memq 'finalizer: type)
                      (memq 'finalizer-method: type))
                  => (lambda (x)
                       (let ((name (cadr x)))
                         (generate-stub-name
                          (if (pair? name) (car name) name)))))
                 (*c++?*
                  (type-finalizer-name name))
                 (else
                  "sexp_finalize_c_type"))
           ");\n"
           "  tmp = sexp_string_to_symbol(ctx, name);\n"
           "  sexp_env_define(ctx, env, tmp, " (type-id-name name) ");\n")
      (if (pair? (struct-fields type))
          (let ((len (make-integer (length (struct-fields type)))))
            (cat "  sexp_type_slots(" (type-id-name name) ") = SEXP_NULL;\n"
                 (lambda ()
                   (do ((ls (reverse (struct-fields type)) (cdr ls)))
                       ((not (pair? ls)))
                     (cat "  sexp_push(ctx, sexp_type_slots("
                          (type-id-name name) "), "
                          "sexp_intern(ctx, "
                          (lambda () (write (x->string (cadr (car ls)))))
                          ", -1));\n")))
                 "  sexp_type_getters(" (type-id-name name) ")"
                 " = sexp_make_vector(ctx, " len ", SEXP_FALSE);\n"
                 "  sexp_type_setters(" (type-id-name name) ")"
                 " = sexp_make_vector(ctx, " len ", SEXP_FALSE);\n")))
      (cond
       ((memq 'predicate: type)
        => (lambda (x)
             (let ((pred (cadr x)))
               (cat "  tmp = sexp_make_type_predicate(ctx, name, "
                    (type-id-name name) ");\n"
                    "  name = sexp_intern(ctx, \"" pred "\", "
                    (string-length (x->string pred)) ");\n"
                    "  sexp_env_define(ctx, env, name, tmp);\n")))))))))

(define (type-getter-name type name field)
  (let ((c-name (if (pair? (cadr field)) (cadr (cadr field)) (cadr field))))
    (string-replace
     (string-append "sexp_" (x->string (type-name (parse-type name)))
                    "_get_" (x->string c-name))
     #\: "_")))

(define (verify-accessor field)
  (if (and (pair? field)
           (not (and (= 3 (length field))
                     (memq (cadr field) '(function: method:)))))
      (error "accessor should be a single symbol or (scheme-name function:|method: c-name) but got" field)))

(define (write-type-getter type name field)
  (let* ((get (car (cddr field)))
         (_ (verify-accessor get))
         (c-name (if (pair? (cadr field)) (cadr (cadr field)) (cadr field)))
         (ptr (string-append
               "((" (x->string (or (type-struct-type name) ""))
               " " (x->string name) "*)"
               "sexp_cpointer_value(x))")))
    (cat "sexp " (type-getter-name type name field)
         " (sexp ctx, sexp self, sexp_sint_t n, sexp x) {\n"
         (lambda () (write-validator "x" (parse-type name 0)))
         "  return "
         (lambda ()
           (c->scheme-converter
            (car field)
            (cond
             ((and (pair? get) (eq? 'function: (cadr get)))
              (string-append (car (cddr get)) "(" ptr ")"))
             ((and (pair? get) (eq? 'method: (cadr get)))
              (string-append ptr "->" (car (cddr get)) "()"))
             ((pair? get)
              (error "invalid getter" get))
             (else
              (string-append
               (if (type-struct? (car field)) "&" "")
               ptr "->" (x->string c-name))))
            (and (or (type-struct? (car field)) (type-link? (car field)))
                 "x")))
         ";\n"
         "}\n\n")))

(define (type-setter-name type name field)
  (let ((c-name (if (pair? (cadr field)) (cadr (cadr field)) (cadr field))))
    (string-replace
     (string-append "sexp_" (x->string (type-name (parse-type name)))
                    "_set_" (x->string c-name))
     #\: "_")))

(define (write-type-setter-assignment type name field dst val)
  (let* ((set (cadr (cddr field)))
         (_ (verify-accessor set))
         (c-name (if (pair? (cadr field)) (cadr (cadr field)) (cadr field)))
         (ptr (string-append
               "((" (x->string (or (type-struct-type name) ""))
               " " (x->string name) "*)"
               "sexp_cpointer_value(" (x->string dst) "))")))
    (cond
     ((and (pair? set) (eq? 'function: (cadr set)))
      (lambda ()
        (cat (car (cddr set)) "(" ptr ", "
             (lambda () (scheme->c-converter (car field) val)) ");\n")))
     ((and (pair? set) (eq? 'method: (cadr set)))
      (lambda ()
        (cat ptr "->" (car (cddr set)) "("
             (lambda () (scheme->c-converter (car field) val)) ");\n")))
     ((pair? set)
      (error "invalid setter" set))
     ((type-struct? (car field))
      ;; assign to a nested struct - copy field-by-field
      (let ((field-type
             (cond ((lookup-type (type-name (car field)))
                    => (lambda (x) (cddr (cdr x))))
                   (else (cdr field)))))
        (lambda ()
          (for-each
           (lambda (subfield)
             (let ((subname (x->string (cadr subfield))))
               (cat
                "  "
                ptr "->" (x->string (cadr field))
                "." (x->string (cadr subfield))
                " = "
                (string-append
                 "((" (x->string (or (type-struct-type (type-name (car field)))
                                     ""))
                 " " (mangle (type-name (car field))) "*)"
                 "sexp_cpointer_value(" val "))"
                 "->" (x->string (cadr subfield)))
                ";\n")))
           (struct-fields field-type)))))
     (else
      (lambda ()
        (cat "  " ptr "->" c-name " = "
             (lambda () (scheme->c-converter (car field) val)) ";\n"))))))

(define (write-type-setter type name field)
  (cat "sexp " (type-setter-name type name field)
       " (sexp ctx, sexp self, sexp_sint_t n, sexp x, sexp v) {\n"
       (lambda () (write-validator "x" (parse-type name 0)))
       (lambda () (write-validator "v" (parse-type (car field) 1)))
       (write-type-setter-assignment type name field "x" "v")
       "  return SEXP_VOID;\n"
       "}\n\n"))

(define (write-type-funcs-helper orig-type name type)
  ;; maybe write finalizer
  (cond
   ((or (memq 'finalizer: type) (memq 'finalizer-method: type))
    => (lambda (x)
         (let* ((y (cadr x))
                (scheme-name (if (pair? y) (car y) y))
                (cname (if (pair? y) (cadr y) y))
                (method? (not (memq 'finalizer: type))))
           (cat "sexp " (generate-stub-name scheme-name)
                " (sexp ctx, sexp self, sexp_sint_t n, sexp x) {\n"
                "  if (sexp_cpointer_freep(x)) {\n"
                "    " (if method? "" cname) "("
                (if method? "(" "")
                "\n#ifdef __cplusplus\n"
                "(" (mangle name) "*)"
                "\n#endif\n"
                "sexp_cpointer_value(x)"
                (if method? (string-append ")->" (x->string cname) "()") "")
                ");\n"
                ;; TODO: keep track of open/close separately from ownership
                "    sexp_cpointer_freep(x) = 0;\n"
                "  }\n"
                "  return SEXP_VOID;\n"
                "}\n\n")
           ;; make the finalizer available
           (set! *funcs*
                 (cons (parse-func `(void ,y (,name))) *funcs*))))))
  ;; maybe write constructor
  (cond
   ((memq 'constructor: type)
    => (lambda (x)
         (let ((make (car (cadr x)))
               (args (cdr (cadr x))))
           (cat "sexp " (generate-stub-name make)
                " (sexp ctx, sexp self, sexp_sint_t n"
                (lambda ()
                  (let lp ((ls args) (i 0))
                    (cond ((pair? ls)
                           (cat ", sexp arg" i)
                           (lp (cdr ls) (+ i 1))))))
                ") {\n"
                "  " (type-c-name name) " r;\n"
                "  sexp_gc_var1(res);\n"
                "  sexp_gc_preserve1(ctx, res);\n"
                ;; TODO: support heap-managed allocations
                ;; "  res = sexp_alloc_tagged(ctx, sexp_sizeof(cpointer)"
                ;; " + sizeof(struct " (type-name name) "), "
                ;; (type-id-name name)
                ;; ");\n"
                ;; "  r = sexp_cpointer_value(res) = "
                ;; "sexp_cpointer_body(res);\n"
                ;; "  res = sexp_alloc_tagged(ctx, sexp_sizeof(cpointer), sexp_type_tag("
                ;; (type-id-name name)
                ;; "));\n"
                "  res = sexp_alloc_tagged(ctx, sexp_sizeof(cpointer), "
                "sexp_unbox_fixnum(sexp_opcode_return_type(self)));\n"
                "  sexp_cpointer_value(res) = calloc(1, sizeof("
                (type-c-name-derefed name) "));\n"
                "  r = (" (type-c-name name) ") sexp_cpointer_value(res);\n"
                "  memset(r, 0, sizeof("
                (type-c-name-derefed name) "));\n"
                "  sexp_freep(res) = 1;\n"
                (lambda ()
                  (let lp ((ls args) (i 0))
                    (cond
                     ((pair? ls)
                      (let* ((a (car ls))
                             (field
                              (find (lambda (f) (and (pair? f) (eq? a (cadr f))))
                                    (cddr x)))
                             (arg (string-append "arg" (number->string i))))
                        (cond
                         ((and field (>= (length field) 4))
                          (cat
                           (write-type-setter-assignment
                            type name field "res" arg)))
                         (field
                          (cat "  r->" (cadr field) " = "
                               (lambda ()
                                 (scheme->c-converter (car field) arg))
                               ";\n")))
                        (lp (cdr ls) (+ i 1)))))))
                "  sexp_gc_release1(ctx);\n"
                "  return res;\n"
                "}\n\n")
           (set! *funcs*
                 (cons (parse-func
                        `(,name ,make
                                ,(map (lambda (a)
                                        (cond
                                         ((find (lambda (x) (eq? a (cadr x)))
                                                (struct-fields type))
                                          => car)
                                         (else 'sexp)))
                                      args)))
                       *funcs*))))))
  ;; write field accessors
  (let lp ((ls (struct-fields type))
           (i 0))
    (cond
     ((not (pair? ls)))
     ((and (pair? (car ls)) (pair? (cdar ls)))
      (let* ((field (car ls))
             (get+set (cddr field)))
        (cond
         ((and (pair? get+set) (car get+set))
          (let ((get-name (if (pair? (car get+set))
                              (caar get+set)
                              (car get+set))))
            (write-type-getter type name field)
            (set! *funcs*
                  (cons (parse-func
                         `(,(car field)
                           (,get-name
                            #f
                            ,(type-getter-name type name field))
                           (,name)))
                        *funcs*))
            (if (type-struct-type name)
                (set! *type-getters*
                      (cons `(,get-name ,name ,i) *type-getters*)))))
         (else "SEXP_FALSE"))
        (cond
         ((and (pair? get+set)
               (pair? (cdr get+set))
               (cadr get+set))
          (let ((set-name (if (pair? (cadr get+set))
                              (car (cadr get+set))
                              (cadr get+set))))
            (write-type-setter type name field)
            (set! *funcs*
                  (cons (parse-func
                         `(,(car field)
                           (,set-name
                            #f
                            ,(type-setter-name type name field))
                           (,name ,(car field))))
                        *funcs*))
            (if (type-struct-type name)
                (set! *type-setters*
                      (cons `(,set-name ,name ,i) *type-setters*)))))))
      (lp (cdr ls) (+ i 1))))))

(define (write-type-funcs orig-type)
  (let* ((name (car orig-type))
         (type (cdr orig-type))
         (imported? (cond ((member 'imported?: type) => cadr) (else #f))))
    (if (not imported?)
        (write-type-funcs-helper orig-type name type))))

(define (write-const const)
  (let ((scheme-name
         (if (pair? (cadr const)) (car (cadr const)) (cadr const)))
        (c-name
         (if (pair? (cadr const)) (cadr (cadr const)) (mangle (cadr const)))))
    (cat "  name = sexp_intern(ctx, \"" scheme-name "\", "
         (string-length (x->string scheme-name)) ");\n"
         "  sexp_env_define(ctx, env, name, tmp="
         (lambda () (c->scheme-converter (car const) c-name)) ");\n")))

(define (write-utilities)
  (define (input-env-string? x)
    (and (eq? 'env-string (type-base x)) (not (type-result? x))))
  (cond
   (*c++?*
    (for-each
     (lambda (t)
       (cond
        ((and (not (memq 'finalizer: (cdr t)))
              (not (memq 'finalizer-method: (cdr t)))
              (type-struct-type (car t)))
         (let ((name (type-c-name-derefed (car t)))
               (finalizer-name (type-finalizer-name (car t))))
           (cat
            "sexp " finalizer-name " ("
            "sexp ctx, sexp self, sexp_sint_t n, sexp obj) {\n"
            "  if (sexp_cpointer_freep(obj))\n"
            "    delete static_cast<" name "*>"
            "(sexp_cpointer_value(obj));\n"
            "  sexp_cpointer_value(obj) = NULL;\n"
            "  return SEXP_VOID;\n"
            "}\n\n")))))
     *types*)))
  (cond
   ((any (lambda (f)
           (or (any input-env-string? (func-results f))
               (any input-env-string? (func-scheme-args f))))
         *funcs*)
    (cat "static char* sexp_concat_env_string (sexp x) {\n"
         "  int klen=sexp_string_size(sexp_car(x)), vlen=sexp_string_size(sexp_cdr(x));\n"
         "  char *res = (char*) calloc(1, klen+vlen+2);\n"
         "  strncpy(res, sexp_string_data(sexp_car(x)), klen);\n"
         "  res[sexp_string_size(sexp_car(x))] = '=';\n"
         "  strncpy(res+sexp_string_size(sexp_car(x)), sexp_string_data(sexp_cdr(x)), vlen);\n"
         "  res[len-1] = '\\0';\n"
         "  return res;\n"
         "}\n\n"))))

(define (write-init)
  (newline)
  (write-utilities)
  (for-each write-func *funcs*)
  (for-each write-method *methods*)
  (for-each write-type-funcs *types*)
  (for-each (lambda (n) (cat "}  // " n "\n")) *open-namespaces*)
  (newline)
  (if *c++?*
      (cat "extern \"C\"\n"))
  (cat "sexp sexp_init_library (sexp ctx, sexp self, sexp_sint_t n, sexp env, const char* version, const sexp_abi_identifier_t abi) {\n"
       (lambda ()
         (for-each
          (lambda (t) (cat "  sexp " t ";\n"))
          *tags*))
       "  sexp_gc_var3(name, tmp, op);\n"
       "  if (!(sexp_version_compatible(ctx, version, sexp_version)\n"
       "        && sexp_abi_compatible(ctx, abi, SEXP_ABI_IDENTIFIER)))\n"
       "    return SEXP_ABI_ERROR;\n"
       "  sexp_gc_preserve3(ctx, name, tmp, op);\n")
  (for-each write-const *consts*)
  (for-each write-type *types*)
  (for-each write-func-binding *funcs*)
  (for-each write-method-binding *methods*)
  (for-each (lambda (x) (cat "  " x "\n")) (reverse *inits*))
  (for-each *post-init-hook* (lambda (f) (f)))
  (cat "  sexp_gc_release3(ctx);\n"
       "  return SEXP_VOID;\n"
       "}\n\n"))

(define (generate file)
  (cat "/* Automatically generated by chibi-ffi; version: "
       *ffi-version* " */\n")
  (c-system-include "chibi/eval.h")
  (load file (current-environment))
  (cat "/*\ntypes: " (map car *types*) "\nenums: " *c-enum-types* "\n*/\n")
  (write-init))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; main

(let ((args (command-line)))
  (let lp ((args (if (pair? args) (cdr args) args))
           (compile? #f)
           (cc #f)
           (cflags '())
           (features '()))
    (cond
     ((and (pair? args) (not (equal? "" (car args)))
           (eqv? #\- (string-ref (car args) 0)))
      (case (string->symbol (car args))
        ((-c --compile)
         (lp (cdr args) #t cc cflags features))
        ((-cc --cc)
         (lp (cddr args) compile? (cadr args) cflags features))
        ((-f --flags)
         (if (null? (cdr args))
             (error "--flags requires an argument"))
         (lp (cddr args)
             compile?
             cc
             (append cflags (string-split (cadr args) #\space))
             features))
        ((--features)
         (if (null? (cdr args))
             (error "--features requires an argument"))
         (lp (cddr args)
             compile?
             cc
             cflags
             (append features (string-split (cadr args) #\,))))
        (else
         (error "unknown option" (car args)))))
     (else
      (if (pair? features)
          (set! *features* features))
      (let* ((src (if (or (not (pair? args)) (equal? "-" (car args)))
                      "/dev/stdin"
                      (car args)))
             (dest
              (case (length args)
                ((0) "-")
                ((1) (string-append (strip-extension src) ".c"))
                ((2) (cadr args))
                (else
                 (error "usage: chibi-ffi [-c] <file.stub> [<output.c>]")))))
        (if (not (equal? "/dev/stdin" src))
            (let ((slash (string-scan-right src #\/)))
              (if (string-cursor>? slash (string-cursor-start src))
                  (set! wdir (substring-cursor src (string-cursor-start src) slash)))))
        (if (equal? "-" dest)
            (generate src)
            (with-output-to-file dest (lambda () (generate src))))
        (cond
         ((and compile? (not (equal? "-" dest)))
          ;; This has to use `eval' for bootstrapping, since we need
          ;; chibi-ffi to compile to (chibi process) module.
          (let* ((so (string-append (strip-extension src)
                                    *shared-object-extension*))
                 (execute (begin (eval '(import (chibi process))
                                       (current-environment))
                                 (eval 'execute (current-environment))))
                 (base-args (append cflags *cflags*
                                    `("-o" ,so ,dest "-lchibi-scheme")
                                    (map (lambda (x) (string-append "-l" x))
                                         (reverse *clibs*))
                                    (apply append
                                           (map (lambda (x) (list "-framework" x))
                                                (reverse *frameworks*)))))
                 (args
                  (eval
                   `(cond-expand
                     (macosx (append '("-dynamiclib" "-Oz") ',base-args))
                     (else (append '("-fPIC" "-shared" "-Os") ',base-args)))))
                 (cc (or cc (if *c++?* "c++" "cc"))))
            (display ";; " (current-error-port))
            (write (cons cc args) (current-error-port))
            (newline (current-error-port))
            (execute cc (cons cc args))))))))))
