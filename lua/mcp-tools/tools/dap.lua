local registry = require("mcp-tools.registry")

local ok, dap = pcall(require, "dap")
if not ok then
  return
end

local program_output = {}
local max_output_lines = 1000

local function init_output_capture(session_id)
  if not program_output[session_id] then
    program_output[session_id] = {
      stdout = {},
      stderr = {},
      console = {},
      all = {},
      start_time = vim.fn.localtime(),
    }
  end
end

local function store_output(session_id, category, output, source)
  if not program_output[session_id] then
    init_output_capture(session_id)
  end

  local storage = program_output[session_id]
  local timestamp = vim.fn.localtime()

  local lines = vim.split(output, "\n", { plain = true })
  for _, line in ipairs(lines) do
    if line ~= "" then
      table.insert(storage[category], line)
      table.insert(storage.all, {
        category = category,
        source = source or "unknown",
        timestamp = timestamp,
        line = line,
      })
    end
  end

  while #storage[category] > max_output_lines do
    table.remove(storage[category], 1)
  end
  while #storage.all > max_output_lines do
    table.remove(storage.all, 1)
  end
end

local function cleanup_output_storage(session_id)
  program_output[session_id] = nil
end

local function get_code_context(file_path, target_line, context_lines)
  context_lines = context_lines or 5

  if not file_path or file_path == "<unknown>" then
    return nil, "Unknown file path"
  end

  if vim.fn.filereadable(file_path) == 0 then
    return nil, "File not readable: " .. file_path
  end

  local lines = {}
  local file = io.open(file_path, "r")
  if not file then
    return nil, "Could not open file: " .. file_path
  end

  local line_num = 1
  for line in file:lines() do
    lines[line_num] = line
    line_num = line_num + 1
  end
  file:close()

  local total_lines = #lines
  if target_line < 1 or target_line > total_lines then
    return nil, "Line " .. target_line .. " is out of range (1-" .. total_lines .. ")"
  end

  local start_line = math.max(1, target_line - context_lines)
  local end_line = math.min(total_lines, target_line + context_lines)

  local context_output = {}
  table.insert(context_output, "\nCode context:")
  table.insert(context_output, string.rep("-", 60))

  for i = start_line, end_line do
    local line_content = lines[i] or ""
    local line_indicator = (i == target_line) and "> " or "  "
    table.insert(context_output, string.format("%s%4d | %s", line_indicator, i, line_content))
  end

  table.insert(context_output, string.rep("-", 60))
  return table.concat(context_output, "\n")
end

local function smart_buffer_management(target_file, target_line)
  local resolved_file = target_file
  if not vim.startswith(resolved_file, "/") then
    resolved_file = vim.fn.getcwd() .. "/" .. resolved_file
  end

  if vim.fn.filereadable(resolved_file) == 0 then
    return nil, "File not found: " .. resolved_file
  end

  local function is_special_buffer(bufnr)
    local buftype = vim.bo[bufnr].buftype
    if buftype ~= "" and buftype ~= "acwrite" then
      return true
    end

    local filetype = vim.bo[bufnr].filetype
    local special_filetypes = {
      "codecompanion", "avante", "chatgpt", "copilot-chat",
      "dap-repl", "dapui_scopes", "dapui_breakpoints",
      "dapui_stacks", "dapui_watches", "dapui_console",
    }
    for _, ft in ipairs(special_filetypes) do
      if filetype == ft then
        return true
      end
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return true
    end

    local special_patterns = { "^term://", "^fugitive://", "^oil://" }
    for _, pattern in ipairs(special_patterns) do
      if string.match(name, pattern) then
        return true
      end
    end

    return false
  end

  local target_bufnr = nil
  local target_winnr = nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      if vim.api.nvim_buf_get_name(bufnr) == resolved_file then
        target_bufnr = bufnr
        for _, winnr in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(winnr) == bufnr then
            target_winnr = winnr
            break
          end
        end
        break
      end
    end
  end

  if target_bufnr and target_winnr then
    vim.api.nvim_set_current_win(target_winnr)
    if target_line then
      vim.api.nvim_win_set_cursor(target_winnr, { target_line, 0 })
    end
    return target_bufnr, target_winnr
  end

  local suitable_winnr = nil
  local current_winnr = vim.api.nvim_get_current_win()

  for _, winnr in ipairs(vim.api.nvim_list_wins()) do
    if winnr ~= current_winnr then
      local bufnr = vim.api.nvim_win_get_buf(winnr)
      if not is_special_buffer(bufnr) then
        suitable_winnr = winnr
        break
      end
    end
  end

  if not suitable_winnr then
    local current_bufnr = vim.api.nvim_win_get_buf(current_winnr)
    if not is_special_buffer(current_bufnr) then
      suitable_winnr = current_winnr
    end
  end

  if suitable_winnr then
    vim.api.nvim_set_current_win(suitable_winnr)
    if target_bufnr then
      vim.api.nvim_win_set_buf(suitable_winnr, target_bufnr)
    else
      vim.cmd("edit " .. vim.fn.fnameescape(resolved_file))
      target_bufnr = vim.api.nvim_get_current_buf()
    end
    if target_line then
      vim.api.nvim_win_set_cursor(suitable_winnr, { target_line, 0 })
    end
    return target_bufnr, suitable_winnr
  end

  local width = vim.api.nvim_win_get_width(0)
  local split_cmd = width > 120 and "vsplit" or "split"
  vim.cmd(split_cmd .. " " .. vim.fn.fnameescape(resolved_file))

  target_bufnr = vim.api.nvim_get_current_buf()
  target_winnr = vim.api.nvim_get_current_win()

  if target_line then
    vim.api.nvim_win_set_cursor(target_winnr, { target_line, 0 })
  end

  return target_bufnr, target_winnr
end

local function wait_until_paused_impl(timeout_ms, check_interval_ms)
  timeout_ms = timeout_ms or 30000
  check_interval_ms = check_interval_ms or 100

  local session = dap.session()
  if not session then
    return false, "No active debug session"
  end

  local pause_detected = false
  local pause_reason = "unknown"
  local pause_location = nil
  local location_updated = false
  local pause_start_time = nil
  local termination_detected = false
  local termination_reason = ""

  local listener_key = "wait_until_paused_" .. tostring(math.random(1000000))

  dap.listeners.after["event_stopped"][listener_key] = function(session_obj, body)
    pause_detected = true
    pause_reason = body.reason or "unknown"
    pause_start_time = vim.fn.localtime() * 1000

    local thread_id = body.threadId
    if not thread_id and session_obj.threads then
      for tid, _ in pairs(session_obj.threads) do
        thread_id = tid
        break
      end
    end

    if thread_id and session_obj.request then
      session_obj:request("stackTrace", {
        threadId = thread_id,
        startFrame = 0,
        levels = 1,
      }, function(err, result)
        if not err and result and result.stackFrames and #result.stackFrames > 0 then
          local frame = result.stackFrames[1]
          pause_location = {
            file = (frame.source and frame.source.path) or "<unknown>",
            line = frame.line or 0,
            function_name = frame.name or "<unknown>",
          }
        else
          pause_location = { file = "<unknown>", line = 0, function_name = "<unknown>" }
        end
        location_updated = true
        vim.schedule(function()
          pcall(dap.focus_frame)
        end)
      end)
    else
      pause_location = { file = "<unknown>", line = 0, function_name = "<unknown>" }
      location_updated = true
      vim.schedule(function()
        pcall(dap.focus_frame)
      end)
    end
    return true
  end

  dap.listeners.after["event_terminated"][listener_key] = function()
    termination_detected = true
    termination_reason = "session terminated"
    return true
  end

  dap.listeners.after["event_exited"][listener_key] = function(_, body)
    termination_detected = true
    termination_reason = "debuggee exited with code " .. (body.exitCode or "unknown")
    return true
  end

  local success = vim.wait(timeout_ms, function()
    if termination_detected then
      return true
    end

    local current_session = dap.session()
    if not current_session or current_session.id ~= session.id then
      termination_detected = true
      termination_reason = "session ended"
      return true
    end

    if pause_detected and location_updated then
      return true
    end

    if pause_detected then
      local time_since_pause = vim.fn.localtime() * 1000 - (pause_start_time or 0)
      if time_since_pause > 2000 then
        if not location_updated then
          pause_location = { file = "<unknown>", line = 0, function_name = "<unknown>" }
          location_updated = true
        end
        return true
      end
    end

    return false
  end, check_interval_ms)

  dap.listeners.after["event_stopped"][listener_key] = nil
  dap.listeners.after["event_terminated"][listener_key] = nil
  dap.listeners.after["event_exited"][listener_key] = nil

  if termination_detected then
    return false, "Debug session ended while waiting: " .. termination_reason
  end

  if not success then
    return false, string.format("Timeout after %dms waiting for debugger to pause", timeout_ms)
  end

  if pause_detected then
    local output = string.format("Debugger paused due to: %s", pause_reason)

    if pause_location then
      output = output .. string.format("\nLocation: %s:%d in %s",
        pause_location.file, pause_location.line or 0, pause_location.function_name)

      local code_context = get_code_context(pause_location.file, pause_location.line, 5)
      if code_context then
        output = output .. code_context
      end
    end

    local current_status = dap.status()
    if current_status and current_status ~= "" then
      output = output .. "\nStatus: " .. current_status
    end

    return true, output
  end

  return false, "Unknown wait condition result"
end

dap.listeners.after["event_output"]["mcp_tools_output_capture"] = function(session, body)
  if session and session.id and body and body.output then
    local category = "console"
    if body.category == "stdout" then
      category = "stdout"
    elseif body.category == "stderr" then
      category = "stderr"
    end
    store_output(session.id, category, body.output, body.source or body.category)
  end
end

dap.listeners.after["event_terminated"]["mcp_tools_output_cleanup"] = function(session)
  if session and session.id then
    cleanup_output_storage(session.id)
  end
end

dap.listeners.after["event_exited"]["mcp_tools_output_cleanup"] = function(session)
  if session and session.id then
    cleanup_output_storage(session.id)
  end
end

-- ============================================================================
-- Session Management Tools
-- ============================================================================

registry.register({
  name = "dap_status",
  description = "Get current debug session status including whether a session is active, stopped thread, and capabilities",
  args = {},
  execute = function(cb)
    local session = dap.session()
    if not session then
      cb({ active = false, message = "No active debug session" })
      return
    end
    cb({
      active = true,
      id = session.id,
      status = dap.status(),
      stopped_thread_id = session.stopped_thread_id,
      adapter_type = session.config and session.config.type or "unknown",
      name = session.config and session.config.name or "unnamed",
      capabilities = session.capabilities,
    })
  end,
})

registry.register({
  name = "dap_run",
  description = "Start a new debug session with specified configuration. Set breakpoints before calling this since the program may finish before you can set them otherwise.",
  args = {
    type = { type = "string", description = "Debug adapter type (e.g., 'python', 'node2', 'cppdbg', 'codelldb')", required = true },
    request = { type = "string", description = "Request type: 'launch' or 'attach'", required = true },
    name = { type = "string", description = "Configuration name", required = true },
    program = { type = "string", description = "Program to debug. Use '${file}' for current file or '${workspaceFolder}' for cwd", required = false },
    args = { type = "array", items = { type = "string" }, description = "Program arguments as JSON array", required = false },
    cwd = { type = "string", description = "Working directory. Use '${workspaceFolder}' for cwd", required = false },
    env = { type = "object", description = "Environment variables as JSON object", required = false },
    host = { type = "string", description = "Host to connect to (for attach requests)", required = false },
    port = { type = "number", description = "Port to connect to (for attach requests)", required = false },
    wait_until_paused = { type = "boolean", description = "If true, wait until debugger pauses before returning", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting until paused in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local config = {
      type = args.type,
      request = args.request,
      name = args.name,
    }

    if args.program then
      config.program = args.program
      if config.program == "${file}" then
        config.program = vim.api.nvim_buf_get_name(0)
      elseif config.program == "${workspaceFolder}" then
        config.program = vim.fn.getcwd()
      end
    end

    if args.args then config.args = args.args end
    if args.cwd then
      config.cwd = args.cwd
      if config.cwd == "${workspaceFolder}" then
        config.cwd = vim.fn.getcwd()
      end
    end
    if args.env then config.env = args.env end
    if args.host then config.host = args.host end
    if args.port then config.port = args.port end

    local run_ok, run_err = pcall(dap.run, config)
    if not run_ok then
      cb(nil, "Failed to start debug session: " .. tostring(run_err))
      return
    end

    local result = { success = true, message = string.format("Started debug session '%s' with adapter '%s'", config.name, config.type) }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_terminate",
  description = "Terminate the current debug session",
  args = {},
  execute = function(cb)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local terminate_ok, err = pcall(dap.terminate)
    if not terminate_ok then
      cb(nil, "Failed to terminate session: " .. tostring(err))
      return
    end

    cb({ success = true, message = "Debug session terminated" })
  end,
})

registry.register({
  name = "dap_disconnect",
  description = "Disconnect from the debug adapter",
  args = {
    terminate_debuggee = { type = "boolean", description = "Whether to terminate the debuggee process", required = false, default = true },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local opts = { terminateDebuggee = args.terminate_debuggee }
    local disconnect_ok, err = pcall(dap.disconnect, opts)
    if not disconnect_ok then
      cb(nil, "Failed to disconnect: " .. tostring(err))
      return
    end

    cb({ success = true, message = "Disconnected from debug adapter" })
  end,
})

-- ============================================================================
-- Execution Control Tools
-- ============================================================================

registry.register({
  name = "dap_continue",
  description = "Continue execution of the debugged program",
  args = {
    wait_until_paused = { type = "boolean", description = "If true, wait until debugger pauses before returning", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    dap.continue()
    local result = { success = true, message = "Continuing execution" }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_step_over",
  description = "Step over to the next line",
  args = {
    wait_until_paused = { type = "boolean", description = "If true, wait until step completes before returning", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    dap.step_over()
    local result = { success = true, message = "Stepped over" }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_step_into",
  description = "Step into the function call",
  args = {
    wait_until_paused = { type = "boolean", description = "If true, wait until step completes before returning", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    dap.step_into()
    local result = { success = true, message = "Stepped into" }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_step_out",
  description = "Step out of the current function",
  args = {
    wait_until_paused = { type = "boolean", description = "If true, wait until step completes before returning", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    dap.step_out()
    local result = { success = true, message = "Stepped out" }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_run_to",
  description = "Run execution to a specific file and line number",
  args = {
    filename = { type = "string", description = "Path to the file (absolute or relative to workspace)", required = true },
    line = { type = "number", description = "Line number to run to", required = true },
    wait_until_paused = { type = "boolean", description = "If true, wait until execution reaches the line", required = false, default = false },
    wait_timeout_ms = { type = "number", description = "Timeout for waiting in milliseconds", required = false, default = 30000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local bufnr, err = smart_buffer_management(args.filename, args.line)
    if not bufnr then
      cb(nil, tostring(err))
      return
    end

    local run_ok, run_err = pcall(dap.run_to_cursor)
    if not run_ok then
      cb(nil, "Failed to run to cursor: " .. tostring(run_err))
      return
    end

    local result = { success = true, message = string.format("Running to %s:%d", args.filename, args.line) }

    if args.wait_until_paused then
      local wait_success, wait_result = wait_until_paused_impl(args.wait_timeout_ms)
      if not wait_success then
        cb(nil, wait_result)
        return
      end
      result.wait_result = wait_result
    end

    cb(result)
  end,
})

registry.register({
  name = "dap_wait_until_paused",
  description = "Wait until the debugger is paused (breakpoint hit, step completed, etc.). Blocks until the debugger stops or times out.",
  args = {
    timeout_ms = { type = "number", description = "Maximum time to wait in milliseconds", required = false, default = 30000 },
    check_interval_ms = { type = "number", description = "How often to check if paused in milliseconds", required = false, default = 100 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local wait_success, wait_result = wait_until_paused_impl(args.timeout_ms, args.check_interval_ms)
    if not wait_success then
      cb(nil, wait_result)
      return
    end

    cb({ success = true, result = wait_result })
  end,
})

-- ============================================================================
-- Breakpoint Tools
-- ============================================================================

registry.register({
  name = "dap_set_breakpoint",
  description = "Set a breakpoint at a specific file and line number",
  args = {
    filename = { type = "string", description = "Path to the file (absolute or relative to workspace)", required = true },
    line = { type = "number", description = "Line number for the breakpoint", required = true },
    condition = { type = "string", description = "Optional condition expression for the breakpoint", required = false },
    hit_condition = { type = "string", description = "Optional hit count condition (e.g., '5' to break on 5th hit)", required = false },
    log_message = { type = "string", description = "Optional log message (creates a logpoint instead of breakpoint)", required = false },
  },
  execute = function(cb, args)
    local bufnr, err = smart_buffer_management(args.filename, args.line)
    if not bufnr then
      cb(nil, tostring(err))
      return
    end

    local set_ok, set_err = pcall(dap.set_breakpoint, args.condition, args.hit_condition, args.log_message)
    if not set_ok then
      cb(nil, "Failed to set breakpoint: " .. tostring(set_err))
      return
    end

    local msg = args.log_message and "logpoint" or "breakpoint"
    cb({ success = true, message = string.format("Set %s at %s:%d", msg, args.filename, args.line) })
  end,
})

registry.register({
  name = "dap_remove_breakpoint",
  description = "Remove a breakpoint at a specific file and line",
  args = {
    filename = { type = "string", description = "Path to the file (absolute or relative to workspace)", required = true },
    line = { type = "number", description = "Line number of the breakpoint to remove", required = true },
  },
  execute = function(cb, args)
    local resolved_file = args.filename
    if not vim.startswith(resolved_file, "/") then
      resolved_file = vim.fn.getcwd() .. "/" .. resolved_file
    end

    local bufnr = nil
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == resolved_file then
        bufnr = buf
        break
      end
    end

    if not bufnr then
      cb(nil, "File not loaded in any buffer: " .. args.filename)
      return
    end

    local current_win = vim.api.nvim_get_current_win()
    local current_buf = vim.api.nvim_get_current_buf()
    local current_pos = vim.api.nvim_win_get_cursor(current_win)

    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(current_win, { args.line, 0 })

    local toggle_ok, err = pcall(dap.toggle_breakpoint)

    vim.api.nvim_set_current_buf(current_buf)
    vim.api.nvim_win_set_cursor(current_win, current_pos)

    if not toggle_ok then
      cb(nil, "Failed to toggle breakpoint: " .. tostring(err))
      return
    end

    cb({ success = true, message = string.format("Toggled breakpoint at %s:%d", args.filename, args.line) })
  end,
})

registry.register({
  name = "dap_clear_breakpoints",
  description = "Clear all breakpoints",
  args = {},
  execute = function(cb)
    local clear_ok, err = pcall(dap.clear_breakpoints)
    if not clear_ok then
      cb(nil, "Failed to clear breakpoints: " .. tostring(err))
      return
    end
    cb({ success = true, message = "All breakpoints cleared" })
  end,
})

registry.register({
  name = "dap_breakpoints",
  description = "List all breakpoints with their locations and conditions",
  args = {},
  execute = function(cb)
    local breakpoints = {}

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        local filename = vim.api.nvim_buf_get_name(bufnr)
        if filename and filename ~= "" then
          local signs = vim.fn.sign_getplaced(bufnr, { group = "*" })[1]
          if signs and signs.signs then
            for _, sign in ipairs(signs.signs) do
              if sign.name == "DapBreakpoint" or
                  sign.name == "DapBreakpointCondition" or
                  sign.name == "DapLogPoint" or
                  sign.name == "DapBreakpointRejected" then
                table.insert(breakpoints, {
                  file = filename,
                  line = sign.lnum,
                  type = sign.name:gsub("Dap", ""):lower(),
                  verified = sign.name ~= "DapBreakpointRejected",
                })
              end
            end
          end
        end
      end
    end

    cb(breakpoints)
  end,
})

-- ============================================================================
-- Inspection Tools
-- ============================================================================

registry.register({
  name = "dap_stacktrace",
  description = "Get the current call stack for the stopped thread",
  args = {
    thread_id = { type = "number", description = "Thread ID to get stack for (defaults to stopped thread)", required = false },
    levels = { type = "number", description = "Maximum number of stack frames to return", required = false, default = 20 },
    timeout_ms = { type = "number", description = "Request timeout in milliseconds", required = false, default = 5000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local thread_id = args.thread_id or session.stopped_thread_id
    if not thread_id then
      cb(nil, "No stopped thread")
      return
    end

    local response = nil
    local req_err = nil
    local completed = false

    session:request("stackTrace", {
      threadId = thread_id,
      levels = args.levels,
    }, function(err, result)
      req_err = err
      response = result
      completed = true
    end)

    local success = vim.wait(args.timeout_ms or 5000, function()
      return completed
    end, 100)

    if not success then
      cb(nil, "stackTrace request timed out")
      return
    end

    if req_err then
      cb(nil, tostring(req_err))
      return
    end

    if not response then
      cb(nil, "No response received from debug adapter")
      return
    end

    cb({
      thread_id = thread_id,
      total_frames = response.totalFrames,
      stack_frames = response.stackFrames,
    })
  end,
})

registry.register({
  name = "dap_scopes",
  description = "Get scopes for a stack frame. Returns scope information including variables references.",
  args = {
    frame_id = { type = "number", description = "Stack frame ID to get scopes for", required = true },
    timeout_ms = { type = "number", description = "Request timeout in milliseconds", required = false, default = 5000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local response = nil
    local req_err = nil
    local completed = false

    session:request("scopes", {
      frameId = args.frame_id,
    }, function(err, result)
      req_err = err
      response = result
      completed = true
    end)

    local success = vim.wait(args.timeout_ms or 5000, function()
      return completed
    end, 100)

    if not success then
      cb(nil, "scopes request timed out")
      return
    end

    if req_err then
      cb(nil, tostring(req_err))
      return
    end

    if not response then
      cb(nil, "No response received from debug adapter")
      return
    end

    cb(response.scopes)
  end,
})

registry.register({
  name = "dap_variables",
  description = "Get variables in a scope. Use dap_scopes first to get variablesReference IDs.",
  args = {
    variables_reference = { type = "number", description = "Variables reference ID from a scope or parent variable", required = true },
    filter = { type = "string", description = "Filter: 'indexed' for array elements, 'named' for properties", required = false },
    start = { type = "number", description = "Start index for indexed variables", required = false },
    count = { type = "number", description = "Number of variables to return", required = false },
    timeout_ms = { type = "number", description = "Request timeout in milliseconds", required = false, default = 5000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local request_args = { variablesReference = args.variables_reference }
    if args.filter then request_args.filter = args.filter end
    if args.start then request_args.start = args.start end
    if args.count then request_args.count = args.count end

    local response = nil
    local req_err = nil
    local completed = false

    session:request("variables", request_args, function(err, result)
      req_err = err
      response = result
      completed = true
    end)

    local success = vim.wait(args.timeout_ms or 5000, function()
      return completed
    end, 100)

    if not success then
      cb(nil, "variables request timed out")
      return
    end

    if req_err then
      cb(nil, tostring(req_err))
      return
    end

    if not response then
      cb(nil, "No response received from debug adapter")
      return
    end

    cb(response.variables)
  end,
})

registry.register({
  name = "dap_evaluate",
  description = "Evaluate an expression in the debug context",
  args = {
    expression = { type = "string", description = "Expression to evaluate", required = true },
    frame_id = { type = "number", description = "Stack frame ID for evaluation context", required = false },
    context = { type = "string", description = "Context: 'watch', 'repl', or 'hover'", required = false, default = "repl" },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local eval_result = nil
    local eval_error = nil
    local completed = false

    session:request("evaluate", {
      expression = args.expression,
      frameId = args.frame_id or (session.current_frame and session.current_frame.id),
      context = args.context,
    }, function(err, result)
      eval_error = err
      eval_result = result
      completed = true
    end)

    local success = vim.wait(5000, function()
      return completed
    end, 100)

    if not success then
      cb(nil, "Evaluation timed out")
      return
    end

    if eval_error then
      cb(nil, "Evaluation failed: " .. (eval_error.message or tostring(eval_error)))
      return
    end

    if not eval_result then
      cb(nil, "No evaluation result received")
      return
    end

    cb({
      result = eval_result.result or "<no result>",
      type = eval_result.type or "unknown",
      variables_reference = eval_result.variablesReference or 0,
    })
  end,
})

registry.register({
  name = "dap_threads",
  description = "List all threads in the debug session",
  args = {
    timeout_ms = { type = "number", description = "Request timeout in milliseconds", required = false, default = 5000 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local response = nil
    local req_err = nil
    local completed = false

    session:request("threads", {}, function(err, result)
      req_err = err
      response = result
      completed = true
    end)

    local success = vim.wait(args.timeout_ms or 5000, function()
      return completed
    end, 100)

    if not success then
      cb(nil, "threads request timed out")
      return
    end

    if req_err then
      cb(nil, tostring(req_err))
      return
    end

    if not response then
      cb(nil, "No response received from debug adapter")
      return
    end

    cb(response.threads)
  end,
})

registry.register({
  name = "dap_current_location",
  description = "Get the current execution location with surrounding code context",
  args = {
    context_lines = { type = "number", description = "Number of lines of code context to include above and below", required = false, default = 5 },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local current_frame = session.current_frame
    if not current_frame then
      cb(nil, "No current execution location available")
      return
    end

    local location = {
      file = (current_frame.source and current_frame.source.path) or "<unknown>",
      line = current_frame.line or 0,
      column = current_frame.column or 0,
      function_name = current_frame.name or "<unknown>",
    }

    local code_context = get_code_context(location.file, location.line, args.context_lines)

    cb({
      location = location,
      code_context = code_context,
    })
  end,
})

registry.register({
  name = "dap_program_output",
  description = "Get the output from the running/debugged program (stdout, stderr, console)",
  args = {
    category = { type = "string", description = "Output category: 'all', 'stdout', 'stderr', or 'console'", required = false, default = "all" },
    lines = { type = "number", description = "Number of recent lines to retrieve (max: 1000)", required = false, default = 50 },
    include_metadata = { type = "boolean", description = "Include timestamps and source information", required = false, default = false },
  },
  execute = function(cb, args)
    local session = dap.session()
    if not session then
      cb(nil, "No active debug session")
      return
    end

    local session_id = session.id
    local category = args.category or "all"
    local lines_requested = math.min(args.lines or 50, 1000)
    local include_metadata = args.include_metadata or false

    if not program_output[session_id] then
      cb({ message = "No output captured for current session", lines = {} })
      return
    end

    local storage = program_output[session_id]
    local output_lines = {}

    if category == "all" then
      local all_output = storage.all
      local start_idx = math.max(1, #all_output - lines_requested + 1)

      for i = start_idx, #all_output do
        local entry = all_output[i]
        if include_metadata then
          local time_str = os.date("%H:%M:%S", entry.timestamp)
          table.insert(output_lines, string.format("[%s][%s] %s", time_str, entry.category, entry.line))
        else
          table.insert(output_lines, entry.line)
        end
      end
    else
      if not storage[category] then
        cb(nil, "Invalid category: " .. category)
        return
      end

      local cat_output = storage[category]
      local start_idx = math.max(1, #cat_output - lines_requested + 1)

      for i = start_idx, #cat_output do
        table.insert(output_lines, cat_output[i])
      end
    end

    cb({
      category = category,
      line_count = #output_lines,
      lines = output_lines,
    })
  end,
})
