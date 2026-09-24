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
assert(vim.api.nvim_buf_line_count(preview) == 1, "preview must be a fixed one-line viewport")

for _, window in ipairs(vim.api.nvim_list_wins()) do
	if vim.api.nvim_win_get_buf(window) == preview then
		vim.api.nvim_set_current_win(window)
		break
	end
end
local preview_scroll_map = vim.fn.maparg("j", "n", false, true)
assert(
	preview_scroll_map.rhs == "<Nop>",
	"preview must not scroll independently: " .. vim.inspect(preview_scroll_map)
)
vim.cmd.write()
local saved = table.concat(vim.fn.readfile(source), "\n")
assert(saved:find("save%-forwarded%-from%-preview"), "preview write did not save the source")

edocview.stop()
