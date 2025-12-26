local M = {}

function M.setup(config)
  if config.opencode then
    local ok, err = pcall(require, "mcp-tools.integrations.opencode")
    if not ok then
      vim.notify("[mcp-tools] Failed to load OpenCode integration: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end
end

return M
