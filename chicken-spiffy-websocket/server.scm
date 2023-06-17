;#TOOD
;change send-message to match send-frame and websockets format

(include "server-lib.scm")

(define-record-type websocket
  (make-websocket inbound-port outbound-port send-bytes read-frame-proc state)
  websocket?
  (inbound-port websocket-inbound-port)
  (outbound-port websocket-outbound-port)
  (send-bytes send-message-bytes)
  (read-frame-proc websocket-read-frame-proc)
  (state websocket-state set-websocket-state!))


(define (send-message data #!optional (optype 'text) (ws (current-websocket)))
  ;; XXX break up large data into multiple frames?
    (optype->opcode optype) ; triggers error if invalid
  (send-frame ws optype data #t))

; (define (send-message data #!optional (optype 'text) ws)
;   ;; TODO break up large data into multiple frames?
;   (optype->opcode optype) ; triggers error if invalid
;   (send-frame ws optype data #t))


(define (websocket-read-frame-payload inbound-port frame-payload-length
                                      frame-masked frame-masking-key)
  (let ((masked-data (read-u8vector frame-payload-length inbound-port)))
    (cond (frame-masked
           (let ((unmasked-data (make-u8vector frame-payload-length)))
             (let loop ((pos 0)
                        (mask-pos 0))
               (cond ((= pos frame-payload-length) unmasked-data)
                     (else
                      (let ((octet (u8vector-ref masked-data pos))
                            (mask (vector-ref frame-masking-key mask-pos)))
                        (u8vector-set!
                         unmasked-data pos (bitwise-xor octet mask))
                        (loop (+ pos 1) (modulo (+ mask-pos 1) 4))))))
             unmasked-data))
          (else
           masked-data))))


(define (websocket-read-frame ws)
  (let* ((inbound-port (websocket-inbound-port ws))
         ;; first byte
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
             ;; second byte
             (b1 (read-byte inbound-port))
             (frame-masked (> (bitwise-and b1 128) 0))
             (frame-optype (opcode->optype frame-opcode))
             (frame-payload-length (bitwise-and b1 127))
             (total-size 0)) ;;;;;;;;added
        (cond ((= frame-payload-length 126)
               (let ((bl0 (read-byte inbound-port))
                     (bl1 (read-byte inbound-port)))
                 (set! frame-payload-length (+ (arithmetic-shift bl0 8) bl1))))
              ((= frame-payload-length 127)
               (set! frame-payload-length (shift 7 0))))
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
           ((eq? frame-optype 'text)
            ;; (if (= frame-fin 1) ;; something?
                 (websocket-read-frame-payload inbound-port frame-payload-length
                                          frame-masked frame-masking-key))
       
           ((eq? frame-optype 'connection-close) 
            (display "closeDebug")
           ;;#TODO: where does it go
              (send-frame ws 'connection-close  (u8vector 3000) #f)
              (set-websocket-state! 'close)
              #t) ;<- return #t
               ;(u8vector (* 3 (close-reason->close-code 'normal)))
               
           
           ((eq? frame-optype 'pong)
           
            ;; pong frame
            ;; we aren't required to respond to an unsolicited pong
            #t);<- return #t
           ;(eq? frame-) 
           (else
            (error "websocket got unhandled opcode: " frame-optype 'other);;;chcnged
            #f))))))))


 ;(define (websocket-close ws)
 ; (send-frame ws 'connection-close (u8vector 3 1000) #t))



(define (sec-websocket-accept-unparser header-contents)
  (map (lambda (header-content)
         (car (vector-ref header-content 0)))
       header-contents))

(define (websocket-accept)
  (let* ((headers (request-headers (current-request)))
         (client-key (header-value 'sec-websocket-key headers))
         (ws-handshake (websocket-compute-handshake client-key))
         (ws (make-websocket
              (request-port (current-request))
              (response-port (current-response))
              send-message
              websocket-read-frame
              'open))
              ;;;;
       (ping-thread
          (make-thread
           (lambda ()
             (let loop ()              
              (display (websocket-state ws))
               (thread-sleep! (ping-interval))
               (when (eq? (websocket-state ws) 'open)
                     (send-message "" 'ping ws)
                     (loop))))
           "ping thread"))
       ;;;;
                            )
    (with-headers
     `((upgrade ("WebSocket" . #f))
       (connection (upgrade . #t))
       (sec-websocket-accept (,ws-handshake . #t)))
     (lambda ()
       (send-response status: 'switching-protocols)
       (flush-output (response-port (current-response)))))
       ;;;
       (when (> (ping-interval) 0)
          ;(thread-start! ping-thread)
          )
       
    ws))



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
  (let loop ((data (websocket-read-frame ws)))
    ;(write (apply string (map integer->char (u8vector->list data))))

    (newline)
    ;(send-message ws data)
    (send-message data 'text ws)
   ; (websocket-close ws)
    (loop (websocket-read-frame ws))))

(header-unparsers
  (alist-update! 'sec-websocket-accept
                 sec-websocket-accept-unparser
                 (header-unparsers)))

(vhost-map `(("localhost" . ,(make-websocket-handler application-code))))
(server-port 8000)
;; (root-path "./web")
;(debug-log (current-error-port))
(start-server)

