local M = {}
local opts = { debounce = 300, pixels_per_column = 9, pixels_per_row = 18, auto_open = true }
local session
local script = debug.getinfo(1, "S").source:sub(2):gsub("/lua/edocview/init.lua$", "/python/render.py")

local function valid(s)
	return session == s and vim.api.nvim_win_is_valid(s.source_win) and vim.api.nvim_win_is_valid(s.preview_win)
end
local function error_message(message)
	vim.schedule(function()
		vim.notify("edocview: " .. message, vim.log.levels.ERROR)
	end)
end
local function draw(s)
	if not valid(s) or not s.pdf then
		return
	end
	if s.drawing then
		s.redraw = true
		return
	end
	local cols = vim.api.nvim_win_get_width(s.preview_win)
	local rows = vim.api.nvim_win_get_height(s.preview_win)
	if vim.api.nvim_buf_line_count(s.preview_buf) ~= rows then
		local lines = {}
		for i = 1, rows do
			lines[i] = ""
		end
		vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, lines)
	end
	local line = vim.api.nvim_win_get_cursor(s.source_win)[1]
	local total = vim.api.nvim_buf_line_count(s.source_buf)
	local fraction = (line - 1) / math.max(1, total - 1)
	local key = table.concat({ s.pdf, cols, rows, math.floor(fraction * 1000) }, ":")
	if s.last_view == key then
		return
	end
	s.drawing = true
	s.serial = s.serial + 1
	local png = s.dir .. "/view-" .. s.serial .. ".png"
	vim.system({
		"python3",
		script,
		"viewport",
		s.pdf,
		png,
		tostring(cols * opts.pixels_per_column),
		tostring(rows * opts.pixels_per_row),
		tostring(fraction),
	}, { text = true }, function(result)
		vim.schedule(function()
			s.drawing = false
			if not valid(s) then
				return
			end
			if result.code == 0 then
				if s.image then
					s.image:clear()
				end
				local image = require("image").from_file(png, {
					window = s.preview_win,
					buffer = s.preview_buf,
					x = 0,
					y = 0,
					width = cols,
					height = rows,
					namespace = "edocview",
					max_width_window_percentage = 100,
					max_height_window_percentage = 100,
				})
				if image then
					image:render()
					s.image = image
					s.last_view = key
				end
			else
				error_message(result.stderr or "viewport failed")
			end
			if s.redraw then
				s.redraw = false
				draw(s)
			end
		end)
	end)
end
local function compile(s)
	if not valid(s) then
		return
	end
	if s.compiling then
		s.recompile = true
		return
	end
	s.compiling = true
	s.generation = s.generation + 1
	local input = s.dir .. "/source." .. s.extension
	local pdf = s.dir .. "/document-" .. s.generation .. ".pdf"
	vim.fn.writefile(vim.api.nvim_buf_get_lines(s.source_buf, 0, -1, false), input)
	local origin = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.source_buf), ":h")
	vim.system({ "python3", script, "compile", input, pdf, origin }, { text = true }, function(result)
		vim.schedule(function()
			s.compiling = false
			if not valid(s) then
				return
			end
			if result.code == 0 then
				s.pdf = pdf
				s.last_view = nil
				draw(s)
			else
				error_message((result.stderr or result.stdout or "render failed"):sub(-1600))
			end
			if s.recompile then
				s.recompile = false
				compile(s)
			end
		end)
	end)
end
function M.stop()
	local s = session
	if not s then
		return
	end
	session = nil
	if s.timer then
		s.timer:stop()
		s.timer:close()
	end
	if s.group then
		pcall(vim.api.nvim_del_augroup_by_id, s.group)
	end
	if s.image then
		s.image:clear()
	end
	if vim.api.nvim_win_is_valid(s.preview_win) then
		vim.api.nvim_win_close(s.preview_win, true)
	end
	if vim.api.nvim_buf_is_valid(s.preview_buf) then
		pcall(vim.api.nvim_buf_delete, s.preview_buf, { force = true })
	end
	-- Give any in-flight compiler or rasterizer time to release its inputs.
	vim.defer_fn(function()
		vim.fn.delete(s.dir, "rf")
	end, 2000)
end
function M.setup(config)
	opts = vim.tbl_deep_extend("force", opts, config or {})
	local group = vim.api.nvim_create_augroup("EdocviewAutoOpen", { clear = true })
	if opts.auto_open then
		vim.api.nvim_create_autocmd("FileType", {
			group = group,
			pattern = { "markdown", "tex", "plaintex", "latex", "typst", "pdf" },
			callback = function(args)
				if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ":e") == "" then
					return
				end
				vim.schedule(function()
					if
						vim.api.nvim_buf_is_valid(args.buf)
						and vim.api.nvim_get_current_buf() == args.buf
						and (not session or session.source_buf ~= args.buf)
					then
						local ok, err = pcall(M.open)
						if not ok then
							error_message(tostring(err))
						end
					end
				end)
			end,
		})
		vim.api.nvim_create_autocmd("BufReadPost", {
			group = group,
			pattern = "*.pdf",
			callback = function(args)
				vim.schedule(function()
					if
						vim.api.nvim_buf_is_valid(args.buf)
						and vim.api.nvim_get_current_buf() == args.buf
						and (not session or session.source_buf ~= args.buf)
					then
						local ok, err = pcall(M.open)
						if not ok then
							error_message(tostring(err))
						end
					end
				end)
			end,
		})
	end
end
function M.toggle()
	local current = vim.api.nvim_get_current_buf()
	if session and valid(session) and (session.source_buf == current or session.preview_buf == current) then
		M.stop()
	else
		M.open()
	end
end
function M.open()
	M.stop()
	local source_win = vim.api.nvim_get_current_win()
	local source_buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(source_buf)
	local ext = name:match("%.([^.]*)$")
	if not ext or not ({ md = true, markdown = true, tex = true, typ = true, pdf = true })[ext] then
		error("edocview: save a Markdown, LaTeX, Typst, or PDF file first")
	end
	if not pcall(require, "image") then
		error("edocview: image.nvim is required")
	end
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	vim.cmd("rightbelow vsplit")
	local preview_win = vim.api.nvim_get_current_win()
	local preview_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(preview_win, preview_buf)
	vim.bo[preview_buf].buftype = "nofile"
	vim.bo[preview_buf].bufhidden = "wipe"
	vim.bo[preview_buf].swapfile = false
	vim.bo[preview_buf].filetype = "edocview"
	vim.wo[preview_win].number = false
	vim.wo[preview_win].relativenumber = false
	vim.wo[preview_win].signcolumn = "no"
	vim.wo[preview_win].statuscolumn = ""
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "" })
	vim.api.nvim_set_current_win(source_win)
	local s = {
		source_win = source_win,
		source_buf = source_buf,
		preview_win = preview_win,
		preview_buf = preview_buf,
		dir = dir,
		extension = ext,
		generation = 0,
		serial = 0,
	}
	session = s
	local function step(delta)
		if not valid(s) then
			return
		end
		local current = vim.api.nvim_win_get_cursor(source_win)[1]
		local last = vim.api.nvim_buf_line_count(source_buf)
		local next_line = math.max(1, math.min(last, current + delta))
		vim.api.nvim_win_set_cursor(source_win, { next_line, 0 })
		vim.api.nvim_win_call(source_win, function()
			vim.cmd("normal! zz")
		end)
		draw(s)
	end
	for key, delta in pairs({
		j = 1,
		k = -1,
		["<C-d>"] = 15,
		["<C-u>"] = -15,
		["<ScrollWheelDown>"] = 3,
		["<ScrollWheelUp>"] = -3,
	}) do
		vim.keymap.set("n", key, function()
			step(delta)
		end, { buffer = preview_buf, silent = true })
	end
	s.timer = vim.uv.new_timer()
	s.group = vim.api.nvim_create_augroup("EdocviewSession", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		group = s.group,
		buffer = source_buf,
		callback = function()
			s.timer:stop()
			s.timer:start(
				opts.debounce,
				0,
				vim.schedule_wrap(function()
					compile(s)
				end)
			)
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinScrolled" }, {
		group = s.group,
		callback = function(args)
			if args.event ~= "WinScrolled" or tonumber(args.match) == source_win then
				draw(s)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = s.group,
		callback = function()
			s.last_view = nil
			draw(s)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = s.group,
		callback = function(args)
			if tonumber(args.match) == source_win or tonumber(args.match) == preview_win then
				M.stop()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = s.group,
		callback = function()
			if s.image then
				s.image:clear()
			end
			vim.fn.delete(dir, "rf")
		end,
	})
	if ext == "pdf" then
		s.pdf = name
		draw(s)
	else
		compile(s)
	end
end
return M
