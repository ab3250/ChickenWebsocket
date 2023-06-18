(import 
  (scheme) (srfi-1) (srfi-13) (srfi-18) (srfi-69) (chicken base) (chicken string) (chicken time)
  (chicken sort) (chicken io) (chicken file posix) (chicken format) (chicken process-context)
  (chicken process-context posix) (chicken port) (chicken file) (chicken tcp) (chicken condition)
  (chicken pathname) (chicken bitwise) (intarweb) (uri-common) (sendfile)  (srfi-4) (base64)
  (simple-sha1) (chicken blob) (chicken foreign) (chicken port) (srfi-14) (mailbox) (comparse)
  (spiffy) 
)



(define-inline (neq? obj1 obj2) (not (eq? obj1 obj2)))

(define current-websocket (make-parameter #f))
(define ping-interval (make-parameter 5))
(define close-timeout (make-parameter 5)) ;5
(define connection-timeout (make-parameter 58)) ; a little grace period from 60s
(define accept-connection (make-parameter (lambda (origin) #t)))
(define drop-incoming-pings (make-parameter #t))
(define propagate-common-errors (make-parameter #f))
(define access-denied ; TODO test
  (make-parameter (lambda () (send-status 'forbidden "<h1>Access denied</h1>"))))

(define (shift i r inbound-port)
  (if (< i 0)
      r
      (shift (- i 1) (+ (arithmetic-shift (read-byte inbound-port) (* 8 i))
                        r) inbound-port)))

(define max-frame-size (make-parameter 1048576)) ; 1MiB
(define max-message-size
  (make-parameter 1048576 ; 1MiB
                  (lambda (v)
                    (if (> v 1073741823) ; max int size for unmask/utf8 check
                        (signal (make-property-condition 'out-of-range))
                        v))))


(define (unmask fragment)
  (if (fragment-masked? fragment)
      (let ((r (websocket-unmask-frame-payload
                (fragment-payload fragment)
                (fragment-length fragment)
                (fragment-masking-key fragment))))
             (set-fragment-masked! fragment #f)
             r)
      (fragment-payload fragment)))

(define (make-websocket-exception . conditions)
  (apply make-composite-condition (append `(,(make-property-condition 'websocket))
                                          conditions)))

(define (make-protocol-violation-exception msg)
  (make-composite-condition (make-property-condition 'websocket)
                            (make-property-condition 'protocol-error 'msg msg)))

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


(define (control-frame? optype)
  (or (eq? optype 'ping) (eq? optype 'pong) (eq? optype 'connection-close)))

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



(define (send-frame ws optype data last-frame)
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

    (define (valid-utf8? s)
  (or (let ((len (string-length s)))
         ; Try to validate as an ascii string first. Its essentially
         ; free, doesn't generate garbage and is many, many times
         ; faster than the general purpose validator.
         (= 1
            ((foreign-lambda* int ((size_t ws_utlen) (scheme-pointer ws_uts))
"
    if (ws_utlen > UINT_MAX) { return -1; }

    int i;
    for (i = ws_utlen; i != 0; --i)
    {
        if (*((unsigned char*)ws_uts++) > 127)
        {
            C_return(0);
        }
    }

    C_return(1);
") len s)))
      (parse utf8-string (->parser-input s))))

(define (close-code->integer s)
  (if (string-null? s)
      1000
      (+ (arithmetic-shift (char->integer (string-ref s 0)) 8)
         (char->integer (string-ref s 1)))))


(define (close-reason->close-code reason)
    (case reason
      ('normal 1000)
      ('going-away 1001)
      ('protocol-error 1002)
      ('unknown-data-type 1003)
      ('invalid-data 1007)
      ('violated-policy 1008)
      ('message-too-large 1009)
      ('unexpected-error 1011)
      (else (set! invalid-close-reason reason)
            (close-reason->close-code 'unexpected-error))))

; (define (close-code-string->close-reason s)
;   (let ((c (close-code->integer s)))
;     (case c
;       ((1000) 'normal)
;       ((1001) 'going-away)
;       ((1002) 'protocol-error)
;       ((1003) 'unknown-data-type)
;       ((1007) 'invalid-data)
;       ((1008) 'violated-policy)
;       ((1009) 'message-too-large)
;       ((1010) 'extension-negotiation-failed)
;       ((1011) 'unexpected-error)
;       (else
;        (if (and (>= c 3000) (< c 5000))
;            'unknown
;            'invalid-close-code)))))

; (define (valid-close-code? s)
;   (neq? 'invalid-close-code (close-code-string->close-reason s)))