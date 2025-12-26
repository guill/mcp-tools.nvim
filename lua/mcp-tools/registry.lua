-- Tool registry for MCP tools
-- Handles registration, listing, and execution of tools

local M = {}

---@class MCPToolArg
---@field type "string"|"number"|"boolean"|"object"|"array"
---@field description string
---@field required? boolean
---@field default? any

---@class MCPToolDef
---@field name string
---@field description string
---@field args table<string, MCPToolArg>
---@field execute fun(args: table): any

---@type table<string, MCPToolDef>
M._tools = {}

---Register a tool that can be called via MCP
---@param tool MCPToolDef
function M.register(tool)
  assert(tool.name, "Tool must have a name")
  assert(tool.description, "Tool must have a description")
  assert(tool.execute, "Tool must have an execute function")
  assert(type(tool.execute) == "function", "execute must be a function")

  M._tools[tool.name] = {
    name = tool.name,
    description = tool.description,
    args = tool.args or {},
    execute = tool.execute,
  }
end

---Unregister a tool
---@param name string
function M.unregister(name)
  M._tools[name] = nil
end

---Get all registered tools (called by MCP bridge via RPC)
---This returns a serializable representation (no functions)
---@return table<string, {name: string, description: string, args: table}>
function M.list()
  local result = {}
  for name, tool in pairs(M._tools) do
    result[name] = {
      name = tool.name,
      description = tool.description,
      args = tool.args,
    }
  end
  return result
end

---Execute a tool by name (called by MCP bridge via RPC)
---@param name string
---@param args table
---@return any result, string? error
function M.execute(name, args)
  local tool = M._tools[name]
  if not tool then
    return nil, "Unknown tool: " .. name
  end

  -- Apply defaults and validate required args
  local final_args = {}
  for arg_name, arg_def in pairs(tool.args) do
    if args[arg_name] ~= nil then
      final_args[arg_name] = args[arg_name]
    elseif arg_def.default ~= nil then
      final_args[arg_name] = arg_def.default
    elseif arg_def.required then
      return nil, "Missing required argument: " .. arg_name
    end
  end

  -- Copy any extra args not in schema (for flexibility)
  for k, v in pairs(args or {}) do
    if final_args[k] == nil then
      final_args[k] = v
    end
  end

  local ok, result = pcall(tool.execute, final_args)
  if not ok then
    return nil, "Tool execution error: " .. tostring(result)
  end
  return result, nil
end

---Check if a tool is registered
---@param name string
---@return boolean
function M.has(name)
  return M._tools[name] ~= nil
end

---Get count of registered tools
---@return number
function M.count()
  local n = 0
  for _ in pairs(M._tools) do
    n = n + 1
  end
  return n
end

---Clear all registered tools (mainly for testing)
function M.clear()
  M._tools = {}
end

return M
