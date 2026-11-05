#hasheq(
 (version . 1)
 ;; The maintained reference owns a real contract suite and a native host
 ;; build on every desktop platform. Packaged/native-UI evidence is driven by
 ;; the framework's Native UI End-to-End workflow; products add their own
 ;; package and native-ui suites here when they own that evidence.
 (requirements
  . (#hasheq((kind . contract) (platforms . (windows macos linux)))
     #hasheq((kind . native-build) (platforms . (windows macos linux)))))
 (suites
  . (#hasheq((id . backend-contract)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "test" "tests/"))
             (timeout-seconds . 600)
             (evidence . ()))
     #hasheq((id . schema-contract)
             (kind . contract)
             (platforms . (windows macos linux))
             (command . ("raco" "rivet" "schema" "check" "rivet-schema.json" "--json"))
             (timeout-seconds . 120)
             (evidence . ()))
     #hasheq((id . native-build)
             (kind . native-build)
             (platforms . (windows macos linux))
             (command . ("raco" "rivet" "build"))
             (timeout-seconds . 1800)
             (evidence . ())))))
