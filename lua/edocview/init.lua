local M = {}

local opts = {
	debounce = 500,
	pixels_per_column = 9,
	pixels_per_row = 18,
	page_gap = 1,
	auto_open = true,
}
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

local function show_status(s, title, detail)
	if not valid(s) or s.pdf then
		return
	end
	vim.bo[s.preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, { title, "", detail or "" })
	vim.bo[s.preview_buf].modifiable = false
	vim.bo[s.preview_buf].modified = false
end

local function clear_images(s)
	for _, image in ipairs(s.images or {}) do
		pcall(image.clear, image)
	end
	s.images = {}
	s.page_cache = {}
end

local function source_cursor_fraction(s)
	local line = vim.api.nvim_win_get_cursor(s.source_win)[1]
	local total = vim.api.nvim_buf_line_count(s.source_buf)
	return (line - 1) / math.max(1, total - 1)
end

local function source_view_fraction(s)
	local info = vim.fn.getwininfo(s.source_win)[1]
	local total = vim.api.nvim_buf_line_count(s.source_buf)
	local height = vim.api.nvim_win_get_height(s.source_win)
	return (info.topline - 1) / math.max(1, total - height)
end

local function preview_view_fraction(s)
	local info = vim.fn.getwininfo(s.preview_win)[1]
	local height = vim.api.nvim_win_get_height(s.preview_win)
	return (info.topline - 1) / math.max(1, (s.total_rows or 1) - height)
end

local function with_sync_guard(s, callback)
	if not valid(s) then
		return
	end
	s.syncing = true
	callback()
	vim.defer_fn(function()
		if session == s then
			s.syncing = false
		end
	end, 30)
end

local function terminal_cell_size()
	local ok, size = pcall(function()
		return require("image/utils/term").get_size()
	end)
	if ok and size and size.cell_width and size.cell_height then
		return size.cell_width, size.cell_height
	end
	return opts.pixels_per_column, opts.pixels_per_row
end

local function resize_preview_buffer(s, total_rows)
	local current_rows = vim.api.nvim_buf_line_count(s.preview_buf)
	vim.bo[s.preview_buf].modifiable = true
	if not s.preview_initialized then
		vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, { "" })
		current_rows = 1
		s.preview_initialized = true
	end
	if total_rows > current_rows then
		local lines = {}
		for index = 1, total_rows - current_rows do
			lines[index] = ""
		end
		vim.api.nvim_buf_set_lines(s.preview_buf, current_rows, -1, false, lines)
	elseif total_rows < current_rows then
		vim.api.nvim_buf_set_lines(s.preview_buf, total_rows, -1, false, {})
	end
	vim.bo[s.preview_buf].modifiable = false
	vim.bo[s.preview_buf].modified = false
end

local function set_preview_fraction(s, fraction)
	if not valid(s) or not s.total_rows then
		return
	end
	fraction = math.max(0, math.min(1, fraction))
	local height = vim.api.nvim_win_get_height(s.preview_win)
	local top = math.floor(fraction * math.max(0, s.total_rows - height)) + 1
	if vim.fn.getwininfo(s.preview_win)[1].topline == top then
		return
	end
	with_sync_guard(s, function()
		vim.api.nvim_win_call(s.preview_win, function()
			vim.api.nvim_win_set_cursor(s.preview_win, { math.min(s.total_rows, top + math.floor(height / 2)), 0 })
			vim.fn.winrestview({ topline = top, leftcol = 0 })
		end)
	end)
end

local function set_source_fraction(s, fraction)
	if not valid(s) then
		return
	end
	fraction = math.max(0, math.min(1, fraction))
	local total = vim.api.nvim_buf_line_count(s.source_buf)
	local line = math.floor(fraction * math.max(0, total - 1)) + 1
	if vim.api.nvim_win_get_cursor(s.source_win)[1] == line then
		return
	end
	with_sync_guard(s, function()
		vim.api.nvim_win_set_cursor(s.source_win, { line, 0 })
		vim.api.nvim_win_call(s.source_win, function()
			vim.cmd("normal! zz")
		end)
	end)
end

local function render_pages(s)
	if not valid(s) or not s.pdf then
		return
	end
	if s.rasterizing then
		s.reraster = true
		return
	end

	local cols = vim.api.nvim_win_get_width(s.preview_win)
	if s.rendered_pdf == s.pdf and s.rendered_cols == cols then
		return
	end

	s.rasterizing = true
	s.render_serial = (s.render_serial or 0) + 1
	local serial = s.render_serial
	local pdf = s.pdf
	local output_dir = string.format("%s/pages-%d", s.dir, serial)
	local cell_width, cell_height = terminal_cell_size()
	local pixel_width = math.max(1, math.floor(cols * cell_width))

	vim.system({ "python3", script, "pages", pdf, output_dir, tostring(pixel_width) }, { text = true }, function(result)
		vim.schedule(function()
			s.rasterizing = false
			if not valid(s) then
				return
			end
			if result.code ~= 0 and s.pdf == pdf then
				error_message((result.stderr or result.stdout or "page rasterization failed"):sub(-1600))
			elseif serial == s.render_serial and s.pdf == pdf and vim.api.nvim_win_get_width(s.preview_win) == cols then
				local ok, pages = pcall(vim.json.decode, result.stdout)
				if not ok or type(pages) ~= "table" or #pages == 0 then
					error_message("page rasterizer returned no pages")
				else
					local page_layout = {}
					local total_rows = 0
					for _, page in ipairs(pages) do
						local page_rows = math.max(1, math.ceil(page.height / cell_height))
						page_layout[#page_layout + 1] = {
							path = page.path,
							hash = page.hash,
							row = total_rows,
							height = page_rows,
						}
						total_rows = total_rows + page_rows + opts.page_gap
					end
					s.total_rows = math.max(1, total_rows - opts.page_gap)
					resize_preview_buffer(s, s.total_rows)
					s.rendered_pdf = s.pdf
					s.rendered_cols = cols
					set_preview_fraction(s, source_cursor_fraction(s))

					local old_cache = s.page_cache or {}
					local new_cache = {}
					local images = {}
					for index, page in ipairs(page_layout) do
						local cached = old_cache[index]
						local image
						if cached and cached.hash == page.hash and cached.height == page.height then
							image = cached.image
							if cached.row ~= page.row then
								pcall(image.clear, image)
							end
							image:render({ x = 0, y = page.row, width = cols, height = page.height })
						else
							if cached and cached.image then
								pcall(cached.image.clear, cached.image)
							end
							image = require("image").from_file(page.path, {
								id = string.format("edocview-%d-%d-%s", s.source_buf, index, page.hash:sub(1, 12)),
								window = s.preview_win,
								buffer = s.preview_buf,
								x = 0,
								y = page.row,
								width = cols,
								height = page.height,
								inline = true,
								namespace = "edocview",
								max_width_window_percentage = 100,
								ignore_global_max_size = true,
							})
							if image then
								image:render()
							end
						end
						if image then
							images[#images + 1] = image
							new_cache[index] = { hash = page.hash, height = page.height, row = page.row, image = image }
						end
					end
					for index = #page_layout + 1, #old_cache do
						if old_cache[index] and old_cache[index].image then
							pcall(old_cache[index].image.clear, old_cache[index].image)
						end
					end
					s.images = images
					s.page_cache = new_cache
				end
			end

			if s.reraster then
				s.reraster = false
				render_pages(s)
			end
		end)
	end)
end

local function compile(s, report_error)
	if not valid(s) then
		return
	end
	if s.compiling then
		s.recompile = true
		s.report_recompile_error = s.report_recompile_error or report_error
		return
	end

	s.compiling = true
	s.generation = s.generation + 1
	local generation = s.generation
	local input = s.dir .. "/source." .. s.extension
	local pdf = s.dir .. "/document-" .. generation .. ".pdf"
	vim.fn.writefile(vim.api.nvim_buf_get_lines(s.source_buf, 0, -1, false), input)
	local origin = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(s.source_buf), ":h")

	vim.system({ "python3", script, "compile", input, pdf, origin }, { text = true }, function(result)
		vim.schedule(function()
			s.compiling = false
			if not valid(s) then
				return
			end
			if result.code == 0 and generation == s.generation and not s.recompile then
				s.pdf = pdf
				s.rendered_pdf = nil
				render_pages(s)
			elseif result.code ~= 0 then
				local message = vim.trim(result.stderr or result.stdout or "document compiler failed")
				if report_error then
					show_status(s, "Preview unavailable", message)
					error_message(message)
				else
					show_status(
						s,
						"Waiting for valid document…",
						"The last successful preview will return automatically."
					)
				end
			end
			if s.recompile then
				s.recompile = false
				local next_report_error = s.report_recompile_error
				s.report_recompile_error = false
				compile(s, next_report_error)
			end
		end)
	end)
end

local function scroll_preview(s, delta)
	if not valid(s) or not s.total_rows then
		return
	end
	vim.api.nvim_win_call(s.preview_win, function()
		local view = vim.fn.winsaveview()
		local height = vim.api.nvim_win_get_height(s.preview_win)
		view.topline = math.max(1, math.min(s.total_rows - height + 1, view.topline + delta))
		vim.api.nvim_win_set_cursor(s.preview_win, { math.min(s.total_rows, view.topline + math.floor(height / 2)), 0 })
		vim.fn.winrestview(view)
	end)
	set_source_fraction(s, preview_view_fraction(s))
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
	clear_images(s)
	if vim.api.nvim_win_is_valid(s.preview_win) then
		vim.api.nvim_win_close(s.preview_win, true)
	end
	if vim.api.nvim_buf_is_valid(s.preview_buf) then
		pcall(vim.api.nvim_buf_delete, s.preview_buf, { force = true })
	end
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
	vim.api.nvim_buf_set_name(
		preview_buf,
		string.format("edocview://%d/%s", source_buf, vim.fn.fnamemodify(name, ":t"))
	)
	vim.bo[preview_buf].buftype = "acwrite"
	vim.bo[preview_buf].bufhidden = "wipe"
	vim.bo[preview_buf].buflisted = false
	vim.bo[preview_buf].swapfile = false
	vim.bo[preview_buf].undolevels = -1
	vim.bo[preview_buf].filetype = "edocview"
	vim.b[preview_buf].edocview_preview = true
	vim.wo[preview_win].number = false
	vim.wo[preview_win].relativenumber = false
	vim.wo[preview_win].signcolumn = "no"
	vim.wo[preview_win].statuscolumn = ""
	vim.wo[preview_win].cursorline = false
	vim.wo[preview_win].wrap = false
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, { "Rendering…" })
	vim.bo[preview_buf].modifiable = false
	vim.bo[preview_buf].modified = false
	vim.api.nvim_set_current_win(source_win)

	local s = {
		source_win = source_win,
		source_buf = source_buf,
		preview_win = preview_win,
		preview_buf = preview_buf,
		dir = dir,
		extension = ext,
		generation = 0,
		images = {},
		page_cache = {},
	}
	session = s

	local function page_delta(multiplier)
		return math.max(1, math.floor(vim.api.nvim_win_get_height(preview_win) * multiplier))
	end
	for key, delta in pairs({ j = 1, k = -1, ["<ScrollWheelDown>"] = 3, ["<ScrollWheelUp>"] = -3 }) do
		vim.keymap.set("n", key, function()
			scroll_preview(s, delta)
		end, { buffer = preview_buf, silent = true })
	end
	vim.keymap.set("n", "<C-d>", function()
		scroll_preview(s, page_delta(0.5))
	end, { buffer = preview_buf, silent = true })
	vim.keymap.set("n", "<C-u>", function()
		scroll_preview(s, -page_delta(0.5))
	end, { buffer = preview_buf, silent = true })

	s.timer = vim.uv.new_timer()
	s.group = vim.api.nvim_create_augroup("EdocviewSession", { clear = true })
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = s.group,
		buffer = source_buf,
		callback = function()
			s.timer:stop()
			s.timer:start(
				opts.debounce,
				0,
				vim.schedule_wrap(function()
					compile(s, false)
				end)
			)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = s.group,
		buffer = source_buf,
		callback = function()
			s.timer:stop()
			compile(s, true)
		end,
	})
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = s.group,
		buffer = preview_buf,
		callback = function()
			if vim.api.nvim_buf_is_valid(source_buf) then
				vim.api.nvim_buf_call(source_buf, function()
					vim.cmd("silent write")
				end)
			end
			vim.bo[preview_buf].modified = false
		end,
	})
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = s.group,
		buffer = source_buf,
		callback = function()
			if not s.syncing then
				set_preview_fraction(s, source_cursor_fraction(s))
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = s.group,
		callback = function(args)
			if s.syncing then
				return
			end
			local win = tonumber(args.match or args.file)
			if win == source_win then
				set_preview_fraction(s, source_view_fraction(s))
			elseif win == preview_win then
				set_source_fraction(s, preview_view_fraction(s))
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = s.group,
		callback = function()
			if valid(s) and s.rendered_cols ~= vim.api.nvim_win_get_width(preview_win) then
				s.rendered_cols = nil
				render_pages(s)
			end
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
			clear_images(s)
			vim.fn.delete(dir, "rf")
		end,
	})

	if ext == "pdf" then
		s.pdf = name
		render_pages(s)
	else
		compile(s, true)
	end
end

return M
