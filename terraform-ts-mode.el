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
           (concat (treesit-node-text label) " " (treesit-node-text label2))
         (treesit-node-text (or label (treesit-search-subtree node "identifier"))))))))

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

    (treesit-major-mode-setup)))

;;;###autoload
(when (treesit-ready-p 'terraform)
  (add-to-list 'auto-mode-alist '("\\.tf\\(vars\\)?\\'" . terraform-ts-mode)))

(provide 'terraform-ts-mode)
;;; terraform-ts-mode.el ends here
