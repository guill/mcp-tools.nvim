local bridge = require("mcp-tools.bridge")

local M = {}

local function debug_notify(msg, level)
  local config = require("mcp-tools.config")
  if config.get("debug") then
    vim.notify(msg, level)
  end
end

---@param port number
---@param token string
function M._open_terminal(port, token)
  local mcp_config = {
    ["nvim-tools"] = {
      url = "http://127.0.0.1:" .. port,
      headers = {
        Authorization = "Bearer " .. token,
      },
    },
  }

  local temp_file = vim.fn.tempname() .. ".json"
  local f = io.open(temp_file, "w")
  if not f then
    vim.notify("[mcp-tools] Failed to create temp config file", vim.log.levels.ERROR)
    return
  end
  f:write(vim.json.encode(mcp_config))
  f:close()

  local cmd = "amp --ide --mcp-config " .. vim.fn.shellescape(temp_file)
  vim.cmd("terminal " .. cmd)

  debug_notify("[mcp-tools] Started Amp with nvim-tools MCP server on port " .. port, vim.log.levels.INFO)
end

function M.start()
  if bridge.is_running() then
    local port = bridge.get_port()
    local token = bridge.get_auth_token()
    if port and token then
      M._open_terminal(port, token)
    else
      vim.notify("[mcp-tools] Bridge running but port/token unavailable", vim.log.levels.ERROR)
    end
  else
    bridge.start({
      nvim_socket = vim.v.servername,
      on_ready = function(port)
        local token = bridge.get_auth_token()
        if token then
          M._open_terminal(port, token)
        else
          vim.notify("[mcp-tools] Bridge started but auth token unavailable", vim.log.levels.ERROR)
        end
      end,
      on_stop = function()
        local config = require("mcp-tools.config")
        local on_stop = config.get("on_stop")
        if on_stop then
          on_stop()
        end
      end,
    })
  end
end

function M.setup()
  vim.api.nvim_create_user_command("AmpStartWithMCP", function()
    M.start()
  end, { desc = "Start Amp with nvim-tools MCP server" })
end

return M
