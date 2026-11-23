#lang racket/base

;; Behavior tests for rivet/bridge: schema codec round-trips and the RVT1
;; pipe transport against a real child serve loop (bridge-echo.rkt).

(require rackunit
         racket/match
         racket/async-channel
         racket/runtime-path
         json
         rivet/bridge)

(define-runtime-path here ".")

;; ---------------------------------------------------------------------------
;; Codec (schema grammar = `raco rivet schema write` output)
;; ---------------------------------------------------------------------------

(define (scalar n) (hash 'kind "scalar" 'name n))
(define (optional t) (hash 'kind "optional" 'element t))
(define (record n) (hash 'kind "record" 'name n))

(define schema
  (hash 'rpcs
        (list (hash 'name "echo"
                    'arguments (list (hash 'name "s" 'type (scalar "String")))
                    'result (scalar "String"))
              (hash 'name "add"
                    'arguments (list (hash 'name "a" 'type (scalar "Int64"))
                                     (hash 'name "b" 'type (scalar "Int64")))
                    'result (scalar "Int64"))
              (hash 'name "wrap"
                    'arguments (list (hash 'name "item" 'type (record "item")))
                    'result (record "item"))
              (hash 'name "maybe"
                    'arguments (list (hash 'name "x" 'type (optional (scalar "String"))))
                    'result (optional (scalar "String")))
              (hash 'name "blob"
                    'arguments (list (hash 'name "data" 'type (scalar "Bytes")))
                    'result (scalar "Bytes"))
              (hash 'name "tone"
                    'arguments (list (hash 'name "c" 'type (record "tone")))
                    'result (record "tone")))
        'records
        (list (hash 'name "item"
                    'fields (list (hash 'name "display-name" 'type (scalar "String"))
                                  (hash 'name "count" 'type (scalar "Int64"))
                                  (hash 'name "note" 'type (optional (scalar "String"))))))
        'enums (list (hash 'name "tone" 'cases '("red" "blue")))))

(define codec (make-bridge-codec schema))
(define (encode name args) (bridge-codec-encode codec name args))
(define (decode name result) (bridge-codec-decode codec name result))

(test-case "codec: primitives round-trip"
  (check-equal? (encode 'echo (hasheq 's "hi")) '("hi"))
  (check-equal? (decode 'echo "hi!") "hi!")
  (check-equal? (encode 'add (hasheq 'a 2 'b 3)) '(2 3))
  (check-equal? (decode 'add 5) 5))

(test-case "codec: record camel object <-> field-ordered wire list"
  (define wire (encode 'wrap (hasheq 'item (hasheq 'displayName "A" 'count 2))))
  (check-equal? wire (list (list "A" 2 (void))))
  (check-equal? (decode 'wrap (car wire))
                (hash 'displayName "A" 'count 2 'note 'null)))

(test-case "codec: optional null <-> void, false/zero stay real"
  (check-equal? (encode 'maybe (hasheq)) (list (void)))
  (check-equal? (encode 'maybe (hasheq 'x 'null)) (list (void)))
  (check-equal? (decode 'maybe (void)) 'null)
  (check-equal? (decode 'maybe "x") "x"))

(test-case "codec: Bytes <-> base64 string"
  (check-equal? (encode 'blob (hasheq 'data "aGk=")) (list #"hi"))
  (check-equal? (decode 'blob #"hi") "aGk=")
  ;; long payloads must not carry line separators
  (define big (make-bytes 100 65))
  (define b64 (decode 'blob big))
  (check-false (regexp-match? #rx"[\r\n]" b64))
  (check-equal? (encode 'blob (hasheq 'data b64)) (list big)))

(test-case "codec: enum projected as record validates cases"
  (check-equal? (encode 'tone (hasheq 'c "red")) '("red"))
  (check-equal? (decode 'tone "blue") "blue")
  (check-exn exn:fail? (lambda () (encode 'tone (hasheq 'c "green")))))

(test-case "codec: scalar validation and unknown rpc raise"
  (check-exn exn:fail? (lambda () (encode 'add (hasheq 'a "x" 'b 1))))
  (check-exn exn:fail? (lambda () (encode 'echo (hasheq 's 7))))
  (check-exn exn:fail? (lambda () (encode 'nope (hasheq)))))

(test-case "codec: bad-param error shape"
  (define err (bridge-codec-bad-param-error codec 'echo "s: expected string"))
  (check-equal? (hash-ref err 'code) "bad-param")
  (check-equal? (hash-ref err 'retryable) #f))

;; ---------------------------------------------------------------------------
;; Transport against a real child backend
;; ---------------------------------------------------------------------------

(define echo-path (build-path here "bridge-echo.rkt"))

(define (start-echo)
  (define-values (proc in out err)
    (subprocess #f #f #f (find-executable-path "racket") (path->string echo-path)))
  (values (thread (lambda () (subprocess-wait proc))) in out))

(define events (make-async-channel))

(test-case "transport: hello, calls, events, error frame, teardown"
  (set-bridge-event-handler!
   (lambda (payload)
     (match payload
       [(list _name value) (async-channel-put events value)]
       [_ (void)])))
  (start-bridge! start-echo)
  (check-true (bridge-alive?))
  (define-values (r1 e1) (bridge-call "echo" "hi"))
  (check-equal? r1 "hi!")
  (check-false e1)
  (define-values (r2 e2) (bridge-call "add" 2 3))
  (check-equal? r2 5)
  (check-false e2)
  (define-values (r3 e3) (bridge-call "poke"))
  (check-false e3)
  (check-equal? (sync/timeout 10 events) "pong")
  (define-values (r4 e4) (bridge-call "nosuch-rpc"))
  (check-false r4)
  (check-not-false e4)
  (stop-bridge!)
  (check-false (bridge-alive?)))

(test-case "transport: codec over the wire"
  (start-bridge! start-echo)
  (define-values (r e) (bridge-call "echo" (car (encode 'echo (hasheq 's "wire")))))
  (check-false e)
  (check-equal? (decode 'echo r) "wire!")
  (stop-bridge!))