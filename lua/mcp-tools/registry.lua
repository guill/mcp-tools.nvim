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
---@field execute fun(cb: fun(result: any, err?: string), args: table)
---@field timeout? number

---@type table<string, MCPToolDef>
M._tools = {}

---@type table<string, {done: boolean, result?: any, error?: string}>
M._pending_tasks = {}

---@type number
M._next_task_id = 1

---Register a tool that can be called via MCP
---The execute function receives (cb, args) where cb(result, err?) signals completion
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
    timeout = tool.timeout,
  }
end

---Unregister a tool
---@param name string
function M.unregister(name)
  M._tools[name] = nil
end

---Get all registered tools (called by MCP bridge via RPC)
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

---Prepare and validate arguments for a tool
---@param tool MCPToolDef
---@param args table
---@return table? final_args, string? error
local function prepare_args(tool, args)
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

  for k, v in pairs(args or {}) do
    if final_args[k] == nil then
      final_args[k] = v
    end
  end

  return final_args, nil
end

---Execute a tool by name (called by MCP bridge via RPC)
---Returns immediately with either a result (sync) or task_id (async)
---@param name string
---@param args table
---@return {done?: boolean, pending?: boolean, task_id?: string, result?: any, error?: string}
function M.execute(name, args)
  local tool = M._tools[name]
  if not tool then
    return { done = true, error = "Unknown tool: " .. name }
  end

  local final_args, arg_err = prepare_args(tool, args)
  if arg_err then
    return { done = true, error = arg_err }
  end

  local task_id = tostring(M._next_task_id)
  M._next_task_id = M._next_task_id + 1

  local sync_result = nil
  local is_sync_phase = true
  local cb_called = false

  local cb = function(result, err)
    if cb_called then
      vim.schedule(function()
        vim.notify("[mcp-tools] Warning: callback called multiple times for " .. name, vim.log.levels.WARN)
      end)
      return
    end
    cb_called = true

    if is_sync_phase then
      sync_result = { result = result, error = err }
    else
      vim.schedule(function()
        if M._pending_tasks[task_id] then
          M._pending_tasks[task_id] = { done = true, result = result, error = err }
        end
      end)
    end
  end

  local ok, exec_err = pcall(tool.execute, cb, final_args)

  is_sync_phase = false

  if not ok then
    return { done = true, error = "Tool execution error: " .. tostring(exec_err) }
  end

  if sync_result then
    return { done = true, result = sync_result.result, error = sync_result.error }
  else
    M._pending_tasks[task_id] = { done = false }
    return { pending = true, task_id = task_id, timeout = tool.timeout }
  end
end

---Get result of an async task (called by MCP bridge via polling)
---@param task_id string
---@return {done: boolean, result?: any, error?: string}
function M.get_result(task_id)
  local task = M._pending_tasks[task_id]
  if not task then
    return { done = true, error = "Unknown or expired task: " .. task_id }
  end
  if task.done then
    M._pending_tasks[task_id] = nil
    return { done = true, result = task.result, error = task.error }
  end
  return { done = false }
end

---Cancel a pending task
---@param task_id string
---@return {cancelled: boolean}
function M.cancel_task(task_id)
  M._pending_tasks[task_id] = nil
  return { cancelled = true }
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

---Get count of pending tasks
---@return number
function M.pending_count()
  local n = 0
  for _ in pairs(M._pending_tasks) do
    n = n + 1
  end
  return n
end

---Clear all registered tools (mainly for testing)
function M.clear()
  M._tools = {}
end

---Clear all pending tasks (for cleanup)
function M.clear_pending()
  M._pending_tasks = {}
end

return M
