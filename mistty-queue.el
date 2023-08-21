;;; mistty.el --- Queue of terminal actions for mistty.el. -*- lexical-binding: t -*-

(eval-when-compile
  (require 'cl-lib))
(require 'generator)

(require 'mistty-log)
(require 'mistty-util)

;; A queue of strings to send to the terminal process.
;;
;; The queue contains a generator, which yields the strings to send to
;; the terminal.
(cl-defstruct (mistty--queue
               (:constructor mistty--make-queue (proc))
               (:conc-name mistty--queue-)
               (:copier nil))
  ;; The process the queue is communicating with.
  proc

  ;; A generator that yields strings to send to the terminal or nil.
  iter
  
  ;; Timer used by mistty--dequeue-with-timer.
  timer
  
  ;; Timer called if the process doesn't not answer after a certain
  ;; time.
  timeout
)

(defsubst mistty--queue-empty-p (queue)
  "Returns t if QUEUE generator hasn't finished yet."
  (not (mistty--queue-iter queue)))

(defun mistty--send-string (proc str)
  (when (and str (length> str 0) (process-live-p proc))
    (mistty-log "SEND[%s]" str)
    (process-send-string proc str)))

(defun mistty--enqueue-str (queue str)
  "Enqueue sending STR to the terminal.

Does nothing is STR is nil or empty."
  (when (and str (length> str 0))
    (mistty--enqueue queue (mistty--iter-single str))))

(defun mistty--enqueue (queue gen)
  "Add GEN to the queue.

The given generator should yield strings to send to the process.
`iter-yield' calls return once some response has been received
from the process or after too long has passed without response.
In the latter case, `iter-yield' returns \\='timeout.

If the queue is empty, this function also kicks things off by
sending the first string generated by GEN to the process.

If the queue is not empty, GEN is appended to the current
generator, to be executed afterwards.

Does nothing if GEN is nil."
  (cl-assert (mistty--queue-p queue))
  (when gen
    (if (mistty--queue-empty-p queue)
        (progn ; This is the first generator; kick things off.
          (setf (mistty--queue-iter queue) gen)
          (mistty--dequeue queue))
      (setf (mistty--queue-iter queue)
            (mistty--iter-chain (mistty--queue-iter queue) gen)))))

(defun mistty--dequeue (queue &optional value)
  "Send the next string from the queue to the terminal.

If VALUE is set, send that value to the first call to `iter-next'."
  (cl-assert (mistty--queue-p queue))
  (mistty--cancel-timeout queue)
  (unless (mistty--queue-empty-p queue)
    (condition-case nil
        (let ((proc (mistty--queue-proc queue))
              seq)
          (setq seq (iter-next (mistty--queue-iter queue) value))
          (while (or (null seq) (length= seq 0))
            (setq seq (iter-next (mistty--queue-iter queue))))
          (setf (mistty--queue-timeout queue)
                (run-with-timer
                 0.5 nil #'mistty--timeout-handler
                 (current-buffer) queue))
          (mistty--send-string proc seq))
    (iter-end-of-sequence
     (setf (mistty--queue-iter queue) nil)))))

(defun mistty--dequeue-with-timer (queue)
  "Call `mistty--dequeue' on a timer.

Restart the timer if a dequeue is already scheduled. The idea is
to accumulate updates that arrive at the same time from the
process, waiting for it to pause."
  (cl-assert (mistty--queue-p queue))
  (mistty--cancel-timeout queue)
  (mistty--cancel-timer queue)
  (unless (mistty--queue-empty-p queue)
    (setf (mistty--queue-timer queue)
          (run-with-timer
           0.1 nil #'mistty--queue-timer-handler
           (current-buffer) queue))))

(defun mistty--cancel-queue (queue)
  "Clear QUEUE and cancel all pending timers."
  (setf (mistty--queue-proc queue) nil)
  (mistty--cancel-timeout queue)
  (mistty--cancel-timer queue))

(defun mistty--cancel-timeout (queue)
  (cl-assert (mistty--queue-p queue))
  (when (timerp (mistty--queue-timeout queue))
    (cancel-timer (mistty--queue-timeout queue))
    (setf (mistty--queue-timeout queue) nil)))

(defun mistty--cancel-timer (queue)
  (cl-assert (mistty--queue-p queue))
  (when (timerp (mistty--queue-timer queue))
    (cancel-timer (mistty--queue-timer queue))
    (setf (mistty--queue-timer queue) nil)))

(defun mistty--timeout-handler (buf queue)
  (cl-assert (mistty--queue-p queue))
  (mistty--with-live-buffer buf
    (let ((proc (mistty--queue-proc queue)))
      (when (and (mistty--queue-timeout queue)
                 ;; last chance, in case some scheduling kerfuffle meant
                 ;; process output ended up buffered.
                 (not (and (process-live-p proc)
                           (accept-process-output proc 0 nil t))))
        (setf (mistty--queue-timeout queue) nil)
        (mistty-log "TIMEOUT")
        (mistty--dequeue queue 'timeout)))))

(defun mistty--queue-timer-handler (buf queue)
  "Idle timer callback that calls `mistty--dequeue'."
  (cl-assert (mistty--queue-p queue))
  (mistty--with-live-buffer buf
    (setf (mistty--queue-timer queue) nil)
    (mistty--dequeue queue)))

(iter-defun mistty--iter-single (elt)
  "Returns a generator that returns ELT and ends."
  (iter-yield elt))

(iter-defun mistty--iter-chain (iter1 iter2)
  "Returns a generator that first calls ITER1, then ITER2."
  (iter-do (value iter1)
    (iter-yield value))
  (iter-do (value iter2)
    (iter-yield value)))

(provide 'mistty-queue)