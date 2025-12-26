local bridge = require("mcp-tools.bridge")

local M = {}

M._subscribed = false

local function register_with_opencode(opencode_url, mcp_port)
  local body = vim.json.encode({
    name = "nvim-tools",
    config = {
      type = "remote",
      url = "http://127.0.0.1:" .. mcp_port,
      enabled = true,
    },
  })

  vim.system({
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
    opencode_url .. "/mcp",
  }, {}, function(result)
    if result.code == 0 then
      vim.schedule(function()
        vim.notify("[mcp-tools] Registered with OpenCode", vim.log.levels.INFO)
      end)
    else
      vim.schedule(function()
        vim.notify("[mcp-tools] Failed to register with OpenCode: " .. (result.stderr or "unknown error"), vim.log.levels.WARN)
      end)
    end
  end)
end

function M.setup()
  if M._subscribed then
    return
  end

  local ok, opencode_state = pcall(require, "opencode.state")
  if not ok then
    return
  end

  M._subscribed = true

  opencode_state.subscribe("opencode_server", function(_, server, prev)
    if server and server.url then
      bridge.start({
        nvim_socket = vim.v.servername,
        on_ready = function(port)
          register_with_opencode(server.url, port)
        end,
        on_stop = function()
          local config = require("mcp-tools.config")
          local on_stop = config.get("on_stop")
          if on_stop then
            on_stop()
          end
        end,
      })
    elseif prev and not server then
      bridge.stop()
    end
  end)

  if opencode_state.opencode_server and opencode_state.opencode_server.url then
    bridge.start({
      nvim_socket = vim.v.servername,
      on_ready = function(port)
        register_with_opencode(opencode_state.opencode_server.url, port)
      end,
    })
  end
end

M.setup()

return M
