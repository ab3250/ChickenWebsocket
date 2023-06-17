module websockets
; parameters
ping-interval close-timeout connection-timeout accept-connection drop-incoming-pings propagate-common-errors
   max-frame-size max-message-size
; high level API
with-websocket with-concurrent-websocket send-message receive-message current-websocket
; low level API
;; send-frame read-frame read-frame-payload
;; receive-fragments valid-utf8?
;; control-frame? upgrade-to-websocket
;; current-websocket unmask close-websocket
;; process-fragments
;; fragment
;; make-fragment fragment? fragment-payload fragment-length
;; fragment-masked? fragment-masking-key fragment-last?
;; fragment-optype
(define-inline (neq? obj1 obj2) (not (eq? obj1 obj2)))
(define current-websocket (make-parameter #f))
(define ping-interval (make-parameter 15))
(define close-timeout (make-parameter 5))
(define connection-timeout (make-parameter 58)) ; a little grace period from 60s
(define accept-connection (make-parameter (lambda (origin) #t)))
(define drop-incoming-pings (make-parameter #t))
(define propagate-common-errors (make-parameter #f))
(define access-denied ; TODO test
  (make-parameter (lambda () (send-status 'forbidden "<h1>Access denied</h1>"))))
(define max-frame-size (make-parameter 1048576)) ; 1MiB
(define max-message-size
  (make-parameter 1048576 ; 1MiB
                  (lambda (v)
                    (if (> v 1073741823) ; max int size for unmask/utf8 check
                        (signal (make-property-condition 'out-of-range))
                        v))))
(define (make-websocket-exception . conditions))
(define (make-protocol-violation-exception msg))
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
    ('continuation 0)
    ('text 1)
    ('binary 2)
    ('connection-close 8)
    ('ping 9)
    ('pong 10)
    (else (signal (make-websocket-exception
                   (make-property-condition 'invalid-optype))))))

(define (control-frame? optype)
  (or (eq? optype 'ping) (eq? optype 'pong) (eq? optype 'connection-close)))

(define-record-type websocket
  (make-websocket inbound-port outbound-port user-thread
                  send-mutex read-mutex last-message-timestamp
                  state send-mailbox read-mailbox concurrent)
  websocket?
  (inbound-port websocket-inbound-port)
  (outbound-port websocket-outbound-port)
  (user-thread websocket-user-thread)
  (send-mutex websocket-send-mutex)
  (read-mutex websocket-read-mutex)
  (last-message-timestamp websocket-last-message-timestamp
                          set-websocket-last-message-timestamp!)
  (state websocket-state set-websocket-state!)
  (send-mailbox websocket-send-mailbox)
  (read-mailbox websocket-read-mailbox)
  (concurrent websocket-concurrent?))

(define-record-type websocket-fragment
  (make-fragment payload length masked masking-key
                           fin optype)
  fragment?
  (payload fragment-payload)
  (length fragment-length)
  (masked fragment-masked? set-fragment-masked!)
  (masking-key fragment-masking-key)
  (fin fragment-last?)
  (optype fragment-optype))

(define (hex-string->string hexstr))
(define (send-frame ws optype data last-frame)))
(define (send-message data #!optional (optype 'text) (ws (current-websocket))))
(define (websocket-unmask-frame-payload payload len frame-masking-key)
(define tmaskkey (make-u8vector 4 #f #t #t))
(define (unmask fragment)
(define (read-frame-payload inbound-port frame-payload-length)
(define (read-frame total-size ws)
(define (close-code->integer s)
(define (close-code-string->close-reason s)
  (let ((c (close-code->integer s)))
    (case c
      ((1000) 'normal)
      ((1001) 'going-away)
      ((1002) 'protocol-error)
      ((1003) 'unknown-data-type)
      ((1007) 'invalid-data)
      ((1008) 'violated-policy)
      ((1009) 'message-too-large)
      ((1010) 'extension-negotiation-failed)
      ((1011) 'unexpected-error)
      (else
       (if (and (>= c 3000) (< c 5000))
           'unknown
           'invalid-close-code)))))
(define (valid-close-code? s)
(define (receive-fragments #!optional (ws (current-websocket)))
(define (process-fragments fragments optype #!optional (ws (current-websocket)))
(define (receive-message #!optional (ws (current-websocket)))
; TODO does #!optional and #!key work together?
(define (close-websocket #!optional (ws (current-websocket))
                         #!key (close-reason 'normal) (data (make-u8vector 0)))
  (define invalid-close-reason #f)
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

(define (websocket-compute-handshake client-key)
(define (sec-websocket-accept-unparser header-contents)
(header-unparsers
 (alist-update! 'sec-websocket-accept
                sec-websocket-accept-unparser
                (header-unparsers)))
(define (websocket-accept #!optional (concurrent #f))
(define (with-websocket proc #!optional (concurrent #f))
(define (with-concurrent-websocket proc)
(define (upgrade-to-websocket #!optional (concurrent #f))
