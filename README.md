# VimQuest.nvim

A Neovim plugin that turns your codebase into an English vocabulary quiz. VimQuest copies code files from your project, injects word puzzles as comments, and lets you practice vocabulary without leaving your editor.

## How It Works

1. VimQuest scans your project and randomly selects code files
2. Copies them to a temporary session directory
3. Injects vocabulary tasks as code comments (fill-in-the-blank, synonym replacement, etc.)
4. Adds `Prev: file:line`, `Next: file:line`, and short Vim motion practice hints below each task
5. You edit the answer lines directly in the code, then check your results
6. After the round, you can start a new round or restore your original project

## Task Types

| Type | Description |
|------|-------------|
| **Fill** | Complete a sentence with the missing English word (given Chinese meaning) |
| **Replace** | Replace a synonym back to the core word |
| **Delete** | Remove the redundant word from a sentence |
| **Meaning** | Type the English word from its Chinese definition |
| **Japanese Meaning** | Type the English word from its Japanese definition |
| **Example Translation** | Guess the word from a Japanese example sentence |

## Installation

### lazy.nvim

```lua
{
  dir = vim.fn.stdpath("config"),
  name = "VimQuest.nvim",
  lazy = false,
  config = function()
    require("vimquest").setup()
  end,
}
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:VimQuestStart` | Start a new quiz round |
| `:VimQuestStop` | Stop and restore the original project |
| `:VimQuestNext` | Jump to the next task |
| `:VimQuestPrev` | Jump to the previous task |
| `:VimQuestNextRound` | Start another round in the original project |
| `:VimQuestRestart` | Restart with a fresh set of tasks |
| `:VimQuestTasks` | Search and jump to any task with Telescope |
| `:VimQuestList` | Put all tasks in the quickfix list |
| `:VimQuestCheck` | Check the whole round and show the result report |
| `:VimQuestHint` | Show hint for the task at cursor |
| `:VimQuestStats` | Show current round statistics |
| `:VimQuestWords` | Open the continuous word typing drill |

### Keymaps (default)

| Key | Action |
|-----|--------|
| `<leader>qs` | Start |
| `qn` | Next task |
| `qp` | Previous task |
| `<leader>qr` | Restart with new tasks |
| `<leader>qN` | Next round |
| `<leader>qt` | Search tasks |
| `<leader>ql` | Quickfix task list |
| `<leader>qc` | Check all answers |
| `<leader>qh` | Show hint |
| `<leader>qw` | Word typing drill |
| `<leader>qS` | Show stats |
| `K` | Show hint (when in active session) or LSP hover |

### Word Drill

`:VimQuestWords` opens a borderless two-line popup at the bottom left. Completion is disabled in that input buffer. Right-drag inside the popup to move it; the position is remembered for the current Neovim session. Type the shown word on the first line and press Enter to verify it. The second line shows English, Japanese, then Chinese. Correctly entered words are recorded under `stdpath("data")/vimquest/words_seen.json`; practiced words are shown with the `Comment` highlight but remain in the random pool. Type `/exit` to close it.

## Configuration

```lua
require("vimquest").setup({
  task_count = 10,          -- number of tasks per round
  copy_file_count = 10,     -- number of files to copy
  wordlist = "lua/vimquest/data/ogden-850-words.json",
  words_popup = {
    row = nil,              -- nil means bottom; negative values count from bottom
    col = 1,                -- negative values count from right
  },
  exclude_dirs = {          -- directories to skip
    [".git"] = true,
    ["node_modules"] = true,
  },
  code_extensions = {       -- file extensions to include
    lua = true, js = true, ts = true, py = true,
    -- ... see defaults for full list
  },
})
```

## Word List

The default word list is based on Ogden's Basic English (850 words), with Chinese and Japanese translations, example sentences, synonyms, and core meanings.

## Requirements

- Neovim >= 0.8
