local M = {}

local n = require("nui-components")

local function build_progress_dots(current, total)
  local dots = {}
  for i = 1, total do
    table.insert(dots, i <= current and "●" or "○")
  end
  return table.concat(dots, "")
end

local function is_text_only(q)
  return not q.choices or #q.choices == 0
end

local function show_question(questions, idx, answers, on_complete)
  local total = #questions
  local q = questions[idx]
  local text_only = is_text_only(q)
  local multiselect = q.multiselect and not text_only

  local signal = n.create_signal({
    selected_choice = nil,
    selected_choices = {},
    custom_text = "",
  })

  if q.default_choice and q.choices and q.choices[q.default_choice + 1] then
    if multiselect then
      signal.selected_choices = { q.choices[q.default_choice + 1] }
    else
      signal.selected_choice = q.choices[q.default_choice + 1]
    end
  end

  local renderer
  local result_action = nil

  local function get_current_answer()
    local state = signal:get_value()

    if text_only then
      return state.custom_text
    end

    if multiselect then
      local result = {}
      for _, choice in ipairs(state.selected_choices or {}) do
        table.insert(result, choice)
      end
      local trimmed_text = state.custom_text:match("^%s*(.-)%s*$")
      if trimmed_text and trimmed_text ~= "" then
        table.insert(result, trimmed_text)
      end
      return result
    end

    if state.custom_text ~= "" then
      return state.custom_text
    end

    return state.selected_choice
  end

  local function has_valid_answer()
    local answer = get_current_answer()
    if answer == nil then
      return false
    end
    if type(answer) == "string" and answer == "" then
      return false
    end
    if type(answer) == "table" and #answer == 0 then
      return false
    end
    return true
  end

  local function advance()
    if not has_valid_answer() then
      return
    end

    answers[idx] = {
      question = q.question,
      answer = get_current_answer(),
    }

    result_action = "next"
    renderer:close()
  end

  local function go_back()
    result_action = "back"
    renderer:close()
  end

  local function cancel()
    result_action = "cancel"
    renderer:close()
  end

  local is_first = idx == 1
  local is_last = idx == total

  local progress_text = string.format(
    "Question %d of %d                                    [%s]",
    idx,
    total,
    build_progress_dots(idx, total)
  )

  local question_text = "❓ " .. q.question
  if multiselect then
    question_text = question_text .. " (select multiple)"
  end

  local components = {
    n.paragraph({ lines = progress_text, is_focusable = false }),
    n.gap(1),
    n.paragraph({ lines = question_text, is_focusable = false }),
    n.gap(1),
  }

  if multiselect then
    local options = {}
    for i, choice in ipairs(q.choices) do
      table.insert(options, n.option({ id = tostring(i), text = choice }))
    end

    table.insert(
      components,
      n.select({
        autofocus = true,
        size = math.min(#q.choices, 8),
        data = options,
        multiselect = true,
        prepare_node = function(is_selected, node)
          local Line = require("nui.line")
          local line = Line()
          local prefix = is_selected and "[x] " or "[ ] "
          line:append(prefix)
          line:append(node.text)
          return line
        end,
        on_select = function(selected_value)
          if selected_value and type(selected_value) == "table" then
            local choices = {}
            for _, v in ipairs(selected_value) do
              if v and v.text then
                table.insert(choices, v.text)
              end
            end
            signal.selected_choices = choices
          else
            signal.selected_choices = {}
          end
          signal.custom_text = ""
        end,
      })
    )

    table.insert(components, n.gap(1))
    table.insert(
      components,
      n.button({
        label = is_last and "  ✓ Submit  " or "  → Next  ",
        on_press = function()
          vim.schedule(advance)
        end,
      })
    )

    table.insert(components, n.gap(1))
    table.insert(components, n.paragraph({ lines = string.rep("─", 56), is_focusable = false }))
    table.insert(components, n.paragraph({ lines = "💬 Or type your answer:", is_focusable = false }))
  elseif not text_only then
    local options = {}
    for i, choice in ipairs(q.choices) do
      table.insert(options, n.option({ id = tostring(i), text = choice }))
    end

    table.insert(
      components,
      n.select({
        autofocus = true,
        size = math.min(#q.choices, 8),
        data = options,
        on_select = function(selected_value)
          if selected_value and selected_value.text then
            signal.selected_choice = selected_value.text
            signal.custom_text = ""
            vim.schedule(advance)
          end
        end,
      })
    )

    table.insert(components, n.gap(1))
    table.insert(components, n.paragraph({ lines = string.rep("─", 56), is_focusable = false }))
    table.insert(components, n.paragraph({ lines = "💬 Or type your answer:", is_focusable = false }))
  end

  table.insert(
    components,
    n.text_input({
      autofocus = text_only,
      size = 3,
      autoresize = true,
      max_lines = 6,
      wrap = true,
      value = signal.custom_text,
      on_change = function(value)
        signal.custom_text = value
        if value ~= "" and not text_only and not multiselect then
          signal.selected_choice = nil
        end
      end,
    })
  )

  table.insert(components, n.gap(1))

  local footer_parts = {}
  if is_last then
    table.insert(footer_parts, "↵ Submit")
  else
    table.insert(footer_parts, "↵ Next")
  end
  if not is_first then
    table.insert(footer_parts, "C-p Previous")
  end
  if not text_only then
    table.insert(footer_parts, "Tab Navigate")
  end
  table.insert(footer_parts, "Esc Cancel")

  table.insert(components, n.paragraph({ lines = table.concat(footer_parts, "   "), is_focusable = false }))

  local choice_count = q.choices and #q.choices or 0
  local extra_height = 0
  if multiselect then
    extra_height = math.min(choice_count, 8) + 2
  elseif not text_only then
    extra_height = math.min(choice_count, 8)
  end

  renderer = n.create_renderer({
    width = 66,
    height = 20 + extra_height,
    position = "50%",
    relative = "editor",
    keymap = {
      focus_next = "<Tab>",
      focus_prev = "<S-Tab>",
    },
    on_unmount = function()
      vim.schedule(function()
        if result_action == "next" then
          if idx >= total then
            on_complete({ completed = true, answers = answers })
          else
            show_question(questions, idx + 1, answers, on_complete)
          end
        elseif result_action == "back" then
          if idx > 1 then
            show_question(questions, idx - 1, answers, on_complete)
          end
        else
          on_complete({ completed = false, answers = {} })
        end
      end)
    end,
  })

  renderer:add_mappings({
    {
      mode = { "n" },
      key = "<CR>",
      handler = advance,
    },
    {
      mode = { "n", "i" },
      key = "<C-p>",
      handler = function()
        if not is_first then
          go_back()
        end
      end,
    },
    {
      mode = { "n" },
      key = "<Esc>",
      handler = cancel,
    },
  })

  renderer:render(n.rows({
    flex = 1,
    border_style = "rounded",
    border_label = " Interview ",
  }, unpack(components)))
end

function M.show(questions, on_complete)
  show_question(questions, 1, {}, on_complete)
end

return M
