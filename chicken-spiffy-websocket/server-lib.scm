(import 
  (scheme)
  (srfi-1)
  (srfi-13)
  (srfi-18)
  (srfi-69)
  (chicken base)
  (chicken string)
  (chicken time)
  (chicken sort)
  (chicken io)
  (chicken file posix)
  (chicken format)
  (chicken process-context)
  (chicken process-context posix)
  (chicken port)
  (chicken file)
  (chicken tcp)
  (chicken condition)
  (chicken pathname)
  (chicken bitwise)
  (intarweb)
  (uri-common)
  (sendfile)  
  (srfi-4)
  (spiffy)
  (base64)
  (simple-sha1)
  (chicken blob)
  (chicken foreign)
  (chicken port)
  (srfi-14)
  (mailbox)
  (comparse)
)

(define (opcode->optype op)
  (case op
    ((0) 'continuation)
    ((1) 'text)
    ((2) 'binary)
    ((8) 'connection-close)
    ((9) 'ping)
    ((10) 'pong)
    (else (signal (make-protocol-violation-exception "bad opcode")))))

(define (optype->opcode t)
  (case t
    ('continuation     #x0)
    ('text             #x1)
    ('binary           #x2)
    ('connection-close #x8)
    ('ping             #x9)
    ('pong             #xa)
    (else (signal (make-websocket-exception
                   (make-property-condition 'invalid-optype))))))

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

(define (hex-string->string hexstr)
  ;; convert a string like "a745ff12" to a string
  (let ((result (make-string (/ (string-length hexstr) 2))))
    (let loop ((hexs (string->list hexstr))
               (i 0))
      (if (< (length hexs) 2)
          result
          (let ((ascii (string->number (string (car hexs) (cadr hexs)) 16)))
            (string-set! result i (integer->char ascii))
            (loop (cddr hexs)
                  (+ i 1)))))))

(define (make-websocket-exception . conditions)
  (apply make-composite-condition (append `(,(make-property-condition 'websocket))
                                          conditions)))

(define (make-protocol-violation-exception msg)
  (make-composite-condition (make-property-condition 'websocket)
                            (make-property-condition 'protocol-error 'msg msg)))


(define (websocket-send-frame ws optype data last-frame)
  ; TODO this sucks
  (when (u8vector? data) (set! data (blob->string (u8vector->blob/shared data))))
  (let* ((len (if (string? data) (string-length data) (u8vector-length data)))
         (frame-fin (if last-frame 1 0))
         (frame-rsv1 0)
         (frame-rsv2 0)
         (frame-rsv3 0)
         (frame-opcode (optype->opcode optype))
         (octet0 (bitwise-ior (arithmetic-shift frame-fin 7)
                              (arithmetic-shift frame-rsv1 6)
                              (arithmetic-shift frame-rsv2 5)
                              (arithmetic-shift frame-rsv3 4)
                              frame-opcode))

         (frame-masked 0)
         (frame-payload-length (cond ((< len 126) len)
                                     ((< len 65536) 126)
                                     (else 127)))
         (octet1 (bitwise-ior (arithmetic-shift frame-masked 7)
                              frame-payload-length))
         (outbound-port (websocket-outbound-port ws)))

    (write-u8vector (u8vector octet0 octet1) outbound-port)

    (write-u8vector
     (cond
      ((= frame-payload-length 126)
       (u8vector
        (arithmetic-shift (bitwise-and len 65280) -8)
        (bitwise-and len 255)))
      ((= frame-payload-length 127)
       (u8vector
        0 0 0 0
        (arithmetic-shift
         (bitwise-and len 4278190080) -24)
        (arithmetic-shift
         (bitwise-and len 16711680) -16)
        (arithmetic-shift
         (bitwise-and len 65280) -8)
        (bitwise-and len 255)))
      (else (u8vector)))
     outbound-port)

    (write-string data len outbound-port)
    (flush-output outbound-port)
    #t))

(define (sha1-sum in-bv)
  (hex-string->string (string->sha1sum in-bv)))

  (define (websocket-compute-handshake client-key)
  (let* ((key-and-magic
          (string-append client-key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
         (key-and-magic-sha1 (sha1-sum key-and-magic)))
    (base64-encode key-and-magic-sha1)))