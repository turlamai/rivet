#lang racket/base

;; In-process backend bridge (turlamai/glaze#159): the RVT1 client half of
;; `rivet/backend`'s serve loop over a pipe pair, plus the schema-driven
;; app-value codec products need on the caller side. Extracted from podlens
;; so every rivet-backend product embedded in a shell (glaze or native)
;; shares one implementation instead of per-product copies.
;;
;; The transport owns process lifecycle and framing only; argument and
;; result meaning stays with the product schema via `make-bridge-codec`.

(require racket/match
         racket/string
         racket/async-channel
         racket/contract
         json
         "protocol.rkt")

(provide (contract-out
          [start-bridge! (-> procedure? any)]
          [stop-bridge! (-> any)]
          [bridge-call (->* ((or/c string? symbol?)) () #:rest list? (values any/c any/c))]
          [bridge-alive? (-> boolean?)]
          [set-bridge-event-handler! (-> procedure? any)]
          [make-bridge-codec (-> jsexpr? bridge-codec?)]
          [bridge-codec? (-> any/c boolean?)]
          [bridge-codec-encode (-> bridge-codec? symbol? list? jsexpr?)]
          [bridge-codec-decode (-> bridge-codec? symbol? jsexpr? any/c)]
          [bridge-codec-bad-param-error (-> bridge-codec? symbol? any/c jsexpr?)]))

;; ---------------------------------------------------------------------------
;; Transport: spawn the backend, speak RVT1 over stdio pipes.
;; ---------------------------------------------------------------------------

(define server-box (box #f))
(define child-cust (box #f))
(define client-in-box (box #f))
(define client-out-box (box #f))
(define reader-thread (box #f))
(define event-handler (box void))
(define pending (make-hash)) ; id -> async-channel of (cons 'ok/'err value)
(define pending-lock (make-semaphore 1))
(define call-lock (make-semaphore 1))
(define next-id 0)
(define stopping (box #f))

(define (bridge-alive?)
  (define srv (unbox server-box))
  (and srv (not (thread-dead? srv))))

;; The event handler receives the decoded event payload, shaped
;; (list event-name value) exactly as the RVT1 event frame carries it.
(define (set-bridge-event-handler! proc)
  (set-box! event-handler proc))

(define (stop-bridge!)
  (set-box! stopping #t)
  (define out (unbox client-out-box))
  (when out
    (with-handlers ([exn:fail? void])
      (write-frame (frame message:shutdown 0 (encode-value (hash))) out)
      (flush-output out)
      (close-output-port out)))
  (define in (unbox client-in-box))
  (when in (with-handlers ([exn:fail? void]) (close-input-port in)))
  (define srv (unbox server-box))
  (when srv
    (sync/timeout 5 srv))
  (define cust (unbox child-cust))
  (when cust (custodian-shutdown-all cust))
  (set-box! server-box #f)
  (set-box! child-cust #f)
  (set-box! client-in-box #f)
  (set-box! client-out-box #f))

;; start-proc : -> (values thread? input-port? output-port?)
;; The caller owns process creation (executable path, arguments, environment)
;; and must create the subprocess and its waiter thread under the current
;; custodian (the bridge installs a child custodian for teardown); the bridge
;; owns the handshake, framing and call demultiplexing.
(define (start-bridge! start-proc)
  (stop-bridge!)
  (set-box! stopping #f)
  (define cust (make-custodian))
  (set-box! child-cust cust)
  (define-values (srv client-in client-out)
    (parameterize ([current-custodian cust]) (start-proc)))
  (set-box! server-box srv)
  (set-box! client-in-box client-in)
  (set-box! client-out-box client-out)
  (define hello-ch (make-async-channel))
  (define rdr
    (thread
     (lambda ()
       (let loop ()
         (with-handlers ([exn:fail?
                          (lambda (e)
                            ;; Port closed / serve died: wake every waiter
                            ;; with the failure instead of hanging.
                            (async-channel-put hello-ch (cons 'dead e))
                            (call-with-semaphore
                             pending-lock
                             (lambda ()
                               (for ([ch (in-hash-values pending)])
                                 (async-channel-put ch (cons 'dead e)))))
                            (unless (unbox stopping) (raise e)))])
           (define f (read-frame client-in))
           (match (frame-type f)
             [(== message:hello)
              (async-channel-put hello-ch (cons 'hello f))]
             [(== message:response)
              (define ch
                (call-with-semaphore
                 pending-lock
                 (lambda () (hash-ref pending (frame-id f) #f))))
              (when ch
                (async-channel-put ch (cons 'ok (decode-value (frame-payload f)))))]
             [(== message:error)
              (define ch
                (call-with-semaphore
                 pending-lock
                 (lambda () (hash-ref pending (frame-id f) #f))))
              (when ch
                (async-channel-put ch (cons 'err (decode-value (frame-payload f)))))]
             [(== message:event)
              (with-handlers ([exn:fail? void])
                ((unbox event-handler) (decode-value (frame-payload f))))]
             [_ (void)])
           (loop))))))
  (set-box! reader-thread rdr)
  ;; Handshake: the server opens with the RVT1 hello frame.
  (define hello-result (sync/timeout 30 hello-ch))
  (unless hello-result
    (error 'start-bridge! "timed out waiting for RVT1 hello (server alive: ~a)"
           (not (thread-dead? srv))))
  (match hello-result
    [(cons 'hello f) (void)]
    [(cons 'dead e) (raise e)])
  (void))

;; One RPC over the wire. Returns (values result #f) or (values #f error).
;; Arguments and results are wire-level jsexpr; product meaning is applied
;; by the caller through a bridge-codec.
(define (bridge-call name . args)
  (unless (bridge-alive?)
    (error 'bridge-call "backend is not running"))
  (call-with-semaphore
   call-lock
   (lambda ()
     (set! next-id (add1 next-id))
     (define id next-id)
     (define ch (make-async-channel))
     (call-with-semaphore
      pending-lock
      (lambda () (hash-set! pending id ch)))
     (define out (unbox client-out-box))
     (write-frame (frame message:request
                         id
                         (encode-value (list* (if (symbol? name) (symbol->string name) name)
                                              args)))
                  out)
     (flush-output out)
     (define result (sync/timeout 120 ch))
     (call-with-semaphore
      pending-lock
      (lambda () (hash-remove! pending id)))
     (cond
       [(not result)
        (error 'bridge-call "timed out waiting for ~a (server alive: ~a)"
               name (bridge-alive?))]
       [(eq? (car result) 'ok) (values (cdr result) #f)]
       [(eq? (car result) 'err) (values #f (cdr result))]
       [(eq? (car result) 'dead) (raise (cdr result))]))))

;; ---------------------------------------------------------------------------
;; Schema-driven app-value codec.
;;
;; `schema` is the product's rivet schema jsexpr (keys rpcs/records/enums).
;; Racket-side conventions: kebab-case record keys, void for absent/null
;; optionals; wire-side conventions: camelCase keys, explicit null. Record
;; field order follows the schema declaration order.
;; ---------------------------------------------------------------------------

(struct bridge-codec (%encode %decode %bad-param-error))

(define (bridge-codec-encode c name args)
  ((bridge-codec-%encode c) name args))

(define (bridge-codec-decode c name result)
  ((bridge-codec-%decode c) name result))

(define (bridge-codec-bad-param-error c name detail)
  ((bridge-codec-%bad-param-error c) name detail))

(define (kebab->camel s)
  (define parts (string-split s "-"))
  (string-append (car parts)
                 (apply string-append
                        (for/list ([p (in-list (cdr parts))])
                          (if (zero? (string-length p))
                              ""
                              (string-append (string-upcase (substring p 0 1))
                                             (substring p 1)))))))

(define (camel->kebab s)
  (list->string
   (for/fold ([acc '()]) ([c (in-string s)])
     (if (char-upper-case? c)
         (append acc (list #\- (char-downcase c)))
         (append acc (list c))))))

(define (make-bridge-codec schema)
  (define rpcs (hash-ref schema 'rpcs))
  (define records (hash-ref schema 'records (hash)))
  (define enums (hash-ref schema 'enums (hash)))

  (define (spec-kind spec)
    (cond
      [(string? spec) spec]
      [(hash? spec) (hash-ref spec 'kind)]
      [else (error 'bridge-codec "bad type spec: ~e" spec)]))

  (define (encode-value* spec v)
    (cond
      [(void? v) (json-null)]
      [else
       (define k (spec-kind spec))
       (cond
         [(equal? k "optional")
          (if (void? v) (json-null) (encode-value* (hash-ref spec 'type) v))]
         [(equal? k "nullable")
          (if (void? v) (json-null) (encode-value* (hash-ref spec 'type) v))]
         [(equal? k "array")
          (for/list ([x (in-list v)]) (encode-value* (hash-ref spec 'items) x))]
         [(equal? k "map")
          (for/hash ([(key val) (in-hash v)])
            (values key (encode-value* (hash-ref spec 'values) val)))]
         [(equal? k "record")
          (define rname (hash-ref spec 'name))
          (define fields (hash-ref records (string->symbol rname)))
          (for/hash ([f (in-list fields)])
            (define fname (hash-ref f 'name))
            (values (string->symbol (kebab->camel fname))
                    (encode-value* (hash-ref f 'type)
                                   (hash-ref v (string->symbol fname)))))]
         [(hash-ref enums (string->symbol k) #f)
          (unless (string? v)
            (error 'bridge-codec "enum ~a expects string, got ~e" k v))
          v]
         [else v])]))

  (define (decode-value* spec v)
    (cond
      [(eq? v (json-null)) (void)]
      [else
       (define k (spec-kind spec))
       (cond
         [(equal? k "optional") (decode-value* (hash-ref spec 'type) v)]
         [(equal? k "nullable") (decode-value* (hash-ref spec 'type) v)]
         [(equal? k "array")
          (for/list ([x (in-list v)]) (decode-value* (hash-ref spec 'items) x))]
         [(equal? k "map")
          (for/hash ([(key val) (in-hash v)])
            (values key (decode-value* (hash-ref spec 'values) val)))]
         [(equal? k "record")
          (define rname (hash-ref spec 'name))
          (define fields (hash-ref records (string->symbol rname)))
          (for/hash ([f (in-list fields)])
            (define fname (hash-ref f 'name))
            (values (string->symbol fname)
                    (decode-value* (hash-ref f 'type)
                                   (hash-ref v (string->symbol (kebab->camel fname))))))]
         [else v])]))

  (define (rpc-entry name)
    (hash-ref rpcs name
              (lambda () (error 'bridge-codec "unknown rpc ~a" name))))

  (define (encode name args)
    (define entry (rpc-entry name))
    (define params (hash-ref entry 'params '()))
    (unless (= (length args) (length params))
      (error 'bridge-codec "~a expects ~a args, got ~a"
             name (length params) (length args)))
    (for/list ([spec (in-list params)] [v (in-list args)])
      (encode-value* (hash-ref spec 'type) v)))

  (define (decode name result)
    (define entry (rpc-entry name))
    (decode-value* (hash-ref entry 'result) result))

  (define (bad-param-error name detail)
    (hash 'code "bad-param"
          'message (format "~a: ~a" name detail)
          'retryable #f))

  (bridge-codec encode decode bad-param-error))