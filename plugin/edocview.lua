if vim.g.loaded_edocview then
	return
end

vim.g.loaded_edocview = true

vim.api.nvim_create_user_command("EdocviewOpen", function()
	require("edocview").open()
end, {})

vim.api.nvim_create_user_command("EdocviewStop", function()
	require("edocview").stop()
end, {})

vim.api.nvim_create_user_command("EdocviewToggle", function()
	require("edocview").toggle()
end, {})
