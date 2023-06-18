;#TOOD
;change send-message to match send-frame and websockets format

(include "server-lib.scm")

(define-record-type websocket
  (make-websocket inbound-port outbound-port
  send-mutex read-mutex send-mailbox read-mailbox last-message-timestamp state)
  websocket?
  (inbound-port websocket-inbound-port)
  (outbound-port websocket-outbound-port)
  (send-mutex websocket-send-mutex)
  (read-mutex websocket-read-mutex)
  (send-mailbox send-message)
  (read-mailbox read-frame)
  (last-message-timestamp websocket-last-message-timestamp
                          set-websocket-last-message-timestamp!)
  (state websocket-state set-websocket-state!))

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


(define (send-message data #!optional (optype 'text) (ws (current-websocket)))
  ;; XXX break up large data into multiple frames?
    (optype->opcode optype) ; triggers error if invalid    
  (send-frame ws optype data #t))

(define (read-frame-payload inbound-port frame-payload-length)
  (let ((masked-data (make-string frame-payload-length)))
    (read-string! frame-payload-length masked-data inbound-port)
    masked-data))

; (define (read-frame-payload inbound-port frame-payload-length
;                                       frame-masked frame-masking-key)
;   (let ((masked-data (read-u8vector frame-payload-length inbound-port)))
;     (cond (frame-masked
;            (let ((unmasked-data (make-u8vector frame-payload-length)))
;              (let loop ((pos 0)
;                         (mask-pos 0))
;                (cond ((= pos frame-payload-length) unmasked-data)
;                      (else
;                       (let ((octet (u8vector-ref masked-data pos))
;                             (mask (vector-ref frame-masking-key mask-pos)))
;                         (u8vector-set!
;                          unmasked-data pos (bitwise-xor octet mask))
;                         (loop (+ pos 1) (modulo (+ mask-pos 1) 4))))))
;              unmasked-data))
;           (else
;            masked-data))))

(define (read-frame total-size ws)
  (let* ((inbound-port (websocket-inbound-port ws))
         (b0 (read-byte inbound-port)))
    ; we don't support reserved bits yet
    (when (or (> (bitwise-and b0 64) 0)
              (> (bitwise-and b0 32) 0)
              (> (bitwise-and b0 16) 0))
          (signal (make-websocket-exception
                   (make-property-condition 'reserved-bits-not-supported)
                   (make-property-condition 'protocol-error))))
    (cond
     ((eof-object? b0) b0)
     (else
      (let* ((frame-fin (> (bitwise-and b0 128) 0))
             (frame-opcode (bitwise-and b0 15))
             (frame-optype (opcode->optype frame-opcode))
             ;; second byte
             (b1 (read-byte inbound-port))
             ; TODO die on unmasked frame?
             (frame-masked (> (bitwise-and b1 128) 0))
             (frame-payload-length (bitwise-and b1 127)))
        (cond ((= frame-payload-length 126)
               (let ((bl0 (read-byte inbound-port))
                     (bl1 (read-byte inbound-port)))
                 (set! frame-payload-length (+ (arithmetic-shift bl0 8) bl1))))
              ((= frame-payload-length 127)
               (set! frame-payload-length (shift 7 0 inbound-port))))
        (when (or (> frame-payload-length (max-frame-size))
                  (> (+ frame-payload-length total-size) (max-message-size)))
              (signal (make-websocket-exception
                       (make-property-condition 'message-too-large))))
        (let* ((frame-masking-key
                (if frame-masked
                    (let* ((fm0 (read-byte inbound-port))
                           (fm1 (read-byte inbound-port))
                           (fm2 (read-byte inbound-port))
                           (fm3 (read-byte inbound-port)))
                      (vector fm0 fm1 fm2 fm3))
                    #f)))
          (cond
           ((or (eq? frame-optype 'text)
                (eq? frame-optype 'binary)
                (eq? frame-optype 'continuation)
                (eq? frame-optype 'ping)
                (eq? frame-optype 'pong)
                (eq? frame-optype 'connection-close))
            (make-fragment
             (read-frame-payload inbound-port frame-payload-length)
             frame-payload-length frame-masked
             frame-masking-key frame-fin frame-optype))           
           (else
            (signal (make-websocket-exception
                     (make-property-condition 'unhandled-optype
                                              'optype frame-optype)))))))))))

(include "utf8-grammar.scm")

(define (receive-fragments #!optional (ws (current-websocket)))
;  (dynamic-wind
      ;(lambda () (mutex-lock! (websocket-read-mutex ws)))
     ; (lambda ()
        (if (or (eq? (websocket-state ws) 'closing)
                (eq? (websocket-state ws) 'closed)
                (eq? (websocket-state ws) 'error))
            (values #!eof #!eof)
            (let loop ((fragments '())
                       (first #t)
                       (type 'text)
                       (total-size 0))
              (let* ((fragment (read-frame total-size ws))
                     (optype (fragment-optype fragment))
                     (len (fragment-length fragment))
                     (last-frame (fragment-last? fragment)))
                (set-websocket-last-message-timestamp! ws (current-time))
                (cond
                 ((and (control-frame? optype) (> len 125))
                  (set-websocket-state! ws 'error)
                  (signal (make-protocol-violation-exception
                           "control frame bodies must be less than 126 octets")))

                 ; connection close
                 ((and (eq? optype 'connection-close) (= len 1))
                  (set-websocket-state! ws 'error)
                  (signal (make-protocol-violation-exception
                           "close frames must not have a length of 1")))
                 ((and (eq? optype 'connection-close)
                       (not (valid-close-code? (unmask fragment))))
                  (set-websocket-state! ws 'error)
                  (signal (make-protocol-violation-exception
                           (string-append
                            "invalid close code "
                            (number->string (close-code->integer (unmask fragment)))))))
                 ((eq? optype 'connection-close)
                  (set-websocket-state! ws 'closing)
                  (values `(,fragment) optype))

                 ; immediate response
                 ((and (eq? optype 'ping) last-frame (<= len 125))
                  (unless (drop-incoming-pings)
                          (send-message (unmask fragment) 'pong))
                  (loop fragments first type total-size))

                 ; protocol violation checks
                 ((or (and first (eq? optype 'continuation))
                      (and (not first) (neq? optype 'continuation)))
                  (set-websocket-state! ws 'error)
                  (signal (make-protocol-violation-exception
                           "continuation frame out-of-order")))
                 ((and (not last-frame) (control-frame? optype))
                  (set-websocket-state! ws 'error)
                  (signal (make-protocol-violation-exception
                           "control frames can't be fragmented")))

                 ((eq? optype 'pong)
                  (loop fragments first type total-size))

                 (else
                  (if last-frame
                      (values (cons fragment fragments) (if (null? fragments) optype type))
                      (loop (cons fragment fragments) #f
                            (if first optype type)
                            (+ total-size len))))))))
        ;)
      ;(lambda () (mutex-unlock! (websocket-read-mutex ws))))
      )

(define (process-fragments fragments optype #!optional (ws (current-websocket)))
    (display (optype->opcode optype))(flush-output)
  (let ((message-body (string-concatenate/shared
                       (reverse (map unmask fragments)))))
    (when (and (or (eq? optype 'text) (eq? optype 'connection-close))
               (not (valid-utf8?
                     (if (eq? optype 'text)
                         message-body
                         (if (> (string-length message-body) 2)
                             (substring message-body 2)
                             "")))))
          (set-websocket-state! ws 'error)
          (signal (make-websocket-exception
                   (make-property-condition
                    'invalid-data 'msg "invalid UTF-8"))))
    (values message-body optype)))

(define (sec-websocket-accept-unparser header-contents)
  (map (lambda (header-content)
         (car (vector-ref header-content 0)))
       header-contents))

(header-unparsers
  (alist-update! 'sec-websocket-accept
                 sec-websocket-accept-unparser
                 (header-unparsers)))

(define (websocket-accept #!optional (concurrent #f))
  (let* (;(user-thread (current-thread))
         (headers (request-headers (current-request)))
         (client-key (header-value 'sec-websocket-key headers))
         (ws-handshake (websocket-compute-handshake client-key))
         (ws (make-websocket
              (request-port (current-request))
              (response-port (current-response))
              (make-mutex "send")
              (make-mutex "read")
               send-message
               read-frame
               (current-time)
               'open
              ))
         (ping-thread
          (make-thread
           (lambda ()
             (let loop ()
               (thread-sleep! (ping-interval))
               (when (eq? (websocket-state ws) 'open)
                     (send-message "" 'ping ws)
                     (loop))))
           "ping thread")))

    ; make sure the request meets the spec for websockets
    (cond ((not (and (member 'upgrade (header-values 'connection headers))
                     (string-ci= (car (header-value 'upgrade headers '(""))) "websocket")))
           (signal (make-websocket-exception
                    (make-property-condition 'missing-upgrade-header))))
          ((not (string= (header-value 'sec-websocket-version headers "") "13"))
           (with-headers ; TODO test
            `((sec-websocket-version "13"))
            (lambda () (send-status 'upgrade-required))))
          ((not ((accept-connection) (header-value 'origin headers "")))
           ((access-denied))))

    (with-headers
     `((upgrade ("WebSocket" . #f))
       (connection (upgrade . #t))
       (sec-websocket-accept (,ws-handshake . #t)))
     (lambda ()
       (send-response status: 'switching-protocols)))
    (flush-output (response-port (current-response)))

    ; connection timeout thread
    (when (> (connection-timeout) 0)
          (thread-start!
           (lambda ()
             (let loop ()
               (let ((t (websocket-last-message-timestamp ws)))
                  ; Add one to attempt to alleviate checking the timestamp
                  ; right before when the timeout should happen.
                 (thread-sleep! (+ 1 (connection-timeout)))
                 (when (eq? (websocket-state ws) 'open)
                       (if (< (- (time->seconds (current-time))
                                 (time->seconds (websocket-last-message-timestamp ws)))
                              (connection-timeout))
                           (loop)
                           (begin (thread-signal!
                                   (websocket-user-thread ws)
                                   (make-websocket-exception
                                    (make-property-condition 'connection-timeout)))
                                  (close-websocket ws close-reason: 'going-away)))))))))

    (when (> (ping-interval) 0)
          (thread-start! ping-thread))

    ws))

(define (receive-message #!optional (ws (current-websocket)))
  ;(if (websocket-concurrent? ws)
    ;  (let ((msg (mailbox-receive! (websocket-read-mailbox ws))))
     ;   (values (car msg) (cdr msg)))
      (receive (fragments optype) (receive-fragments ws)
               (if (eof-object? fragments)
                   (values #!eof optype)
                   (process-fragments fragments optype))));)


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
  (let loop ((data (read-frame 0 ws)))
    ;(write (apply string (map integer->char (u8vector->list data))))

    ;(send-message ws data)
    (send-message data 'text ws)
    ;(websocket-close ws)
    (loop (read-frame 0 ws))))



(vhost-map `(("localhost" . ,(make-websocket-handler application-code))))
(server-port 8000)
;; (root-path "./web")
(debug-log (current-error-port))
(start-server)

