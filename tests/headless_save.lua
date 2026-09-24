package.preload.image = function()
	return {}
end

local source = assert(vim.env.EDOCVIEW_TEST_SOURCE)
vim.o.swapfile = false
vim.fn.writefile({ "before" }, source)
vim.cmd.edit(vim.fn.fnameescape(source))
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "save-forwarded-from-preview" })

local edocview = require("edocview")
edocview.setup({ auto_open = false })
edocview.open()

local preview
for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
	if vim.b[buffer].edocview_preview then
		preview = buffer
		break
	end
end

assert(preview, "preview buffer was not created")
assert(vim.bo[preview].buftype == "acwrite", "preview must handle writes")
assert(not vim.bo[preview].buflisted, "preview must stay out of buffer lists")
assert(not vim.bo[preview].modifiable, "preview must be read-only")

vim.api.nvim_set_current_buf(preview)
vim.cmd.write()
local saved = table.concat(vim.fn.readfile(source), "\n")
assert(saved:find("save%-forwarded%-from%-preview"), "preview write did not save the source")

edocview.stop()
