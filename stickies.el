;;; stickies.el --- Sticky notes in dedicated frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Felix Lange

;; Author: Felix Lange <fjl@twurst.com>
;; Maintainer: Felix Lange <fjl@twurst.com>
;; Version: 0.1.4
;; Package-Requires: ((emacs "29.1"))
;; Keywords: convenience
;; URL: https://github.com/fjl/stickies.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;;; Commentary:

;; Apple Stickies-style sticky notes for Emacs.  Each note is a flat
;; file in `stickies-directory'.  The directory listing is the source
;; of truth for which notes exist; the index file holds per-note
;; metadata (theme, frame geometry).

;;; Code:

(require 'cl-lib)
(require 'color)
(require 'face-remap)
(require 'files-x)
(require 'easymenu)

(defgroup stickies nil
  "Sticky notes in dedicated frames."
  :group 'convenience
  :prefix "stickies-")

(defcustom stickies-directory
  (expand-file-name "stickies/" "~")
  "Directory holding all sticky note files.
Every non-hidden file in this directory is treated as a sticky note.
The per-note metadata index lives here too, in a hidden file."
  :type 'directory)

(defcustom stickies-default-extension "txt"
  "File extension (without the leading dot) for new sticky notes.
The extension determines the major mode of new notes via
`auto-mode-alist'; for example \"org\" creates `.org' notes that
open in `org-mode'."
  :type 'string)

(defcustom stickies-themes
  '((yellow :background "#fff8b8" :foreground "#222222" :border "#cdb94f")
    (pink   :background "#fcc9c9" :foreground "#222222" :border "#d68a8a")
    (purple :background "#d8c9f0" :foreground "#222222" :border "#a98ad1")
    (blue   :background "#c2dffc" :foreground "#222222" :border "#7fabd6")
    (green  :background "#c5edc6" :foreground "#222222" :border "#85bd86"))
  "Named color themes for sticky notes.
Each entry has the form (NAME PROPERTIES) where PROPERTIES is a plist with
`:background' and `:foreground' colors and an optional `:border' color
\(for the header line's underline and the minibuffer frame's edge).  When
`:border' is omitted it is derived by darkening `:background' (see
`stickies-border-darken')."
  :type '(alist :key-type symbol :value-type sexp))

(defcustom stickies-default-theme 'yellow
  "Name of the default theme used for new sticky notes.
Must be a key in `stickies-themes'."
  :type 'symbol)

(defvar stickies--protected-faces
  '(;; Faces handled specially or structural to a note's own rendering.
    default header-line cursor fringe
    border internal-border child-frame-border scroll-bar
    vertical-border window-divider
    window-divider-first-pixel window-divider-last-pixel
    stickies-close-button-hover stickies-roll-button-hover)
  "Faces never flattened, regardless of `stickies-flatten-exclude'.
These are system-level faces that must keep their own colors: the
note's own structural faces plus frame and window chrome.")

(defcustom stickies-flatten-exclude
  '(region secondary-selection highlight hl-line
    isearch lazy-highlight isearch-fail match
    show-paren-match show-paren-mismatch
    error warning success
    link mouse tooltip
    mode-line mode-line-inactive mode-line-buffer-id
    mode-line-emphasis mode-line-highlight
    tab-bar tab-bar-tab tab-bar-tab-inactive tab-line
    ;; Completion-UI selection and match highlighting, so the current
    ;; candidate and matched text stay visible in the minibuffer frame.
    completions-common-part completions-first-difference completions-highlight
    completions-annotations icomplete-selected-match
    ivy-current-match ivy-minibuffer-match-highlight
    ivy-minibuffer-match-face-1 ivy-minibuffer-match-face-2
    ivy-minibuffer-match-face-3 ivy-minibuffer-match-face-4
    swiper-match-face-1 swiper-match-face-2
    swiper-match-face-3 swiper-match-face-4
    vertico-current selectrum-current-candidate
    orderless-match-face-0 orderless-match-face-1
    orderless-match-face-2 orderless-match-face-3
    helm-selection helm-match)
  "Additional faces that keep their colors in sticky notes.
Includes selection and match-highlight faces of the common completion
UIs (built-in completions, ivy, swiper, vertico, selectrum, orderless,
helm) so the current candidate stays visible in a note's minibuffer
frame.  Faces not currently defined are simply ignored.

Customize this to preserve more (or fewer) faces when flattening a note
and its minibuffer frame to the theme colors.  The faces in
`stickies--protected-faces' are always excluded on top of these."
  :type '(repeat face))

(defcustom stickies-face-remaps nil
  "Extra face remaps applied after flattening.
Each entry is (FACE . SPEC), where SPEC is the property-list form
accepted by `face-remap-add-relative', e.g.
  (org-todo :foreground \"red\" :weight bold).
Applied last so they override flattening."
  :type '(alist :key-type face :value-type sexp))

(defcustom stickies-title-format '("%b")
  "Title shown in a sticky note's header line.
A mode-line construct (see `mode-line-format') rendered with
`format-mode-line', so it may hold strings, %-constructs, your own
variables, and `:eval' forms.  Evaluated in the note's buffer."
  :type 'sexp
  :risky t)

(defcustom stickies-header-text-height 0.8
  "Scale of a note's chrome text relative to its body.
Applies to the smaller text used for the header line and the minibuffer.
A value below 1.0 makes them smaller than the note body; nil leaves them
at the body's size."
  :type '(choice (const :tag "Same as body" nil) number))

(defcustom stickies-auto-save-interval 2
  "Idle seconds before a modified sticky note is auto-saved.
Set to nil to disable auto-saving."
  :type '(choice (number :tag "Seconds")
                 (const :tag "Off" nil)))

(defcustom stickies-new-note-hook nil
  "Hook run after a new sticky note has been created and opened.
Each function is called with no arguments and with the new note's
buffer current."
  :type 'hook)


;;;; Index state and I/O

(defvar stickies--notes nil
  "Alist of per-note metadata.
Each entry has the form (BASENAME . ATTRS) where ATTRS is an
alist that may contain `:theme' (a symbol naming an entry in
`stickies-themes'), `:params' (an alist of frame parameters), and
`:rolled-up' (whether the sticky note was last seen in the rolled-up
state).  Notes are identified by their basename within
`stickies-directory'.")

(defun stickies--index-file ()
  "Return the absolute path of the index file.
It's a dotfile inside `stickies-directory' so directory listings
of notes naturally skip it."
  (expand-file-name ".stickies-index.eld" stickies-directory))

(defun stickies--save-index ()
  "Write `stickies--notes' to the index file."
  (unless (file-directory-p stickies-directory)
    (make-directory stickies-directory t))
  (with-temp-file (stickies--index-file)
    (let ((print-length nil)
          (print-level nil))
      (insert ";; sticky note index\n")
      (prin1 stickies--notes (current-buffer))
      (insert "\n"))))

(defun stickies--load-index ()
  "Load `stickies--notes' from the index file if present.
Drops entries that no longer refer to existing files."
  (let ((file (stickies--index-file)) index)
    (if (file-exists-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (setq index (read (current-buffer)))))
    (if (stickies--validate-index index)
        (progn
          (setq stickies--notes index)
          (stickies--prune-index))
      (message "Sticky note index %s is invalid. %s" file index)
      (setq stickies--notes nil))))

(defun stickies--validate-index (index)
  "Return non-nil if INDEX is a well-formed sticky note index."
  (and (listp index)
       (seq-every-p
        (lambda (entry)
          (and (listp entry)
               (stringp (car entry))
               (seq-every-p #'consp (cdr entry))))
        index)))

(defun stickies--prune-index ()
  "Drop index entries whose files no longer exist in `stickies-directory'."
  (setq stickies--notes
        (cl-remove-if-not
         (lambda (entry)
           (let ((key (car entry)))
             (and (stringp key)
                  (not (string-match-p "/" key))
                  (file-exists-p (stickies--note-path key)))))
         stickies--notes)))

(defun stickies--note-path (basename)
  "Return the absolute path for BASENAME under `stickies-directory'."
  (expand-file-name basename stickies-directory))

(defun stickies--note-file-p (basename)
  "Return non-nil if BASENAME names a real sticky note file.
Excludes hidden files (leading dot -- the index, lock files such as
`.#note.txt', etc.), Emacs backup files (trailing `~') and auto-save
files (`#note.txt#'), none of which should be opened as notes."
  (and (stringp basename)
       (not (string-empty-p basename))
       (not (string-prefix-p "." basename))
       (not (string-suffix-p "~" basename))
       (not (and (string-prefix-p "#" basename)
                 (string-suffix-p "#" basename)))))

(defun stickies--note-basename (path)
  "Return PATH's basename if it is a note file under `stickies-directory'.
Returns nil for paths outside the directory and for non-note files
\(hidden, backup or auto-save files; see `stickies--note-file-p')."
  (and path
       (file-directory-p stickies-directory)
       (let ((p (expand-file-name path)))
         (when (file-in-directory-p p stickies-directory)
           (let ((basename (file-name-nondirectory p)))
             (and (stickies--note-file-p basename) basename))))))

(defun stickies--entry (basename)
  "Return the index cell for BASENAME, or nil."
  (assoc basename stickies--notes))

(defun stickies--register (basename)
  "Ensure BASENAME has an index entry.  Return its cell."
  (let ((cell (stickies--entry basename)))
    (unless cell
      (setq cell (list basename))
      (push cell stickies--notes)
      (stickies--save-index))
    cell))

(defun stickies--unregister (basename)
  "Remove BASENAME from the index."
  (setq stickies--notes
        (cl-remove basename stickies--notes
                   :key #'car :test #'string=))
  (stickies--save-index))

(defun stickies--all-notes ()
  "Return basenames of all note files in `stickies-directory'.
Hidden, backup and auto-save files are excluded; see
`stickies--note-file-p'."
  (when (file-directory-p stickies-directory)
    (cl-remove-if-not #'stickies--note-file-p
                      (directory-files stickies-directory))))


;;;; Color application

(defun stickies--current-theme ()
  "Return the active theme symbol for the current sticky note buffer."
  (let ((basename (and buffer-file-name
                       (stickies--note-basename buffer-file-name))))
    (or (and basename
             (alist-get :theme (cdr (stickies--entry basename))))
        stickies-default-theme)))

(defun stickies--theme-colors ()
  "Return (BG . FG) for the current buffer's theme."
  (let* ((name (stickies--current-theme))
         (spec (or (cdr (assq name stickies-themes))
                   (cdr (assq stickies-default-theme stickies-themes)))))
    (cons (plist-get spec :background)
          (plist-get spec :foreground))))

(defcustom stickies-border-darken 18
  "How much darker than the theme background a derived border is, in percent.
Used only for a theme without an explicit `:border' (see `stickies-themes')."
  :type 'integer)

(defun stickies--theme-border ()
  "Return the border color for the current buffer's theme.
The theme's `:border', or `:background' darkened by `stickies-border-darken'."
  (let* ((name (stickies--current-theme))
         (spec (or (cdr (assq name stickies-themes))
                   (cdr (assq stickies-default-theme stickies-themes)))))
    (or (plist-get spec :border)
        (color-darken-name (plist-get spec :background) stickies-border-darken))))

(defun stickies--paint-frame-faces (frame bg fg border)
  "Pin every non-excluded face of FRAME to BG/FG, frame-locally.
Chrome blends into BG; the child-frame border uses BORDER.  Colors are
set absolutely (not relative as `face-remap' would) so the user's global
theme cannot show through -- both fg and bg are pinned, while
slant/weight/etc. are left alone.  Used for both a note frame and its
minibuffer child frame, so the prompt and completions match the note."
  ;; Pin the body background two ways: the frame parameter covers the area
  ;; painted below the last line of text, and the `default' face covers the
  ;; text background itself.  On the NS port the frame parameter does not
  ;; propagate to the `default' face, so without the explicit face attribute
  ;; the note body keeps the global (often dark) theme while only the chrome
  ;; faces below pick up BG.
  (set-frame-parameter frame 'background-color bg)
  (set-frame-parameter frame 'foreground-color fg)
  (set-face-attribute 'default frame :background bg :foreground fg)
  (set-face-attribute 'header-line frame
                      :background bg
                      :foreground fg
                      :height (or stickies-header-text-height 1.0)
                      ;; A faint box all around, matching the note
                      ;; minibuffer's full border.  Positive line-width
                      ;; insets the text by 1px, just as the minibuffer's
                      ;; child-frame border insets its content -- so the
                      ;; prompt lands exactly where the header text was,
                      ;; with no 1px shift when the minibuffer appears.
                      :box `(:line-width (1 . 1) :color ,border)
                      :underline nil
                      :overline nil)
  ;; Fringe and other chrome blend into the background; the child-frame
  ;; border (the minibuffer's visible 1px edge) uses the border color.
  (dolist (face '(fringe internal-border border
                  scroll-bar vertical-border window-divider
                  window-divider-first-pixel window-divider-last-pixel))
    (when (facep face) (set-face-attribute face frame :background bg)))
  (when (facep 'child-frame-border)
    (set-face-attribute 'child-frame-border frame :background border))
  (when (facep 'cursor) (set-face-attribute 'cursor frame :background fg))
  ;; Header-line button hover: a darker background (the border color), so
  ;; it reads as a press target and meets the header's border seamlessly
  ;; instead of painting the plain note background over it.
  (dolist (face '(stickies-close-button-hover stickies-roll-button-hover))
    (when (facep face)
      (set-face-attribute face frame :background border :foreground fg :box nil)))
  ;; Pin every other face to the theme colors -- including color-less
  ;; faces such as `italic'/`bold', whose text would otherwise inherit
  ;; the frame's background and show a stray patch under a dark global
  ;; theme.  Setting only the colors preserves slant/weight/etc.
  (dolist (face (face-list))
    (unless (or (memq face stickies--protected-faces)
                (memq face stickies-flatten-exclude))
      (set-face-attribute face frame :foreground fg :background bg)))
  (pcase-dolist (`(,face . ,spec) stickies-face-remaps)
    (apply #'set-face-attribute face frame spec))
  ;; Repaint the cached fringe/border pixels the attributes above don't.
  (redraw-frame frame))

(defun stickies--apply-frame-colors (frame)
  "Paint note FRAME and its minibuffer child frame with its theme colors.
The colors are attributes of the frames, not of the note's buffer: the
same buffer shown elsewhere keeps that frame's normal faces, and nothing
displayed in either frame -- buffer text, the prompt, completions,
chrome, the empty area below the last line -- can escape the theme."
  (when (frame-live-p frame)
    (pcase-let ((`(,bg ,fg ,border)
                 (with-current-buffer (stickies--frame-buffer frame)
                   (let ((c (stickies--theme-colors)))
                     (list (car c) (cdr c) (stickies--theme-border))))))
      (stickies--paint-frame-faces frame bg fg border)
      (when-let ((mini (stickies--minibuffer-frame-of frame)))
        (stickies--paint-frame-faces mini bg fg border)))))

(defun stickies--apply-colors ()
  "Recolor the note frame(s) currently displaying the buffer.
Called from a buffer context (mode setup, theme change); the actual
painting is frame-local, see `stickies--apply-frame-colors'.  Only real
note frames are touched, so the buffer shown elsewhere stays normal."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (let ((frame (window-frame window)))
      (when (frame-parameter frame 'stickies-note)
        (stickies--apply-frame-colors frame)))))


;;;; Header line

;; Each button gets its own mouse-face symbol so Emacs treats them as
;; separate highlight regions -- hovering one doesn't light up the other.
(defface stickies-close-button-hover '((t :inherit mode-line-highlight))
  "Mouse hover face for the sticky note close button.")
(defface stickies-roll-button-hover '((t :inherit mode-line-highlight))
  "Mouse hover face for the sticky note roll-up button.")

(defun stickies--button-close (event)
  "Header-line button: delete the sticky note whose button was clicked.
A note with non-whitespace content is deleted only after confirmation;
an empty or whitespace-only note is deleted without prompting."
  (interactive "e")
  (let* ((frame (window-frame (posn-window (event-start event))))
         (buffer (stickies--frame-buffer frame))
         (basename (file-name-nondirectory (buffer-file-name buffer))))
    (when (or (stickies--note-blank-p buffer)
              (yes-or-no-p (format "Delete sticky note %s? " basename)))
      (stickies--delete-note buffer))))

(defvar stickies--close-button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'stickies--button-close)
    m)
  "Keymap for the close button in the sticky note header line.")

(defun stickies--rolled-up-p (&optional frame)
  "Return non-nil if FRAME (default: selected) is rolled up.
The value is the pre-rolled frame height, in lines."
  (frame-parameter frame 'stickies-roll-saved-height))

(defun stickies--persistent-roll-state (frame)
  "The rolled-up state of FRAME as persisted and user-visible: t or nil.
A peeked note (temporarily expanded, see `stickies--peek-down') still
counts as rolled up: that is what it returns to, what the index
records, and what the header-line arrow shows."
  (and (or (stickies--rolled-up-p frame)
           (frame-parameter frame 'stickies-roll-peek))
       t))

(defun stickies--button-roll (_event)
  "Header-line button: toggle the roll-up state of the current sticky note."
  (interactive "e")
  (stickies-toggle-roll-up))

(defvar stickies--roll-button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'stickies--button-roll)
    m)
  "Keymap for the roll-up button in the sticky note header line.")

(defun stickies--header-line ()
  "Return the header-line string for the current sticky note."
  (let* ((title (format-mode-line stickies-title-format))
         ;; The arrow shows the *persisted* roll state: a temporarily
         ;; expanded note (see `stickies--peek-down') keeps the
         ;; rolled-up arrow, because rolled up is what it returns to.
         (roll (propertize
                (if (stickies--persistent-roll-state (selected-frame))
                    " ↓ " " ↑ ")
                'mouse-face 'stickies-roll-button-hover
                'help-echo "mouse-1: roll up/down this sticky note"
                'local-map stickies--roll-button-map))
         (close (propertize
                 " x "
                 'mouse-face 'stickies-close-button-hover
                 'help-echo "mouse-1: close this sticky note"
                 'local-map stickies--close-button-map))
         (fill (propertize
                " " 'display
                `(space :align-to (- right ,(+ (length roll)
                                               (length close)))))))
    (concat " " title fill roll close)))


;;;; Context menu

(defun stickies--set-theme (name)
  "Set NAME as the theme for the current sticky note and persist it."
  (let* ((basename (file-name-nondirectory buffer-file-name))
         (cell (stickies--register basename)))
    (setf (alist-get :theme (cdr cell)) name)
    (stickies--save-index))
  (stickies--apply-colors))

(defun stickies--always-on-top-p (&optional frame)
  "Return non-nil if FRAME (defaults to selected) stays above other windows."
  (eq (frame-parameter frame 'z-group) 'above))

(defun stickies-toggle-always-on-top ()
  "Toggle whether the current sticky note frame stays above other windows."
  (interactive)
  (let ((frame (selected-frame)))
    (set-frame-parameter
     frame 'z-group (if (stickies--always-on-top-p frame) nil 'above))
    (stickies--save-frame-state frame)))

(defvar-local stickies--roll-overlay nil
  "Marker overlay set while the sticky note's buffer is in rolled-up state.")

(defconst stickies--roll-display-vars
  '(cursor-type indicate-buffer-boundaries indicate-empty-lines)
  "Display variables that will be unset while a note is rolled up.")

(defvar-local stickies--roll-saved-vars nil
  "Prior state of `stickies--roll-display-vars', for restore on roll-down.
An alist of (SYMBOL LOCAL-P . VALUE).")

(defun stickies--frame-buffer (frame)
  "Return the buffer shown in FRAME's root window."
  (window-buffer (frame-root-window frame)))

(defun stickies--enter-rolled-up ()
  "Hide buffer content while the sticky note is rolled up.
Keeps the real header line active so the header drag
\(`stickies-drag-frame') continues to work.  An invisible overlay blanks
the (small) body row under the header."
  (unless stickies--roll-overlay
    (setq stickies--roll-saved-vars
          (mapcar (lambda (sym)
                    (cons sym (cons (local-variable-p sym)
                                    (symbol-value sym))))
                  stickies--roll-display-vars))
    (dolist (sym stickies--roll-display-vars)
      (set (make-local-variable sym) nil))
    (let ((o (make-overlay (point-min) (point-max) nil nil t)))
      (overlay-put o 'invisible t)
      (setq stickies--roll-overlay o))))

(defun stickies--exit-rolled-up ()
  "Restore the buffer's normal display."
  (when stickies--roll-overlay
    (delete-overlay stickies--roll-overlay)
    (setq stickies--roll-overlay nil)
    (pcase-dolist (`(,sym ,local-p . ,value) stickies--roll-saved-vars)
      (if local-p
          (set (make-local-variable sym) value)
        (kill-local-variable sym)))
    (setq stickies--roll-saved-vars nil)))

(defun stickies--apply-roll-height (frame)
  "Shrink FRAME to the minimal height with the header line still visible.
`window_wants_header_line' in src/window.c keeps the header iff
WINDOW_PIXEL_HEIGHT > frame_char_height (no mode line).
`set-frame-height' with PIXELWISE sets the frame's text height,
which equals WINDOW_PIXEL_HEIGHT for a single-window frame -- so
passing `frame_char_height + 1' is just enough to keep the
header.  An invisible overlay added in `stickies--enter-rolled-up'
hides whatever buffer content would otherwise paint in the
resulting few-pixel body strip.  The *requested* text height in
pixels is recorded in `stickies-roll-height' so the resize hook
can tell our own resize from an external one."
  (let ((window-min-height 0)
        (window-safe-min-height 0)
        (frame-resize-pixelwise t))
    (set-frame-height frame (1+ (frame-char-height frame)) nil t))
  (set-frame-parameter frame 'stickies-roll-height
                       (1+ (frame-char-height frame)))
  ;; Record the rolled text width; the resize hook restores it (height is
  ;; pinned via `stickies-roll-height', position via `stickies-roll-anchor').
  (set-frame-parameter frame 'stickies-roll-width
                       (frame-text-width frame)))

(defun stickies--roll-down (frame)
  "Expand rolled-up note FRAME back to its pre-roll height.
No-op when FRAME isn't rolled up.  Doesn't persist the state; that is
the caller's business (`stickies-toggle-roll-up' does,
`stickies--peek-down' deliberately doesn't)."
  (when-let ((saved (stickies--rolled-up-p frame)))
    (set-frame-parameter frame 'drag-internal-border t)
    (set-frame-parameter frame 'stickies-roll-saved-height nil)
    (set-frame-parameter frame 'stickies-roll-height nil)
    (set-frame-parameter frame 'stickies-roll-width nil)
    (set-frame-parameter frame 'stickies-roll-anchor nil)
    (with-current-buffer (stickies--frame-buffer frame)
      (stickies--exit-rolled-up))
    (set-frame-height frame saved)))

(defun stickies--roll-up (frame)
  "Shrink note FRAME to its rolled-up titlebar size.
No-op when FRAME is already rolled up.  Doesn't persist the state (see
`stickies--roll-down')."
  (unless (stickies--rolled-up-p frame)
    (set-frame-parameter frame 'drag-internal-border nil)
    (set-frame-parameter frame 'stickies-roll-saved-height
                         (frame-parameter frame 'height))
    (with-current-buffer (stickies--frame-buffer frame)
      (stickies--enter-rolled-up))
    (stickies--apply-roll-height frame)))

(defun stickies-toggle-roll-up (&optional frame)
  "Toggle whether sticky note FRAME (default: the selected frame) is rolled up.
When rolled up the body shrinks to one natural row -- the
smallest size at which Emacs reliably keeps the header line
visible, so the header drag (`stickies-drag-frame') continues to
move the frame.  A rolled-up frame has a fixed height: attempts to
resize it vertically are undone, while width changes are kept.

The toggle acts on the *persisted* roll state, which is also what the
header-line arrow shows: toggling a note that is only temporarily
expanded (see `stickies--peek-down') makes the expansion permanent --
visually nothing moves, the note just stops being rolled up."
  (interactive)
  (let ((frame (or frame (selected-frame))))
    (if (stickies--persistent-roll-state frame)
        (progn
          (set-frame-parameter frame 'stickies-roll-peek nil)
          (stickies--roll-down frame))
      (stickies--roll-up frame))
    (stickies--save-frame-state frame)))

;; A rolled-up note shows only its titlebar, so when the user explicitly
;; switches to its buffer -- `switch-to-buffer', `find-file', a
;; `display-buffer' that routes to the note's frame -- they are looking
;; at something they cannot edit.  "Peeking" fixes that: the note is
;; temporarily expanded and marked with the `stickies-roll-peek' frame
;; parameter, then rolled back up when the peek's reason (the
;; parameter's value) ends:
;;
;;   `selected'    the note's buffer was explicitly switched to
;;                 (`stickies--show-note-frame'); released when the
;;                 note stops being the selected frame
;;                 (`stickies--unpeek-on-deselection').
;;   `minibuffer'  a minibuffer read needs room over the note
;;                 (`stickies--minibuffer-setup'); released when the
;;                 read exits, with the deselection release as a
;;                 safety net.
;;
;; Throughout a peek the note keeps being *persisted* as rolled up, so a
;; session ending mid-peek restores it rolled; the header-line roll
;; button likewise keeps showing the persisted (rolled) state, and
;; toggling acts on that state (`stickies-toggle-roll-up').  Only the
;; explicit buffer switch peeks.  Merely selecting or focusing the
;; note's frame -- clicking it, `other-window'/`other-frame' cycling
;; onto it, the focus landing of `stickies-toggle' -- leaves it rolled:
;; the user is moving among frames, not asking to edit this note, and
;; can press the roll button if they want it open.

(defun stickies--peek-down (frame &optional reason)
  "Temporarily expand rolled-up note FRAME, marked with REASON.
REASON (default `selected') becomes the value of the
`stickies-roll-peek' parameter and determines what rolls the note back
up; see the commentary above.  A frame already peeked keeps its
original reason -- in particular, a minibuffer read on a note that is
peeked open for being selected must not re-mark it `minibuffer', or
the read's exit would cut the selection peek short."
  (unless (frame-parameter frame 'stickies-roll-peek)
    (set-frame-parameter frame 'stickies-roll-peek (or reason 'selected)))
  (stickies--roll-down frame))

(defun stickies--unpeek-on-deselection (_frame)
  "Roll peeked notes back up once they are no longer selected.
On `window-selection-change-functions', which fires (at the next
redisplay) for every way of moving away from a note: switching to
another frame's window (`other-window', `other-frame'), clicking
another frame, or a buffer switch elsewhere.  Selection sitting on a
note's own minibuffer child frame is the one exception -- that is a
minibuffer read *on* the note, not a move away from it.

All peeked notes are checked, not just the frame this hook call is
about: a note can lose the selection in two hops -- note to its
minibuffer frame when a read starts (peek rightly kept), minibuffer
frame to elsewhere when the read ends in a buffer switch -- and the
second hop's change functions are called for the minibuffer frame and
the switch target only, never for the note itself."
  (dolist (frame (frame-list))
    (when (and (frame-parameter frame 'stickies-roll-peek)
               (not (eq frame (selected-frame)))
               (not (eq (selected-frame)
                        (frame-parameter frame 'stickies-minibuffer-frame))))
      (set-frame-parameter frame 'stickies-roll-peek nil)
      (stickies--roll-up frame))))

(add-hook 'window-selection-change-functions #'stickies--unpeek-on-deselection)

(defun stickies--popup-menu (event)
  "Show the sticky note context menu at EVENT location."
  (interactive "e")
  (let* ((current (stickies--current-theme))
         (theme-items
          (mapcar (lambda (entry)
                    (let ((name (car entry)))
                      `[,(capitalize (symbol-name name))
                        (stickies--set-theme ',name)
                        :style radio
                        :selected ,(eq name current)]))
                  stickies-themes))
         (menu (easy-menu-create-menu
                "Sticky note"
                (append '(["New Note" stickies-new]
                          ["Rename..." stickies-rename]
                          ["Delete..." stickies-delete]
                          "--")
                        theme-items
                        '("--"
                          ["Always on top" stickies-toggle-always-on-top
                           :style toggle
                           :selected (stickies--always-on-top-p)]
                          ["Rolled up" stickies-toggle-roll-up
                           :style toggle
                           :selected (stickies--persistent-roll-state (selected-frame))]
                          "--"
                          ["Close note" delete-frame])))))
    ;; While the menu is open the command loop is in the middle of a key-sequence; after
    ;; `echo-keystrokes' seconds it echoes the in-progress keys. For a mouse-driven menu
    ;; that echo is effectively blank, but it still shows the minibuffer frame. Disabling
    ;; echo-keystrokes and rebinding show-help-function avoids this.
    (let ((echo-keystrokes 0)
          (show-help-function #'ignore))
      (popup-menu menu event))))

(defvar stickies-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-3] #'stickies--popup-menu)
    (define-key m [header-line mouse-3] #'stickies--popup-menu)
    ;; Notes are moved by stickies' own drag loop (see
    ;; `stickies-drag-frame'), not via the `drag-with-header-line' frame
    ;; parameter and `mouse-drag-frame-move'.
    (define-key m [header-line down-mouse-1] #'stickies-drag-frame)
    m)
  "Keymap for `stickies-mode'.")


;;;; Rolled-up note resizing guard

(defvar stickies-min-size '(15 . 3)
  "Minimum size (WIDTH . HEIGHT), in characters, of a sticky note frame.
Without this a note can be dragged down to an unusable sliver, as
undecorated frames don't get a minimum size enforced by the window
manager.  The floors are skipped while a note is rolled up, which has its
own fixed geometry.")

(defvar stickies--restoring-roll nil
  "Non-nil while `stickies--restore-rolled-geometry' rewrites a frame.
Suppresses the size-change and move handlers it re-triggers, so they
don't schedule another restore on top of the one in progress.")

(defvar stickies--roll-resizing nil
  "Frame currently being resized while rolled up, else nil.
Lets `stickies--constrain-size-on-resize' recognise the first event of a
drag -- when it snapshots the note's resting position -- and tell it from
the events that follow.")

(defvar stickies--roll-resizing-timer nil
  "Idle timer that clears `stickies--roll-resizing' after a drag settles.")

(defun stickies--note-roll-resize (frame)
  "Mark FRAME as mid-resize, clearing the mark shortly after motion stops."
  (setq stickies--roll-resizing frame)
  (when (timerp stickies--roll-resizing-timer)
    (cancel-timer stickies--roll-resizing-timer))
  (setq stickies--roll-resizing-timer
        (run-with-idle-timer 0.15 nil
                             (lambda () (setq stickies--roll-resizing nil)))))

(defun stickies--rolled-geometry-disturbed-p (frame)
  "Return non-nil if rolled-up FRAME's size no longer matches the rolled one.
Compares text width against `stickies-roll-width' and text height against
`stickies-roll-height'.  Position is ignored: only the size is held fixed,
the note is free to be moved."
  (when-let ((w (frame-parameter frame 'stickies-roll-width)))
    (not (and (equal (frame-text-width frame) w)
              (equal (frame-text-height frame)
                     (frame-parameter frame 'stickies-roll-height))))))

(defun stickies--restore-rolled-geometry (frame)
  "Re-impose rolled-up FRAME's fixed size and its current drag anchor.
A rolled-up note is a fixed-size \"titlebar\".  The NS port hardcodes
undecorated frames as resizable (`NSWindowStyleMaskResizable' in nsterm.m,
with no Lisp parameter to disable it), so the corner is always an OS
resize handle and we can't stop the drag; we slam the rolled size back on
every resize event, pinning the size for the duration of the drag.

On the NS port, the position must be re-imposed each event too: relying
on `set-frame-width'/`-height' to keep the top-left lets the frame drift
against AppKit's live resize until it flies off-screen. We pin it to
`stickies-roll-anchor' -- a snapshot of where the note sat when *this*
drag began (taken in `stickies--constrain-size-on-resize'). Because that
anchor is read fresh per drag, never a long-lived stored position, it
stops the drift without ever snapping the note back to a stale spot."
  (when (and (frame-live-p frame) (stickies--rolled-up-p frame))
    (when-let ((w (frame-parameter frame 'stickies-roll-width)))
      (let ((stickies--restoring-roll t)
            (window-min-height 0)
            (window-safe-min-height 0)
            (frame-resize-pixelwise t)
            (anchor (and (eq (window-system frame) 'ns)
                         (frame-parameter frame 'stickies-roll-anchor))))
        (set-frame-width frame w nil t)
        (set-frame-height frame (1+ (frame-char-height frame)) nil t)
        (when anchor
          (set-frame-position frame (car anchor) (cdr anchor)))))))

(defun stickies--constrain-size-on-resize (frame)
  "Hold sticky note FRAME within its size constraints after a resize.
While rolled up the note is a fixed-size titlebar: a resize is undone by
re-imposing the rolled size and the drag anchor
\(`stickies--restore-rolled-geometry'), so it stays put throughout a corner
drag.  On the first event of a drag -- when no resize is yet in progress --
the note's current top-left is snapshot into `stickies-roll-anchor', and
the note is pinned there for the rest of the drag.  Reading the live
position fresh each drag means a note moved beforehand keeps where the
user left it, with no stale stored position to teleport back to.

When expanded, width and height are floored at `stickies-min-size'.
Either way, setting the size/position re-enters this hook, but the result
then satisfies the guard so the recursion stops (and the rolled-up restore
additionally binds `stickies--restoring-roll').

Skipped until the frame is fully built (`stickies-ready'): resizing a
frame mid-realization repaints the NS body with the system appearance,
losing the theme background."
  (when (and (frame-parameter frame 'stickies-note)
             (frame-parameter frame 'stickies-ready)
             (not stickies--restoring-roll))
    (if (stickies--rolled-up-p frame)
        (when (stickies--rolled-geometry-disturbed-p frame)
          (unless (eq stickies--roll-resizing frame)
            ;; Drag just started: remember where the note currently sits.
            (pcase-let ((`(,l ,tp ,_ ,_) (frame-edges frame 'outer-edges)))
              (set-frame-parameter frame 'stickies-roll-anchor (cons l tp))))
          (stickies--note-roll-resize frame)
          (stickies--restore-rolled-geometry frame))
      (when (< (frame-width frame) (car stickies-min-size))
        (set-frame-width frame (car stickies-min-size)))
      (when (< (frame-height frame) (cdr stickies-min-size))
        (set-frame-height frame (cdr stickies-min-size))))))

(add-hook 'window-size-change-functions #'stickies--constrain-size-on-resize)

(defvar stickies-drag-snap-distance 8
  "Pixel radius within which a dragged note clings to another note's edge.
Set to 0 to disable snapping.")

(defun stickies--drag-snap (left top width height edges)
  "Magnetize a dragged note's position toward other notes' edges.
LEFT/TOP is the position the pointer asks for, WIDTH/HEIGHT the dragged
note's outer size, EDGES a list of (LEFT TOP RIGHT BOTTOM) outer edges of
the other note frames.  Returns the possibly adjusted (LEFT . TOP).

Because the drag loop recomputes LEFT/TOP from the absolute pointer
delta on every motion event, clamping here automatically yields
resistance on detach: the unclamped position must leave the snap radius
before a different position is applied.

A neighbor the dragged note overlaps is skipped entirely: notes
stacked (exactly or partly) on top of each other would otherwise cling
to the buried note's edges while being dragged apart.  Exact adjacency
-- the snapped state itself -- has zero intersection and doesn't count
as overlap."
  (let ((d stickies-drag-snap-distance)
        (right (+ left width)) (bottom (+ top height))
        (best-dx nil) (best-dy nil))
    (pcase-dolist (`(,l ,tp ,r ,b) edges)
      (unless (and (< left r) (> right l) (< top b) (> bottom tp))
        (let ((near-y (and (<= top (+ b d)) (>= bottom (- tp d))))
              (near-x (and (<= left (+ r d)) (>= right (- l d)))))
          (when near-y
            (dolist (dx (list (- l right)      ; our right to its left
                              (- r left)       ; our left to its right
                              (- l left)       ; left edges align
                              (- r right)))    ; right edges align
              (when (and (<= (abs dx) d)
                         (or (null best-dx) (< (abs dx) (abs best-dx))))
                (setq best-dx dx))))
          (when near-x
            (dolist (dy (list (- tp bottom)    ; our bottom to its top
                              (- b top)        ; our top to its bottom
                              (- tp top)       ; top edges align
                              (- b bottom)))   ; bottom edges align
              (when (and (<= (abs dy) d)
                         (or (null best-dy) (< (abs dy) (abs best-dy))))
                (setq best-dy dy)))))))
    (cons (+ left (or best-dx 0)) (+ top (or best-dy 0)))))

(defvar stickies--ns-screen-local-mouse 'unknown
  "Whether `mouse-absolute-pixel-position' is monitor-local on this Emacs.
See emacs bug#71912 for the report.

The NS port's `ns-mouse-absolute-pixel-position' (nsfns.m) subtracts
the origin of the screen showing the selected frame's window, so on a
multi-monitor display it returns coordinates local to that monitor,
while frame positions are global (relative to the primary monitor's
top-left corner).")

(defun stickies--ns-selected-monitor-origin ()
  "Global origin (X . Y) of the monitor `mouse-absolute-pixel-position' uses.
That is the monitor showing the selected frame's window: the NS code
behind both the mouse position and the `frames' membership in
`display-monitor-attributes-list' asks for the same \"screen of the
frame's window\", so this lookup tracks the mouse function's reference
point exactly, including the moment a dragged window's screen
assignment flips mid-drag.  Returns nil if the frame is on no monitor
\(window off-screen)."
  (let ((sf (selected-frame)))
    (catch 'hit
      (dolist (mon (display-monitor-attributes-list))
        (when (memq sf (cdr (assq 'frames mon)))
          (let ((geom (cdr (assq 'geometry mon))))
            (throw 'hit (cons (nth 0 geom) (nth 1 geom))))))
      nil)))

(defun stickies--ns-screen-local-mouse-p (raw origin)
  "Measure whether RAW from `mouse-absolute-pixel-position' is monitor-local.
ORIGIN is the global origin of the selected frame's monitor; the caller
only asks when it is non-zero, otherwise local and global coincide and
there is nothing to measure. The ground truth comes from
`mouse-pixel-position', which converts through the frame's own window
and is therefore unaffected by the bug: its frame-relative offset plus
the frame's global edges is the true global mouse position. Whichever
reading of RAW lands closer is the answer; monitor origins are hundreds
of pixels while the slop in the estimate (frame-position cache
staleness, native vs. inner edges) is tens, so the comparison cannot tip
the wrong way. Returns t (bug present), nil (fixed), or `assume' when
the mouse is not over a top-level frame and nothing can be
measured (then treat the bug as present -- true for every NS Emacs to
date -- but don't cache it)."
  (let* ((rel (mouse-pixel-position))
         (mframe (car rel)))
    (if (not (and (framep mframe)
                  (frame-live-p mframe)
                  (not (frame-parent mframe))
                  (integerp (cadr rel))
                  (integerp (cddr rel))))
        'assume
      (let* ((edges (frame-edges mframe 'native-edges))
             (truth-x (+ (nth 0 edges) (cadr rel)))
             (truth-y (+ (nth 1 edges) (cddr rel)))
             (raw-err (+ (abs (- (car raw) truth-x))
                         (abs (- (cdr raw) truth-y))))
             (fixed-err (+ (abs (- (+ (car raw) (car origin)) truth-x))
                           (abs (- (+ (cdr raw) (cdr origin)) truth-y)))))
        (< fixed-err raw-err)))))

(defun stickies--mouse-absolute-pixel-position ()
  "Like `mouse-absolute-pixel-position', but globally correct on NS.
On the NS port the raw value is local to the monitor showing the
selected frame's window (see `stickies--ns-screen-local-mouse').  A
dragged note is normally the selected frame, so when it crosses onto
another monitor the window's screen assignment flips and the raw
position jumps by the monitor offset; the drag loop would compute a
position back on the old monitor, the screen would flip back, and the
note would flicker between the two monitors.  Adding the monitor's
global origin restores true global coordinates; on the primary
monitor the origin is (0 . 0) and the correction is the identity,
which is exactly when the raw value is already right."
  (let ((raw (mouse-absolute-pixel-position)))
    (if (not (eq (window-system) 'ns))
        raw
      (let ((origin (stickies--ns-selected-monitor-origin)))
        (if (or (null origin)
                (and (zerop (car origin)) (zerop (cdr origin))))
            raw
          (let ((verdict stickies--ns-screen-local-mouse))
            (when (eq verdict 'unknown)
              (setq verdict (stickies--ns-screen-local-mouse-p raw origin))
              (unless (eq verdict 'assume)
                (setq stickies--ns-screen-local-mouse verdict)))
            (if verdict
                (cons (+ (car raw) (car origin))
                      (+ (cdr raw) (cdr origin)))
              raw)))))))

(defun stickies--drag-note-frame (frame)
  "Move note FRAME with the mouse until the dragging button is released.
This is essentially a reimplementation of `mouse-drag-frame-move', with
some additional bug fixes and edge snapping.

Returns the non-motion event that ended the tracking."
  ;; On NS, first correct the frame's cached origin from the mouse: an OS
  ;; resize moves the window origin without firing `windowDidMove', so
  ;; Emacs's cached `frame-position' goes stale (there is no
  ;; `windowDidResize' handler updating it), and the drag would seed from
  ;; that cache -- the first motion would snap the note back by the resize
  ;; amount.  The true origin is recoverable without the cache: the screen
  ;; mouse position (`stickies--mouse-absolute-pixel-position') minus the
  ;; frame-relative mouse position (`mouse-pixel-position') is the frame's
  ;; real screen origin.  Setting it doesn't move the window (it is already
  ;; there), it just refreshes the cache.
  (when (eq (window-system frame) 'ns)
    (let ((screen (stickies--mouse-absolute-pixel-position))
          (rel (mouse-pixel-position)))
      (when (and (integerp (cadr rel)) (integerp (cddr rel)))
        (let ((left (- (car screen) (cadr rel)))
              (top  (- (cdr screen) (cddr rel)))
              (pos  (frame-position frame)))
          ;; only set if it's off by more than 2px
          (when (or (> (abs (- left (car pos))) 2)
                    (> (abs (- top (cdr pos))) 2))
            (set-frame-position frame left top))))))
  (run-hooks 'mouse-leave-buffer-hook)
  (let* ((first-pos (frame-position frame))
         (first-xy (stickies--mouse-absolute-pixel-position))
         (outer (frame-edges frame 'outer-edges))
         (width (- (nth 2 outer) (nth 0 outer)))
         (height (- (nth 3 outer) (nth 1 outer)))
         ;; Snap targets, snapshot once: the other notes cannot move
         ;; while this loop has the mouse.
         (snap-edges (and (> stickies-drag-snap-distance 0)
                          (mapcan (lambda (f)
                                    (and (not (eq f frame))
                                         (frame-visible-p f)
                                         (list (frame-edges f 'outer-edges))))
                                  (stickies--frames))))
         (echo-keystrokes 0)
         (frame-resize-pixelwise t)
         (track-mouse 'dragging)
         ;; Without this, motion events are only generated when the
         ;; pointer moves to a different glyph -- but the frame follows
         ;; the pointer, so its frame-relative position barely changes
         ;; and the loop starves after the first event.
         (mouse-fine-grained-tracking t)
         event)
    (while (progn
             (setq event (read-event))
             (memq (car-safe event)
                   '(mouse-movement switch-frame select-window
                     scroll-bar-movement)))
      (when (eq (car-safe event) 'mouse-movement)
        (let* ((xy (stickies--mouse-absolute-pixel-position))
               (left (+ (car first-pos) (- (car xy) (car first-xy))))
               (top (+ (cdr first-pos) (- (cdr xy) (cdr first-xy))))
               (pos (if snap-edges
                        (stickies--drag-snap left top width height snap-edges)
                      (cons left top))))
          ;; The `(+ ...)' form keeps negative coordinates meaning
          ;; "off-screen to the left/top", as `mouse-drag-frame-move' does.
          (modify-frame-parameters
           frame
           `((left . (+ ,(car pos))) (top . (+ ,(cdr pos))))))))
    event))

(defun stickies--drag-release-p (event)
  "Non-nil if EVENT is the button release concluding a real drag."
  (and (eq (event-basic-type event) 'mouse-1)
       (memq 'drag (event-modifiers event))))

(defun stickies-drag-frame (event)
  "Drag the sticky note under EVENT, following the mouse.
Bound to `down-mouse-1' on the note's header line in `stickies-mode-map'.
The release concluding a real drag is swallowed (replaying it would
select another window); a plain click is re-dispatched, so the
header-line buttons keep working."
  (interactive "e")
  (let* ((window (posn-window (event-start event)))
         (frame (cond ((windowp window) (window-frame window))
                      ((framep window) window))))
    (if (not (and frame (frame-parameter frame 'stickies-note)))
        ;; A note buffer shown in a non-note frame: stock behavior.
        (mouse-drag-header-line event)
      (let ((end (stickies--drag-note-frame frame)))
        (unless (stickies--drag-release-p end)
          (push end unread-command-events))))))


;;;; Auto-save

(defvar stickies-mode)             ; defined below via `define-minor-mode'

(defvar stickies--auto-save-timer nil
  "Idle timer that saves modified sticky note buffers.")

(defun stickies--auto-save-tick ()
  "Save modified sticky note buffers and stale frame geometries.
Runs on the same idle timer so position/size changes (which have
no dedicated hook) get persisted within one tick interval without
writing the index on every pixel of drag."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and stickies-mode
                 buffer-file-name
                 (buffer-modified-p))
        (let ((save-silently t))
          (save-buffer)))))
  (stickies--save-stale-frame-state))

(defun stickies--save-stale-frame-state ()
  "Persist geometry of any sticky note frame whose state changed since last save.
Writes the index file at most once even when several frames are dirty."
  (let (dirty)
    (dolist (frame (stickies--frames))
      (let ((basename (frame-parameter frame 'stickies-note)))
        (when basename
          (let ((cell (stickies--entry basename)))
            (when cell
              (let ((cur-params (stickies--frame-geometry frame))
                    (cur-roll   (stickies--persistent-roll-state frame))
                    (cur-scale  (with-current-buffer (stickies--frame-buffer frame)
                                  (if (boundp 'text-scale-mode-amount)
                                      text-scale-mode-amount
                                    0)))
                    (saved-params (alist-get :params (cdr cell)))
                    (saved-roll   (alist-get :rolled-up (cdr cell)))
                    (saved-scale  (or (alist-get :text-scale (cdr cell)) 0)))
                (unless (equal cur-params saved-params)
                  (setf (alist-get :params (cdr cell)) cur-params)
                  (setq dirty t))
                (unless (eq cur-roll saved-roll)
                  (setf (alist-get :rolled-up (cdr cell)) cur-roll)
                  (setq dirty t))
                (unless (eql cur-scale saved-scale)
                  (setf (alist-get :text-scale (cdr cell)) cur-scale)
                  (setq dirty t))))))))
    (when dirty
      (stickies--save-index))))

(defun stickies--ensure-auto-save-timer ()
  "Start the auto-save idle timer if it isn't already running."
  (when (and (numberp stickies-auto-save-interval)
             (not (memq stickies--auto-save-timer timer-idle-list)))
    (setq stickies--auto-save-timer
          (run-with-idle-timer stickies-auto-save-interval t
                               #'stickies--auto-save-tick))))

(defun stickies--save-all-frame-state ()
  "Persist geometry of every visible sticky note frame."
  (dolist (frame (stickies--frames))
    (stickies--save-frame-state frame)))

(add-hook 'kill-emacs-hook #'stickies--save-all-frame-state)


;;;; Text scale

(defun stickies--apply-text-scale ()
  "Apply the current sticky note buffer's stored text-scale, if any.
The amount is read from the buffer's index entry (see
`stickies--save-stale-frame-state', which persists it)."
  (when-let* ((basename (and buffer-file-name
                             (stickies--note-basename buffer-file-name)))
              (amount (alist-get :text-scale (cdr (stickies--entry basename)))))
    (text-scale-set amount)))


;;;; Minor mode

;;;###autoload
(define-minor-mode stickies-mode
  "Minor mode for buffers that are sticky notes.
Applies the buffer's theme colors via a `default' face remap,
hides the mode line, installs a header line with a close button,
binds `mouse-3' to a context menu for changing themes, and closes
the corresponding sticky note frame when the buffer is killed."
  :lighter " Stk"
  :keymap stickies-mode-map
  (if stickies-mode
      (progn
        (setq-local mode-line-format nil)
        (setq-local header-line-format '(:eval (stickies--header-line)))
        ;; Hide the cursor in idle (unfocused) note frames; it reappears
        ;; in whichever note currently has focus.
        (setq-local cursor-in-non-selected-windows nil)
        (setq-local truncate-lines nil)
        ;; Since stickies frames are always dedicated to their buffer,
        ;; ensure that switching to another non-note buffer will work.
        (setq-local switch-to-buffer-in-dedicated-window 'pop)
        (stickies--apply-colors)
        (stickies--apply-text-scale)
        (stickies--ensure-auto-save-timer)
        (add-hook 'kill-buffer-hook #'stickies--on-buffer-killed nil t))
    (kill-local-variable 'mode-line-format)
    (kill-local-variable 'header-line-format)
    (kill-local-variable 'cursor-in-non-selected-windows)
    (kill-local-variable 'truncate-lines)
    (kill-local-variable 'switch-to-buffer-in-dedicated-window)
    (stickies--exit-rolled-up)
    (remove-hook 'kill-buffer-hook #'stickies--on-buffer-killed t)))


;;;; Frame management

(defun stickies--frames (&optional basename)
  "Return sticky note frames, optionally filtered to BASENAME."
  (cl-loop for f in (frame-list)
           for b = (frame-parameter f 'stickies-note)
           when (and b (or (null basename) (string= b basename)))
           collect f))

(defun stickies--frame-geometry (frame)
  "Return an alist of frame parameters describing FRAME's persistent state.
Captures geometry plus toggles like `z-group'.
If FRAME is currently rolled up, save the pre-rolled (expanded)
height so a restored frame doesn't come back as a tiny strip.
`left'/`top' are clamped to non-negative: a negative position (a note
dragged off the top/left edge) is read by `make-frame' as an offset from
the opposite edge, flinging the note off-screen on restore.
Parameters that are nil are dropped: persisting e.g. a nil `left'/`top'
(as can happen for a not-yet-positioned frame) would feed nil back to
`make-frame', which errors on some ports (NS: \"integerp, nil\")."
  (seq-filter
   #'cdr
   `((width   . ,(frame-parameter frame 'width))
     (height  . ,(or (stickies--rolled-up-p frame)
                     (frame-parameter frame 'height)))
     (left    . ,(let ((l (frame-parameter frame 'left)))
                   (and (integerp l) (max 0 l))))
     (top     . ,(let ((tp (frame-parameter frame 'top)))
                   (and (integerp tp) (max 0 tp))))
     (z-group . ,(frame-parameter frame 'z-group)))))

(defun stickies--monitor-workareas (frame)
  "Return the work areas (X Y W H) of every monitor on FRAME's display."
  (delq nil (mapcar (lambda (m) (cdr (assq 'workarea m)))
                    (display-monitor-attributes-list frame))))

(defun stickies--rect-overlap (l top r b area)
  "Return the overlap area of rectangle L TOP R B with monitor AREA.
AREA is a work area of the form (X Y W H)."
  (pcase-let ((`(,x ,y ,w ,h) area))
    (* (max 0 (- (min r (+ x w)) (max l x)))
       (max 0 (- (min b (+ y h)) (max top y))))))

(defun stickies--clamp-frame-onscreen (frame)
  "Move FRAME so it lies within a currently visible monitor work area.
Saved geometry can point at a monitor that is no longer attached;
without this a restored sticky note comes back off-screen and
unreachable.  Clamp to the monitor FRAME most overlaps, or the
first (primary) one when it overlaps none."
  (when (and (frame-live-p frame) (display-graphic-p frame))
    (pcase-let* ((`(,fl ,ft ,fr ,fb) (frame-edges frame 'outer-edges))
                 (fw (- fr fl))
                 (fh (- fb ft))
                 (areas (stickies--monitor-workareas frame)))
      (when areas
        (let ((best (car areas))
              (best-ov (stickies--rect-overlap fl ft fr fb (car areas))))
          (dolist (a (cdr areas))
            (let ((ov (stickies--rect-overlap fl ft fr fb a)))
              (when (> ov best-ov) (setq best a best-ov ov))))
          (pcase-let* ((`(,x ,y ,w ,h) best)
                       ;; Clamp so the whole frame stays inside the work
                       ;; area; pin to the corner if it is larger than the
                       ;; monitor.
                       (left (max x (min (- (+ x w) fw) fl)))
                       (top  (max y (min (- (+ y h) fh) ft))))
            (unless (and (= left fl) (= top ft))
              (let ((frame-resize-pixelwise t))
                (set-frame-position frame left top)))))))))

(defun stickies--attach-position (frame)
  "Choose where note FRAME, which has no saved position, should appear.
Returns (LEFT . TOP) in global pixels.

The anchor is the most recently used note (`stickies--mru-note-frame'
-- the note just created before FRAME, when notes are created in a
row, since `stickies-new' focuses the fresh note).  Tried in order:
flush below
the anchor with left edges aligned, flush above, flush to its left
with top edges aligned, flush to its right -- the first position fully
inside the anchor's monitor work area and overlapping no other note
wins.  Consecutive new notes thus tile a column downward, then wind
up and down through the next columns.

When no side qualifies, the work area is scanned on a fixed 32px grid:
the free spot closest to the anchor wins.  With no free spot left --
the screen is full -- the spot covering the least area of other notes
wins, ties resolved top-to-bottom, left-to-right, so a stream of new
notes beyond the screen's capacity layers over it in the same
predictable pattern instead of piling up in one place.

With no anchor at all (very first note), the work area's top-left
corner."
  (pcase-let* ((anchor (stickies--mru-note-frame frame))
               (`(,wx ,wy ,ww ,wh) (frame-monitor-workarea anchor)))
    (if (not anchor)
        (cons wx wy)
      (pcase-let* ((`(,al ,at ,ar ,ab) (frame-edges anchor 'outer-edges))
                   ;; FRAME is not mapped yet; its `frame-edges' are
                   ;; meaningless, but its text size is already exact.
                   ;; The outer size is that text size plus the
                   ;; outer-vs-text overhead (borders, fringes), which
                   ;; is read off the anchor -- a mapped frame with the
                   ;; same parameters.
                   (w (+ (frame-text-width frame)
                         (- (- ar al) (frame-text-width anchor))))
                   (h (+ (frame-text-height frame)
                         (- (- ab at) (frame-text-height anchor))))
                   (rects (cl-loop for f in (stickies--frames)
                                   when (and (not (eq f frame))
                                             (frame-visible-p f))
                                   collect
                                   (pcase-let ((`(,l ,tp ,r ,b)
                                                (frame-edges f 'outer-edges)))
                                     (list l tp (- r l) (- b tp)))))
                   (covered (lambda (x y)
                              (cl-loop for r in rects
                                       sum (stickies--rect-overlap
                                            x y (+ x w) (+ y h) r))))
                   (inside (lambda (x y)
                             (= (stickies--rect-overlap
                                 x y (+ x w) (+ y h) (list wx wy ww wh))
                                (* w h)))))
        (or
         (cl-loop for (x . y) in (list (cons al ab)        ; below
                                       (cons al (- at h))  ; above
                                       (cons (- al w) at)  ; left
                                       (cons ar at))       ; right
                  when (and (funcall inside x y)
                            (zerop (funcall covered x y)))
                  return (cons x y))
         (let (free free-d any any-cov)
           (cl-loop
            for y from wy to (- (+ wy wh) h) by 32 do
            (cl-loop
             for x from wx to (- (+ wx ww) w) by 32 do
             (let ((cov (funcall covered x y)))
               (if (zerop cov)
                   (let ((d (+ (abs (- x al)) (abs (- y at)))))
                     (when (or (null free) (< d free-d))
                       (setq free (cons x y) free-d d)))
                 (when (or (null any) (< cov any-cov))
                   (setq any (cons x y) any-cov cov))))))
           (or free any))
         (cons wx wy))))))

;; Only bound on the NS port; declared so the `let' binding in
;; `stickies--make-frame' is dynamic and the byte-compiler stays quiet.
(defvar ns-use-native-fullscreen)

(defvar stickies--frame-parameters
  '((width . 40)
    (height . 12)
    ;; A note always opens at the size above, never fullscreen/maximized --
    ;; pin these explicitly so a `fullscreen' or size entry in the user's
    ;; `default-frame-alist' cannot leak into a note frame.
    (fullscreen . nil)
    (undecorated . t)
    (skip-taskbar . t)
    (drag-internal-border . t)
    (unsplittable . t)
    (vertical-scroll-bars . nil)
    (internal-border-width . 2)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (tab-bar-lines . 0))
  "Default frame parameters for sticky note frames.
A `(stickies-note . BASENAME)' marker and a `minibuffer' pointing at the
note's minibuffer child frame are added automatically (see
`stickies--make-frame').  Saved per-note geometry overrides these.")

(defun stickies--make-frame (basename)
  "Create and return a frame displaying the sticky note BASENAME."
  ;; On the NS port a top-level frame gets the FullScreenPrimary collection
  ;; behavior, so creating one while another frame occupies a native
  ;; fullscreen Space makes macOS pull the new note into that Space and turn
  ;; it fullscreen too.  Binding this to nil for the extent of `make-frame'
  ;; drops that behavior (the value is only read while the window is built),
  ;; keeping the note a normal-space window.
  (let ((ns-use-native-fullscreen nil)
        (frame-resize-pixelwise t)
        ;; A note restored rolled up is created one text row tall (see
        ;; below); without these the window minima silently bump the
        ;; new frame to `window-min-height' rows.
        (window-min-height 0)
        (window-safe-min-height 0))
    (let* ((path (stickies--note-path basename))
           (entry (stickies--register basename))
           (saved-params (seq-filter #'cdr (alist-get :params (cdr entry))))
           (rolled-up (alist-get :rolled-up (cdr entry)))
           ;; The note's minibuffer child frame -- created first so the note
           ;; can point its `minibuffer' parameter at its window.
           (mini-frame (stickies--make-minibuffer-frame))
           ;; Order: required markers first (earlier entries win), then
           ;; per-note geometry, then user defaults.
           (params (append `((stickies-note . ,basename)
                             (name . ,(format "Sticky note: %s" basename))
                             (minibuffer . ,(minibuffer-window mini-frame))
                             (visibility . nil)
                             ,@(when rolled-up
                                 `((height . (text-pixels
                                              . ,(1+ (frame-char-height mini-frame)))))))
                           saved-params
                           stickies--frame-parameters))
           (buffer (find-file-noselect path))
           (frame  (make-frame params))
           (window (frame-root-window frame)))
      (set-window-buffer window buffer)
      (set-window-dedicated-p window t)
      ;; Cross-link the note and its minibuffer frame, and make the latter a
      ;; child of the note.
      (set-frame-parameter frame 'stickies-minibuffer-frame mini-frame)
      (set-frame-parameter mini-frame 'stickies-minibuffer frame)
      (set-frame-parameter mini-frame 'parent-frame frame)
      (stickies--apply-frame-colors frame)
      ;; Position (and scale the font of) the minibuffer frame while the note
      ;; is still hidden, so it is fully configured before its first render.
      (stickies--position-minibuffer-frame mini-frame frame)
      ;; A note without a saved position -- typically brand new -- is
      ;; not left to the window manager's arbitrary placement: it opens
      ;; attached to the most recently used note (see
      ;; `stickies--attach-position').
      (unless (assq 'left saved-params)
        (let ((pos (stickies--attach-position frame)))
          (set-frame-position frame (car pos) (cdr pos))))
      ;; Restored geometry may point at a now-detached monitor; pull the
      ;; frame back onto a visible screen so it stays reachable.
      (stickies--clamp-frame-onscreen frame)
      (when rolled-up
        ;; Add rolled-up state state.
        (set-frame-parameter frame 'drag-internal-border nil)
        (set-frame-parameter frame 'stickies-roll-saved-height
                             (or (alist-get 'height saved-params)
                                 (alist-get 'height stickies--frame-parameters)))
        (set-frame-parameter frame 'stickies-roll-height
                             (1+ (frame-char-height frame)))
        (set-frame-parameter frame 'stickies-roll-width
                             (frame-text-width frame))
        (with-current-buffer buffer
          (stickies--enter-rolled-up)))
      ;; Reveal the fully-configured note.
      (make-frame-visible frame)
      ;; Force the minibuffer frame invisible, it gets mapped sometimes.
      (make-frame-invisible mini-frame t)
      ;; Mark the frame fully built so size-change handlers may act on it
      ;; (see `stickies--constrain-size-on-resize').
      (set-frame-parameter frame 'stickies-ready t)
      frame)))

(defun stickies--save-frame-state (frame)
  "Persist FRAME's geometry and rolled-up state into the index."
  (let ((basename (frame-parameter frame 'stickies-note)))
    (when basename
      (let ((cell (stickies--register basename)))
        (setf (alist-get :params (cdr cell))
              (stickies--frame-geometry frame))
        (setf (alist-get :rolled-up (cdr cell))
              (stickies--persistent-roll-state frame))
        (stickies--save-index)))))

(defun stickies--on-frame-deleted (frame)
  "Persist geometry and delete the minibuffer child frame for note FRAME."
  (when (frame-parameter frame 'stickies-note)
    (stickies--save-frame-state frame)
    ;; Delete the minibuffer frame after the note is gone: it is the note's
    ;; minibuffer, so it can't be deleted while the note lives.
    (let ((mini (frame-parameter frame 'stickies-minibuffer-frame)))
      (when (and (frame-live-p mini) (not (eq mini frame)))
        (run-with-timer 0 nil
                        (lambda ()
                          (when (frame-live-p mini)
                            (ignore-errors (delete-frame mini t)))))))))

(add-hook 'delete-frame-functions #'stickies--on-frame-deleted)

;; Each sticky note has its own minibuffer-only child frame, parented to
;; it and set as its `minibuffer'.  It is hidden when idle and shown over
;; the note's content during a read or isearch, so reads, completion and
;; isearch all happen there natively while the note shows nothing when
;; idle.

(defvar minibuffer-prompt-properties)

(defvar stickies--minibuffer-frame-parameters
  '((minibuffer . only)
    (name . "stickies-minibuffer")
    (undecorated . t)
    (minibuffer-exit . t)               ; hide it when the minibuffer exits
    (left-fringe . 0)
    (right-fringe . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (child-frame-border-width . 1)
    (internal-border-width . 0)
    (desktop-dont-save . t)
    (no-other-frame . t)
    ;; Don't take focus when mapped: it would steal it from the note and
    ;; (for isearch, whose keys are read in the note) end isearch at once.
    (no-focus-on-map . t)
    ;; Follow the note's width/left when it is resized (not its height).
    (keep-ratio width-only . left-only)
    (visibility . nil))
  "Frame parameters for a note's minibuffer child frame.
No `z-group': it already stacks above its parent, and `z-group above'
makes it a free-floating draggable panel on macOS.")

(defun stickies--make-minibuffer-frame ()
  "Create and return a hidden minibuffer-only child frame for a note."
  (let ((after-make-frame-functions nil))
    (make-frame stickies--minibuffer-frame-parameters)))

(defun stickies--minibuffer-frame-of (frame)
  "Return the live minibuffer child frame for sticky note FRAME, or nil."
  (let ((mini (frame-parameter frame 'stickies-minibuffer-frame)))
    (and (frame-live-p mini) mini)))

(defun stickies--minibuffer-error-function (data context caller)
  "Display a command error DATA in a note's minibuffer.
Like `minibuffer-error-function' but without its `discard-input', which
busy-loops Emacs at 100% CPU in a minibuffer-only child frame (e.g. when
moving past the start of history).  CONTEXT and CALLER are as for
`command-error-default-function'."
  (if (memq 'minibuffer-quit (get (car data) 'error-conditions))
      (ding t)
    (ding))
  (let ((string (error-message-string data)))
    (let ((inhibit-message t))
      (message "%s%s" (if caller (format "%s: " caller) "") string))
    (minibuffer-message (apply #'propertize (format " [%s%s]" context string)
                               minibuffer-prompt-properties))))

(defun stickies--scale-minibuffer-font (mini)
  "Scale MINI's font to `stickies-header-text-height' of its note's font.
So the prompt, completion, isearch echo and messages match the note's
header line, with a matching line height for an exact line count."
  (when stickies-header-text-height
    (let* ((note (frame-parameter mini 'stickies-minibuffer))
           (h (and (frame-live-p note) (face-attribute 'default :height note)))
           (target (and (integerp h) (round (* stickies-header-text-height h)))))
      (when (and target (not (eql target (face-attribute 'default :height mini))))
        (set-face-attribute 'default mini :height target)))))

(defun stickies--position-minibuffer-frame (mini note)
  "Position and theme MINI over NOTE's content area (without showing it).
This runs on every echo display."
  (when (and (frame-live-p mini) (frame-live-p note))
    (pcase-let* ((`(,bg ,fg ,border)
                  (with-current-buffer (stickies--frame-buffer note)
                    (let ((c (stickies--theme-colors)))
                      (list (car c) (cdr c) (stickies--theme-border)))))
                 (fringes (window-fringes (frame-root-window note)))
                 (left-fringe (or (nth 0 fringes) 0))
                 (right-fringe (or (nth 1 fringes) 0))
                 (native (frame-edges note 'native-edges))
                 (inner (frame-edges note 'inner-edges)))
      (stickies--scale-minibuffer-font mini)
      ;; Anchor to the note's content corner, matching its fringes, with a
      ;; faint 1px border.  Child-frame LEFT/TOP are relative to NOTE's
      ;; native origin; the text width drops the fringes and border so the
      ;; frame's outer edges meet the note's content edges (pixelwise, so
      ;; the width isn't rounded to whole columns).
      (modify-frame-parameters
       mini
       `((frame-resize-pixelwise . t)
         (left . ,(- (nth 0 inner) (nth 0 native)))
         (top . ,(- (nth 1 inner) (nth 1 native)))
         (width text-pixels . ,(- (nth 2 inner) (nth 0 inner) left-fringe right-fringe 2))
         (height . 1)
         (child-frame-border-width . 1)
         (internal-border-width . 0)
         (left-fringe . ,left-fringe)
         (right-fringe . ,right-fringe)
         (background-color . ,bg)
         (foreground-color . ,fg)))
      (set-face-attribute 'fringe mini :background bg)
      (when (facep 'child-frame-border)
        (set-face-attribute 'child-frame-border mini :background border)))))

(defun stickies--show-minibuffer-frame (mini note &optional no-focus)
  "Position MINI over NOTE's content area, theme it, and show it.
With NO-FOCUS non-nil leave input focus on NOTE (for isearch, whose keys
are read in the note rather than the minibuffer)."
  (when (and (frame-live-p mini) (frame-live-p note))
    (stickies--position-minibuffer-frame mini note)
    (make-frame-visible mini)
    (unless no-focus
      (select-frame-set-input-focus mini))))

(defun stickies--minibuffer-setup ()
  "Show a note's minibuffer frame over it during a minibuffer read.
On `minibuffer-setup-hook'.  A rolled-up note has no room, so peek it
open for the duration of the read (`stickies--peek-down' with reason
`minibuffer'); `stickies--minibuffer-exit' rolls it back up.  A note
already peeked open for being selected keeps that wider-scoped peek
instead (see `stickies--peek-down')."
  (let* ((mini (window-frame (selected-window)))
         (note (frame-parameter mini 'stickies-minibuffer)))
    (when (frame-live-p note)
      (when (stickies--rolled-up-p note)
        (stickies--peek-down note 'minibuffer))
      ;; Error handler that doesn't `discard-input' (see above).
      (setq-local command-error-function #'stickies--minibuffer-error-function)
      (stickies--show-minibuffer-frame mini note))))

(defun stickies--minibuffer-exit ()
  "Roll a note back up if `stickies--minibuffer-setup' peeked it open.
On `minibuffer-exit-hook'.  Only releases a peek made for this read
\(reason `minibuffer'); a note peeked open for being selected stays
down until the note is deselected."
  (let* ((mini (window-frame (selected-window)))
         (note (frame-parameter mini 'stickies-minibuffer)))
    (when (and (frame-live-p note)
               (eq (frame-parameter note 'stickies-roll-peek) 'minibuffer))
      (set-frame-parameter note 'stickies-roll-peek nil)
      (stickies--roll-up note))))

(defun stickies--isearch-show ()
  "Show the note's minibuffer frame for isearch's echo.
On `isearch-mode-hook' (isearch uses the echo area, not a recursive
minibuffer, so `minibuffer-exit' doesn't cover it).  Keep focus on the
note so isearch reads its keys."
  (when-let ((mini (stickies--minibuffer-frame-of (selected-frame))))
    (stickies--show-minibuffer-frame mini (selected-frame) t)))

(defun stickies--note-in-isearch-p (mini)
  "Non-nil if MINI's note is currently in isearch."
  (let ((note (frame-parameter mini 'stickies-minibuffer)))
    (and (frame-live-p note)
         (buffer-local-value 'isearch-mode (stickies--frame-buffer note)))))

(defun stickies--hide-minibuffer-frames (&rest _)
  "Hide note minibuffer frames that have nothing to read.
Takes down a frame left up by a stray echo message (which `minibuffer-exit'
does not catch).  A no-op while any read is active -- gated on
`minibuffer-depth', which is stable mid-read (unlike
`active-minibuffer-window'), so it never hides a frame being read in --
and it leaves a frame alone while its note is in isearch."
  (when (zerop (minibuffer-depth))
    (dolist (f (frame-list))
      (when (and (frame-parameter f 'stickies-minibuffer)
                 (frame-visible-p f)
                 (not (stickies--note-in-isearch-p f)))
        (make-frame-invisible f)))))

(defvar stickies--saved-resize-mini-frames 'unset
  "Value of `resize-mini-frames' from before stickies took it over.")

(defun stickies--minibuffer-frame-target-height (frame)
  "Lines needed to show FRAME's minibuffer content.
Bounded by the note's height (so a completion list's current candidate
stays visible)."
  (let* ((win (frame-root-window frame))
         (char-h (frame-char-height frame))
         (pixel-h (cdr (window-text-pixel-size win nil nil nil nil)))
         (needed (max 1 (ceiling pixel-h char-h)))
         (parent (or (frame-parameter frame 'parent-frame) frame))
         (note-max (max 1 (1- (floor (frame-pixel-height parent) char-h)))))
    (min needed note-max)))

(defun stickies--resize-mini-frames (frame)
  "Resize a note minibuffer FRAME to fit its content; defer otherwise.
Installed as `resize-mini-frames'.  Grows for a completion list and
shrinks back for a short message, using a height computed directly from
the content rather than the function `fit-frame-to-buffer' (whose
wrapping interplay can spin redisplay on macOS).  Other minibuffer
frames keep whatever
`resize-mini-frames' did before."
  (if (frame-parameter frame 'stickies-minibuffer)
      (progn
        ;; Re-assert the scaled font first: it may have been reset since the
        ;; frame was last shown (see `stickies--scale-minibuffer-font'), and
        ;; the line count below divides by the resulting char height.
        (stickies--scale-minibuffer-font frame)
        (let ((target (stickies--minibuffer-frame-target-height frame)))
          ;; Only on a real change -- a no-op resize re-enters redisplay.
          (unless (= target (frame-height frame))
            (set-frame-height frame target))))
    (let ((prev stickies--saved-resize-mini-frames))
      (cond ((functionp prev) (funcall prev frame))
            ((and prev (not (eq prev 'unset))) (fit-frame-to-buffer frame))))))

(defvar stickies--in-set-message nil
  "Non-nil while inside `stickies--set-message-function', to avoid re-entry.")

(defun stickies--set-message-function (_message)
  "Position a note's minibuffer frame before an echo message.
This will be installed in `set-message-functions'. Plain messages do map
the minibuffer, but don't go through `minibuffer-setup-hook' or
isearch's hook.

Only acts on a plain message (no interactive read, minibuffer-depth
zero): during a read, setup and `resize-mini-frames' already manage the
frame, and this runs after Emacs has already mapped it."
  (let (suppress)
    (unless stickies--in-set-message
      (let* ((stickies--in-set-message t)
             (frame (selected-frame)))
        (when (and (zerop (minibuffer-depth))
                   (frame-parameter frame 'stickies-note))
          (if (current-idle-time)
              (setq suppress t) ;; skip displaying idle message
            (when-let ((mini (stickies--minibuffer-frame-of frame)))
              (stickies--position-minibuffer-frame mini frame))))))
    suppress))

(defvar stickies--prev-clear-message-function nil
  "Value of `clear-message-function' from before stickies chained onto it.")

(defun stickies--clear-message-function ()
  "Hide note minibuffer frames when the echo area is cleared.
This will be installed as the `clear-message-function'."
  (stickies--hide-minibuffer-frames)
  (when (functionp stickies--prev-clear-message-function)
    (funcall stickies--prev-clear-message-function)))

;; Appended, so it runs after `minibuffer-error-initialize' and wins when
;; installing `command-error-function'.
(add-hook 'minibuffer-setup-hook #'stickies--minibuffer-setup t)
(add-hook 'minibuffer-exit-hook #'stickies--minibuffer-exit)
(add-hook 'isearch-mode-hook #'stickies--isearch-show)
(add-hook 'isearch-mode-end-hook #'stickies--hide-minibuffer-frames)
(add-hook 'set-message-functions #'stickies--set-message-function)

;; On the NS port a child frame is mapped together with its parent, so a
;; note's minibuffer child frame reappears whenever its note gains focus --
;; with nothing to read.  Take such idle frames down on every focus change,
;; not only on the next input event (via `clear-message-function').  The
;; handler runs after Emacs has processed the focus event (so after the map)
;; and is a no-op mid-read (see `stickies--hide-minibuffer-frames').
(add-function :after after-focus-change-function
              #'stickies--hide-minibuffer-frames)

(unless (eq clear-message-function #'stickies--clear-message-function)
  (setq stickies--prev-clear-message-function clear-message-function
        clear-message-function #'stickies--clear-message-function))

(when (eq stickies--saved-resize-mini-frames 'unset)
  (setq stickies--saved-resize-mini-frames resize-mini-frames))
(setq resize-mini-frames #'stickies--resize-mini-frames)

(defun stickies--on-buffer-killed ()
  "Close any sticky note frames showing this buffer."
  (let ((basename (stickies--note-basename buffer-file-name)))
    (when basename
      (dolist (frame (stickies--frames basename))
        (ignore-errors (delete-frame frame))))))

(defun stickies--maybe-enable ()
  "Enable `stickies-mode' for note files under `stickies-directory'.
Only real notes qualify; `stickies--note-basename' already rejects
hidden, backup and auto-save files, so visiting e.g. the index file
leaves the mode off.

The mode relies on child frames and is only enabled on GUI Emacs; on a
TTY the note file just opens normally."
  (when (and (display-graphic-p)
             buffer-file-name
             (stickies--note-basename buffer-file-name)
             (not stickies-mode))
    (stickies-mode 1)))

(add-hook 'find-file-hook #'stickies--maybe-enable)
(add-hook 'after-change-major-mode-hook #'stickies--maybe-enable)


;;;; Showing notes by raising their frame

;; A sticky note's buffer lives in a dedicated frame.  Whenever something
;; tries to show that buffer -- `find-file', `switch-to-buffer',
;; `display-buffer' -- route it to the note's own frame instead of the
;; current window, creating that frame if the note doesn't have one yet.

(defvar stickies--opening-frame nil
  "Non-nil while a note frame is being created.
Guards `stickies--show-note-frame' against re-entering itself (via a
nested display of the note buffer) while `stickies--make-frame' runs.")

(defun stickies--buffer-note-basename (buffer)
  "Return the note basename BUFFER visits, or nil if it isn't a note."
  (when (buffer-live-p buffer)
    (when-let ((file (buffer-file-name buffer)))
      (stickies--note-basename file))))

(defun stickies--mru-note-frame (&optional exclude)
  "Return the most recently used, not rolled-up sticky note frame, or nil.
The buffer list is in most-recently-used order, so the first note
buffer whose frame qualifies is the note the user last worked in.
EXCLUDE, if non-nil, is a frame to skip: `stickies--attach-position'
asks on behalf of a brand-new frame, which must not anchor to itself."
  (cl-loop for buffer in (buffer-list)
           for basename = (stickies--buffer-note-basename buffer)
           for frame = (and basename (car (stickies--frames basename)))
           when (and frame
                     (not (eq frame exclude))
                     (not (stickies--rolled-up-p frame)))
           return frame))

(defun stickies--show-note-frame (buffer)
  "Reveal sticky note BUFFER in its own frame, creating the frame if needed.
Return the frame, or nil if BUFFER is not a note (or a frame is already
being created).  An existing frame is raised and focused; a note with no
live frame gets a fresh one."
  (when (and (display-graphic-p) (not stickies--opening-frame))
    (when-let ((basename (stickies--buffer-note-basename buffer)))
      (let ((frame (car (stickies--frames basename))))
        (unless frame
          (let ((stickies--opening-frame t))
            (stickies--load-index)
            (setq frame (stickies--make-frame basename))))
        (make-frame-visible frame)
        (raise-frame frame)
        (select-frame-set-input-focus frame)
        ;; Showing the buffer is a request to interact with the note, so
        ;; a rolled-up note is peeked open (until it is deselected).
        (when (stickies--rolled-up-p frame)
          (stickies--peek-down frame))
        frame))))

(defun stickies--note-buffer-name-p (buffer-name &optional _action)
  "Return non-nil if BUFFER-NAME names a sticky note buffer."
  (and (stickies--buffer-note-basename (get-buffer buffer-name)) t))

(defun stickies--display-buffer-note-frame (buffer _alist)
  "`display-buffer' action: show sticky-note BUFFER in its own frame.
Return the frame's selected window, or nil to fall through to the
default display."
  (when-let ((frame (stickies--show-note-frame buffer)))
    (frame-selected-window frame)))

(defun stickies--switch-to-buffer-advice (orig buffer-or-name &rest args)
  "Around `switch-to-buffer': route buffers in and out of note frames.
When BUFFER-OR-NAME names a sticky note, reveal that note's frame
\(creating it if needed) instead of showing the note in the current
window. Conversely, a non-note buffer requested while a note frame is
selected pops up in a non-note frame."
  (cond
   ((and buffer-or-name
         (let ((buffer (get-buffer buffer-or-name)))
           (and (stickies--show-note-frame buffer) buffer))))
   ((and buffer-or-name (frame-parameter nil 'stickies-note))
    (pop-to-buffer buffer-or-name nil (car args)))
   (t (apply orig buffer-or-name args))))

(advice-add 'switch-to-buffer :around #'stickies--switch-to-buffer-advice)

(add-to-list 'display-buffer-alist
             '(stickies--note-buffer-name-p stickies--display-buffer-note-frame))


;;;; Interactive commands

(defun stickies--ensure-graphic ()
  "Signal a `user-error' unless the current frame is graphical.
Commands that manipulate note frames call this; those frames exist
only on GUI Emacs."
  (unless (display-graphic-p)
    (user-error "Sticky note frames are only supported on graphical frames")))

(defun stickies--next-basename ()
  "Return a fresh `note-NNN.EXT' whose `note-NNN' stem is unused.
EXT is `stickies-default-extension'.  The stem must be unique across
all extensions so `note-001.txt' isn't picked when `note-001.org'
already exists."
  (let ((used (mapcar #'file-name-sans-extension (stickies--all-notes)))
        (n 1))
    (while (member (format "note-%03d" n) used)
      (cl-incf n))
    (format "note-%03d.%s" n stickies-default-extension)))

;;;###autoload
(defun stickies-new ()
  "Create a new sticky note in `stickies-directory' and open it.
The filename is chosen automatically; use `stickies-rename' to
rename it afterwards."
  (interactive)
  (unless (file-directory-p stickies-directory)
    (make-directory stickies-directory t))
  (stickies--load-index)
  (let* ((basename (stickies--next-basename))
         (path (stickies--note-path basename))
         (cell (stickies--register basename)))
    (with-temp-file path)
    (setf (alist-get :theme (cdr cell)) stickies-default-theme)
    (stickies--save-index)
    ;; The note's own frame is a GUI-only affair; on a TTY just visit
    ;; the new file normally.
    (if (display-graphic-p)
        ;; Land focus on the fresh note, ready for typing.  This also
        ;; makes it the most recently used note, so notes created in a
        ;; row chain: each attaches to the previous one (see
        ;; `stickies--attach-position').
        (select-frame-set-input-focus (stickies--make-frame basename))
      (find-file path))
    (with-current-buffer (find-file-noselect path)
      (run-hooks 'stickies-new-note-hook))))

;;;###autoload
(defun stickies-open (basename)
  "Open the sticky note BASENAME from `stickies-directory'."
  (interactive
   (list (completing-read "Sticky note: " (stickies--all-notes) nil t)))
  ;; On a TTY there are no note frames; just open the file normally.
  (if (not (display-graphic-p))
      (find-file (stickies--note-path basename))
    (let ((existing (stickies--frames basename)))
      (if existing
          (progn (make-frame-visible (car existing))
                 (stickies--clamp-frame-onscreen (car existing))
                 (select-frame-set-input-focus (car existing)))
        (stickies--load-index)
        (stickies--make-frame basename)))))

;;;###autoload
(defun stickies-show-all ()
  "Show every sticky note in `stickies-directory'.
Only supported on graphical frames."
  (interactive)
  (stickies--ensure-graphic)
  (stickies--load-index)
  (dolist (basename (stickies--all-notes))
    (let ((frames (stickies--frames basename)))
      (if frames
          (dolist (f frames)
            (make-frame-visible f)
            (stickies--clamp-frame-onscreen f))
        (stickies--make-frame basename)))))

;;;###autoload
(defun stickies-hide-all ()
  "Hide every visible sticky note frame.
Only supported on graphical frames."
  (interactive)
  (stickies--ensure-graphic)
  (dolist (frame (stickies--frames))
    (stickies--save-frame-state frame)
    (make-frame-invisible frame t))
  ;; Hiding every note leaves no frame selected; focus the foremost
  ;; visible non-note frame (stacking order), i.e. the one behind the notes.
  (when-let ((frame (seq-find
                     (lambda (f)
                       (and (frame-visible-p f)
                            (not (frame-parameter f 'stickies-note))))
                     (or (frame-list-z-order) (frame-list)))))
    (select-frame-set-input-focus frame)))

;;;###autoload
(defun stickies-toggle ()
  "Toggle the visibility of all sticky notes.
If the current frame is itself a sticky note, hide every sticky note.
Otherwise show every sticky note in `stickies-directory' and raise the
frames.  Dispatching on the current frame instead of overall
visibility means one invocation from a non-sticky note frame always
brings the sticky notes forward, even when some are merely occluded
by other windows -- something Emacs has no API to detect.

Only supported on graphical frames."
  (interactive)
  (stickies--ensure-graphic)
  (if (frame-parameter (selected-frame) 'stickies-note)
      (stickies-hide-all)
    (stickies--load-index)
    (dolist (basename (stickies--all-notes))
      (let ((frames (stickies--frames basename)))
        (if frames
            (dolist (f frames)
              (make-frame-visible f)
              (stickies--clamp-frame-onscreen f)
              (raise-frame f))
          (raise-frame (stickies--make-frame basename)))))
    ;; Land focus on the most recently used note.
    (when-let ((frame (stickies--mru-note-frame)))
      (select-frame-set-input-focus frame))))

;;;###autoload
(defun stickies-set-theme (name)
  "Set NAME as the theme for the current sticky note."
  (interactive
   (list (intern
          (completing-read
           "Theme: "
           (mapcar (lambda (e) (symbol-name (car e))) stickies-themes)
           nil t))))
  (unless stickies-mode
    (user-error "Not in a sticky note buffer"))
  (unless (assq name stickies-themes)
    (user-error "Unknown theme: %s" name))
  (stickies--set-theme name))

;;;###autoload
(defun stickies-rename (new-basename)
  "Rename the current sticky note to NEW-BASENAME (within `stickies-directory')."
  (interactive
   (progn
     (unless stickies-mode
       (user-error "Not in a sticky note buffer"))
     (list (read-string
            "New name: " (file-name-nondirectory buffer-file-name)))))
  (when (string-match-p "/" new-basename)
    (user-error "Name must not contain `/'"))
  (let* ((old-basename (file-name-nondirectory buffer-file-name))
         (new-path (stickies--note-path new-basename)))
    (when (string= old-basename new-basename)
      (user-error "Same name; no rename needed"))
    (when (file-exists-p new-path)
      (user-error "File already exists: %s" new-basename))
    ;; Update the index before changing the file.
    (let ((cell (stickies--entry old-basename)))
      (when cell
        (setf (car cell) new-basename)))
    (rename-visited-file new-path)
    (rename-buffer new-basename t)
    (dolist (frame (frame-list))
      (when (equal (frame-parameter frame 'stickies-note) old-basename)
        (set-frame-parameter frame 'stickies-note new-basename)
        (set-frame-parameter frame 'name (format "Sticky note: %s" new-basename))))
    (stickies--save-index)
    ;; Apply colors from the index.
    (stickies--apply-colors)))

;;;###autoload
(defun stickies--note-blank-p (buffer)
  "Return non-nil if note BUFFER holds nothing but whitespace."
  (with-current-buffer buffer
    (not (string-match-p "[^[:space:]]" (buffer-string)))))

(defun stickies--delete-note (buffer)
  "Delete the sticky note shown in BUFFER: its frames, file, buffer and entry."
  (let* ((path (buffer-file-name buffer))
         (basename (file-name-nondirectory path)))
    (dolist (frame (stickies--frames basename))
      ;; Clear the marker so `stickies--on-frame-deleted' doesn't
      ;; re-save geometry into an entry we're about to drop.
      (set-frame-parameter frame 'stickies-note nil)
      (ignore-errors (delete-frame frame)))
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (kill-buffer buffer)
    (delete-file path)
    (stickies--unregister basename)))

(defun stickies-delete ()
  "Delete the current sticky note (with confirmation)."
  (interactive)
  (unless stickies-mode
    (user-error "Not in a sticky note buffer"))
  (let ((basename (file-name-nondirectory buffer-file-name)))
    (when (yes-or-no-p (format "Delete sticky note %s? " basename))
      (stickies--delete-note (current-buffer)))))

(provide 'stickies)
;;; stickies.el ends here
