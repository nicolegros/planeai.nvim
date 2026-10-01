vim.opt.runtimepath:prepend(vim.fn.getcwd())
dofile(vim.fn.getcwd() .. "/plugin/planeai.lua")

local planeai = require("planeai")
local passed = 0
local failed = 0

local function test(name, fn)
  planeai._reset_for_tests()
  local original_notify = vim.notify
  vim.notify = function() end
  local ok, err = xpcall(fn, debug.traceback)
  vim.notify = original_notify
  if ok then
    passed = passed + 1
    io.stdout:write("ok - " .. name .. "\n")
  else
    failed = failed + 1
    io.stderr:write("not ok - " .. name .. "\n" .. err .. "\n")
  end
end

local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

test("registers feedback commands without default mappings", function()
  for _, command in ipairs({ "PlaneAIAddFeedback", "PlaneAISendFeedback", "PlaneAIClearFeedback", "PlaneAIFeedback" }) do
    eq(vim.fn.exists(":" .. command), 2)
  end
end)

test("serializes selected-code feedback with bounded context labels", function()
  local text = planeai.serialize({ {
    file_path = "src/main.lua",
    start_line = 2,
    end_line = 3,
    language = "lua",
    selected_text = "local x = 1\nlocal y = 2",
    context_before = "-- before",
    context_after = "-- after",
    is_unsaved = true,
    text = "Use clearer names.",
  } })
  assert(text:find("--- src/main.lua %(lines 2%-3; unsaved editor content%) ---"))
  assert(text:find("Context before selection:"))
  assert(text:find("```lua"))
  assert(text:find("Comment: Use clearer names."))
end)

-- Mirrors the recommended `<Cmd>` mapping, which runs without leaving visual mode.
vim.keymap.set("x", "<F12>", "<Cmd>PlaneAIAddFeedback<CR>")

-- Keys must end with <F12> (mapping) or <Esc> (command-line usage, where '< and '> are already set).
local function select_and_add(keys)
  vim.g.planeai_session_id = "session-1"
  local original_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("Review this.")
  end
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/example-" .. buf .. ".lua")
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- before", "local value = 1", "local other = 2", "-- after" })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  if keys:match("<Esc>$") then
    vim.cmd("PlaneAIAddFeedback")
  end
  eq(vim.fn.mode(), "n")
  vim.ui.input = original_input
  eq(planeai.pending_count(), 1)

  planeai.setup({ cli_path = "true" })
  local original_system = vim.system
  local sent
  vim.system = function(cmd, _, on_exit)
    sent = cmd[5]
    on_exit({ code = 0, stdout = "", stderr = "" })
  end
  planeai.send_feedback()
  vim.system = original_system
  vim.wait(1000, function()
    return planeai.pending_count() == 0
  end)
  return sent
end

local function assert_whole_lines(text)
  assert(text:find("lines 2%-3"), text)
  assert(text:find("Selected code:\n```lua\nlocal value = 1\nlocal other = 2\n```"), text)
  assert(text:find("Context before selection:\n```lua\n%-%- before\n```"), text)
  assert(text:find("Context after selection:\n```lua\n%-%- after\n```"), text)
end

test("captures whole lines from a characterwise visual selection", function()
  assert_whole_lines(select_and_add("2Gwvjb<F12>"))
end)

test("captures the last line when a characterwise selection ends at its first column", function()
  assert_whole_lines(select_and_add("2G$vj0<F12>"))
end)

test("captures whole lines from a blockwise visual selection", function()
  assert_whole_lines(select_and_add("2Gw<C-v>jl<F12>"))
end)

test("captures whole lines from a linewise visual selection", function()
  assert_whole_lines(select_and_add("2GVj<F12>"))
end)

test("captures the current selection from a mapping instead of the previous one", function()
  assert_whole_lines(select_and_add("4GV<Esc>2GVj<F12>"))
end)

test("captures the last selection when run from the command line", function()
  assert_whole_lines(select_and_add("2GVj<Esc>"))
end)

test("rejects a selection of a single empty line", function()
  vim.cmd("enew!")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x", "", "y" })
  vim.fn.setpos("'<", { 0, 2, 1, 0 })
  vim.fn.setpos("'>", { 0, 2, 1, 0 })
  local feedback, err = planeai._capture_visual()
  eq(feedback, nil)
  eq(err, "Select text before adding PlaneAI feedback.")
end)

test("retains queued feedback when the CLI cannot be found", function()
  vim.g.planeai_session_id = "session-1"
  planeai.setup({ cli_path = "missing-planeai-cli" })
  local original_input = vim.ui.input
  vim.ui.input = function(_, callback)
    callback("Review this.")
  end
  vim.cmd("enew!")
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 1, 1, 0 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
  local original_capture = planeai._capture_visual
  planeai._capture_visual = function()
    return {
      file_path = "x.lua", start_line = 1, end_line = 1, language = "lua",
      selected_text = "x", context_before = "", context_after = "", is_unsaved = false,
    }
  end
  planeai.add_feedback()
  planeai._capture_visual = original_capture
  vim.ui.input = original_input
  eq(planeai.pending_count(), 1)
  planeai.send_feedback()
  eq(planeai.pending_count(), 1)
end)

vim.g.planeai_session_id = nil
io.stdout:write(string.format("%d passed, %d failed\n", passed, failed))
vim.cmd(failed == 0 and "cq 0" or "cq 1")
