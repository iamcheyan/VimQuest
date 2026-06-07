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

5. Inserts 10 vocabulary tasks into those copied files.
6. Opens at least 5 random copied task files as Neovim tab pages.
7. Switches the current working directory to the temporary session directory.

From the user's point of view, they are editing project files, not a quiz sheet. The task is to move around the temporary project, find `VIMQUEST TASK` comment blocks, edit the answer line, and then submit the round.

The user can search for tasks with normal Vim/project tools, for example:

```vim
/VIMQUEST TASK
:vimgrep /VIMQUEST TASK/ **/*
```

or any configured picker/grep workflow.

## Task Format

Each copied file receives one comment block. The comment syntax depends on the file extension when possible:

- `--` for Lua/Vim-style files.
- `#` for Python, shell, YAML, TOML, and similar files.
- `//` for JavaScript/TypeScript/C-like files.
- `<!-- -->` for Markdown/HTML/XML.
- `/* */` for CSS/SCSS.

Example:

```lua
-- ==========================================================
-- VIMQUEST TASK Q01-123456 [1/10] Fill
-- 补全表示 "来,前来" 的英文单词。
-- Answer:
-- ____ here when you're ready.
-- Find this task, edit the Answer line, then run :VimQuestCheck.
-- END VIMQUEST TASK Q01-123456
-- ==========================================================
```

The user edits only the line after `Answer:`.

For edit-style tasks, the answer line is a full sentence that should be edited into the expected sentence. For meaning-style tasks, the answer line starts empty and should become the target English word.

## Round Submission

The user submits the whole round with:

```vim
:VimQuestCheck
```

The plugin scans every task block in the copied files and compares the edited answer line with the expected answer. Comparison currently ignores case and repeated whitespace.

After checking, VimQuest shows a floating result window:

- progress
- correct count
- wrong count
- per-task expected answer

In an interactive Neovim UI, the plugin then asks whether to start the next round.

If the user chooses the next round:

1. The old temporary session directory is deleted.
2. The original project cwd remains the source.
3. A fresh batch of random files is copied.
4. New tasks are inserted.
5. Multiple task files are opened again.

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
| `:VimQuestNext` | Jump to the next known task file/block. |
| `:VimQuestCheck` | Submit the round and show results. |
| `:VimQuestHint` | Show the word hint for the task under the cursor. |
| `:VimQuestStats` | Show current round progress. |

## Keymaps

| Key | Purpose |
| --- | --- |
| `<leader>qs` | Start VimQuest. |
| `<leader>qx` | Stop VimQuest. |
| `<leader>qn` | Jump to next task. |
| `<leader>qc` | Check all answers. |
| `<leader>qh` | Show hint. |
| `<leader>qt` | Show stats. |
| `K` | In a VimQuest session, show hint for the task under cursor; otherwise fall back to LSP hover. |

## Task Types

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

The task shows the Chinese core meaning. The user enters the English word.

### Japanese Meaning

Uses `ja`.

The task shows the Japanese meaning. The user enters the English word.

### Example Translation

Uses `exj`.

The task shows the Japanese example translation. The user guesses the core English word.

## Hint System

When the cursor is inside a task block, `K` or `:VimQuestHint` opens a floating window.

The hint includes:

- Word
- Chinese meaning
- Japanese meaning
- English definition
- English example
- Chinese example translation
- Japanese example translation
- Chinese core meaning

The hint is task-aware: it tries to find the task block under the current cursor and shows the matching word entry.

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
- `tasks`: generated tasks and their file locations.
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
4. Inserting task blocks only into copied files.
5. Restoring the original cwd/file/cursor on stop.
6. Deleting the copied session directory on stop or next round.

## Current MVP Limits

- The task insertion point is random and may land inside code blocks, strings, or syntax-sensitive regions. This is acceptable for MVP because files are temporary copies, but a later version can insert near safer boundaries.
- The checker only reads the single line after `Answer:`.
- `:VimQuestCheck` checks the whole round, not one task at a time.
- Round state is memory-only and is lost if Neovim exits unexpectedly.
- Opened files are currently shown as tab pages. This is simple and visible, but a future version could use buffers, quickfix, or a custom task list.

## Possible Next Steps

- Open 8 or 10 files by default instead of 5.
- Add a quickfix list containing all task locations.
- Add `:VimQuestList` to jump between tasks.
- Add safer insertion strategies per filetype.
- Add per-word memory or spaced repetition later, still offline.
- Add a session recovery command for stale temp directories.
- Add a config option for language emphasis: Chinese, Japanese, or mixed.
