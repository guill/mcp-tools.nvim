local M = {}

---@class MCPToolsBridgeConfig
---@field command? string[] Command to run the bridge (auto-detected if nil)
---@field port? number Port to listen on (0 = OS assigns)
---@field log_level? "debug"|"info"|"warn"|"error"

---@class MCPToolsConfig
---@field tools? {dap?: boolean, diagnostics?: boolean, lsp?: boolean, undo?: boolean}
---@field integrations? {opencode?: boolean}
---@field bridge? MCPToolsBridgeConfig
---@field on_ready? fun(port: number)
---@field on_stop? fun()

---@type MCPToolsConfig
M.defaults = {
  tools = {
    dap = true,
    diagnostics = true,
    lsp = true,
    undo = true,
  },
  integrations = {
    opencode = true,
  },
  bridge = {
    command = nil,
    port = 0,
    log_level = "info",
  },
  on_ready = nil,
  on_stop = nil,
}

---@type MCPToolsConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? MCPToolsConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@param key string
---@return any
function M.get(key)
  local keys = vim.split(key, ".", { plain = true })
  local value = M.options
  for _, k in ipairs(keys) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[k]
  end
  return value
end

return M
