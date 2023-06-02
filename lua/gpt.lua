local M = {}

-- OpenAI API key
local api_key = nil

-- jobid
local jobid = nil

-- Model version
local model

-- opts of vim.notify
local notify_opts = {
	title = 'gpt.nvim'
}

local function get_visual_selection()
	vim.cmd('noau normal! "vy"')
	vim.cmd('noau normal! gv')
	return vim.fn.getreg('v')
end

local function send_keys(keys)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(keys, true, false, true),
		'm', true
	)
end

local function create_response_writer(opts)
	-- Setup options
	opts = opts or {}
	local scroll_win = opts.scroll_win
	local line_start = opts.line_no or vim.fn.line(".")
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local nsnum = vim.api.nvim_create_namespace("gpt")
	local extmarkid = vim.api.nvim_buf_set_extmark(bufnr, nsnum, line_start, 0, {})

	-- Store entire response
	local response = ""
	return function(chunk)
		-- Delete the currently written response
		local num_lines = #(vim.split(response, "\n", {}))
		vim.cmd 'undojoin'
		vim.api.nvim_buf_set_lines(bufnr, line_start, line_start + num_lines, false, {})

		-- Update the line start to wherever the extmark is now
		line_start = vim.api.nvim_buf_get_extmark_by_id(bufnr, nsnum, extmarkid, {})[1]

		-- Write out the latest
		response = response .. chunk
		local lines = vim.split(response, "\n", {})
		vim.cmd 'undojoin'
		vim.api.nvim_buf_set_lines(bufnr, line_start, line_start, false, lines)

		-- Scroll
		if scroll_win and #lines > 1 then
			vim.api.nvim_win_call(scroll_win, function() vim.cmd "noau norm! zb" end)
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
	model = opts.model or "gpt-3.5-turbo"

	-- Make sure the share directory exists to log
	local share_dir = vim.fn.stdpath 'data'
	if vim.fn.isdirectory(share_dir) == 0 then
		vim.fn.mkdir(share_dir, "p")
	end
end

--[[
Given a prompt, call chatGPT and stream back the results one chunk
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
	if temp ~= nil then
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
	if log ~= nil then
		log:write(command)
		log:close()
	end

	local cb = opts.on_chunk
	local on_exit = opts.on_exit
	jobid = vim.fn.jobstart(command, {
		stdout_buffered = false,
		on_exit = function()
			if on_exit then
				on_exit()
			end
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

						if chunk and cb then
							cb(chunk)
						end
					end
				end
			end
		end,
	})
end

--[[
In visual mode given some selected text, ask the user how they
would like it to be rewritten. Then rewrite it that way.
]]
--
M.replace = function()
	local mode = vim.api.nvim_get_mode().mode
	if mode ~= "v" and mode ~= "V" then
		print("Please select some text")
		return
	end

	local text = get_visual_selection()

	local prompt = "Rewrite this text "
	prompt = prompt .. vim.fn.input("[Prompt]: " .. prompt)
	prompt = prompt .. ": \n\n" .. text .. "\n\nRewrite:"

	send_keys("d")

	if mode == 'V' then
		send_keys("O")
	end

	M.stream(prompt, {
		on_chunk = function(chunk)
			chunk = vim.split(chunk, "\n", {})
			vim.cmd 'undojoin'
			vim.api.nvim_put(chunk, "c", mode == 'V', true)
		end
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

	local function create_prompt(ft)
		---@diagnostic disable-next-line: redundant-parameter
		local commentstring = string.format(vim.api.nvim_buf_get_option(0, 'commentstring'),
			' Written by ' .. model)
		local source_name
		if ft == 'lua' then
			source_name = 'Lua'
		elseif ft == 'rust' then
			source_name = 'Rust'
		elseif ft == 'c' then
			source_name = 'C'
		elseif ft == 'python' then
			source_name = 'Python3'
		else
			return nil
		end
		return string.format(
			"You are an excellent coding helper, returning %s source code that satisfies the user's input. The response is ONLY simplest source code. Your output is NOT markdown, BUT an executable source code. ALL explanations other than the excutable source code must be written in comments.\nThe first line is always a %s comment:\n%s",
			source_name, source_name, commentstring)
	end

	local system_prompt_str = create_prompt(filetype)
	if not system_prompt_str then
		vim.notify('This filetype is not supported.', vim.log.levels.INFO, notify_opts)
		return
	end
	-- 命令の入力
	local ok, order = pcall(vim.fn.input, 'Order: ')
	if not ok or order == '' then
		return
	end
	local messages = {
		{ role = 'system', content = system_prompt_str },
		{ role = 'user',   content = order .. "\n\nCode:" },
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
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)


	-- 現在のウィンドウとバッファを保存
	local current_win = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_get_current_buf()
	-- vsplitを開く
	vim.api.nvim_command(opener)
	-- 新しいウィンドウを取得
	local new_win = vim.api.nvim_get_current_win()
	-- 新しいウィンドウにバッファを設定
	vim.api.nvim_win_set_buf(new_win, bufnr)
	-- ステータスライン
	---@diagnostic disable-next-line: redundant-parameter
	vim.api.nvim_win_set_option(new_win, "stl", "order-result")
	-- 元のウィンドウに戻る
	vim.api.nvim_set_current_win(current_win)
	-- 元のバッファに戻る
	vim.api.nvim_win_set_buf(current_win, current_buf)

	local writer = create_response_writer {
		line_no = 0,
		bufnr = bufnr,
		scroll_win = (opts.scroll == nil or opts.scroll) and new_win or nil,
	}
	require 'gpt'.stream(messages, {
		on_chunk = function(chunk)
			---@diagnostic disable-next-line: redundant-parameter
			vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
			writer(chunk)
			---@diagnostic disable-next-line: redundant-parameter
			vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)
		end,
		on_exit = function()
			vim.notify("Order fulfillment is complete.", vim.log.levels.INFO, notify_opts)
		end,
	})
end

--[[
Ask the user for a prompt and insert the response where the cursor
is currently positioned.
]]
--
M.prompt = function()
	local input = vim.fn.input("[Prompt]: ")
	if input == "" then
		return
	end

	send_keys("<esc>")
	M.stream(input, {
		on_chunk = create_response_writer()
	})
end

--[[
Take the current visual selection as the prompt to chatGPT.
Insert the response one line below the current selection.
]]
--
M.visual_prompt = function()
	local mode = vim.api.nvim_get_mode().mode
	local text = get_visual_selection()

	local prompt = ""
	local input = vim.fn.input("[Prompt]: " .. prompt)

	if input == "" then
		return
	end

	prompt = prompt .. input
	prompt = prompt .. "\n\n ===== \n\n" .. text .. "\n\n ===== \n\n"

	send_keys("<esc>")

	if mode == 'V' then
		send_keys("o<CR><esc>")
	end

	M.stream(prompt, {
		on_chunk = create_response_writer()
	})

	send_keys("<esc>")
end

--[[
Interrupt ChatGPT job.
]]
--
M.cancel = function()
	if jobid then
		vim.fn.jobstop(jobid)
	end
end

return M
