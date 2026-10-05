# Drop Shelf

A drop zone in the Omarchy bar, inspired by the shelf in NotchNook. Drag files onto it from Nautilus (or anything
that drags files), one or many at a time, as often as you like. Each drop is staged: the shelf remembers *where the files are*
and touches nothing. When you are ready, either:

- **drag the shelf into a folder**: grab the shelf icon in the bar and drop it on a Nautilus window or folder, or
- **press the target** next to it and choose a folder.

Everything staged is then copied (or moved, if you switch the mode) into that folder.

## Using it

| Where | What |
|---|---|
| Bar, shelf icon | Drop files on it to stage them. It lights up while you hold files over it. Shows how many are staged. Click for the panel. Drag it into a folder to deliver. |
| Bar, target | Appears once something is staged. Opens the folder chooser and delivers there. While a delivery runs it becomes a stop button. |
| Panel | Copy / Move switch, the staged list (name, where it lives, size), recent folders for one-click delivery, *Remove missing*, *Clear shelf*. |
| Keys in the panel | `j`/`k` move · `enter` deliver to the highlighted recent folder · `o` choose folder · `m` copy/move · `d` remove from shelf · `c` clear · `s` stop |

**Copy** leaves the originals in place and, by default, clears the delivered items off the shelf (turn on *Keep files on the
shelf after copying* to deliver the same set to several folders). **Move** takes them from where they were; moved items always
leave the shelf.

Nothing is ever overwritten. If a name is taken in the target folder, the new copy becomes `name (2).ext`, `name (3).ext` and so
on. A file that disappeared after you staged it is shown in red and skipped; *Remove missing* takes those off the shelf.

Dragging the shelf out works differently from the target button. The file manager does the copy (or move) itself and never says
where the files went, so after a drag the shelf only checks what is still in place. In move mode, the items that moved leave the
shelf; in copy mode everything stays until you clear it.

## Install

```bash
omarchy plugin add https://github.com/cgranier/omarchy-drop-shelf.git --enable
omarchy plugin enable cgranier.dropshelf center --after omarchy.clock
```

The second line puts it right after the clock, in the middle of the bar.

## Remove

```bash
omarchy plugin disable cgranier.dropshelf
omarchy plugin remove cgranier.dropshelf
rm -rf ~/.local/state/dropshelf   # optional: the staged list and recent folders
```

## How it handles your files

- The shell never reads or writes a file itself. `bin/dropshelf` (Python, standard library only) does, and every path reaches it on
  **stdin**, never in its arguments, so other local users cannot read your file names from `/proc`.
- **State** (staged paths, mode, last five folders) lives in `~/.local/state/dropshelf/state.json`, at most 512 KB and 200 items.
  The helper reaches it through directory descriptors from `$HOME` down, refusing symlinks and directories it does not own, and
  replaces it atomically.
- **Delivery** opens the target folder once (it must be yours) and creates everything relative to it with
  `O_CREAT|O_EXCL|O_NOFOLLOW`, so nothing already there, including a planted symlink, is ever followed or replaced. Moves use
  `renameat2(RENAME_NOREPLACE)`. Across file systems a move is a full copy first; the original is removed only if it is still the
  same file afterwards and nothing inside it had to be skipped. Links inside folders are copied as links; sockets, FIFOs and
  devices are skipped and reported.
- **Stopping** a delivery removes whatever the current item had written so far and never touches an original.
- The folder chooser is Omarchy's own `omarchy-file-select` (the desktop portal).
- Every process has a deadline, and every output is capped before the shell reads it.

## Tests

```bash
node tests/model.test.js
bash tests/dropshelf.test.sh
```

## Notes

- Needs the built-in Omarchy bar. Under a replacement bar the shelf shows as unavailable.
- Only local files can be staged. Links dragged from a browser are counted and ignored.

MIT licensed.
