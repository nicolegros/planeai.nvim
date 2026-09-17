vim.opt.runtimepath:prepend(vim.fn.getcwd())
dofile(vim.fn.getcwd() .. "/plugin/planeai.lua")

local planeai = require("planeai")
local passed = 0
local failed = 0

local function test(name, fn)
  planeai._reset_for_tests()
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("ok - " .. name)
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

test("captures a characterwise visual selection and nearby context", function()
  vim.cmd("enew!")
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/example.lua")
  vim.bo[buf].filetype = "lua"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "-- before", "local value = 1", "-- after" })
  vim.fn.setpos("'<", { 0, 2, 1, 0 })
  vim.fn.setpos("'>", { 0, 2, 15, 0 })
  local feedback, err = planeai._capture_visual("v")
  assert(not err, err)
  eq(feedback.start_line, 2)
  eq(feedback.end_line, 2)
  eq(feedback.selected_text, "local value = 1")
  eq(feedback.context_before, "-- before")
  eq(feedback.context_after, "-- after")
  eq(feedback.language, "lua")
end)

test("rejects blockwise visual selections", function()
  local feedback, err = planeai._capture_visual("\22")
  eq(feedback, nil)
  eq(err, "Blockwise visual selections are not supported.")
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
print(string.format("%d passed, %d failed", passed, failed))
vim.cmd(failed == 0 and "cq 0" or "cq 1")
