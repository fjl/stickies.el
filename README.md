# stickies.el — sticky notes in dedicated frames

Pastel-colored panes of text that auto-saves, floating above other application windows.
Creating a new note doesn't ask for a file name, a commitment-free writing space. Note
frames can collapse into a title-bar to hide their content.

Heavily inspired by Apple's Stickies.app, this package provides a similar experience, but
the notes are just text files stored in a directory. And you can use any Emacs mode for
the content. Org-mode checklists, spreadsheets, enriched-mode, inline images...

![Screenshot](./images/screenshot.png)

## Installation

At this time, stickies.el is not yet available in MELPA. You have to add it to your
load path somehow and then require it in your Emacs configuration:

```elisp
(require 'stickies)
```

## Commands

- `stickies-new` — create a new note.
- `stickies-open` — open an existing note by name.
- `stickies-toggle` — show all notes, or hide them if a note is focused.
- `stickies-show-all` / `stickies-hide-all` — show or hide every note.
- `stickies-rename` — rename the current note.
- `stickies-delete` — delete the current note on disk (asks for confirmation).
- `stickies-set-theme` — set the current note's color theme.

I recommend binding at least `stickies-new` and `stickies-toggle` to easily-reachable
keys. Since stickies is GUI-only anyway, you can use super-keys:

```elisp
(keymap-global-set "s--" 'stickies-new)
(keymap-global-set "s-+" 'stickies-toggle)
```

## Hooks

Two separate hooks are provided for configuring sticky notes.

### stickies-mode-hook

This runs whenever a note buffer is set up. Use it to tweak appearance or behavior of
every note (fonts, modes, local variables). Here is an example:

```elisp
(defun my-stickies-mode-hook ()
  (variable-pitch-mode 1)
  (visual-line-mode 1))

(add-hook 'stickies-mode-hook 'my-stickies-mode-hook)
```

### stickies-new-note-hook

This runs once after a new note is created. You can use it to insert a template. It's also
the place to enable `enriched-mode`, should you choose to use it, since enabling it for
the first time will write an invisible preamble into the buffer.

```elisp
(defun my-stickies-new-note-setup ()
  (use-hard-newlines 0 'always)
  (enriched-mode 1))

(add-hook 'stickies-new-note-hook 'my-stickies-new-note-setup)
```
