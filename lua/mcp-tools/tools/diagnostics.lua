local registry = require("mcp-tools.registry")

registry.register({
  name = "diagnostics_list",
  description = "Get LSP diagnostics for a buffer",
  args = {
    bufnr = {
      type = "number",
      description = "Buffer number (0 for current)",
      required = false,
      default = 0,
    },
    severity = {
      type = "string",
      description = "Filter by severity: error, warn, info, hint",
      required = false,
    },
  },
  execute = function(args)
    local bufnr = args.bufnr == 0 and vim.api.nvim_get_current_buf() or args.bufnr
    local diagnostics = vim.diagnostic.get(bufnr)

    if args.severity then
      local severity_map = {
        error = vim.diagnostic.severity.ERROR,
        warn = vim.diagnostic.severity.WARN,
        info = vim.diagnostic.severity.INFO,
        hint = vim.diagnostic.severity.HINT,
      }
      local target_severity = severity_map[args.severity:lower()]
      if target_severity then
        diagnostics = vim.tbl_filter(function(d)
          return d.severity == target_severity
        end, diagnostics)
      end
    end

    return vim.tbl_map(function(d)
      return {
        lnum = d.lnum + 1,
        col = d.col + 1,
        message = d.message,
        severity = vim.diagnostic.severity[d.severity],
        source = d.source,
      }
    end, diagnostics)
  end,
})
