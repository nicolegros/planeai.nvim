local M = {}

local MAX_LINES = 200
local MAX_BYTES = 12 * 1024
local MAX_CONTEXT_BYTES = 4 * 1024

local config = { cli_path = "planeai-cli" }
local queue = {}
local sending = false

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "planeai.nvim" })
end

local function session_id()
  local id = vim.g.planeai_session_id
  if type(id) ~= "string" or id:match("^%s*$") then
    return nil
  end
  return id
end

local function context_error()
  notify("No PlaneAI session context; launch Neovim from PlaneAI.", vim.log.levels.ERROR)
end

local function truncate_utf8(text, max_bytes)
  if #text <= max_bytes then
    return text
  end
  if max_bytes < #"…" then
    return ""
  end
  local limit = max_bytes - #"…"
  local end_index = limit
  while end_index > 0 and text:byte(end_index + 1) and text:byte(end_index + 1) >= 0x80 and text:byte(end_index + 1) < 0xC0 do
    end_index = end_index - 1
  end
  return text:sub(1, end_index) .. "…"
end

local function context_lines(bufnr, first, last, max_bytes)
  if first > last or max_bytes <= 0 then
    return ""
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
  local output = {}
  local remaining = max_bytes
  for _, line in ipairs(lines) do
    local separator = #output == 0 and "" or "\n"
    if #separator >= remaining then
      break
    end
    local clipped = truncate_utf8(line, remaining - #separator)
    table.insert(output, clipped)
    remaining = remaining - #separator - #clipped
    if #clipped < #line then
      break
    end
  end
  return table.concat(output, "\n")
end

-- Every visual mode captures whole lines so feedback always maps to a line range.
local function capture_visual()
  -- <Cmd> mappings run without leaving visual mode, so '< and '> still hold the previous selection.
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! \27")
  end

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line, end_line = start_pos[2], end_pos[2]
  if start_line == 0 or end_line == 0 then
    return nil, "Select text in visual mode first."
  end

  local lines = vim.fn.getregion(start_pos, end_pos, { type = "V" })
  local selected_text = table.concat(lines, "\n")
  if selected_text == "" then
    return nil, "Select text before adding PlaneAI feedback."
  end
  if end_line - start_line + 1 > MAX_LINES or #selected_text > MAX_BYTES then
    return nil, "Select at most 200 lines or 12 KiB of text for PlaneAI feedback."
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local context_before = context_lines(bufnr, math.max(1, start_line - 2), start_line - 1, MAX_CONTEXT_BYTES)
  local context_after = context_lines(
    bufnr,
    end_line + 1,
    math.min(vim.api.nvim_buf_line_count(bufnr), end_line + 2),
    MAX_CONTEXT_BYTES - #context_before
  )
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    path = "[unnamed buffer]"
  else
    path = vim.fn.fnamemodify(path, ":.")
  end

  return {
    file_path = path,
    start_line = start_line,
    end_line = end_line,
    language = vim.bo[bufnr].filetype,
    selected_text = selected_text,
    context_before = context_before,
    context_after = context_after,
    is_unsaved = vim.bo[bufnr].modified,
    text = nil,
  }
end

local function fence_for(content)
  local longest = 2
  for run in content:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  return string.rep("`", longest + 1)
end

local function append_code_block(lines, label, content, language)
  if content == "" then
    return
  end
  local fence = fence_for(content)
  table.insert(lines, label)
  table.insert(lines, fence .. language)
  table.insert(lines, content)
  table.insert(lines, fence)
end

function M.serialize(feedback)
  if #feedback == 0 then
    return ""
  end

  local lines = { "Please address this editor feedback:" }
  for _, item in ipairs(feedback) do
    local line_label = item.start_line == item.end_line
        and ("line " .. item.start_line)
      or ("lines " .. item.start_line .. "-" .. item.end_line)
    local unsaved = item.is_unsaved and "; unsaved editor content" or ""
    table.insert(lines, "")
    table.insert(lines, string.format("--- %s (%s%s) ---", item.file_path, line_label, unsaved))
    append_code_block(lines, "Context before selection:", item.context_before, item.language)
    append_code_block(lines, "Selected code:", item.selected_text, item.language)
    append_code_block(lines, "Context after selection:", item.context_after, item.language)
    table.insert(lines, "Comment: " .. item.text)
  end
  table.insert(lines, "")
  return table.concat(lines, "\n")
end

function M.pending_count()
  return #queue
end

function M.add_feedback()
  if sending then
    notify("PlaneAI feedback is being sent; wait for delivery to finish.", vim.log.levels.WARN)
    return
  end
  if not session_id() then
    context_error()
    return
  end

  local feedback, err = M._capture_visual()
  if not feedback then
    notify(err, vim.log.levels.ERROR)
    return
  end

  vim.ui.input({ prompt = "PlaneAI feedback: " }, function(input)
    local text = input and vim.trim(input) or ""
    if text == "" then
      return
    end
    feedback.text = text
    table.insert(queue, feedback)
    notify(string.format("Feedback queued (%d pending).", #queue))
  end)
end

function M.clear_feedback()
  if sending then
    notify("PlaneAI feedback is being sent; wait for delivery to finish.", vim.log.levels.WARN)
    return
  end
  if #queue == 0 then
    notify("No PlaneAI feedback is queued.")
    return
  end
  queue = {}
  notify("Queued PlaneAI feedback cleared.")
end

local function feedback_label(item, index)
  local lines = item.start_line == item.end_line
      and ("line " .. item.start_line)
    or ("lines " .. item.start_line .. "-" .. item.end_line)
  return string.format("%d. %s (%s): %s", index, item.file_path, lines, item.text)
end

function M.open_feedback()
  if sending then
    notify("PlaneAI feedback is being sent; wait for delivery to finish.", vim.log.levels.WARN)
    return
  end
  if #queue == 0 then
    notify("No PlaneAI feedback is queued.")
    return
  end

  vim.ui.select(queue, {
    prompt = "Queued PlaneAI feedback",
    format_item = function(item)
      for index, candidate in ipairs(queue) do
        if candidate == item then
          return feedback_label(item, index)
        end
      end
      return item.text
    end,
  }, function(item)
    if not item then
      return
    end
    vim.ui.select({ "Edit", "Remove" }, { prompt = "Feedback action" }, function(action)
      if action == "Edit" then
        vim.ui.input({ prompt = "PlaneAI feedback: ", default = item.text }, function(input)
          local text = input and vim.trim(input) or ""
          if text ~= "" then
            item.text = text
            notify("Queued PlaneAI feedback updated.")
          end
        end)
      elseif action == "Remove" then
        for index, candidate in ipairs(queue) do
          if candidate == item then
            table.remove(queue, index)
            notify(string.format("Feedback removed (%d pending).", #queue))
            return
          end
        end
      end
    end)
  end)
end

function M.send_feedback()
  if sending then
    notify("PlaneAI feedback is already being sent.", vim.log.levels.WARN)
    return
  end
  local id = session_id()
  if not id then
    context_error()
    return
  end
  if #queue == 0 then
    notify("No PlaneAI feedback is queued.")
    return
  end
  if vim.fn.executable(config.cli_path) ~= 1 then
    notify("planeai-cli was not found. Install PlaneAI CLI or configure cli_path.", vim.log.levels.ERROR)
    return
  end

  local pending = queue
  local text = M.serialize(pending)
  sending = true
  local ok, err = pcall(vim.system, { config.cli_path, "session", "prompt", id, text }, { text = true }, function(result)
    vim.schedule(function()
      sending = false
      if result.code == 0 then
        if queue == pending then
          queue = {}
        end
        notify(string.format("PlaneAI feedback sent (%d note%s).", #pending, #pending == 1 and "" or "s"))
      else
        local detail = vim.trim(result.stderr ~= "" and result.stderr or result.stdout)
        notify("PlaneAI feedback was not sent" .. (detail ~= "" and ": " .. detail or "."), vim.log.levels.ERROR)
      end
    end)
  end)
  if not ok then
    sending = false
    notify("PlaneAI feedback was not sent: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.setup(opts)
  opts = opts or {}
  if opts.cli_path ~= nil then
    if type(opts.cli_path) ~= "string" or opts.cli_path == "" then
      error("planeai.nvim: cli_path must be a nonempty string")
    end
    config.cli_path = opts.cli_path
  end
end

function M._reset_for_tests()
  queue = {}
  sending = false
  config = { cli_path = "planeai-cli" }
end

M._capture_visual = capture_visual

return M
