import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
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

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

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
            text:
              typeof result === "string"
                ? result
                : JSON.stringify(result, null, 2),
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
