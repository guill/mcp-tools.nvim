local M = {}

local function debug_notify(msg, level)
  local config = require("mcp-tools.config")
  if config.get("debug") then
    vim.notify(msg, level)
  end
end

---@type vim.SystemObj?
M._process = nil

---@type number?
M._port = nil

---@type fun(port: number)?
M._on_ready = nil

---@type fun()?
M._on_stop = nil

---@type string?
M._bridge_path = nil

---@type string[]
M._stdout_buffer = {}

local function find_bridge_path()
  if M._bridge_path then
    return M._bridge_path
  end

  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end

  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  M._bridge_path = plugin_dir .. "/bridge/src/index.ts"

  return M._bridge_path
end

---@return string[]
local function get_runtime_command()
  if vim.fn.executable("bun") == 1 then
    return { "bun", "run" }
  end

  if vim.fn.executable("npx") == 1 then
    return { "npx", "tsx" }
  end

  error("No JavaScript runtime found. Install bun or Node.js with npx.")
end

---@class BridgeStartOpts
---@field nvim_socket string
---@field port? number
---@field on_ready? fun(port: number)
---@field on_stop? fun()

---@param opts BridgeStartOpts
function M.start(opts)
  if M._process then
    vim.notify("[mcp-tools] Bridge already running on port " .. (M._port or "?"), vim.log.levels.WARN)
    return
  end

  local bridge_path = find_bridge_path()
  if vim.fn.filereadable(bridge_path) ~= 1 then
    vim.notify("[mcp-tools] Bridge not found at: " .. bridge_path, vim.log.levels.ERROR)
    return
  end

  local cmd = get_runtime_command()
  table.insert(cmd, bridge_path)

  M._on_ready = opts.on_ready
  M._on_stop = opts.on_stop
  M._stdout_buffer = {}

  local config = require("mcp-tools.config")
  local log_file = config.get("bridge.log_file")

  local env = vim.tbl_extend("force", vim.fn.environ(), {
    NVIM_LISTEN_ADDRESS = opts.nvim_socket,
    MCP_PORT = tostring(opts.port or 0),
    MCP_LOG_FILE = log_file or "",
  })

  M._process = vim.system(cmd, {
    env = env,
    stdout = function(_, data)
      if not data then
        return
      end

      table.insert(M._stdout_buffer, data)
      local port = data:match("MCP server listening on port (%d+)")
      if port then
        M._port = tonumber(port)
        vim.schedule(function()
          debug_notify("[mcp-tools] Bridge ready on port " .. M._port, vim.log.levels.INFO)
          if M._on_ready then
            M._on_ready(M._port)
          end
        end)
      end
    end,
    stderr = function(_, data)
      if data and data:match("%S") then
        vim.schedule(function()
          debug_notify("[mcp-tools:bridge] " .. vim.trim(data), vim.log.levels.DEBUG)
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= nil then
        vim.notify("[mcp-tools] Bridge exited with code " .. result.code, vim.log.levels.WARN)
      end
      M._process = nil
      M._port = nil
      if M._on_stop then
        M._on_stop()
      end
    end)
  end)
end

function M.stop()
  if M._process then
    M._process:kill("sigterm")
    M._process = nil
    M._port = nil
  end
end

---@return boolean
function M.is_running()
  return M._process ~= nil
end

---@return number?
function M.get_port()
  return M._port
end

return M
