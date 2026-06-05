;;; stickies.el --- Sticky notes in dedicated frames -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Felix Lange

;; Author: Felix Lange <fjl@twurst.com>
;; Maintainer: Felix Lange <fjl@twurst.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (mini-frame "20220627.2041"))
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
(require 'face-remap)
(require 'files-x)
(require 'easymenu)
(require 'mini-frame)

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

(defcustom stickies-themes
  '((yellow :background "#fff8b8" :foreground "#222222")
    (pink   :background "#fcc9c9" :foreground "#222222")
    (purple :background "#d8c9f0" :foreground "#222222")
    (blue   :background "#c2dffc" :foreground "#222222")
    (green  :background "#c5edc6" :foreground "#222222"))
  "Named color themes for sticky notes.
Each entry has the form (NAME PROPERTIES) where PROPERTIES is a
plist with `:background' and `:foreground' colors."
  :type '(alist :key-type symbol :value-type sexp))

(defcustom stickies-default-theme 'yellow
  "Name of the default theme used for new sticky notes.
Must be a key in `stickies-themes'."
  :type 'symbol)

(defcustom stickies-flatten-exclude
  '(default header-line cursor fringe
    region secondary-selection highlight hl-line
    isearch lazy-highlight isearch-fail match
    show-paren-match show-paren-mismatch
    minibuffer-prompt error warning success
    link mouse tooltip
    mode-line mode-line-inactive mode-line-buffer-id
    mode-line-emphasis mode-line-highlight
    tab-bar tab-bar-tab tab-bar-tab-inactive tab-line)
  "Faces that keep their colors in sticky notes."
  :type '(repeat face))

(defcustom stickies-face-remaps nil
  "Extra face remaps applied after flattening.
Each entry is (FACE . SPEC), where SPEC is the property-list form
accepted by `face-remap-add-relative', e.g.
  (org-todo :foreground \"red\" :weight bold).
Applied last so they override flattening."
  :type '(alist :key-type face :value-type sexp))

(defcustom stickies-translucent-alpha 75
  "Background alpha (0-100) applied when a sticky note is made translucent.
Requires Emacs 29 or newer and a compositing window manager."
  :type 'integer)

(defcustom stickies-title-format '("%b")
  "Title shown in a sticky note's header line.
A mode-line construct (see `mode-line-format') rendered with
`format-mode-line', so it may hold strings, %-constructs, your own
variables, and `:eval' forms.  Evaluated in the note's buffer.
The roll-up and close buttons are always appended after the title,
whatever the format."
  :type 'sexp
  :risky t)

(defvar stickies-frame-parameters
  '((width . 40)
    (height . 12)
    (minibuffer . nil)
    (undecorated . t)
    (drag-with-header-line . t)
    (unsplittable . t)
    (vertical-scroll-bars . nil)
    (internal-border-width . 0)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0))
  "Default frame parameters for sticky note frames.
A `(stickies-note . BASENAME)' marker is added automatically.
Saved per-note geometry overrides these.")

(defcustom stickies-auto-save-interval 2
  "Idle seconds before a modified sticky note is auto-saved.
Set to nil to disable auto-saving."
  :type '(choice (number :tag "Seconds")
                 (const :tag "Off" nil)))


;;;; Buffer-local note state

(defvar-local stickies--remap-cookies nil
  "List of cookies returned by `face-remap-add-relative' for this buffer.")


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
      (insert ";; stickies index -- automatically generated\n")
      (prin1 `(setq stickies--notes ',stickies--notes) (current-buffer))
      (insert "\n"))))

(defun stickies--load-index ()
  "Load `stickies--notes' from the index file if present.
Drops entries that no longer refer to existing files."
  (let ((file (stickies--index-file)))
    (when (file-readable-p file)
      (load file nil t)))
  (stickies--prune-index))

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

(defun stickies--note-basename (path)
  "Return PATH's basename if it lives under `stickies-directory', else nil."
  (and path
       (file-directory-p stickies-directory)
       (let ((p (expand-file-name path)))
         (when (file-in-directory-p p stickies-directory)
           (file-name-nondirectory p)))))

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
  "Return basenames of all files in `stickies-directory' (no dotfiles)."
  (when (file-directory-p stickies-directory)
    (directory-files stickies-directory nil "\\`[^.]")))


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

(defun stickies--apply-colors ()
  "Apply sticky note colors and face flattening to the current buffer.
Also applies user-defined overrides from `stickies-face-remaps'."
  (dolist (c stickies--remap-cookies)
    (face-remap-remove-relative c))
  (setq stickies--remap-cookies nil)
  (pcase-let ((`(,bg . ,fg) (stickies--theme-colors)))
    (push (face-remap-add-relative 'default
                                   :background bg
                                   :foreground fg)
          stickies--remap-cookies)
    (push (face-remap-add-relative 'header-line
                                   :background bg
                                   :foreground fg
                                   :height 0.8
                                   :box nil
                                   :underline nil
                                   :overline nil)
          stickies--remap-cookies)
    ;; Fringe is set per-frame in `stickies--apply-fringe-color' rather
    ;; than via face-remap, because a buffer-local face-remap change
    ;; alone doesn't repaint the cached fringe pixels.
    (dolist (face (face-list))
      (unless (memq face stickies-flatten-exclude)
        (when (or (not (eq (face-attribute face :foreground nil nil)
                           'unspecified))
                  (not (eq (face-attribute face :background nil nil)
                           'unspecified)))
          (push (face-remap-add-relative face
                                         :foreground fg
                                         :background bg)
                stickies--remap-cookies)))))
  (pcase-dolist (`(,face . ,spec) stickies-face-remaps)
    (push (apply #'face-remap-add-relative face spec)
          stickies--remap-cookies))
  (stickies--apply-fringe-color))

(defun stickies--apply-fringe-color ()
  "Paint fringe of every frame showing this buffer with the theme bg.
Setting the face attribute directly on the frame (rather than via
buffer-local face-remapping) and following with `redraw-frame' is
what reliably repaints the fringe area on a theme change."
  (let ((bg (car (stickies--theme-colors))))
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (let ((frame (window-frame window)))
        (set-face-attribute 'fringe frame :background bg)
        (redraw-frame frame)))))


;;;; Header line

;; Each button gets its own mouse-face symbol so Emacs treats them as
;; separate highlight regions -- hovering one doesn't light up the other.
(defface stickies-close-button-hover '((t :inherit mode-line-highlight))
  "Mouse hover face for the sticky note close button.")
(defface stickies-roll-button-hover '((t :inherit mode-line-highlight))
  "Mouse hover face for the sticky note roll-up button.")

(defun stickies--button-close (_event)
  "Header-line button: close (delete) the current sticky note frame."
  (interactive "e")
  (delete-frame))

(defvar stickies--close-button-map
  (let ((m (make-sparse-keymap)))
    (define-key m [header-line mouse-1] #'stickies--button-close)
    m)
  "Keymap for the close button in the sticky note header line.")

(defun stickies--rolled-up-p (&optional frame)
  "Return non-nil if FRAME (default: selected) is rolled up.
The value is the pre-rolled frame height, in lines."
  (frame-parameter frame 'stickies-roll-saved-height))

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
         (roll (propertize
                (if (stickies--rolled-up-p) " ↓ " " ↑ ")
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

(defun stickies--translucent-p (&optional frame)
  "Return non-nil if FRAME (defaults to selected) is translucent."
  (let ((a (frame-parameter frame 'alpha-background)))
    (and (numberp a) (< a 100))))

(defun stickies-toggle-always-on-top ()
  "Toggle whether the current sticky note frame stays above other windows."
  (interactive)
  (let ((frame (selected-frame)))
    (set-frame-parameter
     frame 'z-group (if (stickies--always-on-top-p frame) nil 'above))
    (stickies--save-frame-state frame)))

(defun stickies-toggle-translucent ()
  "Toggle background translucency of the current sticky note frame."
  (interactive)
  (let ((frame (selected-frame)))
    (set-frame-parameter
     frame 'alpha-background
     (if (stickies--translucent-p frame) nil stickies-translucent-alpha))
    (stickies--save-frame-state frame)))

(defvar-local stickies--roll-overlay nil
  "Marker overlay set while the sticky note's buffer is in rolled-up state.")

(defun stickies--frame-buffer (frame)
  "Return the buffer shown in FRAME's root window."
  (window-buffer (frame-root-window frame)))

(defun stickies--enter-rolled-up ()
  "Hide buffer content while the sticky note is rolled up.
Keeps the real header line active so `drag-with-header-line' --
Emacs's built-in, glitch-free frame drag -- continues to work.
An invisible overlay covers the entire buffer so the (small)
body row paints as blank under the header."
  (unless stickies--roll-overlay
    (setq-local cursor-type nil)
    (let ((o (make-overlay (point-min) (point-max) nil nil t)))
      (overlay-put o 'invisible t)
      (setq stickies--roll-overlay o))))

(defun stickies--exit-rolled-up ()
  "Restore the buffer's normal display."
  (when stickies--roll-overlay
    (delete-overlay stickies--roll-overlay)
    (setq stickies--roll-overlay nil)
    (kill-local-variable 'cursor-type)))

(defun stickies--apply-roll-height (frame)
  "Shrink FRAME to the minimal height with the header line still visible.
`window_wants_header_line' in src/window.c keeps the header iff
WINDOW_PIXEL_HEIGHT > frame_char_height (no mode line).
`set-frame-height' with PIXELWISE sets the frame's text height,
which equals WINDOW_PIXEL_HEIGHT for a single-window frame -- so
passing `frame_char_height + 1' is just enough to keep the
header.  An invisible overlay added in `stickies--enter-rolled-up'
hides whatever buffer content would otherwise paint in the
resulting few-pixel body strip.  The achieved text height in
*pixels* is recorded in `stickies-roll-height' so the resize hook
can tell our own resize from an external one -- line granularity
is too coarse here, since a sub-line drag can hide the header
without changing the frame's height in lines."
  (let ((window-min-height 0)
        (window-safe-min-height 0)
        (frame-resize-pixelwise t))
    (set-frame-height frame (1+ (frame-char-height frame)) nil t))
  (set-frame-parameter frame 'stickies-roll-height
                       (frame-text-height frame)))

(defun stickies-toggle-roll-up ()
  "Toggle whether the current sticky note frame is rolled up.
When rolled up the body shrinks to one natural row -- the
smallest size at which Emacs reliably keeps the header line
visible, so `drag-with-header-line' continues to move the frame
natively.  A rolled-up frame has a fixed height: attempts to
resize it vertically are undone, while width changes are kept."
  (interactive)
  (let ((frame (selected-frame)))
    (if-let ((saved (stickies--rolled-up-p frame)))
        ;; Expand.
        (progn
          (set-frame-parameter frame 'stickies-roll-saved-height nil)
          (set-frame-parameter frame 'stickies-roll-height nil)
          (with-current-buffer (stickies--frame-buffer frame)
            (stickies--exit-rolled-up))
          (set-frame-height frame saved))
      ;; Roll up.
      (set-frame-parameter frame 'stickies-roll-saved-height
                           (frame-parameter frame 'height))
      (with-current-buffer (stickies--frame-buffer frame)
        (stickies--enter-rolled-up))
      (stickies--apply-roll-height frame))
    (stickies--save-frame-state frame)))

(defun stickies--keep-roll-height-on-resize (frame)
  "Undo vertical resizing of a rolled-up sticky note FRAME.
A rolled-up sticky note has a fixed height; any resize that changes
its height is reverted to the rolled-up height, while width
changes are left intact.  The `set-frame-height' inside
`stickies--apply-roll-height' re-enters this hook, but the height
then matches `stickies-roll-height' so the guard stops the
recursion."
  (when (and (frame-parameter frame 'stickies-note)
             (stickies--rolled-up-p frame)
             (not (equal (frame-text-height frame)
                         (frame-parameter frame 'stickies-roll-height))))
    (stickies--apply-roll-height frame)))

(add-hook 'window-size-change-functions #'stickies--keep-roll-height-on-resize)

(defun stickies--save-all-frame-state ()
  "Persist geometry of every visible sticky note frame."
  (dolist (frame (stickies--frames))
    (stickies--save-frame-state frame)))

(add-hook 'kill-emacs-hook #'stickies--save-all-frame-state)

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
                          ["Translucent" stickies-toggle-translucent
                           :style toggle
                           :selected (stickies--translucent-p)]
                          ["Rolled up" stickies-toggle-roll-up
                           :style toggle
                           :selected (stickies--rolled-up-p)]
                          "--"
                          ["Close sticky note" delete-frame])))))
    (popup-menu menu event)))

(defvar stickies-note-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m [mouse-3] #'stickies--popup-menu)
    (define-key m [header-line mouse-3] #'stickies--popup-menu)
    m)
  "Keymap for `stickies-note-mode'.")


;;;; Auto-save

(defvar stickies-note-mode)             ; defined below via `define-minor-mode'

(defvar stickies--auto-save-timer nil
  "Idle timer that saves modified sticky note buffers.")

(defun stickies--auto-save-tick ()
  "Save modified sticky note buffers and stale frame geometries.
Runs on the same idle timer so position/size changes (which have
no dedicated hook) get persisted within one tick interval without
writing the index on every pixel of drag."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and stickies-note-mode
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
                    (cur-roll   (and (stickies--rolled-up-p frame) t))
                    (saved-params (alist-get :params (cdr cell)))
                    (saved-roll   (alist-get :rolled-up (cdr cell))))
                (unless (equal cur-params saved-params)
                  (setf (alist-get :params (cdr cell)) cur-params)
                  (setq dirty t))
                (unless (eq cur-roll saved-roll)
                  (setf (alist-get :rolled-up (cdr cell)) cur-roll)
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


;;;; Minor mode

;;;###autoload
(define-minor-mode stickies-note-mode
  "Minor mode for buffers that are sticky notes.
Applies the buffer's theme colors via a `default' face remap,
hides the mode line, installs a header line with a close button,
binds `mouse-3' to a context menu for changing themes, and closes
the corresponding sticky note frame when the buffer is killed."
  :lighter " Stk"
  :keymap stickies-note-mode-map
  (if stickies-note-mode
      (progn
        (setq-local mode-line-format nil)
        (setq-local header-line-format '(:eval (stickies--header-line)))
        ;; Hide the cursor in idle (unfocused) note frames; it reappears
        ;; in whichever note currently has focus.
        (setq-local cursor-in-non-selected-windows nil)
        (setq-local truncate-lines nil)
        (stickies--apply-colors)
        (stickies--ensure-auto-save-timer)
        (add-hook 'kill-buffer-hook #'stickies--on-buffer-killed nil t))
    (kill-local-variable 'mode-line-format)
    (kill-local-variable 'header-line-format)
    (kill-local-variable 'cursor-in-non-selected-windows)
    (kill-local-variable 'truncate-lines)
    (stickies--exit-rolled-up)
    (dolist (c stickies--remap-cookies)
      (face-remap-remove-relative c))
    (setq stickies--remap-cookies nil)
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
Captures geometry plus toggles like `z-group' and `alpha-background'.
If FRAME is currently rolled up, save the pre-rolled (expanded)
height so a restored frame doesn't come back as a tiny strip."
  `((width            . ,(frame-parameter frame 'width))
    (height           . ,(or (stickies--rolled-up-p frame)
                             (frame-parameter frame 'height)))
    (left             . ,(frame-parameter frame 'left))
    (top              . ,(frame-parameter frame 'top))
    (z-group          . ,(frame-parameter frame 'z-group))
    (alpha-background . ,(frame-parameter frame 'alpha-background))))

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
  (when (display-graphic-p frame)
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
              (set-frame-position frame left top))))))))

(defun stickies--roll-up-on-open (frame &optional attempts)
  "Roll up a newly created FRAME once the window manager honors the size.
A resize issued right after `make-frame' is rounded up to a whole
character row, because the WM has not finished placing the frame
-- leaving two text lines instead of just the header, and locking
that height in as `stickies-roll-height'.  Re-apply the rolled-up
height on short timers until the achieved text height reaches the
target or ATTEMPTS (default 20) is exhausted."
  (let ((attempts (or attempts 20)))
    (when (frame-live-p frame)
      (with-selected-frame frame
        (if (stickies--rolled-up-p frame)
            (stickies--apply-roll-height frame)
          (stickies-toggle-roll-up)))
      (when (and (> attempts 0)
                 (> (frame-text-height frame)
                    (1+ (frame-char-height frame))))
        (run-with-timer 0.05 nil
                        #'stickies--roll-up-on-open frame (1- attempts))))))

(defun stickies--make-frame (basename)
  "Create and return a frame displaying the sticky note BASENAME."
  ;; Let-bind across `make-frame': X size hints (width_inc/height_inc)
  ;; sent to the WM at frame creation depend on this variable, and the
  ;; WM uses them to round later resize requests.  Without pixel-precise
  ;; hints, our rolled-up resize would get rounded up to a whole
  ;; character row -- two text lines instead of just the header.
  (let* ((frame-resize-pixelwise t)
         (path (stickies--note-path basename))
         (entry (stickies--register basename))
         (saved (alist-get :params (cdr entry)))
         (rolled-up (alist-get :rolled-up (cdr entry)))
         ;; Order: per-note geometry first, then user defaults, then
         ;; required markers last (so they always win).
         (params (append `((stickies-note . ,basename)
                           (name . ,(format "Sticky note: %s" basename)))
                         saved
                         stickies-frame-parameters))
         (buffer (find-file-noselect path))
         (frame  (make-frame params))
         (window (frame-root-window frame)))
    (set-window-buffer window buffer)
    (set-window-dedicated-p window t)
    (with-current-buffer buffer
      (stickies--apply-fringe-color))
    ;; Restored geometry may point at a now-detached monitor; pull the
    ;; frame back onto a visible screen so it stays reachable.
    (stickies--clamp-frame-onscreen frame)
    (when rolled-up
      ;; Defer the roll-up: a synchronous resize inside `make-frame'
      ;; lands before the WM has finished sizing the new frame and gets
      ;; rounded up to two character rows.  `stickies--roll-up-on-open'
      ;; keeps re-applying the rolled-up height until the WM honors the
      ;; pixel-precise request.
      (run-with-timer 0 nil #'stickies--roll-up-on-open frame))
    frame))

(defun stickies--save-frame-state (frame)
  "Persist FRAME's geometry and rolled-up state into the index."
  (let ((basename (frame-parameter frame 'stickies-note)))
    (when basename
      (let ((cell (stickies--register basename)))
        (setf (alist-get :params (cdr cell))
              (stickies--frame-geometry frame))
        (setf (alist-get :rolled-up (cdr cell))
              (and (stickies--rolled-up-p frame) t))
        (stickies--save-index)))))

(defun stickies--on-frame-deleted (frame)
  "Persist geometry when a sticky note FRAME is deleted."
  (when (frame-parameter frame 'stickies-note)
    (stickies--save-frame-state frame)))

(add-hook 'delete-frame-functions #'stickies--on-frame-deleted)

(defun stickies--raise-minibuffer-frame ()
  "Focus the minibuffer's frame when entered from a sticky note frame.
Sticky note frames have no minibuffer of their own, so commands that
read input use the minibuffer of another frame.  Without focus
following, the user cannot type into it."
  (let* ((calling (minibuffer-selected-window))
         (calling-frame (and calling (window-frame calling)))
         (mini-frame (window-frame (minibuffer-window))))
    (when (and calling-frame
               (not (eq mini-frame calling-frame))
               (frame-parameter calling-frame 'stickies-note))
      (select-frame-set-input-focus mini-frame))))

(add-hook 'minibuffer-setup-hook #'stickies--raise-minibuffer-frame)

(defun stickies--on-buffer-killed ()
  "Close any sticky note frames showing this buffer."
  (let ((basename (stickies--note-basename buffer-file-name)))
    (when basename
      (dolist (frame (stickies--frames basename))
        (ignore-errors (delete-frame frame))))))

(defun stickies--maybe-enable ()
  "Enable `stickies-note-mode' for files under `stickies-directory'."
  (when (and buffer-file-name
             (stickies--note-basename buffer-file-name)
             (not stickies-note-mode))
    (stickies-note-mode 1)))

(add-hook 'find-file-hook #'stickies--maybe-enable)
(add-hook 'after-change-major-mode-hook #'stickies--maybe-enable)


;;;; Showing notes by raising their frame

;; A sticky note's buffer lives in a dedicated frame.  When something
;; tries to show that buffer elsewhere -- `switch-to-buffer', a
;; `find-file' of an already-open note -- reveal the existing frame
;; instead of duplicating the note in the current window.

(defun stickies--buffer-note-frame (buffer)
  "Return a live sticky note frame showing BUFFER's note, or nil."
  (when (buffer-live-p buffer)
    (when-let* ((file (buffer-file-name buffer))
                (basename (stickies--note-basename file)))
      (car (stickies--frames basename)))))

(defun stickies--raise-note-frame (buffer)
  "Raise the sticky note frame showing BUFFER, if any.  Return the frame or nil."
  (when-let ((frame (stickies--buffer-note-frame buffer)))
    (make-frame-visible frame)
    (raise-frame frame)
    (select-frame-set-input-focus frame)
    frame))

(defun stickies--note-buffer-name-p (buffer-name &optional _action)
  "Return non-nil if BUFFER-NAME is an open sticky note with a live frame."
  (and (stickies--buffer-note-frame (get-buffer buffer-name)) t))

(defun stickies--display-buffer-raise-frame (buffer _alist)
  "`display-buffer' action: reveal sticky-note BUFFER by raising its frame.
Return the frame's selected window, or nil to fall through to the
default display."
  (when-let ((frame (stickies--raise-note-frame buffer)))
    (frame-selected-window frame)))

(defun stickies--switch-to-buffer-advice (orig buffer-or-name &rest args)
  "Around `switch-to-buffer': raise an open sticky note's frame.
When BUFFER-OR-NAME names a sticky note that already has a live
frame, raise that frame instead of showing the note in the
current window.  ORIG is the wrapped `switch-to-buffer' and ARGS
its remaining arguments, called unchanged otherwise."
  (or (and buffer-or-name
           (let ((buffer (get-buffer buffer-or-name)))
             (and (stickies--raise-note-frame buffer) buffer)))
      (apply orig buffer-or-name args)))

(advice-add 'switch-to-buffer :around #'stickies--switch-to-buffer-advice)

(add-to-list 'display-buffer-alist
             '(stickies--note-buffer-name-p stickies--display-buffer-raise-frame))


;;;; Interactive commands

(defun stickies--next-basename ()
  "Return a fresh `note-NNN.txt' whose `note-NNN' stem is unused.
The stem must be unique across all extensions so `note-001.txt'
isn't picked when `note-001.org' already exists."
  (let ((used (mapcar #'file-name-sans-extension (stickies--all-notes)))
        (n 1))
    (while (member (format "note-%03d" n) used)
      (cl-incf n))
    (format "note-%03d.txt" n)))

;;;###autoload
(defun stickies-new ()
  "Create a new sticky note in `stickies-directory' and open it.
The filename is chosen automatically; use `stickies-rename' to
rename it afterwards."
  (interactive)
  (unless (file-directory-p stickies-directory)
    (make-directory stickies-directory t))
  (let* ((basename (stickies--next-basename))
         (path (stickies--note-path basename))
         (cell (stickies--register basename)))
    (with-temp-file path)
    (setf (alist-get :theme (cdr cell)) stickies-default-theme)
    (stickies--save-index)
    (stickies--make-frame basename)))

;;;###autoload
(defun stickies-open (basename)
  "Open the sticky note BASENAME from `stickies-directory'."
  (interactive
   (list (completing-read "Sticky note: " (stickies--all-notes) nil t)))
  (let ((existing (stickies--frames basename)))
    (if existing
        (progn (make-frame-visible (car existing))
               (select-frame-set-input-focus (car existing)))
      (stickies--make-frame basename))))

;;;###autoload
(defun stickies-show-all ()
  "Show every sticky note in `stickies-directory'."
  (interactive)
  (dolist (basename (stickies--all-notes))
    (let ((frames (stickies--frames basename)))
      (if frames
          (dolist (f frames) (make-frame-visible f))
        (stickies--make-frame basename)))))

;;;###autoload
(defun stickies-hide-all ()
  "Hide every visible sticky note frame."
  (interactive)
  (dolist (frame (stickies--frames))
    (stickies--save-frame-state frame)
    (make-frame-invisible frame t)))

;;;###autoload
(defun stickies-toggle ()
  "Toggle the visibility of all sticky notes.
If the current frame is itself a sticky note, hide every sticky note.
Otherwise show every sticky note in `stickies-directory' and raise the
frames.  Dispatching on the current frame instead of overall
visibility means one invocation from a non-sticky note frame always
brings the sticky notes forward, even when some are merely occluded
by other windows -- something Emacs has no API to detect."
  (interactive)
  (if (frame-parameter (selected-frame) 'stickies-note)
      (stickies-hide-all)
    (dolist (basename (stickies--all-notes))
      (let ((frames (stickies--frames basename)))
        (if frames
            (dolist (f frames)
              (make-frame-visible f)
              (raise-frame f))
          (raise-frame (stickies--make-frame basename)))))))

;;;###autoload
(defun stickies-set-theme (name)
  "Set NAME as the theme for the current sticky note."
  (interactive
   (list (intern
          (completing-read
           "Theme: "
           (mapcar (lambda (e) (symbol-name (car e))) stickies-themes)
           nil t))))
  (unless stickies-note-mode
    (user-error "Not in a sticky note buffer"))
  (unless (assq name stickies-themes)
    (user-error "Unknown theme: %s" name))
  (stickies--set-theme name))

(defun stickies--read-name (prompt initial)
  "Read a sticky-note name over the current note's frame.
On a graphical display, show PROMPT in a borderless `mini-frame'
child frame anchored to the top of the sticky note -- styled with
the note's theme colors -- so the rename stays on the note instead
of borrowing another frame's minibuffer.  On a text terminal, fall
back to a plain `read-string'.  INITIAL is the initial input."
  (if (display-graphic-p)
      (pcase-let* ((`(,bg . ,fg) (stickies--theme-colors))
                   (parent (selected-frame))
                   (native (frame-edges parent 'native-edges))
                   (inner (frame-edges parent 'inner-edges))
                   (mini-frame-show-parameters
                    ;; Child-frame LEFT/TOP are measured from the parent's
                    ;; *native* origin, which sits inside the internal
                    ;; border -- offset by it to land on the content
                    ;; corner.  Size the text area in pixels to the
                    ;; parent's inner width with no fringes, so the field's
                    ;; edges match the note's content area exactly on every
                    ;; platform (char/fringe math doesn't line up portably).
                    `((left . ,(- (nth 0 inner) (nth 0 native)))
                      (top . ,(- (nth 1 inner) (nth 1 native)))
                      (width text-pixels . ,(- (nth 2 inner) (nth 0 inner)))
                      (left-fringe . 0)
                      (right-fringe . 0)
                      (vertical-scroll-bars . nil)
                      (horizontal-scroll-bars . nil)
                      (background-color . ,bg)
                      (foreground-color . ,fg)
                      (child-frame-border-width . 0)
                      (internal-border-width . 0))))
        ;; Match the header line's reduced scale by remapping the
        ;; minibuffer's default face; mini-frame then fits the child
        ;; frame's height to this smaller content.
        (minibuffer-with-setup-hook
            (lambda () (face-remap-add-relative 'default :height 0.8))
          (mini-frame-read-from-minibuffer #'read-string prompt initial)))
    (read-string prompt initial)))

;;;###autoload
(defun stickies-rename (new-basename)
  "Rename the current sticky note to NEW-BASENAME (within `stickies-directory')."
  (interactive
   (progn
     (unless stickies-note-mode
       (user-error "Not in a sticky note buffer"))
     (list (stickies--read-name
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
(defun stickies-delete ()
  "Delete the current sticky note (with confirmation)."
  (interactive)
  (unless stickies-note-mode
    (user-error "Not in a sticky note buffer"))
  (let* ((path buffer-file-name)
         (basename (file-name-nondirectory path)))
    (when (yes-or-no-p (format "Delete sticky note %s? " basename))
      (dolist (frame (stickies--frames basename))
        ;; Clear the marker so `stickies--on-frame-deleted' doesn't
        ;; re-save geometry into an entry we're about to drop.
        (set-frame-parameter frame 'stickies-note nil)
        (ignore-errors (delete-frame frame)))
      (set-buffer-modified-p nil)
      (kill-buffer (current-buffer))
      (delete-file path)
      (stickies--unregister basename))))


;;;; Initialization

(condition-case err
    (stickies--load-index)
  (error (message "stickies: failed to load index: %s"
                  (error-message-string err))))

(provide 'stickies)
;;; stickies.el ends here
