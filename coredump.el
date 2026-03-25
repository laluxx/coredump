;;; coredump.el --- Browse coredumpctl output with syntax highlighting -*- lexical-binding: t; -*-

;; Author: Laluxx
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, debugging, coredump
;; URL: https://github.com/laluxx/coredump

;; This file is not part of GNU Emacs.

;;
;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;

;;; Commentary:

;; coredump.el provides a convenient interface to `coredumpctl debug'
;; with GDB disassembly output.  It displays the result in a dedicated
;; read-only buffer with syntax highlighting for metadata fields,
;; stack frames, assembly instructions and GDB annotations.
;;
;; Usage:
;;
;;   M-x coredump
;;
;; Keybindings in the *coredump* buffer:
;;
;;   n   - next section / stack frame
;;   p   - previous section / stack frame
;;   q   - kill buffer
;;   g   - rerun coredumpctl (coredump-revert)
;;   TAB - next field/frame

;;; TODO [0/3]
;; - [ ] Color archlinux with #1793D1 (and other distros)
;; - [ ] copy the backtrace automatically (option)

;;; Code:

(require 'ansi-color)
(require 'cl-lib)

;;; Customisation

(defgroup coredump nil
  "Interface to coredumpctl debug output."
  :group 'tools
  :prefix "coredump-")

(defcustom coredump-coredumpctl-program "coredumpctl"
  "Path or name of the coredumpctl executable."
  :type 'string
  :group 'coredump)

(defcustom coredump-entry "-1"
  "Which core entry to inspect.  \"-1\" means the most recent one.
Any valid coredumpctl match expression is accepted."
  :type 'string
  :group 'coredump)

(defcustom coredump-debugger-program nil
  "Debugger program passed to --debugger, or nil to use the system default."
  :type '(choice (const :tag "System default" nil) string)
  :group 'coredump)

(defcustom coredump-asm-window 32
  "Byte radius around $rip passed to `disassemble'.
The GDB command issued is: disassemble /m $rip-N,$rip+N"
  :type 'integer
  :group 'coredump)

(defcustom coredump-gdb-extra-commands nil
  "List of additional -ex commands appended to the GDB batch invocation.
Each string becomes a separate \"-ex CMD\" argument."
  :type '(repeat string)
  :group 'coredump)

(defcustom coredump-buffer-name "*coredump*"
  "Name of the coredump output buffer."
  :type 'string
  :group 'coredump)

(defcustom coredump-use-other-window t
  "If non-nil, prefer displaying the coredump buffer in another window.
When `coredump-revert' is called from inside a coredump buffer the
current window is always reused, ignoring this setting."
  :type 'boolean
  :group 'coredump)

(defcustom coredump-stderr-to-stdout t
  "If non-nil, redirect stderr to stdout so GDB output is captured."
  :type 'boolean
  :group 'coredump)

(defcustom coredump-auto-copy-backtrace nil
  "If non-nil, copy the stack trace to the kill ring after loading."
  :type 'boolean
  :group 'coredump)

;;; Faces

(defface coredump-field-name-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for coredumpctl metadata field names (PID, UID, Signal, etc.)."
  :group 'coredump)

(defface coredump-field-value-face
  '((t :inherit font-lock-string-face))
  "Face for coredumpctl metadata field values."
  :group 'coredump)

(defface coredump-signal-face
  '((t :inherit error :weight bold))
  "Face for signal names like SIGABRT, SIGSEGV."
  :group 'coredump)

(defface coredump-frame-number-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for stack frame numbers (#0, #1, ...)."
  :group 'coredump)

(defface coredump-frame-address-face
  '((t :inherit font-lock-type-face))
  "Face for addresses in stack frames."
  :group 'coredump)

(defface coredump-frame-function-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for function names in stack frames."
  :group 'coredump)

(defface coredump-frame-lib-face
  '((t :inherit font-lock-comment-face))
  "Face for library/binary names in stack frames."
  :group 'coredump)

(defface coredump-asm-arrow-face
  '((t :inherit warning :weight bold))
  "Face for the => arrow marking the current instruction."
  :group 'coredump)

(defface coredump-asm-address-face
  '((t :inherit font-lock-type-face))
  "Face for addresses in disassembly lines."
  :group 'coredump)

(defface coredump-asm-offset-face
  '((t :inherit font-lock-doc-face))
  "Face for <function+offset> annotations in disassembly."
  :group 'coredump)

(defface coredump-asm-mnemonic-face
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for assembly mnemonics (mov, call, jmp, etc.)."
  :group 'coredump)

(defface coredump-asm-register-face
  '((t :inherit font-lock-variable-name-face))
  "Face for register names (%rax, %rbp, etc.)."
  :group 'coredump)

(defface coredump-gdb-header-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for GDB informational header lines."
  :group 'coredump)

(defface coredump-section-header-face
  '((t :inherit font-lock-preprocessor-face :weight bold))
  "Face for section headers like \"Stack trace of thread N\"."
  :group 'coredump)

(defface coredump-timestamp-face
  '((t :inherit font-lock-string-face :slant italic))
  "Face for timestamp values."
  :group 'coredump)

(defface coredump-path-face
  '((t :inherit font-lock-string-face :underline t))
  "Face for file paths and executables."
  :group 'coredump)

(defface coredump-generated-by-arg-face
  '((t :inherit success))
  "Face for the command inside backticks in \"Core was generated by `CMD'\"."
  :group 'coredump)

;;; Font-lock keywords

(defconst coredump-font-lock-keywords
  `(
    ;; [New LWP ...] / [Thread ...] / Using host libthread_db ...
    ("^\\(\\[.*?\\]\\|Using host libthread_db.*\\)"
     (0 'coredump-gdb-header-face))

    ;; "Core was generated by `CMD ARGS'."
    ;; Highlight the command inside backticks with success face.
    ("^\\(Core was generated by\\) `\\([^']*\\)'\\(\\.\\)"
     (1 'coredump-gdb-header-face)
     (2 'coredump-generated-by-arg-face)
     (3 'coredump-gdb-header-face))

    ;; "Program terminated with signal SIGXXX, description."
    ("^\\(Program terminated with signal\\) \\([A-Z]+\\),\\(.*\\)"
     (1 'coredump-gdb-header-face)
     (2 'coredump-signal-face)
     (3 'coredump-gdb-header-face))

    ;; Section header inside the message block
    ("\\(Stack trace of thread [0-9]+\\):"
     (1 'coredump-section-header-face))

    ;; GDB current-frame header: #0  func (args) at file:line
    ("^#\\([0-9]+\\)  \\([^ \t(]+\\)"
     (1 'coredump-frame-number-face)
     (2 'coredump-frame-function-face))

    ;; Metadata field lines:  "         PID: 49789 (monad)"
    ("^ *\\([A-Za-z][A-Za-z ]+[A-Za-z]\\): \\(.*\\)$"
     (1 'coredump-field-name-face)
     (2 'coredump-field-value-face))

    ;; Stack frame lines: "#N  0xADDR func (lib.so + 0xOFF)"
    ("\\(#[0-9]+\\) +\\(0x[0-9a-fA-F]+\\) +\\([^ \t(]+\\) +(\\([^)]+\\))"
     (1 'coredump-frame-number-face)
     (2 'coredump-frame-address-face)
     (3 'coredump-frame-function-face)
     (4 'coredump-frame-lib-face))

    ;; Current instruction arrow
    ("^=> " (0 'coredump-asm-arrow-face))

    ;; Disassembly address + offset: "   0x7f... <func+268>:"
    ("^ *\\(0x[0-9a-fA-F]+\\) +\\(<[^>]+>\\):"
     (1 'coredump-asm-address-face)
     (2 'coredump-asm-offset-face))

    ;; Assembly mnemonics (first token after the colon on asm lines)
    (":\\s-+\\([a-z][a-z0-9]*\\)\\b"
     (1 'coredump-asm-mnemonic-face))

    ;; Registers and immediate hex values: %rax  $0x0
    ("\\(%[a-z][a-z0-9]*\\|\\$0x[0-9a-fA-F]+\\)"
     (1 'coredump-asm-register-face))

    ;; Signal names anywhere in values
    ("\\b\\(SIG[A-Z]+\\|ABRT\\|SEGV\\|KILL\\|TERM\\|BUS\\|FPE\\|ILL\\|TRAP\\)\\b"
     (0 'coredump-signal-face))

    ;; Arch Linux hostname
    ("\\b\\(archlinux\\)\\b"
     (1 '((t :foreground "#1793D1" :weight bold)) t))

    ;; File paths
    ("\\(/[^ \t\n()]+\\)"
     (1 'coredump-path-face))

    ;; Standalone hex addresses
    ("\\b\\(0x[0-9a-fA-F]+\\)\\b"
     (1 'coredump-frame-address-face)))
  "Font-lock keywords for `coredump-mode'.")

;;; Navigation
;;
;; The buffer has two sections:
;;   FRAMES  — the backtrace lines matching "^ *#[0-9]+"
;;   DISASM  — the disassembly, starting with the first "   0x..." line
;;             after "Dump of assembler code"
;;
;; Cursor is always placed one space before the target character
;; (one space before # for frames, one space before 0x for disasm lines).
;;
;; n:  anywhere before #0       → one space before #0
;;     on #0 … #(N-1)           → one space before next #
;;     on #N (last)             → one space before first disasm address
;;     inside disasm            → one space before next address line
;;                                (wraps: no-op at last disasm line)
;; p:  on first disasm line     → one space before last frame #
;;     inside disasm            → one space before previous address line
;;     on #0                    → point-min
;;     on #1 … #N               → one space before previous #
;;     before #0                → no-op

(defun coredump--frame-positions ()
  "Return sorted list of positions of each # on backtrace lines.
Only matches systemd-style frames (indented, followed by a hex address)
to avoid picking up GDB frame headers like #0  func (args)."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^ +\\(#[0-9]+\\) +0x[0-9a-fA-F]+" nil t)
        (push (match-beginning 1) positions)))
    (sort (delete-dups positions) #'<)))

(defun coredump--disasm-address-positions ()
  "Return sorted list of positions of the 0 on each disasm address line.
Only lines inside the Dump of assembler code block are included."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward "^Dump of assembler code" nil t)
        (forward-line 1)
        (while (not (eobp))
          ;; match both normal lines "   0x..." and arrow line "=> 0x..."
          (when (looking-at "^\\(?:=> \\)?[ ]*\\(0x[0-9a-fA-F]+\\)")
            (push (match-beginning 1) positions))
          (forward-line 1))))
    (sort (delete-dups positions) #'<)))

(defun coredump--rip-position ()
  "Return position of the > character on the => line, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^=>" nil t)
      (1- (point)))))

(defun coredump--current-frame (here frames)
  "Return the frame position in FRAMES that HERE is sitting on.
The position is expected to be two characters before HERE, or nil."
  (cl-find-if (lambda (p) (= here (max (point-min) (- p 2)))) frames))

(defun coredump-next-section ()
  "Move point forward through frames then disassembly lines."
  (interactive)
  (let* ((frames (coredump--frame-positions))
         (addrs  (coredump--disasm-address-positions))
         (here   (point))
         (on-frame (coredump--current-frame here frames))
         (on-addr  (cl-find-if (lambda (p) (= here (max (point-min) (- p 2)))) addrs)))
    (cond
     ((null frames)
      (message "coredump: no stack frames found"))
     ;; Sitting before the first frame (not on any frame)
     ((and (null on-frame) (null on-addr) (< here (car frames)))
      (goto-char (max (point-min) (- (car frames) 2))))
     ;; On the last frame → go to first disasm address
     ((and on-frame (= on-frame (car (last frames))))
      (if addrs
          (goto-char (max (point-min) (- (car addrs) 2)))
        (message "coredump: no disassembly found")))
     ;; On a frame (not last) → next frame
     (on-frame
      (let ((next (cl-find-if (lambda (p) (> p on-frame)) frames)))
        (if next
            (goto-char (max (point-min) (- next 2)))
          (message "coredump: no next frame"))))
     ;; On a disasm addr → next addr
     (on-addr
      (let ((next (cl-find-if (lambda (p) (> p on-addr)) addrs)))
        (if next
            (goto-char (max (point-min) (- next 2)))
          (message "coredump: already at last disasm line"))))
     ;; Fallback: go to first frame
     (t
      (goto-char (max (point-min) (- (car frames) 2)))))))

(defun coredump-prev-section ()
  "Move point backward through disassembly lines then frames."
  (interactive)
  (let* ((frames (coredump--frame-positions))
         (addrs  (coredump--disasm-address-positions))
         (here   (point))
         (on-frame (coredump--current-frame here frames))
         (on-addr  (cl-find-if (lambda (p) (= here (max (point-min) (- p 2)))) addrs)))
    (cond
     ((null frames)
      (message "coredump: no stack frames found"))
     ;; On first disasm addr → jump to last frame
     ((and on-addr (= on-addr (car addrs)))
      (goto-char (max (point-min) (- (car (last frames)) 2))))
     ;; On a disasm addr (not first) → previous addr
     (on-addr
      (let ((prev (cl-reduce (lambda (acc p) (if (< p on-addr) p acc))
                             addrs :initial-value nil)))
        (if prev
            (goto-char (max (point-min) (- prev 2)))
          (goto-char (max (point-min) (- (car (last frames)) 2))))))
     ;; On first frame → point-min
     ((and on-frame (= on-frame (car frames)))
      (goto-char (point-min)))
     ;; On a frame (not first) → previous frame
     (on-frame
      (let ((prev (cl-reduce (lambda (acc p) (if (< p on-frame) p acc))
                             frames :initial-value nil)))
        (if prev
            (goto-char (max (point-min) (- prev 2)))
          (goto-char (point-min)))))
     ;; Before first frame
     ((< here (car frames))
      (message "coredump: already at beginning"))
     ;; Fallback
     (t (message "coredump: nothing to move to")))))

(defun coredump-goto-rip ()
  "Place the cursor on the > of the => current-instruction line."
  (interactive)
  (let ((pos (coredump--rip-position)))
    (if pos
        (goto-char pos)
      (message "coredump: no current instruction (=>) found"))))

;;; Keymap

(defvar coredump-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n")   #'coredump-next-section)
    (define-key map (kbd "p")   #'coredump-prev-section)
    (define-key map (kbd "TAB") #'coredump-next-section)
    (define-key map (kbd "r")   #'coredump-goto-rip)
    (define-key map (kbd "d")   #'coredump-debug-with-gdb)
    (define-key map (kbd "q")   #'coredump-quit)
    (define-key map (kbd "g")   #'coredump-revert)
    (define-key map (kbd "?")   #'coredump-help)
    map)
  "Keymap for `coredump-mode'.")

;;; Major mode

(define-derived-mode coredump-mode special-mode "Coredump"
  "Major mode for viewing `coredumpctl debug' output.

\\{coredump-mode-map}"
  :group 'coredump
  (setq buffer-read-only t)
  (setq font-lock-defaults '(coredump-font-lock-keywords t))
  (font-lock-mode 1)
  (setq-local truncate-lines t)
  (setq-local revert-buffer-function
              (lambda (&optional _auto _noconfirm) (coredump-revert))))

;;; Commands

(defun coredump-help ()
  "Show `coredump-mode' keybindings in a split window below."
  (interactive)
  (split-window-below)
  (describe-mode)
  (other-window 1)
  (delete-window (selected-window))
  (other-window 1)
  (goto-char (point-min))
  (when (re-search-forward "^Key\\s-+Binding" nil t)
    (let ((start (line-beginning-position))
          (inhibit-read-only t))
      (forward-line 2)
      (while (not (or (eobp) (looking-at "^\\s-*$")))
        (forward-line 1))
      (narrow-to-region start (point))))
  (goto-char (point-min))
  (other-window 1))

(defun coredump-quit ()
  "Kill the coredump buffer.
If it is the only window, just kill the buffer.
If other windows exist, also delete this window."
  (interactive)
  (let ((buf (current-buffer))
        (only-window (one-window-p t)))
    (if only-window
        (kill-buffer buf)
      (delete-window (selected-window))
      (kill-buffer buf))))

(defun coredump--parse-field (field)
  "Return the value of FIELD from the current coredump buffer, or nil.
FIELD is the label text as it appears in the buffer, e.g. \"Executable\"."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (concat "^ *" (regexp-quote field) ": *\\(.*?\\) *$") nil t)
      (string-trim (match-string 1)))))

(defun coredump--parse-storage ()
  "Return the core file path from the Storage: line, stripping any trailing note."
  (let ((raw (coredump--parse-field "Storage")))
    (when raw
      ;; strip trailing " (present)" or similar parenthetical
      (if (string-match "\\`\\([^ ]+\\)" raw)
          (match-string 1 raw)
        raw))))

(defun coredump-debug-with-gdb ()
  "Launch a GUD GDB session on the executable and core from the buffer.
Reads Executable: and Storage: fields.  If the core is compressed (.zst),
copies it to a temp file first (to get user ownership), decompresses it
with zstd, then calls `gud-gdb\'."
  (interactive)
  (require 'gud)
  (let ((executable (coredump--parse-field "Executable"))
        (corefile   (coredump--parse-storage)))
    (unless executable
      (user-error "coredump: Could not find Executable: field in buffer"))
    (unless corefile
      (user-error "coredump: Could not find Storage: field in buffer"))
    (setq executable (car (split-string executable " " t)))
    (let* ((tmpcore (if (string-suffix-p ".zst" corefile)
                        (let* ((tmp-zst  (make-temp-file "coredump-" nil ".zst"))
                               (tmp-core (concat tmp-zst ".core")))
                          (message "coredump: copying %s ..."
                                   (file-name-nondirectory corefile))
                          (copy-file corefile tmp-zst t)
                          (message "coredump: decompressing ...")
                          (unless (zerop (call-process "zstd" nil nil nil
                                                       "-d" tmp-zst
                                                       "-o" tmp-core "--force"))
                            (delete-file tmp-zst)
                            (user-error "coredump: Zstd failed"))
                          (delete-file tmp-zst)
                          tmp-core)
                      corefile))
           (tmp-p (not (string= tmpcore corefile))))
      (gud-gdb (format "gdb --fullname %s %s"
                       (shell-quote-argument executable)
                       (shell-quote-argument tmpcore)))
      (when tmp-p
        (run-at-time 10 nil #'delete-file tmpcore)))))

;;;###autoload
(defun coredump-revert ()
  "Re-run coredumpctl and refresh the coredump buffer.
When called from inside a coredump buffer the current window is
reused.  Otherwise `coredump-use-other-window' governs placement."
  (interactive)
  (coredump--run (eq major-mode 'coredump-mode)))

;;;###autoload
(defun coredump ()
  "Run `coredumpctl debug' and display the output in a dedicated buffer.

Output is syntax-highlighted.  Navigate with n / p, refresh with g,
and press q to kill the buffer."
  (interactive)
  (coredump--run nil))

;;; Internal helpers

(defun coredump--build-debugger-arguments ()
  "Build the --debugger-arguments string from customisation variables."
  (let ((parts (list "-batch"
                     (format "-ex \"disassemble $rip-%d,$rip+%d\""
                             coredump-asm-window coredump-asm-window))))
    (dolist (cmd coredump-gdb-extra-commands)
      (push (format "-ex %S" cmd) parts))
    (mapconcat #'identity (nreverse parts) " ")))

(defun coredump--build-command ()
  "Build the full coredumpctl shell command string."
  (concat
   (shell-quote-argument coredump-coredumpctl-program)
   " debug "
   (shell-quote-argument coredump-entry)
   (when coredump-debugger-program
     (concat " --debugger="
             (shell-quote-argument coredump-debugger-program)))
   " --debugger-arguments="
   (shell-quote-argument (coredump--build-debugger-arguments))
   (when coredump-stderr-to-stdout " 2>&1")))

(defun coredump--display-buffer (buf reuse-window)
  "Display BUF in an appropriate window.
If REUSE-WINDOW is non-nil use the selected window directly.
Otherwise honour `coredump-use-other-window'."
  (cond
   (reuse-window
    (switch-to-buffer buf))
   ((and coredump-use-other-window (> (count-windows) 1))
    (display-buffer buf '((display-buffer-use-some-window)
                          (inhibit-same-window . t))))
   (t
    (display-buffer buf '((display-buffer-pop-up-window))))))

(defun coredump--run (reuse-window)
  "Populate the coredump buffer by running coredumpctl and display it.
REUSE-WINDOW is passed directly to `coredump--display-buffer'."
  (let* ((buf (get-buffer-create coredump-buffer-name))
         (cmd (coredump--build-command)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (shell-command cmd buf nil)
        (ansi-color-apply-on-region (point-min) (point-max))
        ;; Strip "End of assembler dump." lines
        (goto-char (point-min))
        (while (re-search-forward "^End of assembler dump\\..*\n" nil t)
          (replace-match ""))
        ;; Strip LWP/libthread_db noise lines
        (goto-char (point-min))
        (while (re-search-forward "^\\(\\[New LWP.*\\|\\[Thread debugging.*\\|Using host libthread_db.*\\)\n" nil t)
          (replace-match ""))
        (unless (eq major-mode 'coredump-mode)
          (coredump-mode))
        (goto-char (point-min))
        (when coredump-auto-copy-backtrace
          (save-excursion
            (when (re-search-forward "^\\s-*Stack trace of thread" nil t)
              (kill-ring-save (line-beginning-position) (point-max))
              (message "coredump: stack trace copied to kill ring"))))))
    (coredump--display-buffer buf reuse-window)))

(provide 'coredump)

;;; coredump.el ends here
