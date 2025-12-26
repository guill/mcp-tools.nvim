local M = {}

function M.setup(config)
  if config.dap then
    pcall(require, "mcp-tools.tools.dap")
  end
  if config.diagnostics then
    pcall(require, "mcp-tools.tools.diagnostics")
  end
  if config.lsp then
    pcall(require, "mcp-tools.tools.lsp")
  end
  if config.undo then
    pcall(require, "mcp-tools.tools.undo")
  end
end

return M
