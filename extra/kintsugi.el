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
    (modify-syntax-entry ?{ "|" st)
    (modify-syntax-entry ?} "|" st)
    st)
  "Syntax table for `kintsugi-mode'.")

(defconst kintsugi--syntax-propertize
  (syntax-propertize-rules
   ("#\\(\"\\).\\(\"\\)"
    (1 ".")
    (2 "."))
   ("#\\({\\)[^}]*\\(}\\)"
    (1 ".")
    (2 ".")))
  "Syntax propertize rules for char literals and binary literals.")

(defconst kintsugi-font-lock-keywords
  (let ((control '("if" "either" "unless" "loop" "break" "return"
                    "function" "do" "try" "match" "attempt" "parse"
                    "not" "and" "or" "all" "any"
                    ;; Loop dialect keywords
                    "for" "in" "from" "to" "by" "when"
                    ;; Attempt/match dialect keywords
                    "source" "then" "fallback" "retries" "default"))
        (builtins '("print" "probe" "compose" "reduce" "apply"
                     "select" "first" "second" "last" "pick"
                     "append" "insert" "remove" "copy"
                     "has?" "index?"
                     "length?" "empty?" "type?"
                     "none?" "integer?" "float?" "logic?"
                     "char?" "block?" "function?" "string?"
                     "context?" "pair?" "tuple?" "date?" "time?"
                     "binary?" "file?" "url?" "email?" "word?" "map?"
                     "min" "max" "abs" "negate" "round" "odd?" "even?"
                     "join" "rejoin" "replace" "split" "trim"
                     "uppercase" "lowercase"
                     "context" "bind" "words-of" "set"
                     "require" "make" "to"
                     "is?" "typeset" "error"
                     ;; Preprocess
                     "emit" "platform")))
    `(
      ;; Directives
      ("#\\(?:preprocess\\|inline\\)" . font-lock-preprocessor-face)
      ;; Inline preprocess #[expr]
      ("#\\[" . font-lock-preprocessor-face)
      ;; Lifecycle hooks
      ("@\\(?:enter\\|exit\\)\\b" . font-lock-preprocessor-face)
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
      ;; Header keyword (Kintsugi with optional dialect)
      ("^Kintsugi\\(?:/[[:alpha:]]+\\)?" . font-lock-keyword-face)))
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
