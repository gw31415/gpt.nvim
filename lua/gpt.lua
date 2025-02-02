local M = {}

-- OpenAI API key
local api_key = nil

-- jobid
local jobid = nil

-- Model version
local model

-- Selection highlight-group
local hlgroup

-- opts of vim.notify
local notify_opts = {
	title = 'gpt.nvim'
}

local function send_keys(keys)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(keys, true, false, true),
		'm', true
	)
end

-- Create a response_writer for the current buffer window
local function create_response_writer(opts)
	-- Setup options
	opts                  = opts or {}
	local winnr           = vim.api.nvim_get_current_win()
	local bufnr           = vim.api.nvim_get_current_buf()
	local _, lnum, col, _ = unpack(vim.fn.getcharpos('.') or { 0, 0, 0, 0 })
	-- zero-indexed lnum
	local line_start      = lnum - 1
	local do_scroll       = opts.scroll

	local nsnum           = vim.api.nvim_create_namespace("gpt")
	local extmarkid       = vim.api.nvim_buf_set_extmark(bufnr, nsnum, line_start, 0, {})

	local first_line      = vim.api.nvim_buf_get_lines(bufnr, line_start, line_start + 1, true)[1]
	-- string found to the left of the cursor
	local left_hand_side  = vim.fn.slice(first_line, 0, col - 1)
	-- string found to the right of the cursor
	local right_hand_side = vim.fn.slice(first_line, col - 1)

	vim.api.nvim_buf_set_lines(bufnr, line_start, line_start, true, {})

	-- Store entire response: initial value is the string that was initially to the right of the cursor
	local response = left_hand_side
	return function(chunk)
		-- Changed to modifiable
		---@diagnostic disable-next-line: redundant-parameter
		vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

		-- Delete the currently written response
		local num_lines = #(vim.split(response, "\n", {}))
		vim.api.nvim_buf_call(bufnr, vim.cmd.undojoin)
		vim.api.nvim_buf_set_lines(bufnr, line_start, line_start + num_lines, false, {})

		-- Update the line start to wherever the extmark is now
		line_start = vim.api.nvim_buf_get_extmark_by_id(bufnr, nsnum, extmarkid, {})[1]

		-- Write out the latest
		response = response .. chunk
		local lines = vim.split(response .. right_hand_side, "\n", {})
		vim.api.nvim_buf_call(bufnr, vim.cmd.undojoin)
		vim.api.nvim_buf_set_lines(bufnr, line_start, line_start, false, lines)

		-- Changed to unmodifiable
		---@diagnostic disable-next-line: redundant-parameter
		vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

		-- Scroll
		if do_scroll and #lines > 1 then
			vim.api.nvim_win_call(winnr, function() vim.cmd "noau norm! zb" end)
		end
	end
end

-- Setup API key
M.setup = function(opts)
	-- Setup options
	local key = opts.api_key
	if type(key) == "string" or type(key) == "function" then
		api_key = key
	else
		vim.notify("Please provide an OpenAI API key or its setup function.", vim.log.levels.WARN, notify_opts)
		return
	end
	model = opts.model or "gpt-3.5-turbo-1106"
	hlgroup = opts.hlgroup or "Visual"

	-- Make sure the share directory exists to log
	local share_dir = vim.fn.stdpath 'data'
	if vim.fn.isdirectory(share_dir) == 0 then
		vim.fn.mkdir(share_dir, "p")
	end
end

--[[
Given a prompt, call ChatGPT and stream back the results one chunk
as a time as they are streamed back from OpenAI.
@params opts.scroll_win win_id of the window if scroll

```
require('gpt').stream("What is the meaning of life?", {
	on_chunk = function(chunk)
		print(chunk)
	end
})
```
]]
--
M.stream = function(prompt_or_messages, opts)
	-- Setup api_key
	if not api_key then
		print("Please provide an OpenAI API key.")
		return
	elseif type(api_key) == "function" then
		api_key = api_key()
	end
	if type(api_key) ~= "string" then
		vim.notify("OpenAI API key is broken.", vim.log.levels.ERROR, notify_opts)
		return
	end

	-- Only one job can be running
	if jobid then
		vim.notify("There is a GPT job already running. Only one job can be running at a time.", vim.log.levels.ERROR,
			notify_opts)
		return
	end

	-- Setup messages
	local messages
	if type(prompt_or_messages) == "string" then
		messages = { { role = "user", content = prompt_or_messages } }
	else
		messages = prompt_or_messages
	end

	-- Setup options
	opts = opts or {}

	-- Write payload to temp file
	local params_path = vim.fn.stdpath 'data' .. "/gpt.query.json"
	local temp = io.open(params_path, "w")
	if temp then
		temp:write(vim.fn.json_encode({
			stream = true,
			model = model,
			messages = messages,
		}))
		temp:close()
	end

	local command =
		"curl --no-buffer https://api.openai.com/v1/chat/completions " ..
		"-H 'Content-Type: application/json' -H 'Authorization: Bearer " .. api_key .. "' " ..
		"-d @" .. params_path .. " | tee ~/.local/share/nvim/gpt.log 2>/dev/null"

	-- Write command to log file
	local log = io.open(vim.fn.stdpath 'data' .. "/gpt.log", "w")
	if log then
		log:write(command)
		log:close()
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local cb = opts.on_chunk or create_response_writer()
	local on_exit = opts.on_exit
	jobid = vim.fn.jobstart(command, {
		stdout_buffered = false,
		on_exit = function()
			-- Restore modifiable
			---@diagnostic disable-next-line: redundant-parameter
			vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)

			if on_exit then on_exit() end
			jobid = nil
		end,
		on_stdout = function(_, data, _)
			for _, line in ipairs(data) do
				if line ~= "" then
					-- Strip token to get down to the JSON
					line = line:gsub("^data: ", "")
					if line == "" then
						break
					end
					if not string.match(line, '%[DONE%]') then
						local json = vim.fn.json_decode(line) or {}
						local chunk = json.choices[1].delta.content
						if chunk then
							cb(chunk)
						end
					end
				end
			end
		end,
	})
end

local gpt_ordering_buffer = nil
--[[
An assistant function that accepts commands and returns source code for the file type currently being edited.
Creates a window to display the source code according to the Vim commands in opts.opener.
]]
--
M.order = function(opts)
	opts = opts or {}
	local opener = opts.opener or 'rightbelow 40vsplit'
	local setup_window = opts.setup_window

	if gpt_ordering_buffer then
		if jobid then
			require 'gpt'.cancel()
			return
		end
		vim.api.nvim_buf_delete(gpt_ordering_buffer, {})
		gpt_ordering_buffer = nil
		return
	end
	---@diagnostic disable-next-line: redundant-parameter
	local filetype = vim.api.nvim_buf_get_option(0, 'filetype')

	local system_prompt_str =
	"You are a coding helper, returning source code that satisfies the user's input. First the file type of the output is indicated in the bracket and then the command is given. Your output is an EXECUTABLE CODE ONLY. ALL explanations other than the excutable source code must be written in comments."

	-- 命令の入力
	local ok, order = pcall(vim.fn.input, 'Order: ')
	if not ok or order == '' then
		return
	end
	local messages = {
		{ role = 'system', content = system_prompt_str },
		{
			role = 'user',
			content =
			"[rust]API Web pour générer la date et l'heure d'accès en text/plain à l'aide d'actix_web"
		},
		{
			role = 'assistant',
			content =
			"use actix_web::{HttpServer, App, Responder, web};\nuse chrono::Local;\n\nasync fn get_time(_req: web::HttpRequest) -> impl Responder {\n    format!(\"{}\", Local::now())\n}\n\n#[actix_web::main]\nasync fn main() -> std::io::Result<()> {\n    HttpServer::new(|| {\n        App::new().route(\"/\", web::get().to(get_time))\n    })\n    .bind(\"127.0.0.1:8080\")?\n    .run()\n    .await\n}"
		},
		{ role = 'user',   content = "[lua]Bubble sorting function with explanation" },
		{
			role = 'assistant',
			content =
			"-- Define the function bubbleSort\nfunction bubbleSort(arr)\n    local n = #arr\n    -- Loop through the array\n    for i = 1, n do\n        -- Loop through the array again for each previous element to i\n        for j = 1, n - i do\n            -- Check if elements need swapping\n            if arr[j] > arr[j + 1] then\n                -- Swap elements\n                arr[j], arr[j + 1] = arr[j + 1], arr[j]\n            end\n        end\n    end\n    -- Return the sorted array\n    return arr\nend",
		},
		{ role = 'user', content = '[css]「隣の客はよく柿食う客だ」を英語に翻訳して' },
		{ role = 'assistant', content = '/* The customer next to me is a frequent persimmon-eater. */' },
		{ role = 'user', content = string.format("[%s]%s", filetype, order) },
	}
	local bufnr = vim.api.nvim_create_buf(false, true)
	gpt_ordering_buffer = bufnr
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_buf_set_option(bufnr, 'filetype', filetype)
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_buf_set_option(bufnr, "bt", "nofile")
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_buf_set_option(bufnr, 'bufhidden', 'hide')
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_buf_set_option(bufnr, 'swapfile', false)


	-- Save the current window and buffer
	local current_win = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_get_current_buf()
	-- Open a vsplit
	vim.api.nvim_command(opener)
	-- Get the new window
	local new_win = vim.api.nvim_get_current_win()
	-- Set the buffer to the new window
	vim.api.nvim_win_set_buf(new_win, bufnr)
	-- Create a writer for the current window and buffer
	local writer = create_response_writer {
		scroll = opts.scroll == nil or opts.scroll,
	}
	-- Set up the window
	if setup_window then setup_window() end
	-- Return to the original window
	vim.api.nvim_set_current_win(current_win)
	-- Return to the original buffer
	vim.api.nvim_win_set_buf(current_win, current_buf)

	require 'gpt'.stream(messages, {
		on_chunk = writer,
		on_exit = function()
			---@diagnostic disable-next-line: redundant-parameter
			vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

			vim.notify("Order fulfillment is complete.", vim.log.levels.INFO, notify_opts)
		end,
	})
end

--  Operatorfunc that follows the instructions to transform and replace text objects.
function _G.gpt_replace_opfunc(type)
	if not type or type == '' then
		---@diagnostic disable-next-line: redundant-parameter
		vim.api.nvim_set_option('operatorfunc', "v:lua.gpt_replace_opfunc")
		return 'g@'
	elseif type == "block" then
		vim.notify("Block selection is not supported.", vim.log.levels.ERROR, notify_opts)
		return
	end

	-- Add highlights
	local pos = {}
	local _, line1, col1, _ = unpack(vim.fn.getpos("'[") or { 0, 0, 0, 0 })
	local _, line2, col2, _ = unpack(vim.fn.getpos("']") or { 0, 0, 0, 0 })
	for line = line1, math.min(line2, vim.fn.line("w$")) do
		if line ~= line1 and line ~= line2 then
			---@diagnostic disable-next-line: param-type-mismatch
			table.insert(pos, vim.fn.matchaddpos(hlgroup, { line }))
		else
			local str = vim.fn.getline(line)
			local start_idx = line == line1 and col1 or 1
			local end_idx = line == line2 and col2 or #str
			for i = start_idx, end_idx do
				---@diagnostic disable-next-line: param-type-mismatch
				table.insert(pos, vim.fn.matchaddpos(hlgroup, { { line, vim.fn.byteidx(str, i) } }))
			end
		end
	end
	vim.cmd.redraw()

	-- Reseive input
	local message = vim.fn.input("Instruction: ")

	-- Remove highlights
	for _, id in pairs(pos) do
		vim.fn.matchdelete(id)
	end
	vim.cmd.redraw()

	-- Exit if no input
	if message == "" then return end

	-- Note the value of virtualedit
	---@diagnostic disable-next-line: redundant-parameter
	local ve = vim.api.nvim_get_option('ve')
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_set_option('ve', 'onemore') -- To support deletion up to the end of the line.

	if type == "line" then
		vim.cmd "noau norm! '[V']c"
	else
		vim.cmd "noau norm! `[v`]d"
	end
	-- Change to normal-mode
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes('<esc>', true, false, true),
		'm', true
	)

	message = string.format('%s:\n\n%s', message, vim.fn.getreg('"'))

	require 'gpt'.stream({
		-- Instruction
		{
			role = "system",
			content =
			"You are a flexible text conversion tool. Output only the resulting string",
		},
		-- Order
		{ role = "user", content = message },
	}, {
		---@diagnostic disable-next-line: redundant-parameter
		on_exit = function() vim.api.nvim_set_option('ve', ve) end
	})
end

vim.keymap.set('', '<Plug>(gpt-replace)', _G.gpt_replace_opfunc, { expr = true })

--[[
Ask the user for a prompt and insert the response where the cursor
is currently positioned.
]]
--
M.prompt = function()
	local input = vim.fn.input("[Prompt]: ")
	if input == "" then return end

	send_keys("<esc>")
	M.stream(input)
end

--[[
Interrupt ChatGPT job.
]]
--
M.cancel = function()
	if jobid then vim.fn.jobstop(jobid) end
end

return M
