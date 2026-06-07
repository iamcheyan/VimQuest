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
  words = nil,
}

local defaults = {
  task_count = 10,
  copy_file_count = 10,
  open_file_count = 5,
  wordlist = "lua/vimquest/data/ogden-850-words.json",
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
      editable = replace_word_once(ex, entry.w, synonym),
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

local function build_tasks()
  local words = shuffle(vim.deepcopy(load_words()))
  local tasks = {}
  local builder_index = 1
  for _, entry in ipairs(words) do
    local task = active_task_builders[builder_index](entry)
    builder_index = builder_index % #active_task_builders + 1
    if task then
      table.insert(tasks, task)
    end
    if #tasks >= config.task_count then
      break
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

local function task_block(task, index, total)
  local rel = task.file
  if is_input_task(task) then
    return { comment_line(rel, "[Guess] " .. (task.display or task.editable)) }
  end
  return { comment_line(rel, task.editable) }
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
    task.answer_line = insert_at
    local block = task_block(task, i, usable)
    for offset, line in ipairs(block) do
      table.insert(lines, insert_at + offset - 1, line)
    end
    vim.fn.writefile(lines, path)
  end

  while #tasks > usable do
    table.remove(tasks)
  end
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

local function start_session(cwd, original)
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
    local tasks = build_tasks()
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
      "Round started: %d tasks inserted. %d files opened. Use <leader>qn to navigate.",
      #state.tasks,
      math.min(#state.tasks, math.max(5, config.open_file_count))
    )
  )
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

function M.next_round()
  if not ensure_active() then
    return
  end

  local original = state.original
  local old_session_dir = state.session_dir
  state.active = false
  state.session_dir = nil
  state.tasks = {}
  state.current = 0
  state.correct = 0
  state.wrong = 0
  state.checked = {}

  if old_session_dir then
    vim.fn.delete(old_session_dir, "rf")
  end
  start_session(original.cwd, original)
end

local function show_check_report(results)
  local lines = {
    "VimQuest Round Result",
    "",
    string.format("Progress %d/%d", state.correct + state.wrong, #state.tasks),
    string.format("Correct %d", state.correct),
    string.format("Wrong %d", state.wrong),
    "",
    "Answers:",
  }
  for _, result in ipairs(results) do
    table.insert(
      lines,
      string.format(
        "%s [%s] %s -> %s",
        result.correct and "OK" or "NO",
        result.task.type,
        result.task.file,
        result.task.expected
      )
    )
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
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  return win
end

function M.check()
  if not ensure_active() then
    return
  end

  local task = task_at_cursor()
  local index = task_index(task)
  state.current = index

  local actual, correct
  if is_input_task(task) then
    local input = vim.fn.input(task.type .. " > ")
    if input == "" then
      notify("Cancelled.", vim.log.levels.INFO)
      return
    end
    actual = input
    correct = normalize(actual) == normalize(task.expected)
  else
    actual = answer_for_task(task)
    correct = actual ~= nil and normalize(actual) == normalize(task.expected)
  end
  state.checked[index] = correct
  recompute_stats()

  if correct then
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = vim.api.nvim_get_current_buf() })
    if index < #state.tasks then
      notify(string.format("Correct. Moving to %d/%d.", index + 1, #state.tasks))
      state.current = index
      M.next()
    else
      notify(
        string.format(
          "Correct. Round complete. Correct %d | Wrong %d | Accuracy %d%%",
          state.correct,
          state.wrong,
          math.floor((state.correct / #state.tasks) * 100 + 0.5)
        )
      )
    end
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

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})

  vim.api.nvim_create_user_command("VimQuestStart", M.start, { force = true })
  vim.api.nvim_create_user_command("VimQuestStop", M.stop, { force = true })
  vim.api.nvim_create_user_command("VimQuestNext", M.next, { force = true })
  vim.api.nvim_create_user_command("VimQuestPrev", M.prev, { force = true })
  vim.api.nvim_create_user_command("VimQuestCheck", M.check, { force = true })
  vim.api.nvim_create_user_command("VimQuestHint", M.hint, { force = true })
  vim.api.nvim_create_user_command("VimQuestStats", M.stats, { force = true })

  vim.keymap.set("n", "<leader>qs", M.start, { desc = "VimQuest start" })
  vim.keymap.set("n", "<leader>qx", M.stop, { desc = "VimQuest stop" })
  vim.keymap.set("n", "<leader>qn", M.next, { desc = "VimQuest next" })
  vim.keymap.set("n", "<leader>qp", M.prev, { desc = "VimQuest prev" })
  vim.keymap.set("n", "<leader>qc", M.check, { desc = "VimQuest check" })
  vim.keymap.set("n", "<leader>qh", M.hint, { desc = "VimQuest hint" })
  vim.keymap.set("n", "<leader>qt", M.stats, { desc = "VimQuest stats" })
  vim.keymap.set("n", "K", function()
    if state.active then
      M.hint()
    else
      vim.lsp.buf.hover()
    end
  end, { desc = "Hover or VimQuest hint" })
end

return M
