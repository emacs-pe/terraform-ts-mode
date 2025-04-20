;;; terraform-ts-mode.el --- Major mode for editing Terraform files  -*- lexical-binding: t -*-

;; Copyright (C) 2024 Mario Rodas <marsam@users.noreply.github.com>

;; Author: Mario Rodas <marsam@users.noreply.github.com>
;; URL: https://github.com/emacs-pe/terraform-ts-mode
;; Keywords: terraform languages tree-sitter
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))

;; This file is NOT part of GNU Emacs.

;;; License:

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Support for Terraform <https://www.terraform.io/> files.

;; This package is compatible with and tested against the grammar for
;; Terraform found at https://github.com/tree-sitter-grammars/tree-sitter-hcl

;; -------------------------------------------------------------------
;; Israel is committing genocide of the Palestinian people.
;;
;; The population in Gaza is facing starvation, displacement and
;; annihilation amid relentless bombardment and suffocating
;; restrictions on life-saving humanitarian aid.
;;
;; As of March 2025, Israel has killed over 50,000 Palestinians in the
;; Gaza Strip – including 15,600 children – targeting homes,
;; hospitals, schools, and refugee camps.  However, the true death
;; toll in Gaza may be at least around 41% higher than official
;; records suggest.
;;
;; The website <https://databasesforpalestine.org/> records extensive
;; digital evidence of Israel's genocidal acts against Palestinians.
;; Save it to your bookmarks and let more people know about it.
;;
;; Silence is complicity.
;; Protest and boycott the genocidal apartheid state of Israel.
;;
;;
;;                  From the river to the sea, Palestine will be free.
;; -------------------------------------------------------------------

;;; Code:
(require 'treesit)

(eval-when-compile
  (if (fboundp 'treesit-declare-unavailable-functions)
      (treesit-declare-unavailable-functions)
    (declare-function treesit-node-type "treesit.c")
    (declare-function treesit-node-next-sibling "treesit.c")
    (declare-function treesit-parser-create "treesit.c")
    (declare-function treesit-search-subtree "treesit.c")))

(defgroup terraform-ts nil
  "Major mode for editing Terraform files."
  :prefix "terraform-ts-"
  :group 'languages)

(defcustom terraform-ts-indent-offset 2
  "Number of spaces for each indentation step in `terraform-ts-mode'."
  :type 'natnum
  :safe 'natnump)

(defcustom terraform-ts-mode-hook nil
  "Hook run after entering `terraform-ts-mode'."
  :type 'hook
  :options '(eglot-ensure
             flymake-mode
             hs-minor-mode
             outline-minor-mode))

(defcustom terraform-ts-flymake-command '("terraform" "fmt" "-no-color" "-")
  "External tool used to check Terraform source code.
This is a non-empty list of strings: the checker tool possibly
followed by required arguments.  Once launched it will receive
the Terraform source to be checked as its standard input."
  :type '(choice (const :tag "Hclfmt"     ("hclfmt" "-check"))
                 (const :tag "OpenTofu"   ("tofu" "fmt" "-no-color" "-"))
                 (const :tag "Terraform"  ("terraform" "fmt" "-no-color" "-"))
                 (cons  :tag "Set Custom" (string :tag "Command") (repeat (string :tag "Argument")))))

(defvar terraform-ts--syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?#  "< b" table)
    (modify-syntax-entry ?\n "> b" table)
    (modify-syntax-entry ?/  ". 124" table)
    (modify-syntax-entry ?*  ". 23b" table)
    table)
  "Syntax table for `terraform-ts-mode'.")

(defvar terraform-ts--builtins
  '("bool" "string" "number" "object" "tuple" "list" "map" "set" "any")
  "Terraform built-in functions for tree-sitter font-locking.")

(defvar terraform-ts--keywords
  '("for" "endfor" "in"
    "if" "else" "endif")
  "Terraform keywords for tree-sitter font-locking.")

(defvar terraform-ts--treesit-font-lock-rules
  (treesit-font-lock-rules
   :language 'terraform
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'terraform
   :feature 'bracket
   '((["[" "]" "{" "}" "(" ")"]) @font-lock-bracket-face)

   :language 'terraform
   :feature 'delimiter
   '(["." ".*" "," "[*]"] @font-lock-delimiter-face)

   :language 'terraform
   :feature 'string
   '([(quoted_template_start)           ; "
      (quoted_template_end)             ; "
      (template_literal)] @font-lock-string-face
     [(template_interpolation_start)    ; ${
      (template_interpolation_end)      ; }
      (template_directive_start)        ; %{
      (template_directive_end)          ; }
      (strip_marker)                    ; ~
      ] @font-lock-misc-punctuation-face)

   :language 'terraform
   :feature 'operator
   '(["!"] @font-lock-negation-char-face
     ["\*" "/" "%" "\+" "-" ">" ">=" "<" "<=" "==" "!=" "&&" "||"] @font-lock-operator-face)

   :language 'terraform
   :feature 'builtin
   `(((identifier) @font-lock-builtin-face
      (:match ,(regexp-opt terraform-ts--builtins 'symbols)
              @font-lock-builtin-face)))

   :language 'terraform
   :feature 'misc-punctuation
   '(([(ellipsis) "\?" "=>"]) @font-lock-misc-punctuation-face)

   :language 'terraform
   :feature 'constant
   '([(bool_lit) (null_lit)] @font-lock-constant-face)

   :language 'terraform
   :feature 'number
   '((numeric_lit) @font-lock-number-face)

   :language 'terraform
   :feature 'keyword
   `([,@terraform-ts--keywords] @font-lock-keyword-face)

   :language 'terraform
   :feature 'variable
   '((attribute (identifier) @font-lock-variable-name-face)
     ((object_elem
       key: (expression (variable_expr (identifier) @font-lock-variable-name-face)))))

   :language 'terraform
   :feature 'definition
   `((function_call (identifier) @font-lock-function-name-face)
     (body (block (identifier) @font-lock-function-name-face)))

   :language 'terraform
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock settings for `terraform-ts-mode'.")

(defvar terraform-ts--indent-rules
  `((terraform
     ((parent-is "config_file") column-0 0)
     ((node-is ")") parent-bol 0)
     ((node-is "block_end") parent-bol 0)
     ((node-is "tuple_end") parent-bol 0)
     ((node-is "object_end") parent-bol 0)
     ((node-is "attribute") parent-bol 0)
     ((node-is "block") parent-bol 0)
     ((parent-is "comment") prev-adaptive-prefix 0)
     ((parent-is "block") parent-bol terraform-ts-indent-offset)
     ((parent-is "function_call") parent-bol terraform-ts-indent-offset)
     ((parent-is "tuple") parent-bol terraform-ts-indent-offset)
     ((parent-is "object") parent-bol terraform-ts-indent-offset))))

(defun terraform-ts--treesit-defun-name (node)
  "Return the defun name of NODE.
Return nil if there is no name or if NODE is not a defun node."
  (pcase (treesit-node-type node)
    ("attribute"
     (treesit-node-text (treesit-search-subtree node "identifier")))
    ("block"
     (let* ((label (treesit-search-subtree node "string_lit" nil nil 1))
            (label2 (treesit-node-next-sibling label)))
       (if (string-equal (treesit-node-type label2) "string_lit")
           (concat (treesit-node-text (treesit-node-child label 1) t) " " (treesit-node-text (treesit-node-child label2 1)))
         (treesit-node-text (or (treesit-node-child label 1) (treesit-search-subtree node "identifier"))))))))

(defvar-local terraform-ts--flymake-process nil)

;;;###autoload
(defun terraform-ts-flymake (report-fn &rest _args)
  "Terraform backend for Flymake.
Launch `terraform-ts-flymake-command' (which see) and pass to its
standard input the contents of the current buffer.  The output of
this command is analyzed for error messages."
  (unless (executable-find (car terraform-ts-flymake-command))
    (error "Cannot find the Terraform flymake program: %s" (car terraform-ts-flymake-command)))

  (when (process-live-p terraform-ts--flymake-process)
    (kill-process terraform-ts--flymake-process))

  (let ((source (current-buffer)))
    (save-restriction
      (widen)
      (setq
       terraform-ts--flymake-process
       (make-process
        :name "terraform-flymake" :noquery t :connection-type 'pipe
        :buffer (generate-new-buffer " *terraform-ts-flymake*")
        :command terraform-ts-flymake-command
        :sentinel
        (lambda (proc _event)
          (when (eq 'exit (process-status proc))
            (unwind-protect
                (if (with-current-buffer source (eq proc terraform-ts--flymake-process))
                    (with-current-buffer (process-buffer proc)
                      (goto-char (point-min))
                      (cl-loop
                       while (search-forward-regexp
                              "^Error: .+\n\n  on <stdin> line \\([[:digit:]]+\\)\\(?:, in .+\\)?:\\(?:\n\\(?: +.+\\)*\\)+\\(?2:\\(?:.+\n\\)+\\)$"
                              nil t)
                       for msg = (match-string 2)
                       for (beg . end) = (flymake-diag-region
                                          source
                                          (string-to-number (match-string 1)))
                       collect (flymake-make-diagnostic source beg end :error msg)
                       into diags
                       finally (funcall report-fn diags)))
                  (flymake-log :debug "Canceling obsolete check %s" proc))
              (kill-buffer (process-buffer proc)))))))
      (process-send-region terraform-ts--flymake-process (point-min) (point-max))
      (process-send-eof terraform-ts--flymake-process))))

;;;###autoload
(define-derived-mode terraform-ts-mode prog-mode "Terraform"
  "Major mode for editing Terraform files, powered by tree-sitter.

\\{terraform-ts-mode-map}"
  :syntax-table terraform-ts--syntax-table
  (when (treesit-ready-p 'terraform)
    (treesit-parser-create 'terraform)

    ;; Comments.
    (setq-local comment-start "# ")
    (setq-local comment-start-skip "#+\\s-*")

    ;; Indent.
    (setq-local indent-tabs-mode nil
                treesit-simple-indent-rules terraform-ts--indent-rules)

    ;; Electric.
    (setq-local electric-indent-chars
                (append "{}[]()" electric-indent-chars))

    ;; Font-lock.
    (setq-local treesit-font-lock-settings terraform-ts--treesit-font-lock-rules)
    (setq-local treesit-font-lock-feature-list
                '((comment definition)
                  (builtin string number constant)
                  (delimiter operator keyword variable)
                  (bracket error misc-punctuation)))
    ;; Imenu.
    (setq-local treesit-simple-imenu-settings
                `(("Block" "\\`block\\'" nil nil)))

    ;; Navigation.
    (setq-local treesit-defun-type-regexp
                (regexp-opt '("block" "attribute")))
    (setq-local treesit-defun-name-function #'terraform-ts--treesit-defun-name)

    ;; Flymake.
    (add-hook 'flymake-diagnostic-functions #'terraform-ts-flymake nil 'local)

    (treesit-major-mode-setup)))

;;;###autoload
(when (treesit-ready-p 'terraform)
  (add-to-list 'auto-mode-alist '("\\.tf\\(vars\\)?\\'" . terraform-ts-mode)))

(provide 'terraform-ts-mode)
;;; terraform-ts-mode.el ends here
