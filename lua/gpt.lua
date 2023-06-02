local M = {}

-- OpenAI API key
local api_key = nil

-- jobid
local jobid = nil

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
	opts = opts or {}
	local line_start = opts.line_no or vim.fn.line(".")
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local nsnum = vim.api.nvim_create_namespace("gpt")
	local extmarkid = vim.api.nvim_buf_set_extmark(bufnr, nsnum, line_start, 0, {})

	local response = ""
	return function(chunk)
		-- Delete the currently written response
		local num_lines = #(vim.split(response, "\n", {}))
		vim.cmd('undojoin')
		vim.api.nvim_buf_set_lines(
			bufnr, line_start, line_start + num_lines,
			false, {}
		)

		-- Update the line start to wherever the extmark is now
		line_start = vim.api.nvim_buf_get_extmark_by_id(bufnr, nsnum, extmarkid, {})[1]

		-- Write out the latest
		response = response .. chunk
		vim.cmd('undojoin')
		vim.api.nvim_buf_set_lines(
			bufnr, line_start, line_start,
			false, vim.split(response, "\n", {})
		)
	end
end
M.__create_response_writer = create_response_writer

-- Setup API key
M.setup = function(opts)
	local key = opts.api_key
	if type(key) == "string" or type(key) == "function" then
		api_key = key
	else
		vim.notify("Please provide an OpenAI API key or its setup function.", vim.log.levels.WARN, notify_opts)
		return
	end

	-- Make sure the share directory exists to log
	local share_dir = vim.fn.stdpath 'data'
	if vim.fn.isdirectory(share_dir) == 0 then
		vim.fn.mkdir(share_dir, "p")
	end
end

--[[
Given a prompt, call chatGPT and stream back the results one chunk
as a time as they are streamed back from OpenAI.

```
require('gpt').stream("What is the meaning of life?", {
	trim_leading = true, -- Trim leading whitespace of the response
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
	local model = opts.model or "gpt-3.5-turbo"
	local trim_leading = opts.trim_leading or true

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
					if (not string.match(line, '%[DONE%]')) then
						local json = vim.fn.json_decode(line) or {}
						local chunk = json.choices[1].delta.content

						if chunk ~= nil then
							if trim_leading then
								chunk = chunk:gsub("^%s+", "")
								if chunk ~= "" then
									trim_leading = false
								end
							end
							if cb then
								cb(chunk)
							end
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
		trim_leading = true,
		on_chunk = function(chunk)
			chunk = vim.split(chunk, "\n", {})
			vim.cmd 'undojoin'
			vim.api.nvim_put(chunk, "c", mode == 'V', true)
		end
	})
end

--[[
Ask the user for a prompt and insert the response where the cursor
is currently positioned.
]]
--
M.prompt = function()
	local input = vim.fn.input({
		prompt = "[Prompt]: ",
		cancelreturn = "__CANCEL__"
	})

	if input == "__CANCEL__" then
		return
	end

	send_keys("<esc>")
	M.stream(input, {
		trim_leading = true,
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
	local input = vim.fn.input({
		prompt = "[Prompt]: " .. prompt,
		cancelreturn = "__CANCEL__"
	})

	if input == "__CANCEL__" then
		return
	end

	prompt = prompt .. input
	prompt = prompt .. "\n\n ===== \n\n" .. text .. "\n\n ===== \n\n"

	send_keys("<esc>")

	if mode == 'V' then
		send_keys("o<CR><esc>")
	end

	M.stream(prompt, {
		trim_leading = true,
		on_chunk = create_response_writer()
	})

	send_keys("<esc>")
end

--[[
Interrupt ChatGPT job.
]]
--
M.cancel = function()
	vim.fn.jobstop(jobid)
	jobid = nil
end

return M
