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
         net/base64
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
          [bridge-codec-encode (-> bridge-codec? symbol? hash? list?)]
          [bridge-codec-decode (-> bridge-codec? symbol? any/c jsexpr?)]
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
;; `schema` is the product's rivet schema jsexpr as written by
;; `raco rivet schema write`: `rpcs` / `records` / `enums` are lists of
;; named entries; type specs use kinds scalar / optional / list / record
;; (enums project as record kinds and validate against their case list).
;; JSON-side conventions: camelCase object keys, explicit null for absent
;; optionals, base64 strings for Bytes. Wire-side conventions: records are
;; field-ordered lists in schema declaration order, void for absent
;; optionals. This mirrors the codec Podlens shipped (#63) so both products
;; meet the wire identically.
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

(define (make-bridge-codec schema)
  (define record-table
    (for/hash ([r (in-list (hash-ref schema 'records '()))])
      (values (hash-ref r 'name) r)))
  (define enum-table
    (for/hash ([e (in-list (hash-ref schema 'enums '()))])
      (values (hash-ref e 'name) (hash-ref e 'cases))))
  (define rpc-table
    (for/hash ([r (in-list (hash-ref schema 'rpcs))])
      (values (hash-ref r 'name) r)))

  (define (rpc-entry name)
    (hash-ref rpc-table (symbol->string name)
              (lambda () (error 'bridge-codec "unknown rpc ~a" name))))

  (define (json->wire v t)
    (match (hash-ref t 'kind)
      ["scalar"
       (match (hash-ref t 'name)
         ["Void" (void)]
         ["Any" v]
         ["Int64"
          (unless (exact-integer? v)
            (error 'bridge-codec "expected integer, got: ~e" v))
          v]
         ["Bool"
          (unless (boolean? v)
            (error 'bridge-codec "expected boolean, got: ~e" v))
          v]
         ["String"
          (unless (string? v)
            (error 'bridge-codec "expected string, got: ~e" v))
          v]
         ["Bytes"
          (unless (string? v)
            (error 'bridge-codec "expected base64 string, got: ~e" v))
          (base64-decode (string->bytes/utf-8 v))]
         [other (error 'bridge-codec "unsupported scalar type: ~a" other)])]
      ["optional"
       ;; Only JSON null means absent — #f and 0 are real values.
       (if (eq? v (json-null))
           (void)
           (json->wire v (hash-ref t 'element)))]
      ["list"
       (unless (list? v)
         (error 'bridge-codec "expected array, got: ~e" v))
       (for/list ([x (in-list v)])
         (json->wire x (hash-ref t 'element)))]
      ["record"
       (cond
         [(hash-ref enum-table (hash-ref t 'name) #f)
          => (lambda (cases)
               (unless (and (string? v) (member v cases))
                 (error 'bridge-codec "enum ~a expects one of ~a, got: ~e"
                        (hash-ref t 'name) cases v))
               v)]
         [else
          (unless (hash? v)
            (error 'bridge-codec "expected object for record ~a, got: ~e"
                   (hash-ref t 'name) v))
          (define rec (hash-ref record-table (hash-ref t 'name)))
          (for/list ([f (in-list (hash-ref rec 'fields))])
            (define key (string->symbol (kebab->camel (hash-ref f 'name))))
            (json->wire (hash-ref v key (json-null)) (hash-ref f 'type)))])]
      [kind (error 'bridge-codec "unsupported type kind: ~a" kind)]))

  (define (wire->json v t)
    (match (hash-ref t 'kind)
      ["scalar"
       (match (hash-ref t 'name)
         ["Void" (json-null)]
         ["Bytes"
          (unless (bytes? v)
            (error 'bridge-codec "expected bytes on wire, got: ~e" v))
          (bytes->string/utf-8 (base64-encode v #""))]
         ["Any" (if (void? v) (json-null) v)]
         [else (if (void? v) (json-null) v)])]
      ["optional"
       (if (void? v) (json-null) (wire->json v (hash-ref t 'element)))]
      ["list"
       (for/list ([x (in-list v)])
         (wire->json x (hash-ref t 'element)))]
      ["record"
       (cond
         [(hash-ref enum-table (hash-ref t 'name) #f) v]
         [else
          (define rec (hash-ref record-table (hash-ref t 'name)))
          (define fields (hash-ref rec 'fields))
          (unless (= (length fields) (length v))
            (error 'bridge-codec "record ~a: wire arity ~a != schema arity ~a"
                   (hash-ref t 'name) (length v) (length fields)))
          (for/hash ([f (in-list fields)] [x (in-list v)])
            (values (string->symbol (kebab->camel (hash-ref f 'name)))
                    (wire->json x (hash-ref f 'type))))])]
      [kind (error 'bridge-codec "unsupported type kind: ~a" kind)]))

  ;; args: camelCase JSON object (hasheq); missing keys mean absent.
  (define (encode name args)
    (define spec (rpc-entry name))
    (for/list ([a (in-list (hash-ref spec 'arguments '()))])
      (define key (string->symbol (kebab->camel (hash-ref a 'name))))
      (json->wire (hash-ref args key (json-null)) (hash-ref a 'type))))

  (define (decode name result)
    (define spec (rpc-entry name))
    (wire->json result (hash-ref spec 'result)))

  (define (bad-param-error name detail)
    (hash 'code "bad-param"
          'message (format "~a: ~a" name detail)
          'retryable #f))

  (bridge-codec encode decode bad-param-error))