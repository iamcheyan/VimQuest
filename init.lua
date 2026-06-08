local M = {}

local uv = vim.uv or vim.loop

local state = {
  active = false,
  original = nil,
  session_dir = nil,
  tasks = {},
  current = 0,
  correct = 0,
  wrong = 0,
  checked = {},
  results = {},
  words = nil,
  drill = nil,
  drill_position = nil,
  seen_words = nil,
}

local defaults = {
  task_count = 10,
  copy_file_count = 10,
  open_file_count = 5,
  wordlist = "lua/vimquest/data/ogden-850-words.json",
  words_popup = {
    row = nil,
    col = 1,
  },
  exclude_dirs = {
    [".git"] = true,
    ["node_modules"] = true,
    ["dist"] = true,
    ["build"] = true,
    ["target"] = true,
  },
  code_extensions = {
    lua = true,
    vim = true,
    js = true,
    jsx = true,
    ts = true,
    tsx = true,
    json = true,
    md = true,
    py = true,
    rb = true,
    go = true,
    rs = true,
    c = true,
    h = true,
    cpp = true,
    hpp = true,
    java = true,
    sh = true,
    zsh = true,
    fish = true,
    css = true,
    scss = true,
    html = true,
    yml = true,
    yaml = true,
    toml = true,
  },
}

local config = vim.deepcopy(defaults)

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "VimQuest.nvim" })
end

local function join(...)
  local path = table.concat({ ... }, "/"):gsub("//+", "/")
  return path
end

local function exists(path)
  return uv.fs_stat(path) ~= nil
end

local function shuffle(items)
  math.randomseed(os.time() + math.floor(uv.hrtime() % 100000))
  for i = #items, 2, -1 do
    local j = math.random(i)
    items[i], items[j] = items[j], items[i]
  end
  return items
end

local function read_json(path)
  local lines = vim.fn.readfile(path)
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    error("invalid JSON wordlist: " .. path)
  end
  return decoded
end

local function wordlist_path()
  local runtime_paths = vim.api.nvim_get_runtime_file(config.wordlist, false)
  if runtime_paths[1] then
    return runtime_paths[1]
  end
  return join(vim.fn.stdpath("config"), config.wordlist)
end

local function available_dictionaries()
  local sample_path = vim.api.nvim_get_runtime_file("lua/vimquest/data/ogden-850-words.json", false)
  local data_dir
  if sample_path[1] then
    data_dir = sample_path[1]:match("^(.+)/[^/]+$")
  else
    data_dir = join(vim.fn.stdpath("config"), "lua", "vimquest", "data")
  end
  if not exists(data_dir) then
    return {}
  end
  local dicts = {}
  local handle = uv.fs_scandir(data_dir)
  if not handle then
    return {}
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" and name:match("%.json$") then
      local label = name:gsub("%.json$", ""):gsub("^ogden%-850%-words%-?", "")
      if label == "" then
        label = "default"
      end
      table.insert(dicts, {
        label = label,
        file = name,
        path = "lua/vimquest/data/" .. name,
      })
    end
  end
  table.sort(dicts, function(a, b)
    return a.label < b.label
  end)
  return dicts
end

local function load_words()
  if state.words then
    return state.words
  end
  local path = wordlist_path()
  if not exists(path) then
    error("wordlist not found: " .. path)
  end
  state.words = read_json(path)
  return state.words
end

local function should_skip(path)
  for part in path:gmatch("[^/]+") do
    if config.exclude_dirs[part] then
      return true
    end
  end
  return false
end

local function is_code_file(path)
  local ext = path:match("%.([%w_%-]+)$")
  return ext and config.code_extensions[ext] or false
end

local function scan_project(root)
  local files = {}
  local function walk(dir)
    local handle = uv.fs_scandir(dir)
    if not handle then
      return
    end
    while true do
      local name, typ = uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local path = join(dir, name)
      local rel = path:sub(#root + 2)
      if not should_skip(rel) then
        if typ == "directory" then
          walk(path)
        elseif typ == "file" and is_code_file(path) then
          table.insert(files, rel)
        end
      end
    end
  end
  walk(root)
  return shuffle(files)
end

local function copy_files(root, session_dir, files)
  local copied = {}
  for i = 1, math.min(#files, config.copy_file_count) do
    local rel = files[i]
    local src = join(root, rel)
    local dst = join(session_dir, rel)
    vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")
    vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
    table.insert(copied, rel)
  end
  return copied
end

local function sentence_with_word(entry)
  local ex = entry.ex or entry.w
  return ex:gsub("^%s+", ""):gsub("%s+$", "")
end

local function replace_word_once(text, from, to)
  return text:gsub("(%f[%a])" .. vim.pesc(from) .. "(%f[%A])", to, 1)
end

local function blank_word_once(text, word)
  return replace_word_once(text, word:gsub("^%l", string.upper), "____")
    :gsub("(%f[%a])" .. vim.pesc(word) .. "(%f[%A])", "____", 1)
end

local task_builders = {
  fill = function(entry)
    local expected = blank_word_once(sentence_with_word(entry), entry.w)
    return {
      type = "Fill",
      prompt = string.format('补全表示 "%s" 的英文单词。', entry.zh or ""),
      editable = expected,
      expected = sentence_with_word(entry),
      answer = entry.w,
      entry = entry,
    }
  end,
  replace = function(entry)
    local synonyms = entry.s or {}
    if #synonyms == 0 then
      return nil
    end
    local synonym = synonyms[math.random(#synonyms)]
    local ex = sentence_with_word(entry):gsub("^%u", string.lower)
    return {
      type = "Replace",
      prompt = "把近义词替换成核心词。",
      editable = replace_word_once(ex, entry.w, "{{" .. synonym .. "}}"),
      expected = ex,
      answer = entry.w,
      entry = entry,
    }
  end,
  delete = function(entry)
    local ex = sentence_with_word(entry)
    local word = ex:match("^(%a+)")
    local editable = word and ex:gsub("^" .. vim.pesc(word), word .. " " .. word:gsub("^%u", string.lower), 1)
      or (entry.w .. " " .. ex)
    return {
      type = "Delete",
      prompt = "删除多余单词。",
      editable = editable,
      expected = ex,
      answer = entry.w,
      entry = entry,
    }
  end,
  meaning = function(entry)
    return {
      type = "Meaning",
      prompt = "根据中文核心概念输入对应英文。",
      display = entry.core or entry.zh or "",
      editable = "",
      expected = entry.w,
      answer = entry.w,
      entry = entry,
    }
  end,
  japanese_meaning = function(entry)
    return {
      type = "Japanese Meaning",
      prompt = "根据日语释义输入英文。",
      display = entry.ja or "",
      editable = "",
      expected = entry.w,
      answer = entry.w,
      entry = entry,
    }
  end,
  example_translation = function(entry)
    return {
      type = "Example Translation",
      prompt = "根据日语例句翻译猜测核心单词。",
      display = entry.exj or "",
      editable = "",
      expected = entry.w,
      answer = entry.w,
      entry = entry,
    }
  end,
}

local active_task_builders = {
  task_builders.fill,
  task_builders.replace,
  task_builders.delete,
  task_builders.meaning,
  task_builders.japanese_meaning,
  task_builders.example_translation,
}

local function build_tasks(excluded_words)
  local words = shuffle(vim.deepcopy(load_words()))
  local tasks = {}
  local builder_index = 1
  for _, entry in ipairs(words) do
    if not (excluded_words and excluded_words[entry.w]) then
      local task = active_task_builders[builder_index](entry)
      builder_index = builder_index % #active_task_builders + 1
      if task then
        table.insert(tasks, task)
      end
      if #tasks >= config.task_count then
        break
      end
    end
  end
  return tasks
end

local function comment_style(path)
  local ext = path:match("%.([%w_%-]+)$") or ""
  if vim.tbl_contains({ "lua", "vim", "sql" }, ext) then
    return "--", ""
  end
  if vim.tbl_contains({ "py", "rb", "sh", "zsh", "fish", "yml", "yaml", "toml" }, ext) then
    return "#", ""
  end
  if vim.tbl_contains({ "html", "xml", "md" }, ext) then
    return "<!--", "-->"
  end
  if vim.tbl_contains({ "css", "scss" }, ext) then
    return "/*", "*/"
  end
  return "//", ""
end

local function comment_line(path, text)
  local prefix, suffix = comment_style(path)
  if text == "" then
    return prefix .. (suffix ~= "" and " " .. suffix or "")
  end
  return prefix .. " " .. text .. (suffix ~= "" and " " .. suffix or "")
end

local function strip_comment(path, line)
  local prefix, suffix = comment_style(path)
  local text = line or ""
  text = text:gsub("^%s+", "")
  if prefix ~= "" then
    text = text:gsub("^" .. vim.pesc(prefix) .. "%s?", "", 1)
  end
  if suffix ~= "" then
    text = text:gsub("%s?" .. vim.pesc(suffix) .. "%s*$", "")
  end
  return text
end

local input_task_types = {
  ["Meaning"] = true,
  ["Japanese Meaning"] = true,
  ["Example Translation"] = true,
}

local function is_input_task(task)
  return input_task_types[task.type] or false
end

local function task_jump_text(task, label)
  return string.format("%s: %s:%d", label, task.file, task.answer_line)
end

local function task_block(task, index, total)
  local rel = task.file
  local lines
  if is_input_task(task) then
    lines = {
      comment_line(rel, "Prev: pending"),
      comment_line(rel, "[Guess] " .. (task.display or task.editable)),
    }
  else
    lines = {
      comment_line(rel, "Prev: pending"),
      comment_line(rel, task.editable),
    }
  end
  table.insert(lines, comment_line(rel, "Next: pending"))
  table.insert(lines, comment_line(rel, "Practice: gF, <C-o>, <C-i>, /____, ]q/[q"))
  return lines
end

local function set_task_jump_hints(session_dir, tasks)
  for index, task in ipairs(tasks) do
    local prev_task = tasks[(index - 2) % #tasks + 1]
    local next_task = tasks[index % #tasks + 1]
    local path = join(session_dir, task.file)
    local lines = vim.fn.readfile(path)
    lines[task.answer_line - 1] = comment_line(task.file, task_jump_text(prev_task, "Prev"))
    lines[task.answer_line + 1] = comment_line(task.file, task_jump_text(next_task, "Next"))
    vim.fn.writefile(lines, path)
  end
end

local function insert_tasks_into_files(session_dir, files, tasks)
  local usable = math.min(#files, #tasks)
  for i = 1, usable do
    local task = tasks[i]
    local rel = files[i]
    task.file = rel
    task.id = string.format("Q%02d-%06d", i, math.random(999999))

    local path = join(session_dir, rel)
    local lines = vim.fn.readfile(path)
    local insert_at = #lines > 0 and math.random(1, #lines) or 1
    task.answer_line = insert_at + 1
    local block = task_block(task, i, usable)
    for offset, line in ipairs(block) do
      table.insert(lines, insert_at + offset - 1, line)
    end
    vim.fn.writefile(lines, path)
  end

  while #tasks > usable do
    table.remove(tasks)
  end

  set_task_jump_hints(session_dir, tasks)
end

local function ensure_active()
  if not state.active then
    notify("No active VimQuest session. Run :VimQuestStart first.", vim.log.levels.WARN)
    return false
  end
  return true
end

local function open_task(index)
  local task = state.tasks[index]
  if not task then
    return
  end
  local path = join(state.session_dir, task.file)
  vim.cmd.edit(vim.fn.fnameescape(path))
  pcall(vim.api.nvim_win_set_cursor, 0, { task.answer_line, 0 })
  vim.cmd.normal({ args = { "zz" }, bang = true })
  notify(string.format("Task %d/%d | %s", index, #state.tasks, task.file))
end

local function open_round_files()
  local tasks = shuffle(vim.deepcopy(state.tasks))
  local count = math.min(#tasks, math.max(5, config.open_file_count))
  local first = tasks[1]
  if not first then
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(join(state.session_dir, first.file)))
  for i = 2, count do
    vim.cmd.tabedit(vim.fn.fnameescape(join(state.session_dir, tasks[i].file)))
  end
  vim.cmd.tabfirst()
end

local function normalize(text)
  return (text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "):lower()
end

local function buffer_lines_for(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  return vim.fn.readfile(path)
end

local function answer_for_task(task)
  local path = join(state.session_dir, task.file)
  local lines = buffer_lines_for(path)
  return strip_comment(task.file, lines[task.answer_line])
end

local function next_line_answer_for_task(task)
  local path = join(state.session_dir, task.file)
  local lines = buffer_lines_for(path)
  for line_number = task.answer_line + 1, #lines do
    local next = lines[line_number]
    local text = strip_comment(task.file, next)
    if not (text:match("^Prev: .+:%d+$") or text:match("^Next: .+:%d+$") or text:match("^Practice: ")) then
      return text
    end
  end
  return nil
end

local function task_at_cursor()
  if not state.active then
    return nil
  end
  local current = vim.api.nvim_buf_get_name(0)
  if current == "" then
    return nil
  end
  local rel = vim.fn.fnamemodify(current, ":.")
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, task in ipairs(state.tasks) do
    if task.file == rel and row == task.answer_line then
      return task
    end
  end
  return state.tasks[state.current]
end

local function task_index(target)
  for i, task in ipairs(state.tasks) do
    if task == target then
      return i
    end
  end
  return state.current
end

local function task_status(index)
  if state.checked[index] == nil then
    return "todo"
  end
  return state.checked[index] and "ok" or "wrong"
end

local function task_label(index, task)
  return string.format(
    "%02d/%02d [%s] %s:%d %s",
    index,
    #state.tasks,
    task.type,
    task.file,
    task.answer_line,
    task_status(index)
  )
end

local function task_search_text(index, task)
  local entry = task.entry or {}
  return table.concat({
    task_label(index, task),
    task.prompt or "",
    task.expected or "",
    task.answer or "",
    entry.w or "",
    entry.zh or "",
    entry.ja or "",
    entry.en or "",
  }, " ")
end

local function recompute_stats()
  state.correct = 0
  state.wrong = 0
  for _, correct in pairs(state.checked) do
    if correct then
      state.correct = state.correct + 1
    else
      state.wrong = state.wrong + 1
    end
  end
end

local function wipe_temp_buffers(session_dir)
  if not session_dir then
    return
  end
  local prefix = session_dir:gsub("/$", "") .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:sub(1, #prefix) == prefix then
      pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

local function cleanup_old_sessions()
  local cache_dir = vim.fn.expand("~/.cache/vimquest")
  if vim.fn.isdirectory(cache_dir) == 0 then
    return
  end
  for _, entry in ipairs(vim.fn.readdir(cache_dir)) do
    if entry:match("^session%-") then
      vim.fn.delete(join(cache_dir, entry), "rf")
    end
  end
end

local function start_session(cwd, original, excluded_words)
  local session_dir = join(
    vim.fn.expand("~/.cache"),
    "vimquest",
    string.format("session-%s-%06d", os.date("%Y%m%d-%H%M%S"), math.floor(uv.hrtime() % 1000000))
  )

  local ok, err = pcall(function()
    vim.fn.mkdir(session_dir, "p")
    local files = scan_project(cwd)
    local copied = copy_files(cwd, session_dir, files)
    if #copied == 0 then
      error("no supported code files found in project")
    end
    local tasks = build_tasks(excluded_words)
    if #tasks == 0 then
      error("no tasks generated from wordlist")
    end
    insert_tasks_into_files(session_dir, copied, tasks)
    state.active = true
    state.original = original
    state.session_dir = session_dir
    state.tasks = tasks
    state.current = 1
    state.correct = 0
    state.wrong = 0
    state.checked = {}
    state.results = {}
  end)

  if not ok then
    vim.fn.delete(session_dir, "rf")
    notify("Start failed: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  vim.cmd.tcd(vim.fn.fnameescape(session_dir))
  open_round_files()
  state.current = 1
  open_task(1)
  notify(
    string.format(
      "Round started: %d tasks inserted. %d files opened. Use qn to navigate.",
      #state.tasks,
      math.min(#state.tasks, math.max(5, config.open_file_count))
    )
  )
end

local function task_answer_set(tasks)
  local answers = {}
  for _, task in ipairs(tasks or {}) do
    if task.answer then
      answers[task.answer] = true
    end
  end
  return answers
end

function M.start()
  if state.active then
    notify("VimQuest session is already active.", vim.log.levels.WARN)
    return
  end

  cleanup_old_sessions()

  start_session(vim.fn.getcwd(), {
    cwd = vim.fn.getcwd(),
    file = vim.api.nvim_buf_get_name(0),
    cursor = vim.api.nvim_win_get_cursor(0),
  })
end

function M.stop()
  if not ensure_active() then
    return
  end

  local original = state.original
  local session_dir = state.session_dir
  state.active = false
  state.original = nil
  state.session_dir = nil
  state.tasks = {}
  state.current = 0
  state.checked = {}
  state.results = {}

  if original and original.cwd then
    vim.cmd.tcd(vim.fn.fnameescape(original.cwd))
  end
  wipe_temp_buffers(session_dir)
  if original and original.file and original.file ~= "" and exists(original.file) then
    vim.cmd.edit(vim.fn.fnameescape(original.file))
    pcall(vim.api.nvim_win_set_cursor, 0, original.cursor)
  end
  if session_dir then
    vim.fn.delete(session_dir, "rf")
  end
  notify("VimQuest session stopped. Original project restored.")
end

function M.next()
  if not ensure_active() then
    return
  end
  state.current = state.current % #state.tasks + 1
  open_task(state.current)
end

function M.prev()
  if not ensure_active() then
    return
  end
  state.current = (state.current - 2) % #state.tasks + 1
  open_task(state.current)
end

function M.list()
  if not ensure_active() then
    return
  end

  local items = {}
  for index, task in ipairs(state.tasks) do
    table.insert(items, {
      filename = join(state.session_dir, task.file),
      lnum = task.answer_line,
      col = 1,
      text = task_label(index, task),
    })
  end
  vim.fn.setqflist({}, " ", {
    title = "VimQuest Tasks",
    items = items,
  })
  vim.cmd.copen()
  notify(string.format("Loaded %d VimQuest tasks into quickfix.", #items))
end

function M.tasks()
  if not ensure_active() then
    return
  end

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    notify("Telescope is not available.", vim.log.levels.WARN)
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local results = {}
  for index, task in ipairs(state.tasks) do
    table.insert(results, {
      index = index,
      task = task,
      display = task_label(index, task),
      ordinal = task_search_text(index, task),
    })
  end

  pickers
    .new({}, {
      prompt_title = "VimQuest Tasks",
      finder = finders.new_table({
        results = results,
        entry_maker = function(entry)
          return {
            value = entry,
            display = entry.display,
            ordinal = entry.ordinal,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local selection = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not selection then
            return
          end
          state.current = selection.value.index
          open_task(state.current)
        end)
        return true
      end,
    })
    :find()
end

function M.next_round()
  if not ensure_active() then
    return
  end

  local original = state.original
  local old_session_dir = state.session_dir
  local excluded_words = task_answer_set(state.tasks)
  state.active = false
  state.session_dir = nil
  state.tasks = {}
  state.current = 0
  state.correct = 0
  state.wrong = 0
  state.checked = {}
  state.results = {}

  if old_session_dir then
    wipe_temp_buffers(old_session_dir)
    vim.fn.delete(old_session_dir, "rf")
  end
  start_session(original.cwd, original, excluded_words)
end

local function show_round_report()
  local done = state.correct + state.wrong
  local accuracy = #state.tasks > 0 and math.floor((state.correct / #state.tasks) * 100 + 0.5) or 0
  local lines = {
    "VimQuest Round Result",
    "",
    string.format("Progress %d/%d", done, #state.tasks),
    string.format("Correct %d", state.correct),
    string.format("Wrong %d", state.wrong),
    string.format("Accuracy %d%%", accuracy),
    "",
    "Answers:",
  }
  for index, task in ipairs(state.tasks) do
    local correct = state.checked[index] == true
    local result = state.results[index] or {}
    local actual = result.actual or ""
    table.insert(
      lines,
      string.format(
        "%02d. %s [%s] %s:%d",
        index,
        correct and "OK" or "NO",
        task.type,
        task.file,
        task.answer_line
      )
    )
    table.insert(lines, string.format("    Your answer: %s", actual ~= "" and actual or "(empty)"))
    table.insert(lines, string.format("    Expected: %s", task.expected or ""))
  end

  local width = math.min(92, math.max(50, vim.o.columns - 8))
  local height = math.min(#lines, math.max(10, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = "single",
    title = " VimQuest Result ",
    style = "minimal",
  })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  return win
end

local function prompt_next_round(report_win)
  vim.ui.select({ "Yes", "No" }, { prompt = "Start a new VimQuest round?" }, function(choice)
    if report_win and vim.api.nvim_win_is_valid(report_win) then
      pcall(vim.api.nvim_win_close, report_win, true)
    end
    if choice == "Yes" then
      M.next_round()
    else
      notify("Round complete. Run :VimQuestNextRound or :VimQuestStop when ready.")
    end
  end)
end

local function complete_round()
  local report_win = show_round_report()
  prompt_next_round(report_win)
end

local function check_replace(task, actual)
  local cleaned = actual:gsub("%{%{", ""):gsub("%}%}", "")
  if normalize(cleaned) == normalize(task.expected) then
    return true
  end
  local word = task.answer
  local synonyms = task.entry.s or {}
  local pattern = "(%f[%a])" .. vim.pesc(word) .. "(%f[%A])"
  local replaced = cleaned:match(pattern)
  if replaced and normalize(replaced) == normalize(word) then
    return true
  end
  for _, syn in ipairs(synonyms) do
    local pat = "(%f[%a])" .. vim.pesc(syn) .. "(%f[%A])"
    if cleaned:match(pat) then
      local without = cleaned:gsub(pat, "____", 1)
      local expected_without = task.expected:gsub(pattern, "____", 1)
      if normalize(without) == normalize(expected_without) then
        return true
      end
    end
  end
  return false
end


local function check_task(task)
  local actual, correct
  if is_input_task(task) then
    actual = vim.fn.input(string.format("%s [%s] > ", task.type, task.prompt or task.expected or ""))
    correct = normalize(actual) == normalize(task.expected)
  elseif task.type == "Replace" then
    actual = answer_for_task(task)
    correct = actual ~= nil and check_replace(task, actual)
    if not correct then
      actual = next_line_answer_for_task(task)
      correct = actual ~= nil and check_replace(task, actual)
    end
  else
    actual = answer_for_task(task)
    correct = actual ~= nil and normalize(actual) == normalize(task.expected)
    if not correct then
      actual = next_line_answer_for_task(task)
      correct = actual ~= nil and normalize(actual) == normalize(task.expected)
    end
  end
  return actual, correct == true
end

local function save_session_buffers()
  if not state.session_dir then
    return
  end
  local prefix = state.session_dir:gsub("/$", "") .. "/"
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name:sub(1, #prefix) == prefix and vim.api.nvim_buf_is_loaded(bufnr) then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd.silent("write")
      end)
    end
  end
end

function M.check()
  if not ensure_active() then
    return
  end

  save_session_buffers()

  for index, task in ipairs(state.tasks) do
    local actual, correct = check_task(task)
    state.checked[index] = correct
    state.results[index] = {
      actual = actual,
      correct = correct,
    }
  end
  state.current = #state.tasks
  recompute_stats()

  notify(
    string.format(
      "Round checked. Correct %d | Wrong %d | Accuracy %d%%",
      state.correct,
      state.wrong,
      math.floor((state.correct / #state.tasks) * 100 + 0.5)
    )
  )
  complete_round()
end

function M.check_current()
  if not ensure_active() then
    return
  end

  local task = task_at_cursor()
  local index = task_index(task)
  state.current = index
  local actual, correct = check_task(task)
  state.checked[index] = correct
  state.results[index] = {
    actual = actual,
    correct = correct,
  }
  recompute_stats()
  local done = state.correct + state.wrong

  if correct then
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = vim.api.nvim_get_current_buf() })
  end

  if done >= #state.tasks then
    notify(
      string.format(
        "Round complete. Correct %d | Wrong %d | Accuracy %d%%",
        state.correct,
        state.wrong,
        math.floor((state.correct / #state.tasks) * 100 + 0.5)
      )
    )
    complete_round()
  elseif correct then
    notify(string.format("Correct. Moving to %d/%d.", index % #state.tasks + 1, #state.tasks))
    state.current = index
    M.next()
  else
    notify("Wrong. Stay here and try again.", vim.log.levels.WARN)
  end
end

function M.hint()
  if not ensure_active() then
    return
  end
  local task = task_at_cursor()
  if not task then
    notify("No VimQuest task found here.", vim.log.levels.WARN)
    return
  end
  local entry = task.entry
  local use_ja = math.random() > 0.5
  local synonyms = entry.s and table.concat(entry.s, ", ") or ""
  local lines = {
    "**" .. (entry.w or "") .. "**",
    "",
    "Definition: " .. (entry.en or ""),
    "",
    "Example: " .. (entry.ex or ""),
    "",
    "Synonyms: " .. synonyms,
  }
  if use_ja then
    vim.list_extend(lines, {
      "",
      "Japanese: " .. (entry.ja or ""),
      "",
      "Example (ja): " .. (entry.exj or ""),
      "",
      "Core (ja): " .. (entry.core_ja or ""),
    })
  else
    vim.list_extend(lines, {
      "",
      "Chinese: " .. (entry.zh or ""),
      "",
      "Example (zh): " .. (entry.exz or ""),
      "",
      "Core: " .. (entry.core or ""),
    })
  end

  local width = math.min(72, math.max(40, vim.o.columns - 8))
  local height = math.min(#lines, math.max(16, vim.o.lines - 6))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 1,
    width = width,
    height = height,
    border = "single",
    title = " VimQuest Hint ",
    style = "minimal",
  })
  vim.api.nvim_win_set_cursor(win, {2, 0})
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
end

function M.stats()
  if not ensure_active() then
    return
  end
  local done = state.correct + state.wrong
  local rate = done > 0 and math.floor((state.correct / done) * 100 + 0.5) or 0
  notify(string.format("Progress %d/%d\nCorrect %d\nWrong %d\nAccuracy %d%%", done, #state.tasks, state.correct, state.wrong, rate))
end

function M.select_dictionary()
  local dicts = available_dictionaries()
  if #dicts == 0 then
    notify("No dictionaries found in data/ directory.", vim.log.levels.WARN)
    return
  end

  local current_file = config.wordlist:match("([^/]+)$")

  vim.ui.select(dicts, {
    prompt = "Select VimQuest dictionary:",
    format_item = function(item)
      local marker = item.file == current_file and " ✓" or ""
      return item.label .. marker
    end,
  }, function(choice)
    if not choice then
      return
    end
    config.wordlist = choice.path
    state.words = nil
    load_words()
    notify(string.format("Dictionary changed to: %s (%d words)", choice.label, #state.words))
  end)
end

local function truncate_display(text, width)
  text = tostring(text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  local out = {}
  local used = 0
  local limit = math.max(1, width - 1)
  for _, char in utf8.codes(text) do
    local piece = utf8.char(char)
    local char_width = vim.fn.strdisplaywidth(piece)
    if used + char_width > limit then
      break
    end
    table.insert(out, piece)
    used = used + char_width
  end
  return table.concat(out) .. "…"
end

local function drill_entry_line(entry, width)
  local text = table.concat({
    entry.w or "",
    entry.ja or "",
    entry.zh or entry.core or "",
  }, " ")
  return truncate_display(text, width)
end

local function user_data_dir()
  return join(vim.fn.stdpath("data"), "vimquest")
end

local function seen_words_path()
  return join(user_data_dir(), "words_seen.json")
end

local function load_seen_words()
  if state.seen_words then
    return state.seen_words
  end

  local path = seen_words_path()
  state.seen_words = {}
  if not exists(path) then
    return state.seen_words
  end

  local ok, decoded = pcall(read_json, path)
  if not ok or type(decoded) ~= "table" then
    notify("Could not read VimQuest word history. Starting with empty history.", vim.log.levels.WARN)
    return state.seen_words
  end

  for word, seen in pairs(decoded) do
    if type(word) == "string" and seen then
      state.seen_words[word] = true
    end
  end
  return state.seen_words
end

local function save_seen_words()
  local seen_words = load_seen_words()
  vim.fn.mkdir(user_data_dir(), "p")
  vim.fn.writefile({ vim.json.encode(seen_words) }, seen_words_path())
end

local function word_seen(word)
  return load_seen_words()[word] == true
end

local function mark_word_seen(word)
  if not word or word == "" then
    return
  end
  local seen_words = load_seen_words()
  if seen_words[word] then
    return
  end
  seen_words[word] = true
  save_seen_words()
end

local function drill_pick_word()
  local words = load_words()
  if #words == 0 then
    return nil
  end
  local entry = words[math.random(#words)]
  if state.drill and state.drill.word and #words > 1 then
    for _ = 1, 8 do
      if entry.w ~= state.drill.word then
        break
      end
      entry = words[math.random(#words)]
    end
  end
  return entry
end

local function drill_close()
  local drill = state.drill
  state.drill = nil
  if not drill then
    return
  end
  if drill.win and vim.api.nvim_win_is_valid(drill.win) then
    pcall(vim.api.nvim_win_close, drill.win, true)
  end
  if drill.buf and vim.api.nvim_buf_is_valid(drill.buf) then
    pcall(vim.api.nvim_buf_delete, drill.buf, { force = true })
  end
end

local function drill_render(entry)
  local drill = state.drill
  if not drill or not vim.api.nvim_buf_is_valid(drill.buf) then
    return
  end
  drill.entry = entry
  drill.word = entry and entry.w or nil
  vim.api.nvim_buf_set_lines(drill.buf, 0, -1, false, {
    "",
    entry and drill_entry_line(entry, drill.width) or "No words",
  })
  vim.api.nvim_buf_clear_namespace(drill.buf, drill.ns, 0, -1)
  if entry and word_seen(entry.w) then
    vim.api.nvim_buf_set_extmark(drill.buf, drill.ns, 1, 0, {
      end_line = 2,
      hl_group = "Comment",
      hl_eol = true,
    })
  end
  if drill.win and vim.api.nvim_win_is_valid(drill.win) then
    vim.api.nvim_set_current_win(drill.win)
    vim.api.nvim_win_set_cursor(drill.win, { 1, 0 })
    vim.cmd.startinsert()
  end
end

local function drill_next()
  local entry = drill_pick_word()
  if not entry then
    notify("Word list is empty.", vim.log.levels.WARN)
    drill_close()
    return
  end
  drill_render(entry)
end

local function drill_submit()
  local drill = state.drill
  if not drill or not vim.api.nvim_buf_is_valid(drill.buf) then
    return
  end
  local input = vim.api.nvim_buf_get_lines(drill.buf, 0, 1, false)[1] or ""
  input = input:gsub("^%s+", ""):gsub("%s+$", "")
  if input == "/exit" then
    drill_close()
    return
  end
  if normalize(input) ~= normalize(drill.word) then
    vim.api.nvim_buf_set_lines(drill.buf, 0, 1, false, { "" })
    if drill.win and vim.api.nvim_win_is_valid(drill.win) then
      vim.api.nvim_win_set_cursor(drill.win, { 1, 0 })
      vim.cmd.startinsert()
    end
    notify("Wrong. Type the word shown below.", vim.log.levels.WARN)
    return
  end
  mark_word_seen(drill.word)
  drill_next()
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function drill_default_position(width, height)
  local row = config.words_popup.row
  if row == nil then
    row = vim.o.lines - height - 3
  elseif row < 0 then
    row = vim.o.lines + row
  end

  local col = config.words_popup.col or 1
  if col < 0 then
    col = vim.o.columns + col
  end

  return {
    row = clamp(row, 0, math.max(0, vim.o.lines - height - 1)),
    col = clamp(col, 0, math.max(0, vim.o.columns - width)),
  }
end

local function drill_position(width, height)
  local position = state.drill_position or drill_default_position(width, height)
  return {
    row = clamp(position.row or 0, 0, math.max(0, vim.o.lines - height - 1)),
    col = clamp(position.col or 0, 0, math.max(0, vim.o.columns - width)),
  }
end

local function drill_set_position(row, col)
  local drill = state.drill
  if not drill or not drill.win or not vim.api.nvim_win_is_valid(drill.win) then
    return
  end
  local position = {
    row = clamp(row, 0, math.max(0, vim.o.lines - drill.height - 1)),
    col = clamp(col, 0, math.max(0, vim.o.columns - drill.width)),
  }
  state.drill_position = position
  vim.api.nvim_win_set_config(drill.win, {
    relative = "editor",
    row = position.row,
    col = position.col,
    width = drill.width,
    height = drill.height,
    style = "minimal",
  })
end

local function drill_start_drag()
  local drill = state.drill
  if not drill then
    return
  end
  local mouse = vim.fn.getmousepos()
  local position = drill_position(drill.width, drill.height)
  drill.drag = {
    mouse_row = mouse.screenrow,
    mouse_col = mouse.screencol,
    row = position.row,
    col = position.col,
  }
end

local function drill_drag()
  local drill = state.drill
  if not drill or not drill.drag then
    return
  end
  local mouse = vim.fn.getmousepos()
  drill_set_position(
    drill.drag.row + mouse.screenrow - drill.drag.mouse_row,
    drill.drag.col + mouse.screencol - drill.drag.mouse_col
  )
end

local function drill_stop_drag()
  local drill = state.drill
  if drill then
    drill.drag = nil
  end
end

function M.words()
  if state.drill then
    drill_close()
  end

  local width = math.min(44, math.max(28, vim.o.columns - 4))
  local height = 3
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vimquest-words"
  vim.bo[buf].complete = ""
  vim.bo[buf].omnifunc = ""
  vim.bo[buf].completefunc = ""
  vim.bo[buf].keywordprg = ""
  vim.b[buf].completion = false
  local position = drill_position(width, height)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = position.row,
    col = position.col,
    width = width,
    height = height,
    style = "minimal",
  })
  vim.wo[win].winhl = "Normal:Normal,EndOfBuffer:Normal"
  vim.wo[win].spell = false
  vim.wo[win].wrap = false
  vim.wo[win].foldenable = false

  state.drill = {
    buf = buf,
    win = win,
    width = width,
    height = height,
    ns = vim.api.nvim_create_namespace("vimquest_words"),
  }

  vim.keymap.set("i", "<CR>", drill_submit, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<CR>", drill_submit, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", drill_close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<RightMouse>", drill_start_drag, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<RightDrag>", drill_drag, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<RightRelease>", drill_stop_drag, { buffer = buf, nowait = true, silent = true })

  local cmp_ok, cmp = pcall(require, "cmp")
  if cmp_ok and cmp.setup and cmp.setup.buffer then
    pcall(cmp.setup.buffer, { enabled = false })
    pcall(cmp.close)
  end
  local blink_ok, blink = pcall(require, "blink.cmp")
  if blink_ok and blink.hide then
    pcall(blink.hide)
  end

  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      vim.b[buf].completion = false
      local ok_cmp, local_cmp = pcall(require, "cmp")
      if ok_cmp and local_cmp.close then
        pcall(local_cmp.close)
      end
      local ok_blink, local_blink = pcall(require, "blink.cmp")
      if ok_blink and local_blink.hide then
        pcall(local_blink.hide)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      state.drill = nil
    end,
  })

  drill_next()
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  vim.api.nvim_create_autocmd("VimEnter", {
    group = vim.api.nvim_create_augroup("VimQuestCleanup", { clear = true }),
    callback = function()
      local prefix = vim.fn.expand("~/.cache/vimquest/session-")
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name:sub(1, #prefix) == prefix then
          pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
      end
      cleanup_old_sessions()
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("VimQuestExitCleanup", { clear = true }),
    callback = function()
      if state.active then
        M.stop()
      end
    end,
  })

  vim.api.nvim_create_user_command("VimQuestStart", M.start, { force = true })
  vim.api.nvim_create_user_command("VimQuestStop", M.stop, { force = true })
  vim.api.nvim_create_user_command("VimQuestNext", M.next, { force = true })
  vim.api.nvim_create_user_command("VimQuestPrev", M.prev, { force = true })
  vim.api.nvim_create_user_command("VimQuestNextRound", M.next_round, { force = true })
  vim.api.nvim_create_user_command("VimQuestRestart", M.next_round, { force = true })
  vim.api.nvim_create_user_command("VimQuestTasks", M.tasks, { force = true })
  vim.api.nvim_create_user_command("VimQuestList", M.list, { force = true })
  vim.api.nvim_create_user_command("VimQuestCheck", M.check, { force = true })
  vim.api.nvim_create_user_command("VimQuestHint", M.hint, { force = true })
  vim.api.nvim_create_user_command("VimQuestStats", M.stats, { force = true })
  vim.api.nvim_create_user_command("VimQuestWords", M.words, { force = true })
  vim.api.nvim_create_user_command("VimQuestSelectDictionary", M.select_dictionary, { force = true })

  vim.keymap.set("n", "<leader>qs", M.start, { desc = "VimQuest start" })
  vim.keymap.set("n", "qn", M.next, { desc = "VimQuest next" })
  vim.keymap.set("n", "qp", M.prev, { desc = "VimQuest prev" })
  vim.keymap.set("n", "<leader>qr", M.next_round, { desc = "VimQuest restart with new tasks" })
  vim.keymap.set("n", "<leader>qN", M.next_round, { desc = "VimQuest next round" })
  vim.keymap.set("n", "<leader>qt", M.tasks, { desc = "VimQuest tasks" })
  vim.keymap.set("n", "<leader>ql", M.list, { desc = "VimQuest quickfix list" })
  vim.keymap.set("n", "<leader>qc", M.check, { desc = "VimQuest check all" })
  vim.keymap.set("n", "<leader>qh", M.hint, { desc = "VimQuest hint" })
  vim.keymap.set("n", "<leader>qw", M.words, { desc = "VimQuest words drill" })
  vim.keymap.set("n", "<leader>qd", M.select_dictionary, { desc = "VimQuest select dictionary" })
  vim.keymap.set("n", "<leader>qS", M.stats, { desc = "VimQuest stats" })
  vim.keymap.set("n", "K", function()
    if state.active then
      M.hint()
    else
      vim.lsp.buf.hover()
    end
  end, { desc = "Hover or VimQuest hint" })
end

return M
