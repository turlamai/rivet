#lang racket/base

(require rackunit
         racket/file
         racket/runtime-path
         racket/string)

(define-runtime-path root "../..")

;; Installer-registered Win32 URL/file activations arrive as command-line
;; arguments. Capture them before the native window starts the backend.
;; This is only a source contract; Windows native CI must still compile and
;; exercise the actual generated WinUI app.
(for ([app-path (in-list
                 (list (build-path root "platform" "windows" "host" "App.xaml.cpp")
                       (build-path root "examples" "taskboard" "windows"
                                   "App.xaml.cpp")))])
  (define contents (file->string app-path))
  (for ([needle (in-list
                 '("rivet::system::ActivationArguments()"
                   "AppInstance::FindOrRegisterForKey"
                   "RedirectActivationToAsync(activation)"
                   "RedirectedActivationArguments(redirected)"
                   "ReceiveActivationArguments("
                   "OpenPrimaryWindow(std::move(initial_arguments))"))])
    (check-true (string-contains? contents needle)
                (format "WinUI host must retain and redirect activation: ~a"
                        needle)))
  (check-false
   (string-contains? contents "window_ = winrt::make<MainWindow>();")
   "WinUI must not discard command-line activation payloads"))

(for ([header-path (in-list
                    (list (build-path root "platform" "windows" "host"
                                      "MainWindow.xaml.h")
                          (build-path root "examples" "taskboard" "windows"
                                      "MainWindow.xaml.h")))])
  (define contents (file->string header-path))
  (check-true
   (string-contains? contents "TakeActivationArguments()")
   "product logic must have an explicit native activation consumption point")
  (check-true
   (string-contains? contents "ActivationInbox activations_")
   "native activation inbox must be bounded and retained in the window"))
