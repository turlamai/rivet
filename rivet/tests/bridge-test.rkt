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
;; Codec
;; ---------------------------------------------------------------------------

(define schema
  (hash 'rpcs
        (hash 'echo
              (hash 'params (list (hash 'name "s" 'type "string?"))
                    'result "string?")
              'add
              (hash 'params (list (hash 'name "a" 'type "exact-integer?")
                                  (hash 'name "b" 'type "exact-integer?"))
                    'result "exact-integer?")
              'wrap
              (hash 'params (list (hash 'name "item"
                                        'type (hash 'kind "record" 'name "item")))
                    'result (hash 'kind "record" 'name "item"))
              'maybe
              (hash 'params (list (hash 'name "x"
                                        'type (hash 'kind "optional" 'type "string?")))
                    'result (hash 'kind "optional" 'type "string?"))
              'tone
              (hash 'params (list (hash 'name "c" 'type "color"))
                    'result "color"))
        'records
        (hash 'item
              (list (hash 'name "display-name" 'type "string?")
                    (hash 'name "count" 'type "exact-integer?")
                    (hash 'name "note" 'type (hash 'kind "nullable" 'type "string?"))))
        'enums (hash 'color (list "red" "blue"))))

(define codec (make-bridge-codec schema))
(define (encode name args) (bridge-codec-encode codec name args))
(define (decode name result) (bridge-codec-decode codec name result))

(test-case "codec: primitives round-trip"
  (check-equal? (encode 'echo '("hi")) '("hi"))
  (check-equal? (decode 'echo "hi!") "hi!")
  (check-equal? (encode 'add '(2 3)) '(2 3))
  (check-equal? (decode 'add 5) 5))

(test-case "codec: record kebab->camel and field order"
  (define item (hash 'display-name "A" 'count 2 'note (void)))
  (define wire (car (encode 'wrap (list item))))
  (check-equal? (hash-ref wire 'displayName) "A")
  (check-equal? (hash-ref wire 'count) 2)
  (check-equal? (hash-ref wire 'note) (json-null))
  (check-equal? (decode 'wrap wire) item))

(test-case "codec: optional void <-> null"
  (check-equal? (encode 'maybe (list (void))) (list (json-null)))
  (check-equal? (decode 'maybe (json-null)) (void))
  (check-equal? (decode 'maybe "x") "x"))

(test-case "codec: enum passes validated strings"
  (check-equal? (encode 'tone '("red")) '("red"))
  (check-exn exn:fail? (lambda () (encode 'tone '(7)))))

(test-case "codec: arity and unknown rpc raise"
  (check-exn exn:fail? (lambda () (encode 'echo '())))
  (check-exn exn:fail? (lambda () (encode 'nope '()))))

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
  (define-values (r2 e2) (bridge-call 'add 2 3))
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
  (define-values (r e) (bridge-call "echo" (car (encode 'echo '("wire")))))
  (check-false e)
  (check-equal? (decode 'echo r) "wire!")
  (stop-bridge!))