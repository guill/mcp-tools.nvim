local registry = require("mcp-tools.registry")

registry.register({
  name = "multiple_choice_prompt",
  description = "Prompt the user to select one option from a list of choices. Returns the selected option or nil if cancelled.",
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

registry.register({
  name = "get_open_buffers",
  description = "Get a list of all open buffers with their buffer numbers, file names, and metadata",
  args = {},
  execute = function(cb, args)
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
