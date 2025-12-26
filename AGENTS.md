# AGENTS.md - Developer Guide for mcp-tools.nvim

This document provides essential context for developers (human or AI) working on this codebase.

## Project Overview

**mcp-tools.nvim** exposes NeoVim Lua functions as MCP (Model Context Protocol) tools for AI assistants. The architecture has two main components:

1. **Lua Plugin** (`lua/mcp-tools/`) - Tool registration, async task management, bridge lifecycle
2. **TypeScript Bridge** (`bridge/`) - MCP protocol server, NeoVim RPC client

**Core Design Principle:** The TypeScript bridge is generic and should NEVER need modification when adding new tools. All tool definitions live in Lua.

## Architecture Deep Dive

### Data Flow

```
AI Assistant (OpenCode/Claude Code)
         │
         ▼ HTTP POST / SSE
┌─────────────────────────────────────┐
│  TypeScript Bridge (bridge/src/)    │
│  - Express server on dynamic port   │
│  - MCP SDK for protocol handling    │
│  - neovim package for RPC           │
└─────────────────────────────────────┘
         │
         ▼ msgpack-rpc via unix socket
┌─────────────────────────────────────┐
│  NeoVim Instance                    │
│  - luaeval() executes registry.*    │
│  - Tools run on main thread         │
│  - Async results stored in registry │
└─────────────────────────────────────┘
```

### Registry Internals (`file://lua/mcp-tools/registry.lua`)

The registry implements a sync/async hybrid execution model:

```lua
-- Internal state
M._tools = {}           -- Tool definitions keyed by name
M._pending_tasks = {}   -- Async task results keyed by task_id
M._next_task_id = 1     -- Monotonic task ID counter
```

**Execution Flow:**
1. `execute(name, args)` is called via RPC
2. Tool's `execute(cb, args)` is invoked
3. If `cb()` is called synchronously (during the pcall), returns `{done=true, result=...}`
4. If `cb()` is NOT called synchronously, returns `{pending=true, task_id=...}`
5. Bridge polls `get_result(task_id)` until `done=true`

**Key insight:** The registry detects sync vs async by tracking whether `cb()` was called during the `is_sync_phase` flag (lines 106-131 in registry.lua).

### Bridge Internals (`file://bridge/src/index.ts`)

**Transport Support:**
- **Streamable HTTP** (`/` endpoint) - Modern MCP transport, session-based
- **SSE** (`/sse` + `/messages` endpoints) - Legacy transport, deprecated but supported

**Tool Discovery:** On every `tools/list` request, the bridge queries NeoVim:
```typescript
const tools = await nvim.call("luaeval", [
  "require('mcp-tools.registry').list()"
]);
```

**Tool Execution:**
```typescript
const response = await nvim.call("luaeval", [
  `require('mcp-tools.registry').execute(_A.name, _A.args)`,
  { name: toolName, args: args || {} },
]);

if (response.pending && response.task_id) {
  return await pollForResult(nvim, response.task_id);  // Polls every 100ms
}
```

**Logging:** The `neovim` package hijacks `console.*`. Use `process.stderr.write()` or the `log()` helper for any output.

## NeoVim Threading Model (CRITICAL)

**Everything runs on NeoVim's single main thread.** This affects all development:

### Rule 1: Never Block Indefinitely
```lua
-- BAD: Hangs NeoVim forever
vim.wait(-1, function() return false end)

-- GOOD: Always have timeout
vim.wait(5000, function() return completed end, 100)
```

### Rule 2: Schedule UI Operations from Callbacks
```lua
-- BAD: May crash from wrong context
session:request("stackTrace", {}, function(err, result)
  vim.notify("Done")  -- NOT SAFE
end)

-- GOOD: Schedule to main loop
session:request("stackTrace", {}, function(err, result)
  vim.schedule(function()
    vim.notify("Done")
  end)
end)
```

### Rule 3: Callback Must Be Called Exactly Once
```lua
-- BAD: Double callback
execute = function(cb, args)
  if error then cb(nil, "error") end
  cb(result)  -- Called even on error!
end

-- GOOD: Return after callback
execute = function(cb, args)
  if error then
    cb(nil, "error")
    return  -- STOP HERE
  end
  cb(result)
end
```

## Development Workflows

### Adding a New Tool (Same Category)

1. Open the relevant file in `lua/mcp-tools/tools/`
2. Add a new `registry.register({...})` call
3. That's it - bridge discovers tools dynamically

### Adding a New Tool Category

1. Create `lua/mcp-tools/tools/yourcat.lua`:
```lua
local registry = require("mcp-tools.registry")

registry.register({
  name = "yourcat_toolname",
  description = "What it does",
  args = { ... },
  execute = function(cb, args)
    cb({ result = "data" })
  end,
})
```

2. Add config option in `file://lua/mcp-tools/config.lua`:
```lua
M.defaults = {
  tools = {
    ...
    yourcat = false,  -- Add this
  },
  ...
}
```

3. Load conditionally in `file://lua/mcp-tools/init.lua`:
```lua
if config.get("tools.yourcat") then
  pcall(require, "mcp-tools.tools.yourcat")
end
```

### Modifying the Bridge

1. Edit `file://bridge/src/index.ts`
2. Test locally: `NVIM_LISTEN_ADDRESS=/path/to/socket MCP_PORT=9999 bun run bridge/src/index.ts`
3. Bridge auto-restarts when NeoVim plugin restarts it

### Adding a New Integration

1. Create `lua/mcp-tools/integrations/yourintegration.lua` with a `setup()` function
2. Add config: `integrations = { yourintegration = false }` in config.lua
3. Load in init.lua similar to opencode integration

## Code Patterns

### Config Access (Dot Notation)
```lua
local config = require("mcp-tools.config")
config.get("tools.dap")           -- Returns boolean
config.get("bridge.port")         -- Returns number
config.get("integrations.opencode") -- Returns boolean
```

### Conditional Debug Logging
```lua
local function debug_notify(msg, level)
  local config = require("mcp-tools.config")
  if config.get("debug") then
    vim.notify(msg, level)
  end
end
```

### DAP Session Guard
```lua
local session = dap.session()
if not session then
  cb(nil, "No active debug session")
  return
end
```

### Async DAP Request with Timeout
```lua
local response, req_err, completed = nil, nil, false

session:request("stackTrace", { threadId = id }, function(err, result)
  req_err, response, completed = err, result, true
end)

local success = vim.wait(5000, function() return completed end, 100)
if not success then
  cb(nil, "Request timed out")
  return
end
```

### Smart Buffer Management (`file://lua/mcp-tools/tools/dap.lua:102-217`)
The `smart_buffer_management()` function handles opening files for debugging without disrupting special buffers (AI chat windows, DAP UI, etc.). Study this pattern for any tool that needs to manipulate buffers.

## Bridge Protocol Details

### Registry API (called via luaeval)

| Function | Purpose | Returns |
|----------|---------|---------|
| `registry.list()` | Get all tools | `{name: {name, description, args}}` |
| `registry.execute(name, args)` | Run a tool | `{done?, pending?, task_id?, result?, error?}` |
| `registry.get_result(task_id)` | Poll async result | `{done, result?, error?}` |
| `registry.cancel_task(task_id)` | Cancel pending task | `{cancelled: true}` |

### Tool Definition Schema
```lua
{
  name = "string",           -- Becomes nvim_{name} in MCP
  description = "string",    -- Shown to AI
  args = {
    arg_name = {
      type = "string|number|boolean|object|array",
      description = "string",
      required = boolean,    -- Optional, default false
      default = any,         -- Optional
    },
  },
  execute = function(cb, args) end,
}
```

### Execute Response Types
```lua
-- Sync success
{ done = true, result = any }

-- Sync error  
{ done = true, error = "message" }

-- Async (bridge must poll)
{ pending = true, task_id = "123" }
```

## Testing & Debugging

### Health Check
```vim
:checkhealth mcp-tools
```

### Test Tool Registration
```lua
:lua require('mcp-tools').register({name='test', description='Test', args={}, execute=function(cb) cb({ok=true}) end})
:lua print(vim.inspect(require('mcp-tools.registry').list()))
:lua print(vim.inspect(require('mcp-tools.registry').execute('test', {})))
```

### Test Bridge Standalone
```bash
# Get NeoVim socket path
nvim --headless -c 'echo v:servername' -c 'q'

# Run bridge manually
NVIM_LISTEN_ADDRESS=/run/user/1000/nvim.12345.0 \
MCP_PORT=9999 \
MCP_LOG_FILE=/tmp/mcp-bridge.log \
bun run bridge/src/index.ts

# Test endpoints
curl http://localhost:9999/health
```

### Debug Bridge Logging
Set `bridge.log_file` in config to capture all bridge logs:
```lua
require("mcp-tools").setup({
  bridge = { log_file = "/tmp/mcp-bridge.log" },
  debug = true,
})
```

### Common Issues

**"No active debug session"** - DAP session not started or already terminated. Check `require('dap').session()`.

**Tool timeout** - Bridge polls for 5 minutes max. Check if `cb()` is actually being called.

**"Unknown tool"** - Tool not registered. Check if the tool category is enabled in config and the file is being loaded.

**Port detection failure** - Bridge must print `MCP server listening on port XXXX` to stdout (not stderr). The Lua code parses this exact format.

## File Reference

| File | Lines | Purpose |
|------|-------|---------|
| `lua/mcp-tools/init.lua` | ~84 | Entry point, setup(), public API |
| `lua/mcp-tools/registry.lua` | ~206 | Tool storage, sync/async execution |
| `lua/mcp-tools/bridge.lua` | ~151 | Child process management |
| `lua/mcp-tools/config.lua` | ~62 | Configuration with dot-notation |
| `lua/mcp-tools/health.lua` | ~82 | :checkhealth implementation |
| `lua/mcp-tools/integrations/opencode.lua` | ~166 | OpenCode auto-registration |
| `lua/mcp-tools/tools/dap.lua` | ~1206 | DAP tools (largest, most complex) |
| `lua/mcp-tools/tools/lsp.lua` | ~100 | LSP hover/symbols |
| `lua/mcp-tools/tools/diagnostics.lua` | ~49 | LSP diagnostics |
| `lua/mcp-tools/tools/undo.lua` | ~27 | Undo tree |
| `bridge/src/index.ts` | ~403 | MCP server, NeoVim RPC |

## Dependencies

### Lua Side
- NeoVim 0.9+ (requires `vim.system()`)
- Optional: nvim-dap, opencode.nvim

### Bridge Side
- Bun 1.0+ or Node.js 18+ with npx
- `@modelcontextprotocol/sdk` - MCP protocol (note: some types are deprecated)
- `neovim` - msgpack-rpc client
- `express` - HTTP server

Install: `cd bridge && npm install`

## Code Style Notes

- Lua uses snake_case for functions and variables
- TypeScript uses camelCase
- All tools disabled by default (explicit opt-in)
- Error messages should be actionable ("No active debug session" not "Error")
- Use `cb(nil, "error message")` not `error()` or `assert()` in tools

