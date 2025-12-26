local registry = require("mcp-tools.registry")

local ok, dap = pcall(require, "dap")
if not ok then
  return
end

registry.register({
  name = "dap_status",
  description = "Get current debug session status including whether a session is active, stopped thread, and capabilities",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { active = false, message = "No active debug session" }
    end
    return {
      active = true,
      stopped_thread_id = session.stopped_thread_id,
      capabilities = session.capabilities,
    }
  end,
})

registry.register({
  name = "dap_stacktrace",
  description = "Get the current call stack for the stopped thread. Returns stack frames with function names, file paths, and line numbers.",
  args = {
    thread_id = {
      type = "number",
      description = "Thread ID to get stack for (defaults to stopped thread)",
      required = false,
    },
    levels = {
      type = "number",
      description = "Maximum number of stack frames to return",
      required = false,
      default = 20,
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    local thread_id = args.thread_id or session.stopped_thread_id
    if not thread_id then
      return { error = "No stopped thread" }
    end

    local response, err = session:request("stackTrace", {
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
  name = "dap_scopes",
  description = "Get scopes for a stack frame. Returns scope information including variables references.",
  args = {
    frame_id = {
      type = "number",
      description = "Stack frame ID to get scopes for",
      required = true,
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    local response, err = session:request("scopes", {
      frameId = args.frame_id,
    })

    if err then
      return { error = tostring(err) }
    end

    return response.scopes
  end,
})

registry.register({
  name = "dap_variables",
  description = "Get variables in a scope. Use dap_scopes first to get variablesReference IDs.",
  args = {
    variables_reference = {
      type = "number",
      description = "Variables reference ID from a scope or parent variable",
      required = true,
    },
    filter = {
      type = "string",
      description = "Filter: 'indexed' for array elements, 'named' for properties",
      required = false,
    },
    start = {
      type = "number",
      description = "Start index for indexed variables",
      required = false,
    },
    count = {
      type = "number",
      description = "Number of variables to return",
      required = false,
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    local request_args = {
      variablesReference = args.variables_reference,
    }
    if args.filter then
      request_args.filter = args.filter
    end
    if args.start then
      request_args.start = args.start
    end
    if args.count then
      request_args.count = args.count
    end

    local response, err = session:request("variables", request_args)

    if err then
      return { error = tostring(err) }
    end

    return response.variables
  end,
})

registry.register({
  name = "dap_evaluate",
  description = "Evaluate an expression in the debug context. Can evaluate variables, expressions, or execute REPL commands.",
  args = {
    expression = {
      type = "string",
      description = "Expression to evaluate",
      required = true,
    },
    frame_id = {
      type = "number",
      description = "Stack frame ID for evaluation context",
      required = false,
    },
    context = {
      type = "string",
      description = "Context: 'watch', 'repl', or 'hover'",
      required = false,
      default = "repl",
    },
  },
  execute = function(args)
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    local response, err = session:request("evaluate", {
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

registry.register({
  name = "dap_breakpoints",
  description = "List all breakpoints, optionally filtered by buffer",
  args = {
    bufnr = {
      type = "number",
      description = "Buffer number to filter by (optional)",
      required = false,
    },
  },
  execute = function(args)
    local breakpoints = require("dap.breakpoints")
    local all_bps = breakpoints.get(args.bufnr)

    local result = {}
    for bufnr, bps in pairs(all_bps) do
      local filename = vim.api.nvim_buf_get_name(bufnr)
      for _, bp in ipairs(bps) do
        table.insert(result, {
          bufnr = bufnr,
          file = filename,
          line = bp.line,
          condition = bp.condition,
          hit_condition = bp.hitCondition,
          log_message = bp.logMessage,
        })
      end
    end

    return result
  end,
})

registry.register({
  name = "dap_threads",
  description = "List all threads in the debug session",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    local response, err = session:request("threads", {})

    if err then
      return { error = tostring(err) }
    end

    return response.threads
  end,
})

registry.register({
  name = "dap_continue",
  description = "Continue execution of the debugged program",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    dap.continue()
    return { success = true, message = "Continuing execution" }
  end,
})

registry.register({
  name = "dap_step_over",
  description = "Step over to the next line",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    dap.step_over()
    return { success = true, message = "Stepped over" }
  end,
})

registry.register({
  name = "dap_step_into",
  description = "Step into the function call",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    dap.step_into()
    return { success = true, message = "Stepped into" }
  end,
})

registry.register({
  name = "dap_step_out",
  description = "Step out of the current function",
  args = {},
  execute = function()
    local session = dap.session()
    if not session then
      return { error = "No active debug session" }
    end

    dap.step_out()
    return { success = true, message = "Stepped out" }
  end,
})
