if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("planeai.nvim requires Neovim 0.10 or later.", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("PlaneAIAddFeedback", function()
  require("planeai").add_feedback()
end, { range = true, desc = "Queue feedback for the current PlaneAI visual selection" })

vim.api.nvim_create_user_command("PlaneAISendFeedback", function()
  require("planeai").send_feedback()
end, { desc = "Send queued feedback to the PlaneAI session" })

vim.api.nvim_create_user_command("PlaneAIClearFeedback", function()
  require("planeai").clear_feedback()
end, { desc = "Clear queued PlaneAI feedback" })

vim.api.nvim_create_user_command("PlaneAIFeedback", function()
  require("planeai").open_feedback()
end, { desc = "Inspect, edit, or remove queued PlaneAI feedback" })
