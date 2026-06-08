# VimQuest.nvim Design Notes

## Positioning

VimQuest.nvim is an offline Neovim learning plugin. It is not a standalone word-card plugin. The intended experience is closer to editing a temporary copy of a real project while solving English vocabulary tasks with Vim motions and edits.

The current MVP optimizes for:

- Practicing Vim navigation and editing.
- Learning English words, examples, synonyms, Chinese meanings, Japanese meanings, and core meanings.
- Never modifying the real project.
- Running fully offline from a local JSON word list.
- Keeping implementation simple enough to maintain inside this Neovim config.

## Current Gameplay

The user starts a round with:

```vim
:VimQuestStart
```

VimQuest then:

1. Saves the current editor context:
   - current working directory
   - current file
   - cursor position
2. Scans the current project for supported code/text files.
3. Skips ignored directories:
   - `.git`
   - `node_modules`
   - `dist`
   - `build`
   - `target`
4. Randomly copies 10 files into:

```text
~/.cache/vimquest/session-*/
```

5. Inserts 10 fill-in-the-blank tasks into those copied files.
6. Opens at least 5 random copied task files as Neovim tab pages.
7. Switches the current working directory to the temporary session directory.
8. Automatically jumps to the first task line.

From the user's point of view, they are editing project files, not a quiz sheet. Each task is a small comment block in the copied file: `Prev: file:line` sits above the answer line, `Next: file:line` sits below it, followed by a short Vim motion practice hint.

Example visible task line:

```js
// Prev: src/previous-task.js:18
// The ____ time I met you.
// Next: src/other-task.js:42
// Practice: gF, <C-o>, <C-i>, /____, ]q/[q
```

The user edits that line directly:

```js
// The first time I met you.
```

The user can move between tasks with:

- `qn` / `:VimQuestNext`
- `qp` / `:VimQuestPrev`
- `<leader>qt` / `:VimQuestTasks`
- `:VimQuestList` and quickfix motions
- `gF` on the path part of the `Prev: file:line` or `Next: file:line` reminders below a task
- `<C-o>` / `<C-i>` after jumps, `/____` search, and quickfix `]q` / `[q`
- normal Vim navigation across the opened tab pages
- searching for `____`

## Task Format

Each copied file receives one visible fill-in-the-blank sentence. The sentence is inserted as a comment using the file's comment syntax when possible:

- `--` for Lua/Vim-style files.
- `#` for Python, shell, YAML, TOML, and similar files.
- `//` for JavaScript/TypeScript/C-like files.
- `<!-- -->` for Markdown/HTML/XML.
- `/* */` for CSS/SCSS.

Example:

```lua
-- ____ here when you're ready.
```

The user edits the same line into the full expected sentence:

```lua
-- Come here when you're ready.
```

The plugin does not currently write visible metadata next to the task. It keeps the task file path and line number in memory for this session.

## Current Check Flow

The user checks the whole round with:

```vim
:VimQuestCheck
```

or:

```vim
<leader>qc
```

The plugin checks every task and opens a result report. Comparison currently ignores case and repeated whitespace.

For code-editing tasks:

- VimQuest reads the inserted answer line, falling back to the next non-metadata line.
- Open temporary buffers are saved before checking, so edited answers are included.

For input tasks:

- VimQuest prompts for each answer during the check.

After checking all tasks, VimQuest shows correct and wrong answers, then asks whether to start another round.

## Stop And Restore

The user exits VimQuest with:

```vim
:VimQuestStop
```

This restores:

- original working directory
- original file
- original cursor position

Then it deletes the temporary session directory.

The real project is never written by VimQuest. All task edits happen under `~/.cache/vimquest/session-*`.

## Commands

| Command | Purpose |
| --- | --- |
| `:VimQuestStart` | Start a new session and round. |
| `:VimQuestStop` | Restore the original project and remove the temp copy. |
| `:VimQuestNext` | Jump to the next task. |
| `:VimQuestPrev` | Jump to the previous task. |
| `:VimQuestNextRound` | Start another round in the original project. |
| `:VimQuestRestart` | Restart with a fresh set of tasks. |
| `:VimQuestTasks` | Open a Telescope picker for fuzzy task search and jump. |
| `:VimQuestList` | Populate the quickfix list with all task locations. |
| `:VimQuestCheck` | Check the whole round and show the result report. |
| `:VimQuestHint` | Show the requirement and hint for the task under the cursor. |
| `:VimQuestStats` | Show current round progress. |
| `:VimQuestWords` | Open the continuous word typing drill. |

## Keymaps

| Key | Purpose |
| --- | --- |
| `<leader>qs` | Start VimQuest. |
| `qn` | Jump to next task. |
| `qp` | Jump to previous task. |
| `<leader>qr` | Restart with new tasks. |
| `<leader>qN` | Start another round. |
| `<leader>qt` | Search tasks with Telescope. |
| `<leader>ql` | Open the quickfix task list. |
| `<leader>qc` | Check the whole round. |
| `<leader>qh` | Show hint. |
| `<leader>qw` | Open word typing drill. |
| `<leader>qS` | Show stats. |
| `K` | In a VimQuest session, show hint for the task under cursor; otherwise fall back to LSP hover. |

## Word Drill

`:VimQuestWords` opens a borderless narrow two-line popup at the bottom left. The first line is an input line with completion disabled. The second line shows English, Japanese, then Chinese. Pressing Enter verifies the input; correct input advances to another random word. Correctly entered words are stored in `stdpath("data")/vimquest/words_seen.json`; practiced words use the `Comment` highlight but still remain eligible for random practice. Typing `/exit` closes the popup. Right-drag inside the popup moves it, and the moved position is remembered for the current Neovim session.

## Task Types

All six task types are active. Tasks are distributed round-robin across types during a round.

### Fill

Uses `w`, `zh`, and `ex`.

The example sentence is blanked:

```text
____ here when you're ready.
```

The user edits it into:

```text
Come here when you're ready.
```

### Replace

Uses `s`, `w`, and `ex`.

A synonym replaces the core word:

```text
arrive here when you're ready.
```

The user edits it into:

```text
come here when you're ready.
```

This is meant to encourage `ciw`, `cw`, `:s`, and similar Vim edits.

### Delete

Uses `w` and `ex`.

A duplicate word is inserted:

```text
Come come here when you're ready.
```

The user deletes the extra word:

```text
Come here when you're ready.
```

This is meant to encourage `dw`, `de`, `x`, and related deletion motions.

### Meaning

Uses `core`.

The task shows the Chinese core meaning as a comment. During `:VimQuestCheck`, the user types the English word in the input prompt.

### Japanese Meaning

Uses `ja`.

The task shows the Japanese meaning as a comment. During `:VimQuestCheck`, the user types the English word in the input prompt.

### Example Translation

Uses `exj`.

The task shows the Japanese example translation as a comment. During `:VimQuestCheck`, the user guesses the core English word in the input prompt.

## Hint System

When the cursor is on a task line, `K` or `:VimQuestHint` opens a floating window.

The current hint is intentionally short. It includes:

- task requirement
- blank sentence
- answer word
- Chinese meaning
- English example
- Chinese core meaning

The hint is task-aware by file path and line number. If the cursor is not exactly on a task line, the plugin falls back to the current task index.

## Implementation Structure

Current files:

```text
config/nvim/lua/plugins/vimquest.lua
config/nvim/lua/vimquest/init.lua
config/nvim/lua/vimquest/data/ogden-850-words.json
config/nvim/lua/vimquest/docs/design.md
```

`lua/plugins/vimquest.lua` registers the local plugin through lazy.nvim:

```lua
return {
  dir = vim.fn.stdpath("config"),
  name = "VimQuest.nvim",
  lazy = false,
  config = function()
    require("vimquest").setup()
  end,
}
```

`lua/vimquest/init.lua` owns the runtime:

- session state
- project scan
- file copy
- task generation
- task insertion
- navigation
- checking
- hint window
- stats
- command/keymap registration

The implementation intentionally avoids external Lua dependencies. It uses Neovim APIs, `vim.json`, filesystem APIs, and the local JSON word list.

## State Model

The plugin keeps in-memory state for one active session:

- `active`: whether VimQuest is running.
- `original`: saved cwd/file/cursor.
- `session_dir`: temp project copy path.
- `tasks`: generated tasks, expected answers, file locations, and inserted line numbers.
- `current`: current task index for `:VimQuestNext`.
- `correct` / `wrong`: current round stats.
- `checked`: per-task check result.
- `words`: cached decoded word list.

This is intentionally not persisted across Neovim restarts in the MVP.

## Safety Boundary

The most important invariant is:

VimQuest must never edit the source project after `:VimQuestStart`.

The implementation enforces this by:

1. Scanning the source project only to choose files.
2. Copying selected files into `~/.cache/vimquest/session-*`.
3. Switching Neovim cwd to the copied session.
4. Inserting task lines only into copied files.
5. Restoring the original cwd/file/cursor on stop.
6. Deleting the copied session directory on stop or next round.

## Current MVP Limits

- The task insertion point is random and may land inside code blocks, strings, or syntax-sensitive regions. This is acceptable for MVP because files are temporary copies, but a later version can insert near safer boundaries.
- The checker reads inserted task lines stored in memory, and prompts for input-task answers during the full-round check.
- Task locations are memory-only. If the user inserts or deletes lines above a task, the stored line number may become stale in the current MVP.
- Round state is memory-only and is lost if Neovim exits unexpectedly.
- Opened files are currently shown as tab pages. This is simple and visible, but a future version could use buffers, quickfix, or a custom task list.

## Possible Next Steps

- Open 8 or 10 files by default instead of 5.
- Refresh task line tracking after edits above inserted task lines.
- Add safer insertion strategies per filetype.
- Add per-word memory or spaced repetition later, still offline.
- Add a session recovery command for stale temp directories.
- Add a config option for language emphasis: Chinese, Japanese, or mixed.
