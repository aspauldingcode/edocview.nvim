package.preload.image = function()
	return {}
end

local source = assert(vim.env.EDOCVIEW_TEST_SOURCE)
vim.o.swapfile = false
vim.cmd.edit(vim.fn.fnameescape(source))

local edocview = require("edocview")
edocview.setup({ auto_open = false })
edocview.open()
assert(#vim.api.nvim_list_wins() == 2, "edocview did not create its companion window")

-- This must tear down the preview first and then exit Neovim by closing the
-- remaining source window. Reaching the next line means :q was intercepted.
vim.cmd.quit()
error(":q returned instead of exiting after edocview cleanup")
