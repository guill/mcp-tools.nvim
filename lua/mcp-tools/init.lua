local M = {}

local config = require("mcp-tools.config")
local registry = require("mcp-tools.registry")
local bridge = require("mcp-tools.bridge")

M._setup_done = false

---@param opts? MCPToolsConfig
function M.setup(opts)
  if M._setup_done then
    return
  end
  M._setup_done = true

  config.setup(opts)

  if config.get("tools.dap") then
    pcall(require, "mcp-tools.tools.dap")
  end
  if config.get("tools.diagnostics") then
    pcall(require, "mcp-tools.tools.diagnostics")
  end
  if config.get("tools.lsp") then
    pcall(require, "mcp-tools.tools.lsp")
  end
  if config.get("tools.undo") then
    pcall(require, "mcp-tools.tools.undo")
  end
  if config.get("tools.test") then
    pcall(require, "mcp-tools.tools.test")
  end
  if config.get("tools.interview") then
    pcall(require, "mcp-tools.tools.interview")
  end

  if config.get("integrations.opencode") then
    local ok, opencode_integration = pcall(require, "mcp-tools.integrations.opencode")
    if ok then
      opencode_integration.setup()
    end
  end

  if config.get("integrations.ampcode") then
    local ok, ampcode_integration = pcall(require, "mcp-tools.integrations.ampcode")
    if ok then
      ampcode_integration.setup()
    end
  end
end

---@param tool MCPToolDef
function M.register(tool)
  registry.register(tool)
end

---@param name string
function M.unregister(name)
  registry.unregister(name)
end

---@return table<string, {name: string, description: string, args: table}>
function M.list_tools()
  return registry.list()
end

---@class MCPStartOpts
---@field nvim_socket? string
---@field port? number

---@param opts? MCPStartOpts
function M.start(opts)
  opts = opts or {}
  bridge.start({
    nvim_socket = opts.nvim_socket or vim.v.servername,
    port = opts.port or config.get("bridge.port") or 0,
    on_ready = config.get("on_ready"),
    on_stop = config.get("on_stop"),
  })
end

function M.stop()
  bridge.stop()
end

---@return boolean
function M.is_running()
  return bridge.is_running()
end

---@return number?
function M.get_port()
  return bridge.get_port()
end

return M
