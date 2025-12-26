local registry = require("mcp-tools.registry")

registry.register({
  name = "lsp_hover",
  description = "Get hover information at cursor position",
  args = {
    bufnr = {
      type = "number",
      description = "Buffer number (0 for current)",
      required = false,
      default = 0,
    },
    line = {
      type = "number",
      description = "Line number (1-indexed, defaults to cursor)",
      required = false,
    },
    col = {
      type = "number",
      description = "Column number (1-indexed, defaults to cursor)",
      required = false,
    },
  },
  execute = function(args)
    local bufnr = args.bufnr == 0 and vim.api.nvim_get_current_buf() or args.bufnr
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = args.line and (args.line - 1) or cursor[1] - 1
    local col = args.col and (args.col - 1) or cursor[2]

    local params = {
      textDocument = vim.lsp.util.make_text_document_params(bufnr),
      position = { line = line, character = col },
    }

    local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, 2000)
    if not results then
      return { error = "No hover information available" }
    end

    for _, result in pairs(results) do
      if result.result and result.result.contents then
        local contents = result.result.contents
        if type(contents) == "table" then
          if contents.value then
            return { hover = contents.value, kind = contents.kind }
          elseif contents[1] then
            return { hover = contents[1].value or contents[1], kind = contents[1].kind }
          end
        else
          return { hover = contents }
        end
      end
    end

    return { error = "No hover information available" }
  end,
})

registry.register({
  name = "lsp_symbols",
  description = "Get document symbols for a buffer",
  args = {
    bufnr = {
      type = "number",
      description = "Buffer number (0 for current)",
      required = false,
      default = 0,
    },
  },
  execute = function(args)
    local bufnr = args.bufnr == 0 and vim.api.nvim_get_current_buf() or args.bufnr
    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }

    local results = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 5000)
    if not results then
      return { error = "No symbols found" }
    end

    local symbols = {}
    for _, result in pairs(results) do
      if result.result then
        for _, symbol in ipairs(result.result) do
          table.insert(symbols, {
            name = symbol.name,
            kind = vim.lsp.protocol.SymbolKind[symbol.kind] or symbol.kind,
            range = symbol.range or (symbol.location and symbol.location.range),
          })
        end
      end
    end

    return symbols
  end,
})
