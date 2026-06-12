-- Minimal init used both by the test runner and child Neovim processes.
vim.cmd([[let &rtp.=','.getcwd()]])

if #vim.api.nvim_list_uis() == 0 then
    -- running headless (test runner or child process)
    vim.opt.runtimepath:append("deps/mini.nvim")
    require("mini.test").setup()
end
