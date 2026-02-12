import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
  CallToolResult,
} from "@modelcontextprotocol/sdk/types.js";
import { isInitializeRequest } from "@modelcontextprotocol/sdk/types.js";
import { attach, NeovimClient } from "neovim";
import express, { Request, Response, NextFunction } from "express";

const NVIM_SOCKET = process.env.NVIM_LISTEN_ADDRESS;
const PORT = parseInt(process.env.MCP_PORT || "0");
const LOG_FILE = process.env.MCP_LOG_FILE;
const AUTH_TOKEN = process.env.MCP_AUTH_TOKEN;
const POLL_INTERVAL_MS = 100;
const TOOL_TIMEOUT_MS = parseInt(process.env.MCP_TOOL_TIMEOUT || "0") || 0;
const UNLIMITED_TIMEOUT = 0;

let logStream: fs.WriteStream | null = null;
if (LOG_FILE) {
  const logDir = path.dirname(LOG_FILE);
  if (!fs.existsSync(logDir)) {
    fs.mkdirSync(logDir, { recursive: true });
  }
  logStream = fs.createWriteStream(LOG_FILE, { flags: "a" });
}

// The neovim package monkey-patches console.* to redirect to a silent logger.
// We must use process.stderr.write() for any output we want to see.
function log(msg: string): void {
  const timestamp = new Date().toISOString();
  const line = `[${timestamp}] [bridge] ${msg}`;
  process.stderr.write(line + "\n");
  if (logStream) {
    logStream.write(line + "\n");
  }
}

if (!NVIM_SOCKET) {
  log("ERROR: NVIM_LISTEN_ADDRESS environment variable not set");
  process.exit(1);
}

if (!AUTH_TOKEN) {
  log("ERROR: MCP_AUTH_TOKEN environment variable not set");
  process.exit(1);
}

function validateAuthToken(req: Request): boolean {
  const authHeader = req.headers.authorization;
  if (!authHeader) {
    return false;
  }
  const [scheme, token] = authHeader.split(" ");
  return scheme === "Bearer" && token === AUTH_TOKEN;
}

interface ToolArg {
  type: "string" | "number" | "boolean" | "object" | "array";
  description: string;
  required?: boolean;
  default?: unknown;
  items?: Record<string, unknown>;
  properties?: Record<string, unknown>;

}

interface ToolDef {
  name: string;
  description: string;
  args: Record<string, ToolArg>;
}

interface ExecuteResponse {
  done?: boolean;
  pending?: boolean;
  task_id?: string;
  result?: unknown;
  error?: string;
  timeout?: number;
}

interface GetResultResponse {
  done: boolean;
  result?: unknown;
  error?: string;
}

function formatResult(result: unknown): CallToolResult {
  return {
    content: [
      {
        type: "text",
        text:
          typeof result === "string" ? result : JSON.stringify(result, null, 2),
      },
    ],
  };
}

function formatError(error: string): CallToolResult {
  return {
    content: [{ type: "text", text: `Error: ${error}` }],
    isError: true,
  };
}

async function pollForResult(
  nvim: NeovimClient,
  taskId: string,
  toolTimeout?: number
): Promise<CallToolResult> {
  const startTime = Date.now();
  const effectiveTimeout = toolTimeout !== undefined ? toolTimeout : TOOL_TIMEOUT_MS;
  const hasTimeout = effectiveTimeout !== UNLIMITED_TIMEOUT;

  while (!hasTimeout || Date.now() - startTime < effectiveTimeout) {
    const response = (await nvim.call("luaeval", [
      `require('mcp-tools.registry').get_result(_A)`,
      taskId,
    ])) as GetResultResponse;

    if (response.done) {
      if (response.error) {
        return formatError(response.error);
      }
      return formatResult(response.result);
    }

    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }

  await nvim.call("luaeval", [
    `require('mcp-tools.registry').cancel_task(_A)`,
    taskId,
  ]);

  return formatError(`Timeout after ${effectiveTimeout}ms waiting for tool result`);
}

function createMcpServer(nvim: NeovimClient): Server {
  const server = new Server(
    { name: "mcp-tools-nvim", version: "1.0.0" },
    { capabilities: { tools: {} } }
  );

  async function discoverTools(): Promise<Record<string, ToolDef>> {
    try {
      return (await nvim.call("luaeval", [
        "require('mcp-tools.registry').list()",
      ])) as Record<string, ToolDef>;
    } catch (err) {
      log(`Failed to discover tools: ${err}`);
      return {};
    }
  }

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    log("Handling tools/list request");
    const tools = await discoverTools();
    const toolList = Object.entries(tools).map(([name, def]) => ({
      name: `nvim_${name}`,
      description: def.description,
      inputSchema: {
        type: "object" as const,
        properties: Object.fromEntries(
          Object.entries(def.args).map(([argName, argDef]) => {
            const schema: Record<string, unknown> = {
              type: argDef.type,
              description: argDef.description,
            };
            if (argDef.default !== undefined) {
              schema.default = argDef.default;
            }
            if (argDef.type === "array") {
              schema.items = argDef.items ?? {};
            }
            if (argDef.type === "object" && argDef.properties) {
              schema.properties = argDef.properties;
            }

            return [argName, schema];
          })
        ),
        required: Object.entries(def.args)
          .filter(([_, d]) => d.required)
          .map(([n]) => n),
      },
    }));
    log(`Returning ${toolList.length} tools`);
    return { tools: toolList };
  });

  server.setRequestHandler(
    CallToolRequestSchema,
    async (request): Promise<CallToolResult> => {
      const { name, arguments: args } = request.params;
      const toolName = name.startsWith("nvim_") ? name.slice(5) : name;
      log(`Handling tools/call for: ${name} (${toolName})`);

      try {
        const response = (await nvim.call("luaeval", [
          `require('mcp-tools.registry').execute(_A.name, _A.args)`,
          { name: toolName, args: args || {} },
        ])) as ExecuteResponse;

        if (response.error && response.done) {
          log(`Tool error: ${response.error}`);
          return formatError(response.error);
        }

        if (response.done) {
          log(`Tool completed synchronously`);
          return formatResult(response.result);
        }

        if (response.pending && response.task_id) {
          log(`Tool running async, polling task: ${response.task_id} (timeout: ${response.timeout ?? TOOL_TIMEOUT_MS}ms)`);
          return await pollForResult(nvim, response.task_id, response.timeout);
        }

        return formatError("Unexpected response from tool execution");
      } catch (err) {
        log(`Bridge error: ${err}`);
        return formatError(`Bridge error: ${err}`);
      }
    }
  );

  return server;
}

async function main() {
  log(`Starting MCP bridge, connecting to NeoVim at ${NVIM_SOCKET}`);
  if (LOG_FILE) {
    log(`Logging to file: ${LOG_FILE}`);
  }

  const nvim: NeovimClient = attach({ socket: NVIM_SOCKET });

  log(`Attached to NeoVim, testing connection...`);

  try {
    const version = await nvim.request("nvim_get_api_info", []);
    log(`NeoVim API version: ${version[0]}`);
  } catch (err) {
    log(`Failed to get API info: ${err}`);
  }

  log(`Connected to NeoVim at ${NVIM_SOCKET}`);

  const app = express();
  app.use(express.json());

  app.use((req: Request, res: Response, next: NextFunction) => {
    res.setHeader("Access-Control-Allow-Origin", "null");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, mcp-session-id");

    if (req.method === "OPTIONS") {
      res.status(204).end();
      return;
    }

    next();
  });

  app.use((req: Request, res: Response, next: NextFunction) => {
    if (req.path === "/health") {
      next();
      return;
    }

    if (!validateAuthToken(req)) {
      log(`Unauthorized request to ${req.path} from ${req.ip}`);
      res.status(401).json({
        jsonrpc: "2.0",
        error: { code: -32000, message: "Unauthorized: Invalid or missing auth token" },
        id: null,
      });
      return;
    }

    next();
  });

  const transports: Record<
    string,
    StreamableHTTPServerTransport | SSEServerTransport
  > = {};

  app.all("/", async (req: Request, res: Response) => {
    log(`Received ${req.method} request to / (Streamable HTTP)`);

    try {
      const sessionId = req.headers["mcp-session-id"] as string | undefined;
      let transport: StreamableHTTPServerTransport;

      if (sessionId && transports[sessionId]) {
        const existingTransport = transports[sessionId];
        if (existingTransport instanceof StreamableHTTPServerTransport) {
          transport = existingTransport;
          log(`Reusing existing Streamable HTTP session: ${sessionId}`);
        } else {
          res.status(400).json({
            jsonrpc: "2.0",
            error: {
              code: -32000,
              message:
                "Bad Request: Session exists but uses a different transport protocol",
            },
            id: null,
          });
          return;
        }
      } else if (
        !sessionId &&
        req.method === "POST" &&
        isInitializeRequest(req.body)
      ) {
        log(`Creating new Streamable HTTP transport (stateless mode)`);
        transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (sid) => {
            log(`Streamable HTTP session initialized: ${sid}`);
            transports[sid] = transport;
          },
        });

        transport.onclose = () => {
          const sid = transport.sessionId;
          if (sid && transports[sid]) {
            log(`Transport closed for session ${sid}`);
            delete transports[sid];
          }
        };

        const server = createMcpServer(nvim);
        await server.connect(transport);
      } else if (req.method === "GET") {
        log(`GET request without session, returning 405`);
        res.status(405).json({
          jsonrpc: "2.0",
          error: {
            code: -32000,
            message: "Method not allowed: Use POST to initialize session",
          },
          id: null,
        });
        return;
      } else {
        log(`Invalid request: no session ID and not initialization`);
        res.status(400).json({
          jsonrpc: "2.0",
          error: {
            code: -32000,
            message: "Bad Request: No valid session ID provided",
          },
          id: null,
        });
        return;
      }

      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      log(`Error handling Streamable HTTP request: ${error}`);
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: {
            code: -32603,
            message: "Internal server error",
          },
          id: null,
        });
      }
    }
  });

  app.get("/sse", async (_req: Request, res: Response) => {
    log(`Received GET request to /sse (deprecated SSE transport)`);
    const transport = new SSEServerTransport("/messages", res);
    transports[transport.sessionId] = transport;

    res.on("close", () => {
      log(`SSE connection closed for session ${transport.sessionId}`);
      delete transports[transport.sessionId];
    });

    const server = createMcpServer(nvim);
    await server.connect(transport);
    log(`SSE transport connected with session: ${transport.sessionId}`);
  });

  app.post("/messages", async (req: Request, res: Response) => {
    const sessionId = req.query.sessionId as string;
    log(`Received POST to /messages for session: ${sessionId}`);

    const existingTransport = transports[sessionId];
    if (existingTransport instanceof SSEServerTransport) {
      await existingTransport.handlePostMessage(req, res, req.body);
    } else if (existingTransport instanceof StreamableHTTPServerTransport) {
      res.status(400).json({
        jsonrpc: "2.0",
        error: {
          code: -32000,
          message:
            "Bad Request: Session exists but uses a different transport protocol",
        },
        id: null,
      });
    } else {
      log(`No transport found for session: ${sessionId}`);
      res.status(400).send("No transport found for sessionId");
    }
  });

  app.get("/health", (_req: Request, res: Response) => {
    res.json({ status: "ok", nvim: NVIM_SOCKET });
  });

  const httpServer = app.listen(PORT, "127.0.0.1", () => {
    const addr = httpServer.address();
    const actualPort = typeof addr === "object" ? addr?.port : PORT;
    // Parsed by Lua bridge.lua to extract the port number
    process.stdout.write(`MCP server listening on port ${actualPort}\n`);
    log(`Server started on port ${actualPort}`);
  });

  const shutdown = async (signal: string) => {
    log(`Received ${signal}, shutting down...`);

    for (const sessionId in transports) {
      try {
        log(`Closing transport for session ${sessionId}`);
        await transports[sessionId]!.close();
        delete transports[sessionId];
      } catch (error) {
        log(`Error closing transport for session ${sessionId}: ${error}`);
      }
    }

    httpServer.close();
    nvim.quit();

    if (logStream) {
      logStream.end();
    }

    log("Server shutdown complete");
    process.exit(0);
  };

  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main().catch((err) => {
  log(`Fatal error: ${err}`);
  process.exit(1);
});
