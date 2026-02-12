local registry = require("mcp-tools.registry")

registry.register({
  name = "interview",
  description = "Present one or more questions to the user with multiple-choice options or free-text input. "
    .. "Each question can be: (1) single-select with choices, (2) multi-select with choices, or (3) text-only. "
    .. "Choice-based questions always allow a custom text answer as fallback.",
  timeout = 0,
  args = {
    questions = {
      type = "array",
      items = {
        type = "object",
        properties = {
          question = { type = "string", description = "The question text" },
          choices = { type = "array", items = { type = "string" }, description = "If omitted, question is text-only" },
          multiselect = { type = "boolean", description = "Allow multiple selections (default false)" },
          default_choice = { type = "number", description = "0-based index of default selected choice" },
        },
        required = { "question" },
      },
      description = "Array of question objects. Each object has: "
        .. "'question' (string, required) - the question text; "
        .. "'choices' (array of strings, optional) - if omitted, question is text-only; "
        .. "'multiselect' (boolean, optional, default false) - allow multiple selections; "
        .. "'default_choice' (number, optional) - 0-based index of default selected choice.",
      required = true,
    },
  },
  execute = function(cb, args)
    if not args.questions or type(args.questions) ~= "table" or #args.questions == 0 then
      cb(nil, "questions array is required and must not be empty")
      return
    end

    for i, q in ipairs(args.questions) do
      if not q.question or type(q.question) ~= "string" or q.question == "" then
        cb(nil, string.format("Question %d: 'question' field is required and must be a non-empty string", i))
        return
      end
      if q.choices ~= nil and type(q.choices) ~= "table" then
        cb(nil, string.format("Question %d: 'choices' must be an array if provided", i))
        return
      end
      if q.choices and #q.choices == 0 then
        cb(nil, string.format("Question %d: 'choices' array must not be empty if provided", i))
        return
      end
    end

    local has_nui_components, _ = pcall(require, "nui-components")
    if not has_nui_components then
      cb(nil, "nui-components.nvim is required for the interview tool. Please install grapp-dev/nui-components.nvim")
      return
    end

    local ui = require("mcp-tools.tools.interview.ui")
    ui.show(args.questions, function(result)
      cb(result)
    end)
  end,
})
