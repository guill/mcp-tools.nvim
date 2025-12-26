# NeoVim MCP Tools Plugin - Design Document

A standalone NeoVim plugin that exposes Lua functions as MCP (Model Context Protocol) tools for AI coding assistants.

> **For Implementers:** This document contains everything needed to implement this plugin from scratch. Start with the [Implementation Phases](#implementation-phases) section for a step-by-step guide. The [Lua Implementation Details](#lua-implementation-details) and [Complete Bridge Implementation](#complete-bridge-implementation) sections contain reference implementations.

## Problem Statement

Modern AI coding assistants like OpenCode, Claude Code, and Cursor support the Model Context Protocol (MCP) for extending their capabilities with custom tools. However, there's currently no way to expose NeoVim-specific functionality (like DAP debugging, LSP queries, undo history, etc.) to these assistants.

### Primary Use Case: Debug Adapter Protocol (DAP) Integration

When debugging code, developers often need AI assistance to:
- Inspect the current call stack
- Evaluate expressions in the debug context
- Understand variable states at breakpoints
- Navigate through stack frames

Currently, AI assistants have no visibility into the debug session running in NeoVim. This plugin bridges that gap.

### Secondary Use Cases

The same infrastructure enables exposing:
- LSP diagnostics and code actions
- Undo/redo history
- Buffer contents and metadata
- Quickfix/location lists
- Custom user-defined functions

## Goals

1. **Lua-first tool registration** - Users should be able to register tools entirely in Lua without touching TypeScript
2. **Zero modifications to OpenCode.nvim** - Hook into existing events, don't fork or patch
3. **Support multiple NeoVim instances** - Each NeoVim instance gets its own MCP server that correctly routes back to that specific instance
4. **Generic MCP bridge** - The TypeScript component should never need modification when adding new tools
5. **Automatic lifecycle management** - MCP server starts/stops with the AI assistant's session
6. **Portable design** - While initially targeting OpenCode, the architecture should support any MCP-compatible AI tool

## Design Decision: Why This Approach?

During design, three approaches were considered:

### Option A: Standalone Plugin + MCP Server (CHOSEN)

A separate NeoVim plugin that spawns an MCP server, connecting to OpenCode via the standard MCP protocol.

**Pros:**
- Zero modifications to OpenCode.nvim
- Uses OpenCode's existing MCP infrastructure
- Could work with other MCP-compatible tools (Claude Code, Cursor, etc.)
- Clean separation of concerns
- Easier to contribute as a separate project

**Cons:**
- Extra process (the MCP bridge)
- Slightly more complex architecture

### Option B: OpenCode Plugin (TypeScript)

Create an OpenCode plugin (`.opencode/plugin/*.ts`) that connects to NeoVim via RPC.

**Pros:**
- Simpler, fewer moving parts
- Runs in OpenCode's Bun runtime

**Cons:**
- Tightly coupled to OpenCode
- Plugin runs outside NeoVim, communication overhead
- Users would need TypeScript knowledge to extend

### Option C: Modify OpenCode.nvim Directly

Fork or extend OpenCode.nvim to add tool registration.

**Pros:**
- Most integrated, no external processes
- Direct Lua execution

**Cons:**
- Requires upstream changes or maintaining a fork
- Couples the feature to OpenCode.nvim specifically

### Decision Rationale

**Option A was chosen** because:
1. The user wanted something that could be contributed upstream or used standalone
2. Zero modifications to OpenCode.nvim means no fork maintenance
3. The MCP protocol is standard and supported by multiple AI tools
4. Lua-first tool registration meets the extensibility requirement
5. The TypeScript bridge is generic and never needs modification for new tools

## Constraints

### Multiple NeoVim Instances

Users often have multiple NeoVim instances running, each potentially with an OpenCode session. The solution must:

- Pass `v:servername` (NeoVim's socket path) to the MCP bridge
- Ensure each MCP bridge connects only to its parent NeoVim instance
- Use dynamic ports to avoid conflicts between instances

### NeoVim's `v:servername`

Each NeoVim instance exposes an RPC socket at a path like:
```
/run/user/1000/nvim.233803.0
```

This is available in Lua as `vim.v.servername`. The MCP bridge uses this to connect back via msgpack-rpc.

### OpenCode.nvim Integration Points

OpenCode.nvim exposes these via `require('opencode.state')`:

| State Key | Description |
|-----------|-------------|
| `opencode_server` | The server object (has `.url` property when running) |
| `subscribe(key, callback)` | Subscribe to state changes |
| `event_manager` | Event system for finer-grained events |

The `opencode_server` state changes to a server object when OpenCode starts and to `nil` when it stops.

#### State Subscription Pattern

The `state.subscribe` function signature:
```lua
---@param key string|string[]|nil  -- Key to watch, array of keys, or '*' for all
---@param cb fun(key:string, new_val:any, old_val:any)
state.subscribe('opencode_server', function(key, new_server, old_server)
  -- new_server is nil when stopped, has .url when running
end)
```

#### Event Manager (Alternative Integration)

For finer-grained lifecycle events, `state.event_manager` provides:

| Event | Description | Properties |
|-------|-------------|------------|
| `custom.server_starting` | Server spawn initiated | `{ server_job }` |
| `custom.server_ready` | Server is listening | `{ server_job, url }` |
| `custom.server_stopped` | Server has stopped | `{}` |

Usage:
```lua
local state = require('opencode.state')
if state.event_manager then
  state.event_manager:subscribe('custom.server_ready', function(data)
    -- data.url contains the server URL
  end)
end
```

#### Existing Hooks in OpenCode.nvim

OpenCode.nvim already has a hooks system (for reference, not for our use):
```lua
hooks = {
  on_file_edited = nil,           -- Called after a file is edited
  on_session_loaded = nil,        -- Called after a session is loaded  
  on_done_thinking = nil,         -- Called when thinking completes
  on_permission_requested = nil,  -- Called on permission request
}
```

These are configured via `require('opencode').setup({ hooks = {...} })` but are **not** what we use for integration. We use `state.subscribe` instead.

### OpenCode's Dynamic MCP Registration

OpenCode supports adding MCP servers at runtime via HTTP API:
```
POST /mcp
{
  "name": "nvim-tools",
  "config": {
    "type": "remote",
    "url": "http://127.0.0.1:<port>"
  }
}
```

This allows registering our MCP bridge without modifying config files.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           NeoVim Instance                                   │
│  v:servername = /run/user/1000/nvim.12345.0                                │
│                                                                             │
│  ┌────────────────────────────────────────────────────────────────────────┐│
│  │                    mcp-tools-nvim (this plugin)                        ││
│  │                                                                        ││
│  │  ┌──────────────────┐    ┌──────────────────────────────────────────┐ ││
│  │  │  Tool Registry   │    │         MCP Bridge Server                │ ││
│  │  │  (Lua)           │◀───│  (TypeScript - spawned as child process) │ ││
│  │  │                  │    │                                          │ ││
│  │  │  Registered:     │    │  • Connects to NeoVim via NVIM socket    │ ││
│  │  │  • dap_*         │    │  • Discovers tools via luaeval RPC       │ ││
│  │  │  • diagnostics_* │    │  • Exposes tools via MCP protocol        │ ││
│  │  │  • lsp_*         │    │  • Routes tool calls back to Lua         │ ││
│  │  │  • undo_*        │    │                                          │ ││
│  │  └──────────────────┘    └────────────────────┬─────────────────────┘ ││
│  │                                               │ HTTP/SSE              ││
│  └───────────────────────────────────────────────┼────────────────────────┘│
│                                                  │                         │
│  ┌──────────────────┐                           │                         │
│  │  opencode.nvim   │                           │                         │
│  │  (unmodified)    │                           │                         │
│  │                  │    ┌──────────────────────▼────────────────────────┐│
│  │  state.subscribe │    │              OpenCode CLI                     ││
│  │  ('opencode_     │    │                                               ││
│  │   server', ...)  │───▶│  • Discovers nvim-tools MCP via POST /mcp    ││
│  │                  │    │  • Calls tools: dap_stacktrace, etc.          ││
│  └──────────────────┘    └───────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. User starts OpenCode in NeoVim
2. `opencode.nvim` spawns `opencode serve` and sets `state.opencode_server`
3. Our plugin detects this via `state.subscribe('opencode_server', ...)`
4. Plugin spawns MCP bridge with `NVIM_LISTEN_ADDRESS=<v:servername>`
5. MCP bridge connects to NeoVim via msgpack-rpc socket
6. Plugin registers MCP with OpenCode via `POST /mcp`
7. OpenCode discovers tools by calling MCP's `tools/list`
8. When OpenCode calls a tool, MCP bridge invokes Lua via `nvim.call('luaeval', ...)`
9. Lua function executes and returns result through the chain

## Directory Structure

```
mcp-tools.nvim/
├── lua/
│   └── mcp-tools/
│       ├── init.lua                 -- Plugin entry, setup()
│       ├── registry.lua             -- Tool registration API
│       ├── bridge.lua               -- MCP bridge process management
│       ├── config.lua               -- Configuration handling
│       ├── integrations/
│       │   ├── init.lua             -- Integration loader
│       │   └── opencode.lua         -- OpenCode.nvim integration
│       └── tools/
│           ├── init.lua             -- Built-in tool loader
│           ├── dap.lua              -- DAP debugging tools
│           ├── diagnostics.lua      -- LSP diagnostics tools
│           ├── lsp.lua              -- LSP query tools
│           └── undo.lua             -- Undo tree tools
├── bridge/                          -- TypeScript MCP server
│   ├── package.json
│   ├── tsconfig.json
│   ├── bun.lockb
│   └── src/
│       ├── index.ts                 -- Entry point
│       ├── nvim.ts                  -- NeoVim RPC client wrapper
│       └── mcp.ts                   -- MCP server setup
├── scripts/
│   └── install-bridge.sh            -- Bridge dependency installer
├── doc/
│   └── mcp-tools.txt                -- Vim help documentation
└── README.md
```

## Public Lua API

### Setup

```lua
require('mcp-tools').setup({
  -- Enable/disable built-in tools (default: all false)
  tools = {
    dap = true,           -- DAP debugging tools
    diagnostics = true,   -- LSP diagnostics
    lsp = true,           -- LSP hover, symbols
    undo = true,          -- Undo tree inspection
    test = true,          -- Test tools (for development)
  },
  
  -- Enable/disable integrations (default: all false)
  integrations = {
    opencode = true,      -- OpenCode.nvim auto-registration
  },
  
  -- MCP bridge configuration
  bridge = {
    -- Command to run the bridge (auto-detected if nil)
    command = nil,  -- e.g., { 'bun', 'run', '/path/to/bridge' }
    
    -- Port range for dynamic allocation (0 = OS assigns)
    port = 0,
    
    -- Log level for bridge process
    log_level = 'info',  -- 'debug', 'info', 'warn', 'error'
  },
  
  -- Called when MCP server is ready
  on_ready = function(port) end,
  
  -- Called when MCP server stops
  on_stop = function() end,
})
```

### Tool Registration

```lua
local mcp = require('mcp-tools')

-- Register a custom tool
mcp.register({
  -- Unique tool name (required)
  name = 'my_custom_tool',
  
  -- Description shown to AI (required)
  description = 'Does something useful with the buffer',
  
  -- Argument schema (required, can be empty table)
  args = {
    bufnr = {
      type = 'number',
      description = 'Buffer number (0 for current)',
      required = false,
      default = 0,
    },
    pattern = {
      type = 'string', 
      description = 'Search pattern',
      required = true,
    },
  },
  
  -- Execution function (required)
  -- Receives: args table with validated/defaulted values
  -- Returns: any serializable value (will be JSON encoded)
  -- Throws: error string on failure
  execute = function(args)
    local bufnr = args.bufnr == 0 and vim.api.nvim_get_current_buf() or args.bufnr
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local matches = {}
    for i, line in ipairs(lines) do
      if line:match(args.pattern) then
        table.insert(matches, { line = i, text = line })
      end
    end
    return matches
  end,
})
```

### Tool Unregistration

```lua
-- Remove a tool by name
mcp.unregister('my_custom_tool')
```

### Manual Bridge Control

```lua
-- Start bridge manually (usually automatic via integrations)
mcp.start({
  nvim_socket = vim.v.servername,
  port = 0,  -- Let OS assign
})

-- Stop bridge
mcp.stop()

-- Check if bridge is running
if mcp.is_running() then
  print('MCP bridge running on port ' .. mcp.get_port())
end

-- Get registered tools
local tools = mcp.list_tools()
for name, def in pairs(tools) do
  print(name .. ': ' .. def.description)
end
```

## Built-in Tools

### DAP Tools (`tools.dap`)

Requires `nvim-dap` to be installed. Tools are only registered if DAP is available.

**Session Management:**

| Tool | Description | Arguments |
|------|-------------|-----------|
| `dap_status` | Get debug session status | none |
| `dap_run` | Start a new debug session | `name`, `type`, `request`, `program?`, etc. |
| `dap_terminate` | Terminate the current session | none |
| `dap_disconnect` | Disconnect from debug adapter | `terminate_debuggee?` |

**Execution Control:**

| Tool | Description | Arguments |
|------|-------------|-----------|
| `dap_continue` | Continue execution | `wait_until_paused?` |
| `dap_step_over` | Step over | `wait_until_paused?` |
| `dap_step_into` | Step into | `wait_until_paused?` |
| `dap_step_out` | Step out | `wait_until_paused?` |
| `dap_run_to` | Run to specific file and line | `filename`, `line`, `wait_until_paused?` |
| `dap_wait_until_paused` | Wait until debugger pauses | `timeout_ms?` |

**Breakpoints:**

| Tool | Description | Arguments |
|------|-------------|-----------|
| `dap_set_breakpoint` | Set breakpoint at file:line | `filename`, `line`, `condition?`, `hit_condition?`, `log_message?` |
| `dap_remove_breakpoint` | Remove breakpoint at file:line | `filename`, `line` |
| `dap_clear_breakpoints` | Clear all breakpoints | none |
| `dap_breakpoints` | List all breakpoints | none |

**Inspection:**

| Tool | Description | Arguments |
|------|-------------|-----------|
| `dap_stacktrace` | Get current call stack | `thread_id?`, `levels?` |
| `dap_scopes` | Get scopes for a stack frame | `frame_id` |
| `dap_variables` | Get variables in a scope | `variables_reference`, `filter?`, `start?`, `count?` |
| `dap_evaluate` | Evaluate expression | `expression`, `frame_id?`, `context?` |
| `dap_threads` | List all threads | none |
| `dap_current_location` | Get current location with code context | `context_lines?` |
| `dap_program_output` | Get program stdout/stderr/console | `category?`, `lines?`, `include_metadata?` |

### Diagnostics Tools (`tools.diagnostics`)

| Tool | Description | Arguments |
|------|-------------|-----------|
| `diagnostics_list` | Get diagnostics | `bufnr?`, `severity?` |

### LSP Tools (`tools.lsp`)

| Tool | Description | Arguments |
|------|-------------|-----------|
| `lsp_hover` | Get hover info | `bufnr?`, `line?`, `col?` |
| `lsp_symbols` | Document symbols | `bufnr?` |

### Undo Tools (`tools.undo`)

| Tool | Description | Arguments |
|------|-------------|-----------|
| `undo_tree` | Get undo tree structure | `bufnr?` |

### Test Tools (`tools.test`)

Tools for verifying MCP bridge async/sync execution patterns:

| Tool | Description | Arguments |
|------|-------------|-----------|
| `test_async_prompt` | Tests async execution via user prompt | `prompt`, `options` |
| `test_sync_buffers` | Tests sync execution via NeoVim API | none |

## MCP Bridge Implementation

### TypeScript Bridge (`bridge/src/index.ts`)

The bridge is a Node.js/Bun process that:

1. Connects to NeoVim via the socket in `NVIM_LISTEN_ADDRESS`
2. Starts an HTTP server with SSE endpoint for MCP
3. Dynamically discovers tools by calling `require('mcp-tools.registry').list()` via RPC
4. Handles MCP `tools/list` by returning discovered tools with JSON schemas
5. Handles MCP `tools/call` by invoking `require('mcp-tools.registry').execute(name, args)` via RPC

### Key Design: Dynamic Discovery

The bridge does NOT have a hardcoded list of tools. On every `tools/list` request, it queries NeoVim for currently registered tools. This means:

- Tools can be registered/unregistered at runtime
- Lazy-loaded plugins can register tools when they load
- No bridge restart needed when tools change

### NeoVim RPC Communication

Using the `neovim` npm package:

```typescript
import { attach } from 'neovim';

const nvim = attach({ socket: process.env.NVIM_LISTEN_ADDRESS });

// Discover tools
const tools = await nvim.call('luaeval', [
  "require('mcp-tools.registry').list()"
]);

// Execute tool
const [result, error] = await nvim.call('luaeval', [
  "require('mcp-tools.registry').execute(_A.name, _A.args)",
  { name: 'dap_stacktrace', args: { levels: 20 } }
]);
```

### MCP Protocol

The bridge implements MCP over HTTP with SSE:

- `GET /mcp` - SSE endpoint for MCP messages
- Tools are exposed via the standard MCP `tools/list` and `tools/call` methods

OpenCode connects to this as a "remote" MCP server.

### Bridge package.json

```json
{
  "name": "mcp-tools-nvim",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "start": "bun run src/index.ts",
    "start:node": "npx tsx src/index.ts"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.0.0",
    "neovim": "^5.0.0",
    "express": "^4.18.0"
  },
  "devDependencies": {
    "@types/express": "^4.17.0",
    "@types/node": "^20.0.0",
    "typescript": "^5.0.0",
    "tsx": "^4.0.0"
  }
}
```

### Complete Bridge Implementation

Here's a more complete bridge implementation for reference:

```typescript
// bridge/src/index.ts
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { attach, NeovimClient } from "neovim";
import express, { Request, Response } from "express";

const NVIM_SOCKET = process.env.NVIM_LISTEN_ADDRESS;
const PORT = parseInt(process.env.MCP_PORT || "0");

if (!NVIM_SOCKET) {
  console.error("NVIM_LISTEN_ADDRESS environment variable not set");
  process.exit(1);
}

interface ToolArg {
  type: "string" | "number" | "boolean" | "object" | "array";
  description: string;
  required?: boolean;
  default?: unknown;
}

interface ToolDef {
  name: string;
  description: string;
  args: Record<string, ToolArg>;
}

async function main() {
  // Connect to NeoVim via msgpack-rpc
  const nvim: NeovimClient = attach({ socket: NVIM_SOCKET });
  
  console.error(`Connected to NeoVim at ${NVIM_SOCKET}`);

  // Create MCP server
  const server = new Server(
    { name: "mcp-tools-nvim", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  // Discover tools dynamically from NeoVim
  async function discoverTools(): Promise<Record<string, ToolDef>> {
    try {
      return (await nvim.call("luaeval", [
        "require('mcp-tools.registry').list()"
      ])) as Record<string, ToolDef>;
    } catch (err) {
      console.error("Failed to discover tools:", err);
      return {};
    }
  }

  // Handle tools/list - called by OpenCode to discover available tools
  server.setRequestHandler("tools/list", async () => {
    const tools = await discoverTools();
    return {
      tools: Object.entries(tools).map(([name, def]) => ({
        name: `nvim_${name}`,  // Prefix with nvim_ to avoid conflicts
        description: def.description,
        inputSchema: {
          type: "object" as const,
          properties: Object.fromEntries(
            Object.entries(def.args).map(([argName, argDef]) => [
              argName,
              { 
                type: argDef.type, 
                description: argDef.description,
                default: argDef.default,
              },
            ])
          ),
          required: Object.entries(def.args)
            .filter(([_, d]) => d.required)
            .map(([n]) => n),
        },
      })),
    };
  });

  // Handle tools/call - called by OpenCode to execute a tool
  server.setRequestHandler("tools/call", async (request) => {
    const { name, arguments: args } = request.params as { 
      name: string; 
      arguments?: Record<string, unknown>;
    };
    
    // Remove nvim_ prefix if present
    const toolName = name.startsWith("nvim_") ? name.slice(5) : name;

    try {
      const [result, error] = (await nvim.call("luaeval", [
        `require('mcp-tools.registry').execute(_A.name, _A.args)`,
        { name: toolName, args: args || {} },
      ])) as [unknown, string | null];

      if (error) {
        return {
          content: [{ type: "text", text: `Error: ${error}` }],
          isError: true,
        };
      }

      return {
        content: [
          { 
            type: "text", 
            text: typeof result === "string" 
              ? result 
              : JSON.stringify(result, null, 2) 
          },
        ],
      };
    } catch (err) {
      return {
        content: [{ type: "text", text: `Bridge error: ${err}` }],
        isError: true,
      };
    }
  });

  // Start HTTP server with SSE transport
  const app = express();
  
  // SSE endpoint for MCP
  app.get("/mcp", async (req: Request, res: Response) => {
    const transport = new SSEServerTransport("/mcp", res);
    await server.connect(transport);
  });
  
  // Health check endpoint
  app.get("/health", (req: Request, res: Response) => {
    res.json({ status: "ok", nvim: NVIM_SOCKET });
  });

  const httpServer = app.listen(PORT, "127.0.0.1", () => {
    const addr = httpServer.address();
    const actualPort = typeof addr === "object" ? addr?.port : PORT;
    // This line is parsed by the Lua bridge.lua to get the port
    console.log(`MCP server listening on port ${actualPort}`);
  });

  // Graceful shutdown
  process.on("SIGTERM", () => {
    console.error("Received SIGTERM, shutting down...");
    httpServer.close();
    nvim.quit();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
```

## Lua Implementation Details

### Complete Registry Implementation

```lua
-- lua/mcp-tools/registry.lua
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
  
  -- Apply defaults
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
  for k, v in pairs(args) do
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
  for _ in pairs(M._tools) do n = n + 1 end
  return n
end

return M
```

### Complete Bridge Process Manager

```lua
-- lua/mcp-tools/bridge.lua
local M = {}

---@type vim.SystemObj?
M._process = nil

---@type number?
M._port = nil

---@type fun(port: number)?
M._on_ready = nil

---@type string?
M._bridge_path = nil

---Find the bridge script path relative to this plugin
---@return string
local function find_bridge_path()
  if M._bridge_path then
    return M._bridge_path
  end
  
  -- Get the path to this Lua file
  local source = debug.getinfo(1, 'S').source
  if source:sub(1, 1) == '@' then
    source = source:sub(2)
  end
  
  -- Navigate up from lua/mcp-tools/bridge.lua to plugin root
  local plugin_dir = vim.fn.fnamemodify(source, ':h:h:h')
  M._bridge_path = plugin_dir .. '/bridge/src/index.ts'
  
  return M._bridge_path
end

---Detect available runtime (bun or node+tsx)
---@return string[] command
local function get_runtime_command()
  -- Prefer bun if available
  if vim.fn.executable('bun') == 1 then
    return { 'bun', 'run' }
  end
  
  -- Fall back to npx tsx
  if vim.fn.executable('npx') == 1 then
    return { 'npx', 'tsx' }
  end
  
  error('No JavaScript runtime found. Install bun or Node.js with npx.')
end

---@class BridgeStartOpts
---@field nvim_socket string The NeoVim server socket path
---@field port? number Port to listen on (0 for auto)
---@field on_ready? fun(port: number) Called when bridge is ready

---Start the MCP bridge server
---@param opts BridgeStartOpts
function M.start(opts)
  if M._process then
    vim.notify('MCP bridge already running', vim.log.levels.WARN)
    return
  end
  
  local bridge_path = find_bridge_path()
  if vim.fn.filereadable(bridge_path) ~= 1 then
    vim.notify('MCP bridge not found at: ' .. bridge_path, vim.log.levels.ERROR)
    return
  end
  
  local cmd = get_runtime_command()
  table.insert(cmd, bridge_path)
  
  M._on_ready = opts.on_ready
  
  M._process = vim.system(cmd, {
    env = {
      NVIM_LISTEN_ADDRESS = opts.nvim_socket,
      MCP_PORT = tostring(opts.port or 0),
      -- Inherit PATH for bun/node
      PATH = vim.env.PATH,
    },
    stdout = function(err, data)
      if data then
        -- Parse port from bridge stdout
        local port = data:match('MCP server listening on port (%d+)')
        if port then
          M._port = tonumber(port)
          vim.schedule(function()
            vim.notify('MCP bridge ready on port ' .. M._port, vim.log.levels.INFO)
            if M._on_ready then
              M._on_ready(M._port)
            end
          end)
        end
      end
    end,
    stderr = function(err, data)
      if data and data:match('%S') then
        vim.schedule(function()
          vim.notify('MCP bridge: ' .. data, vim.log.levels.DEBUG)
        end)
      end
    end,
  }, function(result)
    -- On exit
    vim.schedule(function()
      if result.code ~= 0 and result.code ~= nil then
        vim.notify('MCP bridge exited with code ' .. result.code, vim.log.levels.WARN)
      end
      M._process = nil
      M._port = nil
    end)
  end)
end

---Stop the MCP bridge server
function M.stop()
  if M._process then
    M._process:kill('sigterm')
    M._process = nil
    M._port = nil
  end
end

---Check if bridge is running
---@return boolean
function M.is_running()
  return M._process ~= nil
end

---Get the port the bridge is listening on
---@return number?
function M.get_port()
  return M._port
end

return M
```

### Example DAP Tool Implementation

```lua
-- lua/mcp-tools/tools/dap.lua
local registry = require('mcp-tools.registry')

-- Only register if nvim-dap is available
local ok, dap = pcall(require, 'dap')
if not ok then
  return
end

registry.register({
  name = 'dap_status',
  description = 'Get the current debug session status including whether a session is active, the stopped thread, and session capabilities',
  args = {},
  execute = function(args)
    local session = dap.session()
    if not session then
      return {
        active = false,
        message = 'No active debug session',
      }
    end
    
    return {
      active = true,
      stopped_thread_id = session.stopped_thread_id,
      capabilities = session.capabilities,
    }
  end,
})

registry.register({
  name = 'dap_stacktrace',
  description = 'Get the current call stack for the stopped thread. Returns stack frames with function names, file paths, and line numbers.',
  args = {
    thread_id = {
      type = 'number',
      description = 'Thread ID to get stack for (defaults to stopped thread)',
      required = false,
    },
    levels = {
      type = 'number',
      description = 'Maximum number of stack frames to return',
      required = false,
      default = 20,
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = 'No active debug session' }
    end
    
    local thread_id = args.thread_id or session.stopped_thread_id
    if not thread_id then
      return { error = 'No stopped thread' }
    end
    
    -- DAP request is synchronous in this context
    local response, err = session:request('stackTrace', {
      threadId = thread_id,
      levels = args.levels,
    })
    
    if err then
      return { error = tostring(err) }
    end
    
    return {
      thread_id = thread_id,
      total_frames = response.totalFrames,
      stack_frames = response.stackFrames,
    }
  end,
})

registry.register({
  name = 'dap_variables',
  description = 'Get variables in a scope. Use dap_scopes first to get scope IDs.',
  args = {
    variables_reference = {
      type = 'number',
      description = 'Variables reference ID from a scope or parent variable',
      required = true,
    },
    filter = {
      type = 'string',
      description = 'Filter: "indexed" for array elements, "named" for properties',
      required = false,
    },
    start = {
      type = 'number',
      description = 'Start index for indexed variables',
      required = false,
    },
    count = {
      type = 'number',
      description = 'Number of variables to return',
      required = false,
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = 'No active debug session' }
    end
    
    local request_args = {
      variablesReference = args.variables_reference,
    }
    if args.filter then request_args.filter = args.filter end
    if args.start then request_args.start = args.start end
    if args.count then request_args.count = args.count end
    
    local response, err = session:request('variables', request_args)
    
    if err then
      return { error = tostring(err) }
    end
    
    return response.variables
  end,
})

registry.register({
  name = 'dap_evaluate',
  description = 'Evaluate an expression in the debug context. Can evaluate variables, expressions, or execute REPL commands.',
  args = {
    expression = {
      type = 'string',
      description = 'Expression to evaluate',
      required = true,
    },
    frame_id = {
      type = 'number',
      description = 'Stack frame ID for evaluation context',
      required = false,
    },
    context = {
      type = 'string',
      description = 'Context: "watch", "repl", or "hover"',
      required = false,
      default = 'repl',
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = 'No active debug session' }
    end
    
    local response, err = session:request('evaluate', {
      expression = args.expression,
      frameId = args.frame_id,
      context = args.context,
    })
    
    if err then
      return { error = tostring(err) }
    end
    
    return {
      result = response.result,
      type = response.type,
      variables_reference = response.variablesReference,
    }
  end,
})
```

## OpenCode Integration Details

### Detecting OpenCode Server Lifecycle

```lua
-- lua/mcp-tools/integrations/opencode.lua

local M = {}

function M.setup()
  local ok, opencode_state = pcall(require, 'opencode.state')
  if not ok then
    return -- opencode.nvim not installed
  end
  
  opencode_state.subscribe('opencode_server', function(_, server, prev)
    if server and server.url then
      -- Server started
      require('mcp-tools.bridge').start({
        nvim_socket = vim.v.servername,
        on_ready = function(port)
          M._register_with_opencode(server.url, port)
        end,
      })
    elseif prev and not server then
      -- Server stopped
      require('mcp-tools.bridge').stop()
    end
  end)
end

function M._register_with_opencode(opencode_url, mcp_port)
  -- Use vim.system or plenary.curl to POST to OpenCode
  vim.system({
    'curl', '-X', 'POST',
    '-H', 'Content-Type: application/json',
    '-d', vim.json.encode({
      name = 'nvim-tools',
      config = {
        type = 'remote',
        url = 'http://127.0.0.1:' .. mcp_port,
      },
    }),
    opencode_url .. '/mcp',
  })
end

return M
```

### OpenCode Server API Reference

From OpenCode's server documentation:

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/mcp` | Add MCP server dynamically. Body: `{ name, config }` |
| `GET` | `/mcp` | Get MCP server status |

The `config` object for remote MCP:
```json
{
  "type": "remote",
  "url": "http://127.0.0.1:<port>",
  "enabled": true
}
```

## Implementation Phases

### Phase 1: Core Infrastructure

1. Create plugin directory structure
2. Implement `registry.lua` - tool registration/execution
3. Implement `bridge.lua` - process lifecycle management
4. Create minimal TypeScript bridge that discovers and executes tools
5. Basic `init.lua` with `setup()` function

**Deliverable:** Manual tool registration and bridge startup works.

### Phase 2: OpenCode Integration

1. Implement `integrations/opencode.lua`
2. Auto-start bridge when OpenCode server starts
3. Auto-register MCP with OpenCode via POST /mcp
4. Auto-stop bridge when OpenCode server stops

**Deliverable:** Tools automatically available in OpenCode sessions.

### Phase 3: Built-in DAP Tools

1. Implement `tools/dap.lua` with core debugging tools
2. Handle DAP session lifecycle (tools gracefully fail when no session)
3. Test with actual debugging sessions

**Deliverable:** Can inspect debug state from OpenCode.

### Phase 4: Additional Built-in Tools

1. Implement `tools/diagnostics.lua`
2. Implement `tools/lsp.lua`
3. Implement `tools/undo.lua`

**Deliverable:** Full suite of built-in tools.

### Phase 5: Polish

1. Vim help documentation
2. README with usage examples
3. Installation script for bridge dependencies
4. Health check (`:checkhealth mcp-tools`)
5. Error handling and edge cases

**Deliverable:** Release-ready plugin.

## Testing Strategy

### Unit Tests

- Tool registration and unregistration
- Argument validation and defaults
- Tool execution with mocked functions
- Registry list() returns serializable data (no functions)
- Error handling in execute()

### Integration Tests

- Bridge spawning and communication
- OpenCode state subscription
- MCP protocol compliance
- Port parsing from bridge stdout
- Graceful shutdown on SIGTERM

### Manual Testing

- With actual OpenCode session
- With nvim-dap debugging session
- Multiple NeoVim instances simultaneously
- Bridge restart after crash
- Tool registration after bridge start (dynamic discovery)

### Test Commands

```bash
# Run bridge standalone for testing
NVIM_LISTEN_ADDRESS=/run/user/1000/nvim.12345.0 MCP_PORT=9999 bun run bridge/src/index.ts

# Test MCP endpoint with curl
curl -N http://localhost:9999/mcp

# In NeoVim, test tool registration
:lua require('mcp-tools').register({ name = 'test', description = 'Test tool', args = {}, execute = function() return 'ok' end })
:lua print(vim.inspect(require('mcp-tools.registry').list()))
:lua print(vim.inspect(require('mcp-tools.registry').execute('test', {})))
```

## Edge Cases and Considerations

### Tool Execution Context

Tools execute in NeoVim's main Lua context. Consider:

1. **Blocking operations** - Long-running tools will block NeoVim. Consider using `vim.schedule()` for heavy work.
2. **Buffer context** - Tools that operate on "current buffer" need to handle the case where the user switches buffers.
3. **Error handling** - Always wrap tool logic in pcall and return meaningful error messages.

### DAP Session Lifecycle

DAP sessions can start/stop independently of OpenCode sessions:

```lua
-- Tools should gracefully handle missing sessions
execute = function(args)
  local session = require('dap').session()
  if not session then
    return { error = 'No active debug session' }
  end
  -- ...
end
```

### Bridge Process Management

The bridge process is a child of NeoVim. Edge cases:

1. **NeoVim crashes** - Bridge orphaned, will exit when socket connection fails
2. **Bridge crashes** - Lua side should detect and optionally restart
3. **Multiple start() calls** - Should be idempotent (check if already running)
4. **Port conflicts** - Use port 0 to let OS assign

### Dynamic Tool Discovery

The bridge discovers tools on each `tools/list` call. This means:

1. **Lazy loading** - Plugins that register tools on-demand will work
2. **Runtime changes** - Tools can be added/removed while bridge is running
3. **No caching** - Each discovery call queries NeoVim (acceptable overhead)

### Serialization Constraints

Data returned from tools must be JSON-serializable:

- No functions
- No circular references  
- No metatables (use vim.deepcopy if needed)
- Userdata must be converted to primitive types

```lua
-- BAD: Returns non-serializable data
execute = function() 
  return vim.api.nvim_get_current_buf()  -- Returns buffer handle (number), OK
end

-- BAD: Returns function
execute = function()
  return { callback = function() end }  -- Will fail serialization
end

-- GOOD: Return plain data
execute = function()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end
```

## Dependencies

### Lua (NeoVim)

- NeoVim 0.9+ (for `vim.system`)
- Optional: `nvim-dap` (for DAP tools)

### TypeScript Bridge

- Node.js 18+ or Bun 1.0+
- `neovim` - NeoVim msgpack-rpc client
- `@modelcontextprotocol/sdk` - MCP server implementation
- `express` - HTTP server (for SSE transport)

## Open Questions

1. **Bridge runtime:** Bun vs Node.js? Bun is faster to start but less common.
   - **Recommendation:** Support both, prefer Bun if available.

2. **MCP transport:** HTTP/SSE vs stdio?
   - HTTP/SSE is required for OpenCode's remote MCP registration.
   - Could support stdio for other integrations in the future.

3. **Tool namespacing:** Should tool names be prefixed (e.g., `nvim_dap_stacktrace`)?
   - **Recommendation:** Yes, use `nvim_` prefix to avoid conflicts with other MCP tools.

4. **Configuration persistence:** Should we modify `.opencode/opencode.json`?
   - **Recommendation:** No, use dynamic registration only. Avoids file conflicts.

## OpenCode.nvim Source Reference

Key files in OpenCode.nvim that implementers may want to reference (paths relative to `~/.local/share/nvim/lazy/opencode.nvim/`):

| File | Purpose |
|------|---------|
| `lua/opencode/state.lua` | Observable state with subscribe/unsubscribe pattern |
| `lua/opencode/event_manager.lua` | Event system, custom events like `server_ready` |
| `lua/opencode/opencode_server.lua` | Server spawning with `vim.system` |
| `lua/opencode/server_job.lua` | API client, `ensure_server()` function |
| `lua/opencode/api_client.lua` | HTTP API methods including experimental tool endpoints |
| `lua/opencode/context.lua` | How OpenCode gathers editor context (diagnostics, selections) |
| `lua/opencode/config.lua` | Configuration schema and defaults |

### How OpenCode.nvim Spawns the Server

From `opencode_server.lua`, the server is spawned via:
```lua
self.job = vim.system({
  'opencode',
  'serve',
}, {
  cwd = opts.cwd,
  stdout = function(err, data)
    if data then
      local url = data:match('opencode server listening on ([^%s]+)')
      if url then
        self.url = url
        self.spawn_promise:resolve(self)
      end
    end
  end,
  stderr = function(err, data)
    -- error handling
  end,
}, function(exit_opts)
  -- cleanup on exit
end)
```

The server URL is parsed from stdout when the server prints `"opencode server listening on <url>"`.

### OpenCode's Experimental Tool Endpoints

OpenCode has experimental endpoints for querying available tools:

| Endpoint | Description |
|----------|-------------|
| `GET /experimental/tool/ids` | List all tool IDs (built-in + dynamic) |
| `GET /experimental/tool?provider=<p>&model=<m>` | List tools with JSON schemas |

These are exposed in `api_client.lua`:
```lua
function OpencodeApiClient:list_tool_ids(directory)
  return self:_call('/experimental/tool/ids', 'GET', nil, { directory = directory })
end

function OpencodeApiClient:list_tools(provider, model, directory)
  return self:_call('/experimental/tool', 'GET', nil, {
    provider = provider,
    model = model,
    directory = directory,
  })
end
```

## nvim-dap API Reference

For implementing DAP tools, here are the key nvim-dap APIs:

### Getting the Current Session

```lua
local dap = require('dap')
local session = dap.session()  -- Returns current session or nil

if session then
  -- Session is active
  local thread_id = session.stopped_thread_id  -- Thread that hit breakpoint
end
```

### Making DAP Requests

The session object has a `request` method for DAP protocol requests:

```lua
-- Get stack trace
local response = session:request('stackTrace', {
  threadId = session.stopped_thread_id,
  levels = 20,  -- Max frames to return
})
-- response.stackFrames is array of stack frames

-- Get scopes for a frame
local scopes_response = session:request('scopes', {
  frameId = frame.id,
})
-- scopes_response.scopes is array of scopes

-- Get variables in a scope  
local vars_response = session:request('variables', {
  variablesReference = scope.variablesReference,
})
-- vars_response.variables is array of variables

-- Evaluate an expression
local eval_response = session:request('evaluate', {
  expression = 'myVariable',
  frameId = frame.id,  -- Optional: context for evaluation
  context = 'repl',    -- 'watch', 'repl', or 'hover'
})
-- eval_response.result is the string result
```

### DAP Listeners

nvim-dap has an event system for monitoring debug events:

```lua
local dap = require('dap')

-- Listen for stopped events (breakpoint hit, step complete, etc.)
dap.listeners.after.event_stopped['my-plugin'] = function(session, body)
  -- body.reason: 'breakpoint', 'step', 'exception', etc.
  -- body.threadId: the stopped thread
end

-- Listen for session changes
dap.listeners.on_session['my-plugin'] = function(old_session, new_session)
  -- Called when session starts/stops
end
```

### Breakpoints

```lua
local breakpoints = require('dap.breakpoints')

-- Get all breakpoints
local all_bps = breakpoints.get()  -- { [bufnr] = { bp1, bp2, ... }, ... }

-- Get breakpoints for specific buffer
local buf_bps = breakpoints.get(bufnr)
```

## Error Handling Pattern

The registry's `execute` function returns a tuple `[result, error]` to handle errors gracefully:

```lua
---Execute a tool (called by MCP bridge via RPC)
---@param name string
---@param args table
---@return any result, string? error
function M.execute(name, args)
  local tool = M._tools[name]
  if not tool then
    return nil, "Unknown tool: " .. name
  end
  
  local ok, result = pcall(tool.execute, args or {})
  if not ok then
    return nil, "Tool error: " .. tostring(result)
  end
  return result, nil
end
```

The TypeScript bridge handles this pattern:
```typescript
const [result, error] = await nvim.call('luaeval', [
  `require('mcp-tools.registry').execute(_A.name, _A.args)`,
  { name, args }
]) as [any, string | null];

if (error) {
  return { content: [{ type: "text", text: `Error: ${error}` }], isError: true };
}
```

## References

- [OpenCode Documentation](https://opencode.ai/docs/)
- [OpenCode MCP Servers](https://opencode.ai/docs/mcp-servers/)
- [OpenCode Server API](https://opencode.ai/docs/server/)
- [OpenCode Plugins](https://opencode.ai/docs/plugins/)
- [OpenCode Custom Tools](https://opencode.ai/docs/custom-tools/)
- [Model Context Protocol Specification](https://spec.modelcontextprotocol.io/)
- [nvim-dap](https://github.com/mfussenegger/nvim-dap)
- [nvim-dap API Documentation](https://github.com/mfussenegger/nvim-dap/blob/master/doc/dap.txt)
- [NeoVim RPC API](https://neovim.io/doc/user/api.html)
- [neovim npm package](https://www.npmjs.com/package/neovim)
