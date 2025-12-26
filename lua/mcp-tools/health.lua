local M = {}

local health = vim.health

function M.check()
  health.start("mcp-tools.nvim")

  local bridge = require("mcp-tools.bridge")
  local registry = require("mcp-tools.registry")
  local config = require("mcp-tools.config")

  if vim.fn.executable("bun") == 1 then
    health.ok("bun is installed")
  elseif vim.fn.executable("npx") == 1 then
    health.ok("npx is installed (using tsx)")
  else
    health.error("No JavaScript runtime found", { "Install bun or Node.js with npx" })
  end

  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) == "@" then
    source = source:sub(2)
  end
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  local bridge_path = plugin_dir .. "/bridge/src/index.ts"
  local package_json = plugin_dir .. "/bridge/package.json"
  local node_modules = plugin_dir .. "/bridge/node_modules"

  if vim.fn.filereadable(bridge_path) == 1 then
    health.ok("Bridge script found: " .. bridge_path)
  else
    health.error("Bridge script not found", { "Expected at: " .. bridge_path })
  end

  if vim.fn.filereadable(package_json) == 1 then
    health.ok("package.json found")
  else
    health.error("package.json not found", { "Expected at: " .. package_json })
  end

  if vim.fn.isdirectory(node_modules) == 1 then
    health.ok("node_modules installed")
  else
    health.warn("node_modules not found", { "Run: cd " .. plugin_dir .. "/bridge && npm install" })
  end

  if bridge.is_running() then
    health.ok("MCP bridge running on port " .. bridge.get_port())
  else
    health.info("MCP bridge not running")
  end

  local tool_count = registry.count()
  if tool_count > 0 then
    health.ok(tool_count .. " tools registered")
  else
    health.warn("No tools registered")
  end

  local has_dap = pcall(require, "dap")
  if has_dap then
    health.ok("nvim-dap available (DAP tools enabled)")
  else
    health.info("nvim-dap not found (DAP tools disabled)")
  end

  local has_opencode = pcall(require, "opencode.state")
  if has_opencode then
    health.ok("opencode.nvim available (auto-integration enabled)")
  else
    health.info("opencode.nvim not found (manual bridge start required)")
  end

  if config.get("integrations.opencode") then
    health.ok("OpenCode integration enabled in config")
  else
    health.info("OpenCode integration disabled in config")
  end
end

return M
