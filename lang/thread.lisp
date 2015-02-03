;; -*- lisp -*-

;; This file is part of STMX.
;; Copyright (c) 2013-2014 Massimiliano Ghilardi
;;
;; This library is free software: you can redistribute it and/or
;; modify it under the terms of the Lisp Lesser General Public License
;; (http://opensource.franz.com/preamble.html), known as the LLGPL.
;;
;; This library is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty
;; of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;; See the Lisp Lesser General Public License for more details.


(in-package :stmx.lang)

(enable-#?-syntax)


;; CMUCL: fix some buggy bordeaux-threads type declarations
#+cmucl (declaim (ftype (function (t)   t) bt:join-thread))
#+cmucl (declaim (ftype (function (t t) t) bt:condition-wait))


;;;; ** Helpers to initialize thread-local variables

(eval-always
 (defun ensure-thread-initial-binding (sym form)
   (declare (type symbol sym)
            (type (or atom cons) form))
   (unless (assoc sym bt:*default-special-bindings* :test 'eq)
     (push (cons sym form) bt:*default-special-bindings*)))

 (defun ensure-thread-initial-bindings (&rest syms-and-forms)
   (declare (type list syms-and-forms))
   (loop for sym-and-form in syms-and-forms do
        (unless (assoc (first sym-and-form) bt:*default-special-bindings* :test 'eq)
          (push sym-and-form bt:*default-special-bindings*))))

 (defmacro save-thread-initial-bindings (&rest syms)
   `(ensure-thread-initial-bindings
     ,@(loop for sym in syms collect `(cons ',sym ,sym)))))



  


;;;; * Wrappers around Bordeaux Threads to capture
;;;; * the return value of functions executed in threads

(declaim (type t *current-thread*))
(defparameter *current-thread* (current-thread))

(eval-always
  (ensure-thread-initial-binding '*current-thread* '(current-thread))

  (defun start-multithreading ()
    ;; on CMUCL, (bt:start-multiprocessing) is blocking!
    #-cmucl (bt:start-multiprocessing))

  (start-multithreading)

  ;; testing (get-feature 'bt/join-thread) signals an error on CMUCL :(
  (defvar *bt/threads/tested* nil)

  ;; test for multi-threading support:
  ;; BT:*SUPPORTS-THREADS-P* must be non-NIL,
  ;; and (BT:MAKE-THREAD) and (BT:JOIN-THREAD) must work
  (unless *bt/threads/tested*
    (setf *bt/threads/tested* t)

    (if #+stmx/disable-threads nil
        #-stmx/disable-threads bt:*supports-threads-p*

        (progn
          (set-feature 'bt/make-thread t)
          (set-feature 'bt/join-thread
                       (if (let ((x (gensym)))
                             (eq x (bt:join-thread (bt:make-thread (lambda () x)))))
                           :sane
                           :broken)))
        (progn
          #+stmx/disable-threads
          (log:warn "Warning: compiling STMX without multi-threading support.
    reason: feature :STMX/DISABLE-THREADS found in CL:*FEATURES*")

          #-stmx/disable-threads
          (log:warn "Warning: compiling STMX without multi-threading support.
    reason: BORDEAUX-THREADS:*SUPPORTS-THREADS-P* is NIL")
(set-feature 'bt/make-thread nil)
          ;; if no thread support, no need to wrap threads to collect their exit value
          (set-feature 'bt/join-thread :sane)))))




#?+(eql bt/join-thread :broken)
(defstruct wrapped-thread
  (result nil)
  (thread (current-thread) :type bt:thread))



(defun start-thread (function &key name (initial-bindings bt:*default-special-bindings*))

  #?-bt/make-thread
  (error "STMX compiled without multi-threading support, cannot start a new thread")

  #?+bt/make-thread
  (progn
    
    #?+(eql bt/join-thread :sane)
    (make-thread function :name name :initial-bindings initial-bindings)

    #?-(eql bt/join-thread :sane)
    (let ((th (make-wrapped-thread)))
      (setf (wrapped-thread-thread th)
            (make-thread (lambda ()
                           (setf (wrapped-thread-result th)
                                 (funcall function)))
                         :name name
                         :initial-bindings initial-bindings))
      th)))

(defun wait4-thread (th)

  #?-bt/make-thread
  (error "STMX compiled without multi-threading support, cannot wait for a thread")

  #?+bt/make-thread
  (progn
    #?+(eql bt/join-thread :sane)
    (join-thread th)

    #?-(eql bt/join-thread :sane)
    (progn
      (join-thread (wrapped-thread-thread th))
      (wrapped-thread-result th))))

