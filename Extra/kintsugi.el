;;; kintsugi.el --- Major mode for the Kintsugi Programming Language -*- lexical-binding: t; -*-

;; Author: Ray Perry
;; Date: <2022-04-09 Sat>

;;; Code:

(defgroup kintsugi nil
  "Major mode for the Kintsugi programming language."
  :group 'languages
  :prefix "kintsugi-")

(defcustom kintsugi-indent-offset 2
  "Number of spaces for each indentation level in Kintsugi."
  :type 'integer
  :group 'kintsugi)

(defvar kintsugi-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\; "<" st)
    (modify-syntax-entry ?\n ">" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?- "_" st)
    (modify-syntax-entry ?? "_" st)
    (modify-syntax-entry ?! "_" st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?/ "_" st)
    (modify-syntax-entry ?~ "_" st)
    st)
  "Syntax table for `kintsugi-mode'.")

(defconst kintsugi--syntax-propertize
  (syntax-propertize-rules
   ("#\\(\"\\).\\(\"\\)"
    (1 ".")
    (2 ".")))
  "Syntax propertize rules for char literals.")

(defconst kintsugi-font-lock-keywords
  (let ((control '("if" "either" "unless" "while" "repeat" "forever"
                    "break" "function" "do" "try" "error" "match"
                    "loop" "parse" "attempt" "require" "object"
                    "use" "bind"))
        (builtins '("compose" "select" "first" "second" "third"
                     "append" "length?" "type?" "typeset" "emit"
                     "open" "close" "read" "write" "print"
                     "to" "is?" "parse")))
    `(
      ;; Directives
      ("#comptime" . font-lock-preprocessor-face)
      ;; Char literals #"x"
      ("#\".\""  . font-lock-constant-face)
      ;; Binary literals #{...}
      ("#{[^}]*}" . font-lock-constant-face)
      ;; URL literals (before email and file to avoid partial matches)
      ("[[:alpha:]][[:alnum:]+-]*://[^] \t\n[()]*" . font-lock-string-face)
      ;; Email literals
      ("[[:alnum:]._-]+@[[:alnum:]._-]+" . font-lock-string-face)
      ;; File literals
      ("%[[:alnum:]/._-]+" . font-lock-string-face)
      ;; Money literals
      ("\\$[0-9]+\\(?:\\.[0-9]+\\)?" . font-lock-constant-face)
      ;; Pair literals (NxN)
      ("\\b[0-9]+x[0-9]+\\b" . font-lock-constant-face)
      ;; Logic and none
      (,(regexp-opt '("true" "false" "on" "off" "yes" "no" "none") 'symbols)
       . font-lock-constant-face)
      ;; Set-words (word:) — before type names so word!: gets set-word face
      ("\\_<[[:alpha:]][[:alnum:]_?!-]*:" . font-lock-variable-name-face)
      ;; Type names (word!)
      ("\\_<[[:alpha:]][[:alnum:]_-]*!" . font-lock-type-face)
      ;; Shape names (word~)
      ("\\_<[[:alpha:]][[:alnum:]_-]*~" . font-lock-type-face)
      ;; Lit-words ('word)
      ("'[[:alpha:]][[:alnum:]_?!-]*" . font-lock-constant-face)
      ;; Get-words (:word)
      ("\\(?:^\\|[^[:alnum:]_?!-]\\)\\(:[[:alpha:]][[:alnum:]_?!-]*\\)"
       1 font-lock-builtin-face)
      ;; Control flow keywords
      (,(regexp-opt control 'symbols) . font-lock-keyword-face)
      ;; Builtins
      (,(regexp-opt builtins 'symbols) . font-lock-builtin-face)
      ;; Header keyword (Kintsugi with optional tier)
      ("^Kintsugi\\(?:/[[:alpha:]]+\\)?" . font-lock-keyword-face)
      ;; Lambda arrow
      ("->" . font-lock-keyword-face)))
  "Font-lock keywords for `kintsugi-mode'.")

(defun kintsugi-indent-line ()
  "Indent current line as Kintsugi code."
  (let* ((ppss (save-excursion (beginning-of-line) (syntax-ppss)))
         (depth (car ppss)))
    (unless (or (nth 3 ppss) (nth 4 ppss))
      (let* ((closing (save-excursion
                        (back-to-indentation)
                        (looking-at "[])]")))
             (target (* kintsugi-indent-offset
                        (max 0 (if closing (1- depth) depth)))))
        (if (<= (current-column) (current-indentation))
            (indent-line-to target)
          (save-excursion (indent-line-to target)))))))

;;;###autoload
(define-derived-mode kintsugi-mode prog-mode "Kintsugi"
  "Major mode for the Kintsugi Programming Language."
  :syntax-table kintsugi-mode-syntax-table
  (setq-local comment-start "; ")
  (setq-local comment-end "")
  (setq-local font-lock-defaults '(kintsugi-font-lock-keywords))
  (setq-local indent-line-function #'kintsugi-indent-line)
  (setq-local syntax-propertize-function kintsugi--syntax-propertize))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.ktg\\'" . kintsugi-mode))

(provide 'kintsugi)
;;; kintsugi.el ends here
