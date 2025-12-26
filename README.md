# mcp-tools.nvim

A NeoVim plugin that exposes Lua functions as MCP (Model Context Protocol) tools for AI coding assistants like OpenCode, Claude Code, and Cursor.

## Features

- **DAP Integration**: Inspect debug sessions, call stacks, variables, and evaluate expressions
- **LSP Tools**: Query hover info, document symbols, and diagnostics
- **Undo Tree**: Inspect undo history
- **OpenCode Auto-Integration**: Automatically registers with OpenCode when it starts
- **Custom Tools**: Register your own Lua functions as MCP tools

## Requirements

- NeoVim 0.9+
- One of: [bun](https://bun.sh/) or Node.js 18+ with npx
- Optional: [nvim-dap](https://github.com/mfussenegger/nvim-dap) for debug tools
- Optional: [opencode.nvim](https://github.com/sudo-tee/opencode.nvim) for auto-integration

## Installation

### lazy.nvim

```lua
{
  "guill/mcp-tools.nvim",
  build = "cd bridge && npm install",
  config = function()
    require("mcp-tools").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "guill/mcp-tools.nvim",
  run = "cd bridge && npm install",
  config = function()
    require("mcp-tools").setup()
  end,
}
```

## Configuration

```lua
require("mcp-tools").setup({
  -- Enable/disable built-in tools
  tools = {
    dap = true,         -- Debug Adapter Protocol tools
    diagnostics = true, -- LSP diagnostics
    lsp = true,         -- LSP hover, symbols
    undo = true,        -- Undo tree
  },

  -- Enable/disable integrations
  integrations = {
    opencode = true, -- Auto-register with OpenCode
  },

  -- Bridge configuration
  bridge = {
    port = 0,            -- 0 = OS assigns port
    log_level = "info",  -- debug, info, warn, error
  },

  -- Callbacks
  on_ready = function(port)
    print("MCP bridge ready on port " .. port)
  end,
  on_stop = function()
    print("MCP bridge stopped")
  end,
})
```

## Built-in Tools

### DAP Tools (requires nvim-dap)

| Tool | Description |
|------|-------------|
| `nvim_dap_status` | Get debug session status |
| `nvim_dap_stacktrace` | Get current call stack |
| `nvim_dap_scopes` | Get scopes for a stack frame |
| `nvim_dap_variables` | Get variables in a scope |
| `nvim_dap_evaluate` | Evaluate an expression |
| `nvim_dap_breakpoints` | List all breakpoints |
| `nvim_dap_threads` | List all threads |
| `nvim_dap_continue` | Continue execution |
| `nvim_dap_step_over` | Step over |
| `nvim_dap_step_into` | Step into |
| `nvim_dap_step_out` | Step out |

### LSP Tools

| Tool | Description |
|------|-------------|
| `nvim_lsp_hover` | Get hover information |
| `nvim_lsp_symbols` | Get document symbols |
| `nvim_diagnostics_list` | Get diagnostics |

### Undo Tools

| Tool | Description |
|------|-------------|
| `nvim_undo_tree` | Get undo tree structure |

## Registering Custom Tools

```lua
local mcp = require("mcp-tools")

mcp.register({
  name = "my_tool",
  description = "Does something useful",
  args = {
    bufnr = {
      type = "number",
      description = "Buffer number",
      required = false,
      default = 0,
    },
  },
  execute = function(args)
    -- Your tool logic here
    return { result = "success" }
  end,
})
```

## Manual Bridge Control

```lua
local mcp = require("mcp-tools")

-- Start bridge manually
mcp.start({
  nvim_socket = vim.v.servername,
  port = 0,
})

-- Stop bridge
mcp.stop()

-- Check status
if mcp.is_running() then
  print("Bridge on port " .. mcp.get_port())
end

-- List registered tools
for name, def in pairs(mcp.list_tools()) do
  print(name .. ": " .. def.description)
end
```

## Health Check

Run `:checkhealth mcp-tools` to verify your installation.

## How It Works

1. When OpenCode starts, this plugin detects it via `opencode.state.subscribe`
2. Plugin spawns a TypeScript MCP bridge that connects to NeoVim via RPC
3. Plugin registers the MCP server with OpenCode via `POST /mcp`
4. OpenCode discovers tools via MCP `tools/list`
5. When OpenCode calls a tool, the bridge invokes Lua via `nvim.call('luaeval', ...)`

## Architecture

```
NeoVim Instance
├── mcp-tools.nvim (this plugin)
│   ├── Tool Registry (Lua)
│   └── MCP Bridge (TypeScript, child process)
│       ├── Connects to NeoVim via socket
│       ├── Exposes tools via MCP protocol
│       └── Routes tool calls back to Lua
└── opencode.nvim
    └── Discovers nvim-tools MCP server
```

## License

MIT
