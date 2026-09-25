local M = {}

local opts = {
	debounce = 500,
	pixels_per_column = 9,
	pixels_per_row = 18,
	page_gap = 1,
	scroll_interval = 16,
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
	if not valid(s) or s.pdf or s.image then
		return
	end
	vim.bo[s.preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, { title, "", detail or "" })
	vim.bo[s.preview_buf].modifiable = false
	vim.bo[s.preview_buf].modified = false
end

local function clear_status(s)
	if not valid(s) or s.image then
		return
	end
	vim.bo[s.preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(s.preview_buf, 0, -1, false, { "" })
	vim.bo[s.preview_buf].modifiable = false
	vim.bo[s.preview_buf].modified = false
end

local function clear_images(s)
	for _, page in pairs(s.page_cache or {}) do
		if page.image then
			pcall(page.image.clear, page.image)
		end
	end
	s.image = nil
	s.page_cache = {}
end

local function source_view_fraction(s)
	local info = vim.fn.getwininfo(s.source_win)[1]
	local total = vim.api.nvim_buf_line_count(s.source_buf)
	local height = vim.api.nvim_win_get_height(s.source_win)
	return (info.topline - 1) / math.max(1, total - height)
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

local function preview_geometry(s)
	local info = vim.fn.getwininfo(s.preview_win)[1]
	local cols = math.max(1, info.width - info.textoff)
	local height = vim.api.nvim_win_get_height(s.preview_win)
	-- screenpos() includes tablines, winbars, and gutters. Recompute it for
	-- every placement instead of trusting image.nvim's cached bounds: its
	-- global redraw handlers may have updated those bounds between frames.
	local screen = vim.fn.screenpos(s.preview_win, 1, 1)
	local left = screen.col > 0 and screen.col - 1 or info.wincol - 1 + info.textoff
	local top = screen.row > 0 and screen.row - 1 or info.winrow - 1
	return {
		cols = cols,
		height = height,
		left = left,
		top = top,
		right = left + cols,
		bottom = top + height - 1,
	}
end

local function preview_width(s)
	return preview_geometry(s).cols
end

local function set_preview_fraction(s, fraction)
	if not valid(s) or not s.total_rows or not s.page_layout then
		return
	end
	fraction = math.max(0, math.min(1, fraction))
	local geometry = preview_geometry(s)
	local height = geometry.height
	local top = math.floor(fraction * math.max(0, s.total_rows - height))
	local selected = s.page_layout[#s.page_layout]
	for _, page in ipairs(s.page_layout) do
		if top < page.row + page.height + opts.page_gap then
			selected = page
			break
		end
	end
	if not selected or not selected.image then
		return
	end

	local offset = math.max(0, math.min(math.max(0, selected.height - height), top - selected.row))
	local placement_key = table.concat({ geometry.left, geometry.top, geometry.cols, geometry.height }, ":")
	if s.image == selected.image and s.page_offset == offset and s.placement_key == placement_key then
		return
	end
	local previous = s.image
	local image = selected.image
	-- Prime a newly selected page once. Subsequent scrolling goes straight to
	-- Kitty's crop-capable backend: the page stays resident in terminal memory
	-- and each frame sends only a tiny placement update.
	if not image.is_rendered or not image.bounds or not image.rendered_geometry then
		image.render_offset_top = 0
		image:render({ x = 0, y = 0, width = s.rendered_cols })
	end
	local backend = image.global_state and image.global_state.backend
	if
		image.is_rendered
		and image.bounds
		and image.rendered_geometry
		and backend
		and backend.features
		and backend.features.crop
	then
		local width = math.min(s.rendered_cols, image.rendered_geometry.width)
		local image_height = image.rendered_geometry.height
		local x = geometry.left
		local y = geometry.top - offset
		-- Keep edocview's placement bounded to the preview window. Also detach
		-- the prepared image from image.nvim's generic window redraw handlers;
		-- edocview owns its lifecycle and placement from this point onward.
		image.bounds = {
			left = geometry.left,
			right = geometry.right,
			top = geometry.top,
			bottom = geometry.bottom,
		}
		image.window = nil
		image.buffer = nil
		image.geometry.x = x
		image.geometry.y = y
		image.geometry.width = width
		image.geometry.height = nil
		backend.render(image, x, y, width, image_height)
		-- Direct backend placement intentionally bypasses Image:render(), so
		-- keep its bookkeeping aligned with the real terminal placement too.
		image.rendered_geometry = {
			x = x,
			y = y,
			width = width,
			height = image_height,
		}
	else
		-- Non-Kitty backends retain the old whole-page behavior.
		image:render({ x = 0, y = 0, width = s.rendered_cols })
	end
	s.image = selected.image
	s.page_offset = offset
	s.placement_key = placement_key
	s.view_fraction = fraction
	-- Keep the previous Kitty placement visible until its replacement has
	-- rendered. Clearing first exposes the terminal background as a flash.
	if previous and previous ~= selected.image then
		pcall(previous.clear, previous, true)
	end
end

local function queue_preview_fraction(s, fraction)
	s.pending_fraction = fraction
	if s.preview_update_pending then
		return
	end
	s.preview_update_pending = true
	vim.defer_fn(function()
		if not valid(s) then
			return
		end
		s.preview_update_pending = false
		local pending = s.pending_fraction
		s.pending_fraction = nil
		set_preview_fraction(s, pending)
	end, opts.scroll_interval)
end

local function render_pages(s)
	if not valid(s) or not s.pdf then
		return
	end
	if s.rasterizing then
		s.reraster = true
		return
	end

	local cols = preview_width(s)
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
			elseif serial == s.render_serial and s.pdf == pdf and preview_width(s) == cols then
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
					s.rendered_pdf = s.pdf
					s.rendered_cols = cols
					clear_status(s)

					local old_cache = s.page_cache or {}
					local new_cache = {}
					local stale_images = {}
					for index, page in ipairs(page_layout) do
						local cached = old_cache[index]
						local image
						if cached and cached.hash == page.hash and cached.height == page.height then
							image = cached.image
						else
							if cached and cached.image then
								stale_images[#stale_images + 1] = cached.image
							end
							image = require("image").from_file(page.path, {
								id = string.format("edocview-%d-%d-%s", s.source_buf, index, page.hash:sub(1, 12)),
								window = s.preview_win,
								buffer = s.preview_buf,
								x = 0,
								y = 0,
								width = cols,
								inline = false,
								with_virtual_padding = false,
								namespace = "edocview",
								max_width_window_percentage = 100,
								ignore_global_max_size = true,
							})
							-- image.nvim currently declares this option but does not copy it
							-- onto file-backed image instances. Set it explicitly so its
							-- global height cap cannot defeat edocview's fit-width layout.
							if image then
								image.ignore_global_max_size = true
							end
						end
						if image then
							page.image = image
							new_cache[index] = page
						end
					end
					for index = #page_layout + 1, #old_cache do
						if old_cache[index] and old_cache[index].image then
							stale_images[#stale_images + 1] = old_cache[index].image
						end
					end
					s.page_cache = new_cache
					s.page_layout = page_layout
					s.page_offset = nil
					s.placement_key = nil
					set_preview_fraction(s, source_view_fraction(s))
					for _, image in ipairs(stale_images) do
						if image ~= s.image then
							pcall(image.clear, image, true)
						end
					end
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

function M.stop()
	local s = session
	if not s then
		return
	end
	session = nil
	if s.timer then
		pcall(s.timer.stop, s.timer)
		if not s.timer:is_closing() then
			pcall(s.timer.close, s.timer)
		end
	end
	if s.group then
		pcall(vim.api.nvim_del_augroup_by_id, s.group)
	end
	clear_images(s)
	if vim.api.nvim_win_is_valid(s.preview_win) then
		-- The source may have been the other window and its WinClosed callback
		-- runs later. In that case the preview is now Neovim's last window and
		-- E444 is expected; deleting its scratch buffer below is sufficient.
		pcall(vim.api.nvim_win_close, s.preview_win, true)
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
			pattern = { "markdown", "tex", "plaintex", "latex", "typst", "pdf", "html" },
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
	if
		not ext
		or not ({ md = true, markdown = true, tex = true, typ = true, pdf = true, html = true, htm = true })[ext]
	then
		error("edocview: save a Markdown, LaTeX, Typst, PDF, or HTML file first")
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
	vim.wo[preview_win].foldcolumn = "0"
	vim.wo[preview_win].cursorline = false
	vim.wo[preview_win].wrap = false
	vim.wo[preview_win].scrollbind = false
	vim.wo[preview_win].list = false
	vim.api.nvim_win_call(preview_win, function()
		vim.opt_local.fillchars:append({ eob = " " })
	end)
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
		page_cache = {},
	}
	session = s

	for _, key in ipairs({ "j", "k", "<C-d>", "<C-u>", "<ScrollWheelDown>", "<ScrollWheelUp>" }) do
		vim.keymap.set("n", key, "<Nop>", { buffer = preview_buf, silent = true })
	end

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
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = s.group,
		callback = function(args)
			local win = tonumber(args.match or args.file)
			if win == source_win then
				queue_preview_fraction(s, source_view_fraction(s))
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinResized", {
		group = s.group,
		callback = function()
			if valid(s) then
				if s.rendered_cols ~= preview_width(s) then
					s.rendered_cols = nil
					render_pages(s)
				else
					-- The split may have moved without changing width. Re-place the
					-- resident image using the window's new absolute coordinates.
					s.placement_key = nil
					queue_preview_fraction(s, source_view_fraction(s))
				end
			end
		end,
	})
	vim.api.nvim_create_autocmd("QuitPre", {
		group = s.group,
		buffer = source_buf,
		callback = function()
			-- Tear down the companion first. The user's original :q/:wq can
			-- then close the source (and exit Neovim when it is the last window)
			-- instead of stranding an edocview scratch window behind it.
			if session == s then
				M.stop()
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = s.group,
		callback = function(args)
			if tonumber(args.match) == source_win or tonumber(args.match) == preview_win then
				vim.schedule(function()
					if session == s then
						M.stop()
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = s.group,
		callback = function()
			pcall(clear_images, s)
			pcall(vim.fn.delete, dir, "rf")
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
