-- Test tools for verifying MCP bridge functionality
-- These tools are used to test async/sync execution patterns
local registry = require("mcp-tools.registry")

-- Tests asynchronous tool execution (callback deferred via vim.schedule)
registry.register({
  name = "test_async_prompt",
  description = "Test tool: Prompts user to select from choices (tests async callback execution)",
  args = {
    prompt = {
      type = "string",
      description = "The prompt message to display to the user",
      required = true,
    },
    options = {
      type = "array",
      description = "Array of string options for the user to choose from",
      required = true,
    },
  },
  execute = function(cb, args)
    if not args.options or #args.options == 0 then
      cb(nil, "Options array is required and must not be empty")
      return
    end

    vim.schedule(function()
      vim.ui.select(args.options, { prompt = args.prompt or "Select an option:" }, function(choice, idx)
        if choice then
          cb({ selected = choice, index = idx })
        else
          cb({ selected = nil, cancelled = true })
        end
      end)
    end)
  end,
})

-- Tests synchronous tool execution with NeoVim API calls
registry.register({
  name = "test_sync_buffers",
  description = "Test tool: Lists open buffers (tests sync callback with NeoVim API)",
  args = {},
  execute = function(cb, _)
    local buffers = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        local buftype = vim.bo[bufnr].buftype
        local modified = vim.bo[bufnr].modified
        local readonly = vim.bo[bufnr].readonly
        local filetype = vim.bo[bufnr].filetype
        local line_count = vim.api.nvim_buf_line_count(bufnr)

        table.insert(buffers, {
          bufnr = bufnr,
          name = name ~= "" and name or "[No Name]",
          buftype = buftype,
          filetype = filetype,
          modified = modified,
          readonly = readonly,
          line_count = line_count,
          listed = vim.bo[bufnr].buflisted,
        })
      end
    end
    cb({ buffers = buffers, count = #buffers })
  end,
})
