#lang racket/base

(require rackunit
         "../../rivet/backend.rkt"
         "../../rivet/protocol.rkt")

(define-record Person
  ([name : String]
   [age : Int64]
   [nickname : (Optional String)]))

(define-record Envelope
  ([owner : Person]
   [tags : (List String)]))

(define-enum Status (active inactive))

(define-rpc (echo-person [person : Person] : Person)
  person)

(define-rpc (wrap-person [person : Person] : Envelope)
  (Envelope person (list "taskly" "record")))

(define-rpc (echo-status [status : Status] : Status)
  status)

;; Native clients encode named DTOs inside Lists using the same positional
;; Record and String Enum wire shapes as scalar arguments.
(define-rpc (echo-status-list [statuses : (List Status)] : (List Status))
  (for ([status (in-list statuses)])
    (enum-case status))
  statuses)

(define-rpc (echo-people [people : (List Person)] : (List Person))
  (for ([person (in-list people)])
    (record-ref person 'name))
  people)

(define-rpc (echo-nested-statuses [groups : (List (Optional (List Status)))]
                                  : (List (Optional (List Status))))
  (for ([group (in-list groups)] #:unless (void? group))
    (for ([status (in-list group)])
      (enum-case status)))
  groups)

(define-state selected : Person (Person "Ada" 37 (void)))

(define ada (Person "Ada" 37 (void)))
(check-equal? (record-ref ada 'name) "Ada")
(check-equal? (record-ref ada "age") 37)
(check-true (void? (record-ref ada 'nickname)))
(check-exn exn:fail? (lambda () (record-ref ada 'missing)))
(check-equal? (enum-case (Status 'active)) 'active)
(check-equal? (enum-case (Status "inactive")) 'inactive)
(check-exn #rx"unknown Rivet Enum case" (lambda () (Status 'missing)))

(check-equal?
 (record-schema)
 (list
  (hasheq 'name "Envelope"
          'fields
          (list (hasheq 'name "owner" 'type "Person")
                (hasheq 'name "tags" 'type "(List String)")))
  (hasheq 'name "Person"
          'fields
          (list (hasheq 'name "name" 'type "String")
                (hasheq 'name "age" 'type "Int64")
                (hasheq 'name "nickname" 'type "(Optional String)")))))

(check-equal?
 (enum-schema)
 (list (hasheq 'name "Status" 'cases '("active" "inactive"))))

(define-values (server-in client-out) (make-pipe))
(define-values (client-in server-out) (make-pipe))
(define server-thread (thread (lambda () (serve server-in server-out))))

(define hello (read-frame client-in))
(check-equal? (frame-type hello) message:hello)

;; Record stays RVT1-compatible: the raw wire value is a positional list, while
;; the Racket RPC receives a named record-value and generated clients can expose
;; a native DTO.
(write-frame
 (frame message:request
        1
        (encode-value
         (list "echo-person" (list "Ada" 37 (void)))))
 client-out)
(define echo-response (read-frame client-in))
(check-equal? (frame-type echo-response) message:response)
(check-equal? (decode-value (frame-payload echo-response))
              (list "Ada" 37 (void)))

(write-frame
 (frame message:request
        2
        (encode-value
         (list "wrap-person" (list "Ada" 37 "A"))))
 client-out)
(define wrap-response (read-frame client-in))
(check-equal? (decode-value (frame-payload wrap-response))
              (list (list "Ada" 37 "A") (list "taskly" "record")))

(write-frame
 (frame message:request
        3
        (encode-value (list "$state/get" "selected")))
 client-out)
(define state-response (read-frame client-in))
(check-equal? (decode-value (frame-payload state-response))
              (list "Ada" 37 (void)))

(write-frame
 (frame message:request
        4
        (encode-value
         (list "$state/set" "selected" (list "Grace" 44 "Amazing"))))
 client-out)
(define state-event (read-frame client-in))
(check-equal? (decode-value (frame-payload state-event))
              (list "$state" (list "selected" (list "Grace" 44 "Amazing"))))
(define state-set-response (read-frame client-in))
(check-equal? (decode-value (frame-payload state-set-response))
              (list "Grace" 44 "Amazing"))
(check-equal? (record-ref (state-ref selected) 'name) "Grace")

;; Field shape/type failures become normal request errors, not protocol errors.
(write-frame
 (frame message:request
        5
        (encode-value (list "echo-person" (list "Too" 1))))
 client-out)
(define shape-error (read-frame client-in))
(check-equal? (frame-type shape-error) message:error)
(check-true (string? (decode-value (frame-payload shape-error))))

(write-frame
 (frame message:request
        6
        (encode-value (list "echo-person" (list "Wrong" "age" (void)))))
 client-out)
(define type-error (read-frame client-in))
(check-equal? (frame-type type-error) message:error)
(check-true (string? (decode-value (frame-payload type-error))))

;; Enum stays RVT1-compatible by using its stable case string on the wire.
(write-frame
 (frame message:request 7 (encode-value (list "echo-status" "active")))
 client-out)
(define enum-response (read-frame client-in))
(check-equal? (frame-type enum-response) message:response)
(check-equal? (decode-value (frame-payload enum-response)) "active")

(write-frame
 (frame message:request 8 (encode-value (list "echo-status" "missing")))
 client-out)
(define enum-error (read-frame client-in))
(check-equal? (frame-type enum-error) message:error)

;; Regression for #480: all these requests are raw RVT1 values, not
;; backend-only Record/Enum structures. Conversion must recurse through both
;; Lists and Optionals before the RPC handler sees them.
(define (send-named-list-request id name arg)
  (write-frame
   (frame message:request id (encode-value (list name arg)))
   client-out)
  (define response (read-frame client-in))
  (check-equal? (frame-id response) id)
  response)

(define enum-list-wire (list "active" "inactive"))
(define enum-list-response
  (send-named-list-request 9 "echo-status-list" enum-list-wire))
(check-equal? (frame-type enum-list-response) message:response)
(check-equal? (decode-value (frame-payload enum-list-response))
              enum-list-wire)

(define people-wire
  (list (list "Ada" 37 (void))
        (list "Grace" 44 "G")))
(define people-response
  (send-named-list-request 10 "echo-people" people-wire))
(check-equal? (frame-type people-response) message:response)
(check-equal? (decode-value (frame-payload people-response))
              people-wire)

(define nested-statuses-wire
  (list (list "active" "inactive") (void) '()))
(define nested-response
  (send-named-list-request 11 "echo-nested-statuses" nested-statuses-wire))
(check-equal? (frame-type nested-response) message:response)
(check-equal? (decode-value (frame-payload nested-response))
              nested-statuses-wire)

;; Invalid names, Record arity and inner primitive types must still be rejected
;; as request-local Errors without executing an RPC on malformed DTOs.
(for ([request (in-list
                (list (list 12 "echo-status-list" (list "unknown"))
                      (list 13 "echo-people" (list (list "Ada" 37)))
                      (list 14 "echo-people" (list (list "Ada" "bad-age" (void))))
                      (list 15 "echo-nested-statuses"
                            (list (list "active" "unknown")))))])
  (let ([error-response
         (send-named-list-request (car request)
                                  (cadr request)
                                  (caddr request))])
    (check-equal? (frame-type error-response) message:error)
    (check-true (string? (decode-value (frame-payload error-response))))))

;; A failed DTO call cannot poison subsequent valid RPCs; empty Lists also
;; remain valid on the wire.
(define after-error-response
  (send-named-list-request 16 "echo-status-list" '()))
(check-equal? (frame-type after-error-response) message:response)
(check-equal? (decode-value (frame-payload after-error-response)) '())

(write-frame (frame message:shutdown 0 #"") client-out)
(thread-wait server-thread)
