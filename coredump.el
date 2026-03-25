;;; coredump.el --- Browse and debug coredumps with syntax highlighting -*- lexical-binding: t; -*-

;; Author: Laluxx
;; Version: 0.3.0
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

(defcustom coredump-use-other-window nil
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

(defcustom coredump-use-cache t
  "Whether to cache coredump output to make subsequent views instant."
  :type 'boolean
  :group 'coredump)

(defcustom coredump-show-exit-messages t
  "If non-nil, show a friendly message when quitting a coredump."
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


;;; Cache

(defvar coredump--cache (make-hash-table :test 'equal)
  "Hash table mapping coredump identifiers to their buffer content.")

(defun coredump--get-unique-id (match)
  "Get a deterministic unique ID for the coredump MATCH."
  (let ((command (format "%s info %s --format=json --no-pager"
                         coredump-coredumpctl-program
                         (shell-quote-argument match))))
    (with-temp-buffer
      (let ((exit-code (call-process-shell-command command nil t)))
        (if (and (= exit-code 0) (> (buffer-size) 0))
            ;; Group these two together!
            (progn
              (goto-char (point-min))
              (if (re-search-forward "\"__CURSOR\"\\s-*:\\s-*\"\\([^\"]+\\)\"" nil t)
                  (match-string 1)
                (md5 (buffer-string))))
          ;; This is now correctly the ONLY 'else' part
          (format "fallback-%s" match))))))

(defun coredump--clean-buffer-output ()
  "Clean up the current buffer before caching/displaying."
  (goto-char (point-min))
  ;; Strip "End of assembler dump."
  (while (re-search-forward "^End of assembler dump\\..*\n" nil t)
    (replace-match ""))
  ;; Strip LWP/libthread noise
  (goto-char (point-min))
  (while (re-search-forward "^\\(\\[New LWP.*\\|\\[Thread debugging.*\\|Using host libthread_db.*\\)\n" nil t)
    (replace-match "")))

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
;; n:  anywhere before #0     ->  one space before #0
;;     on #0 … #(N-1)         ->  one space before next #
;;     on #N (last)           ->  one space before first disasm address
;;     inside disasm          ->  one space before next address line
;;                                  (wraps: no-op at last disasm line)
;; p:  on first disasm line   ->  one space before last frame #
;;     inside disasm          ->  one space before previous address line
;;     on #0                  ->  point-min
;;     on #1 … #N             ->  one space before previous #
;;     before #0              ->  no-op

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

(defun coredump-next-line ()
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
     ;; Fallback: in the zone between last frame and disasm
     (t
      (if addrs
          (goto-char (max (point-min) (- (car addrs) 2)))
        (goto-char (max (point-min) (- (car frames) 2))))))))

(defun coredump-prev-line ()
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
     ;; Fallback: in the zone between last frame and disasm
     (t
      (goto-char (max (point-min) (- (car (last frames)) 2)))))))

(defun coredump-goto-rip ()
  "Place the cursor on the > of the => current-instruction line."
  (interactive)
  (let ((pos (coredump--rip-position)))
    (if pos
        (goto-char pos)
      (message "coredump: no current instruction (=>) found"))))



(defun coredump-list ()
  "List coredumps with syntax highlighting and a persistent header."
  (interactive)
  (let* ((output (shell-command-to-string
                  (format "%s list --no-pager" coredump-coredumpctl-program)))
         (all-lines (split-string output "\n" t))
         ;; Extract the original header (TIME PID UID...)
         (header (when (string-prefix-p "TIME" (car all-lines))
                   (propertize (car all-lines) 'face 'font-lock-comment-face)))
         (data-lines (if header (cdr all-lines) all-lines))
         (highlighted-lines
          (mapcar
           (lambda (line)
             (let ((s (copy-sequence line)))
               ;; Signal highlighting
               (when (string-match "\\bSIG[A-Z]+\\b" s)
                 (add-text-properties (match-beginning 0) (match-end 0) '(face coredump-signal-face) s))
               ;; present/missing
               (when (string-match "\\bpresent\\b" s)
                 (add-text-properties (match-beginning 0) (match-end 0) '(face success) s))
               (when (string-match "\\bmissing\\b" s)
                 (add-text-properties (match-beginning 0) (match-end 0) '(face error) s))
               ;; Standalone hyphens
               (let ((start 0))
                 (while (string-match "\\(?:^\\|[[:space:]]\\)\\(-\\)\\(?:[[:space:]]\\|$\\)" s start)
                   (add-text-properties (match-beginning 1) (match-end 1) '(face shadow) s)
                   (setq start (match-end 0))))
               s))
           (reverse data-lines)))
         ;; Combine header and data
         (final-list (if header (cons header highlighted-lines) highlighted-lines))
         (collection (lambda (string pred action)
                       (if (eq action 'metadata)
                           '(metadata (display-sort-function . identity))
                         (complete-with-action action final-list string pred))))
         (choice (completing-read "Select coredump: " collection nil t)))
    (when (and choice (not (string-empty-p choice)))
      ;; If user accidentally selects the header, do nothing
      (if (string-match "[[:space:]]+\\([0-9]+\\)[[:space:]]+" choice)
          (let ((pid (match-string 1 choice)))
            (setq coredump-entry pid)
            (coredump--run nil))
        (unless (string-prefix-p "TIME" choice)
          (message "coredump: Could not parse PID"))))))

;;; Commands

(defun coredump-quit-help ()
  "Kill the coredump buffer and also close the standard *Help* window/buffer."
  (interactive)
  (let ((help-buf (get-buffer "*Help*")))
    (when help-buf
      (let ((help-win (get-buffer-window help-buf)))
        (when help-win
          (delete-window help-win))
        (kill-buffer help-buf))))
  (quit-window))

(defun coredump-help ()
  "Show a clean help window with TAB/n and p/backtab navigation."
  (interactive)
  (let* ((buf-name "*coredump-help*")
         (help-buf (get-buffer-create buf-name))
         (window (display-buffer-below-selected help-buf nil)))
    (with-current-buffer help-buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (substitute-command-keys "\\{coredump-mode-map}"))
        (goto-char (point-min))
        ;; Clean up headers/separators
        (when (re-search-forward "^Key\\s-+Binding" nil t)
          (delete-region (point-min) (line-beginning-position 3)))
        (while (re-search-forward "^-+$" nil t)
          (delete-region (line-beginning-position) (line-beginning-position 2)))

        (set-buffer-modified-p nil)
        (setq-local buffer-read-only t)
        (local-set-key (kbd "TAB")       #'forward-button)
        (local-set-key (kbd "n")         #'forward-button)
        (local-set-key (kbd "<backtab>") #'backward-button)
        (local-set-key (kbd "p")         #'backward-button)
        (local-set-key (kbd "q")         #'coredump-quit-help)
        (local-set-key (kbd "?")         #'coredump-quit-help)))
    (select-window window)
    (fit-window-to-buffer window)
    (goto-char (point-min))
    (end-of-line)
    (backward-sexp)))

(defconst coredump-exit-messages
  '("Take a breather, the bug isn't going anywhere."
    "Excellent debugging session!"
    "One step closer to bug-free code. Probably..."
    "See you at the next SIGSEGV!"
    "The best solutions often come when you're not looking at the screen."
    "Sometimes the best debugger is a good night's sleep."
    "The bug will make more sense after a coffee."
    "Memory leaks aren't the only thing that needs draining. Go grab a drink."
    "May your next gdb session be shorter than this one."
    "Don't let a segmentation fault ruin a perfectly good day."
    "Don't worry, the race condition will wait for you to come back."
    "Your heap is a mess, but your desk doesn't have to be."
    "The bug isn't personal, even if it feels like it is."
    "The code is technically correct, which is the most frustrating kind of wrong."
    "May your next backtrace be shallower than this one.")
  "List of exit messages for `coredump-mode'.")

(defun coredump-quit ()
  "Kill the coredump buffer, its help, and say something nice."
  (interactive)
  (let ((help-buf (get-buffer "*coredump-help*")))
    ;; Cleanup help
    (when help-buf
      (let ((help-win (get-buffer-window help-buf)))
        (when help-win (delete-window help-win))
        (kill-buffer help-buf)))
    ;; Show the message if enabled
    (when (and coredump-show-exit-messages coredump-exit-messages)
      (message (seq-random-elt coredump-exit-messages)))
    (quit-window t)))

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
copies it to a temp file first and decompresses it."
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
        (message "coredump: Temporary core created at %s" tmpcore)))))

;;;###autoload
(defun coredump-revert ()
  "Force a fresh fetch for the current entry and update the cache."
  (interactive)
  (let ((match-id (coredump--get-unique-id coredump-entry)))
    (remhash match-id coredump--cache)
    (coredump--run t)))

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
  (if (or reuse-window (not coredump-use-other-window))
      (switch-to-buffer buf)
    (display-buffer buf '((display-buffer-use-some-window)
                          (inhibit-same-window . t)))))

(defun coredump--build-command-args ()
  "Build the command argument list for coredumpctl."
  (let ((args (list coredump-coredumpctl-program "debug" coredump-entry)))
    (when coredump-debugger-program
      (push (concat "--debugger=" coredump-debugger-program) args))
    (push (concat "--debugger-arguments=" (coredump--build-debugger-arguments)) args)
    (nreverse args)))

(defun coredump--update-timestamp-line ()
  "Update only the numeric part of the \\='min ago' suffix in the Timestamp line."
  (save-excursion
    (goto-char (point-min))
    ;; Match the date string into group 1 and the old minutes into group 2
    (when (re-search-forward "^ +Timestamp: \\(.*?\\) (\\([0-9]+\\)min ago)" nil t)
      (let* ((date-part (match-string 1))
             (new-mins (coredump--get-minutes-ago date-part))
             (inhibit-read-only t))
        ;; Replace only the second match group (the digits) with the new count
        (replace-match (number-to-string new-mins) t t nil 2)))))

(defun coredump--get-minutes-ago (timestamp-str)
  "Calculate integer minutes between TIMESTAMP-STR and now."
  (let* ((time-parsed (parse-time-string timestamp-str))
         (decoded-time (apply #'encode-time time-parsed))
         (diff (float-time (time-subtract (current-time) decoded-time))))
    (truncate (/ diff 60))))


(defun coredump--run (reuse-window)
  "Populate buffer using REUSE-WINDOW.
If cached, update the `minutes ago' timestamp live."
  (let* ((match-id (coredump--get-unique-id coredump-entry))
         (buf (get-buffer-create coredump-buffer-name))
         (cached-data (gethash match-id coredump--cache))
         (done-msg (propertize "DONE" 'face '(success bold))))

    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (and coredump-use-cache cached-data)
            (progn
              (insert cached-data)
              (coredump--update-timestamp-line)
              (message "coredump: loaded from cache"))

          ;; Cache Miss
          (message "coredump: fetching debug data...")
          (shell-command (coredump--build-command) buf nil)
          (ansi-color-apply-on-region (point-min) (point-max))
          (coredump--clean-buffer-output)

          (when (and coredump-use-cache (not (string-empty-p match-id)))
            (puthash match-id (buffer-string) coredump--cache))

          ;; Signal completion with the stylized message
          (message "coredump: %s" done-msg)))

      (unless (eq major-mode 'coredump-mode)
        (coredump-mode))
      (goto-char (point-min)))

    (coredump--display-buffer buf reuse-window)))

;;; Keymap

(defvar coredump-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n")   #'coredump-next-line)
    (define-key map (kbd "p")   #'coredump-prev-line)
    (define-key map (kbd "TAB") #'coredump-next-line)
    (define-key map (kbd "<backtab>") #'coredump-prev-line)
    (define-key map (kbd "r")   #'coredump-goto-rip)
    (define-key map (kbd "d")   #'coredump-debug-with-gdb)
    (define-key map (kbd "l")   #'coredump-list)
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

(provide 'coredump)

;;; coredump.el ends here
