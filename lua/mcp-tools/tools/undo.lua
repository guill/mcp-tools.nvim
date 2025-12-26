local registry = require("mcp-tools.registry")

registry.register({
  name = "undo_tree",
  description = "Get the undo tree structure for a buffer",
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
    vim.api.nvim_set_current_buf(bufnr)
    local tree = vim.fn.undotree()
    return {
      seq_cur = tree.seq_cur,
      seq_last = tree.seq_last,
      save_cur = tree.save_cur,
      save_last = tree.save_last,
      entries = tree.entries,
    }
  end,
})
