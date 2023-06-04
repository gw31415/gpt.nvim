<p align="center">
  <h3 align="center">gw31415/gpt.nvim</h3>
</p>
<p align="center">
  <img src="assets/typing.svg" alt="Typing SVG" />
</p>

<hr/>

Original version is [Here](https://github.com/thmsmlr/gpt.nvim).

Installation is easy.
With your favorite package manager,

```lua
{
  "gw31415/gpt.nvim",
  config = function()
    local function setup_authkey(path)
      path = vim.fn.expand(path, nil, nil)
      local key
      if vim.fn.filereadable(path) == 1 then
        key = vim.fn.trim(vim.fn.readfile(path, nil, 1)[1])
      else
        key = vim.fn.input('OPENAI_API_KEY = ')
        if key == '' then
          return nil
        end
        vim.fn.writefile({ key }, path)
        vim.fn.system({ 'chmod', '600', path })
        vim.notify(string.format(
            'Successfully saved OPENAI_API_KEY at `%s`.', path),
          vim.log.levels.INFO, {
            title = 'gpt.nvim'
          })
      end
      return key
    end

    require 'gpt'.setup {
      api_key = function() return setup_authkey('~/.ssh/openai_api_key.txt') end, -- or directly specify API_KEY string
    }

    vim.keymap.set({ 'n', 'x' }, '<C-g>r', '<Plug>(gpt-replace)')
    vim.keymap.set({ 'n', 'i' }, '<C-g>p', require 'gpt'.prompt)
    vim.keymap.set('n', '<C-g>c', require 'gpt'.cancel)
    vim.keymap.set('n', '<C-g>o', function()
      require 'gpt'.order {
        opener = "10split", -- Default: `rightbelow 40vsplit`
        setup_window = function()
          vim.api.nvim_win_set_option(0, "stl", "order-result")
        end
      }
    end)
  end
}
```

You can get an API key via the [OpenAI user settings page](https://platform.openai.com/account/api-keys)

# Usage

## Stream

`require 'gpt'.stream(messages)` to start output from ChatGPT at the cursor position.

## Prompt

`require 'gpt'.prompt()` sends the prompt entered to the OpenAI ChatGPT API and receives an answer realtime.

## Replace

`<Plug>(gpt-replace)` is an operator key to convert textobj

## Order

`require 'gpt'.order()` receives questions about the current filetype and creates a window that answers them in real time.

# Example

Create commit message from diff --staged.

```lua
vim.api.nvim_create_autocmd('BufReadPost', {
  pattern = "COMMIT_EDITMSG",
  callback = function()
    vim.keymap.set('n', '<C-g><tab>', function()
      local diff = vim.fn.system({ 'git', '--git-dir', vim.fn.expand('%:p:h'), 'diff', '--staged' })
      require 'gpt'.stream('Write a commit message describing the changes and the reasoning:\n\n========\n' .. diff)
    end, { buffer = true })
  end
})
```
