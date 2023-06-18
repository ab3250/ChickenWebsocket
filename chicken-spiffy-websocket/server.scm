(import 
  (scheme) (srfi-1) (srfi-13) (srfi-18) (srfi-69) (chicken base) (chicken string) (chicken time)
  (chicken sort) (chicken io) (chicken file posix) (chicken format) (chicken process-context)
  (chicken process-context posix) (chicken port) (chicken file) (chicken tcp) (chicken condition)
  (chicken pathname) (chicken bitwise) (intarweb) (uri-common) (sendfile)  (srfi-4) (base64)
  (simple-sha1) (chicken blob) (chicken foreign) (chicken port) (srfi-14) (mailbox) (comparse)
  (spiffy) 
)

(include "websocketsmod.scm")

 (set! tcp-read-timeout (make-parameter #f ))

(define (string->bytes str)
  ;; XXX this wont work unless it's all ascii.
  (let* ((lst (map char->integer (string->list str)))
         (bv (make-u8vector (length lst))))
    (let loop ((lst lst)
               (pos 0))
      (if (null? lst) bv
          (begin
            (u8vector-set! bv pos (car lst))
            (loop (cdr lst) (+ pos 1)))))))


(define (make-websocket-handler app-code)
  (lambda (spiffy-continue)
    (cond ((equal? (uri-path (request-uri (current-request))) '(/ "web-socket"))
           (let ((ws (websocket-accept)))
             (app-code ws)))
          ((equal? (uri-path (request-uri (current-request))) '(/ ""))
           ((handle-file) "index.html"))
          (else
           (spiffy-continue)))))



(define (application-code ws)
  ;(send-message ws (string->bytes "testing"))
  (let loop ((data (receive-message ws)))
    ;(write (apply string (map integer->char (u8vector->list data))))

    ;(send-message ws data)
    (send-message data 'text ws)
    ;(websocket-close ws)
    (loop (receive-message ws))))



(vhost-map `(("localhost" . ,(make-websocket-handler application-code))))
(server-port 8000)
;; (root-path "./web")
(debug-log (current-error-port))
(start-server)

