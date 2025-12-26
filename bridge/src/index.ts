import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
  CallToolResult,
} from "@modelcontextprotocol/sdk/types.js";
import { attach, NeovimClient } from "neovim";
import express, { Request, Response } from "express";

const NVIM_SOCKET = process.env.NVIM_LISTEN_ADDRESS;
const PORT = parseInt(process.env.MCP_PORT || "0");
const POLL_INTERVAL_MS = 100;
const MAX_WAIT_MS = 300000; // 5 minutes

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

interface ExecuteResponse {
  done?: boolean;
  pending?: boolean;
  task_id?: string;
  result?: unknown;
  error?: string;
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
  taskId: string
): Promise<CallToolResult> {
  const startTime = Date.now();

  while (Date.now() - startTime < MAX_WAIT_MS) {
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

  return formatError(`Timeout after ${MAX_WAIT_MS}ms waiting for tool result`);
}

async function main() {
  const nvim: NeovimClient = attach({ socket: NVIM_SOCKET });

  console.error(`Connected to NeoVim at ${NVIM_SOCKET}`);

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
      console.error("Failed to discover tools:", err);
      return {};
    }
  }

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    const tools = await discoverTools();
    return {
      tools: Object.entries(tools).map(([name, def]) => ({
        name: `nvim_${name}`,
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

  server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CallToolResult> => {
    const { name, arguments: args } = request.params;
    const toolName = name.startsWith("nvim_") ? name.slice(5) : name;

    try {
      const response = (await nvim.call("luaeval", [
        `require('mcp-tools.registry').execute(_A.name, _A.args)`,
        { name: toolName, args: args || {} },
      ])) as ExecuteResponse;

      if (response.error && response.done) {
        return formatError(response.error);
      }

      if (response.done) {
        return formatResult(response.result);
      }

      if (response.pending && response.task_id) {
        return await pollForResult(nvim, response.task_id);
      }

      return formatError("Unexpected response from tool execution");
    } catch (err) {
      return formatError(`Bridge error: ${err}`);
    }
  });

  const app = express();

  const transports: Map<string, SSEServerTransport> = new Map();

  app.get("/sse", async (req: Request, res: Response) => {
    const sessionId = req.query.sessionId as string | undefined;
    const transport = new SSEServerTransport("/messages", res);

    if (sessionId) {
      transports.set(sessionId, transport);
    }

    res.on("close", () => {
      if (sessionId) {
        transports.delete(sessionId);
      }
    });

    await server.connect(transport);
  });

  app.post("/messages", express.json(), async (req: Request, res: Response) => {
    const sessionId = req.query.sessionId as string | undefined;
    const transport = sessionId ? transports.get(sessionId) : undefined;

    if (!transport) {
      res.status(400).json({ error: "No transport found for session" });
      return;
    }

    await transport.handlePostMessage(req, res);
  });

  app.get("/health", (_req: Request, res: Response) => {
    res.json({ status: "ok", nvim: NVIM_SOCKET });
  });

  const httpServer = app.listen(PORT, "127.0.0.1", () => {
    const addr = httpServer.address();
    const actualPort = typeof addr === "object" ? addr?.port : PORT;
    console.log(`MCP server listening on port ${actualPort}`);
  });

  process.on("SIGTERM", () => {
    console.error("Received SIGTERM, shutting down...");
    httpServer.close();
    nvim.quit();
    process.exit(0);
  });

  process.on("SIGINT", () => {
    console.error("Received SIGINT, shutting down...");
    httpServer.close();
    nvim.quit();
    process.exit(0);
  });
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
