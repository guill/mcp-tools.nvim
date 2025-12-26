local bridge = require("mcp-tools.bridge")

local M = {}

M._subscribed = false

local function debug_notify(msg, level)
  local config = require("mcp-tools.config")
  if config.get("debug") then
    vim.notify(msg, level)
  end
end

local function parse_mcp_response(stdout)
  if not stdout or stdout == "" then
    return nil, "Empty response"
  end

  local ok, response = pcall(vim.json.decode, stdout)
  if not ok then
    return nil, "Invalid JSON: " .. stdout
  end

  return response, nil
end

local function format_mcp_status(response)
  if type(response) ~= "table" then
    return "unknown", nil
  end

  local nvim_tools = response["nvim-tools"]
  if nvim_tools and nvim_tools.status then
    return nvim_tools.status, nvim_tools.error
  end

  if response.status then
    return response.status, response.error
  end

  return "unknown", vim.inspect(response)
end

local function register_with_opencode(opencode_url, mcp_port)
  local mcp_url = "http://127.0.0.1:" .. mcp_port
  local body = vim.json.encode({
    name = "nvim-tools",
    config = {
      type = "remote",
      url = mcp_url,
    },
  })

  vim.system({
    "curl",
    "-s",
    "-w",
    "\n%{http_code}",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
    opencode_url .. "/mcp",
  }, {}, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify(
          "[mcp-tools] Failed to reach OpenCode: " .. (result.stderr or ("curl error " .. result.code)),
          vim.log.levels.ERROR
        )
        return
      end

      local lines = vim.split(result.stdout or "", "\n")
      local http_code = lines[#lines]
      local response_body = table.concat(vim.list_slice(lines, 1, #lines - 1), "\n")

      if http_code ~= "200" then
        vim.notify(
          "[mcp-tools] OpenCode returned HTTP " .. http_code .. ": " .. response_body,
          vim.log.levels.ERROR
        )
        return
      end

      local response, parse_err = parse_mcp_response(response_body)
      if parse_err then
        vim.notify("[mcp-tools] " .. parse_err, vim.log.levels.WARN)
        return
      end

      local status, status_error = format_mcp_status(response)

      if status == "connected" then
        debug_notify("[mcp-tools] Registered with OpenCode at " .. mcp_url, vim.log.levels.INFO)
      elseif status == "failed" then
        vim.notify(
          "[mcp-tools] OpenCode failed to connect to MCP bridge: " .. (status_error or "unknown"),
          vim.log.levels.ERROR
        )
      elseif status == "disabled" then
        debug_notify("[mcp-tools] MCP server was disabled by OpenCode", vim.log.levels.WARN)
      else
        debug_notify("[mcp-tools] MCP registration status: " .. status, vim.log.levels.DEBUG)
      end
    end)
  end)
end

local function start_bridge_when_ready(server)
  if not server or not server.get_spawn_promise then
    return
  end

  local promise = server:get_spawn_promise()

  promise:and_then(function(ready_server)
    if not ready_server or not ready_server.url then
      return
    end

    bridge.start({
      nvim_socket = vim.v.servername,
      on_ready = function(port)
        register_with_opencode(ready_server.url, port)
      end,
      on_stop = function()
        local config = require("mcp-tools.config")
        local on_stop = config.get("on_stop")
        if on_stop then
          on_stop()
        end
      end,
    })
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
    if server then
      start_bridge_when_ready(server)
    elseif prev and not server then
      bridge.stop()
    end
  end)

  if opencode_state.opencode_server then
    start_bridge_when_ready(opencode_state.opencode_server)
  end
end

return M
