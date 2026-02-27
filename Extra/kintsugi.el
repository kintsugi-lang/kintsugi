;;;  -*- lexical-binding: t; -*-
;;; Title: kintsugi.el
;;; Author: Ray Perry
;;; Date: <2022-04-09 Sat>
;;;
;;; Description: Major mode for the Kintsugi Programming Language,
;;; providing syntax highlighting.
;;;

(defconst kintsugi-font-lock-defaults
  (let ((words '("function")))
    `((
        ("\\(\\(?:[[:alnum:]]\\|-\\)+:\\)" 0 font-lock-variable-name-face)
        ("\\(?:%\\(?:[[:alnum:]]\\|-\\|\\.\\|\\/\\)+\\)" 0 font-lock-keyword-face)
        ("\\([':@#]\\(?:[[:alnum:]]\\|-\\)+\\)" 0 font-lock-constant-face)
        ))))

(define-abbrev-table 'kintsugi-mode-abbrev-table ()
  "Abbrev table used while in `kintsugi-mode'.")

(defvar kintsugi-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\[ "(" st)
    (modify-syntax-entry ?\] ")" st)
    (modify-syntax-entry ?\; "<" st)
    (modify-syntax-entry 10 ">" st)
    st)
  "Syntax table used while in `kintsugi-mode'.")

(define-derived-mode kintsugi-mode
  prog-mode "Kintsugi"
  "Major mode for the Kintsugi Programming Language."
  :syntax-table kintsugi-mode-syntax-table
  (setq font-lock-defaults kintsugi-font-lock-defaults))

(setq auto-mode-alist
  (append '(("\\(?:ktgf?\\)$" . kintsugi-mode)) auto-mode-alist))

