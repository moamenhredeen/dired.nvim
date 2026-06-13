-- Self-contained tar browser backed by the native sidecar. Replaces Vim's
-- built-in tar.vim, which shells out to gzip/bzip2/xz (absent on Windows) for
-- compressed tarballs. We render our own listing and route entry read/write
-- through the sidecar so .tar/.tar.gz/.tar.bz2/.tar.xz browse and edit-in-place
-- work everywhere the sidecar runs.
local core = require("dired.core")

local M = {}

-- Patterns mirror dired's supported archive extensions (see functions.lua).
local tar_patterns = {
    "*.tar",
    "*.tar.gz",
    "*.tgz",
    "*.tar.bz2",
    "*.tbz2",
    "*.tar.xz",
    "*.txz",
}

local listing_header = {
    '" dired tar browser',
    "",
    '" <CR>: open entry under cursor',
}

local function is_comment(line)
    return line:sub(1, 1) == '"'
end

local function is_dir_entry(name)
    return name:sub(-1) == "/"
end

-- Render the archive's entry list into the (current) archive buffer.
function M.browse(archive)
    archive = vim.fn.fnamemodify(archive, ":p")
    local names, err = core.tar_list(archive)
    if not names then
        vim.notify("Dired: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local buf = vim.api.nvim_get_current_buf()
    local lines = {}
    vim.list_extend(lines, listing_header)
    lines[2] = '" ' .. archive
    vim.list_extend(lines, names)

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.b[buf].dired_tar_archive = archive
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "tar"

    vim.keymap.set("n", "<CR>", M.open_entry, { buffer = buf, silent = true, desc = "dired: open tar entry" })
end

-- Open the entry under the cursor in a scratch buffer wired for write-back.
function M.open_entry()
    local archive = vim.b.dired_tar_archive
    if not archive then
        return
    end
    local name = vim.api.nvim_get_current_line()
    if is_comment(name) or name == "" then
        return
    end
    if is_dir_entry(name) then
        vim.notify("Dired: that is a directory entry, not a file.", vim.log.levels.WARN)
        return
    end

    local data, err = core.tar_read(archive, name)
    if not data then
        vim.notify("Dired: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local bufname = "tar://" .. archive .. "::" .. name
    local existing = vim.fn.bufnr(bufname)
    if existing ~= -1 then
        vim.cmd("noswapfile new")
        vim.api.nvim_set_current_buf(existing)
        return
    end

    vim.cmd("noswapfile new")
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_name(buf, bufname)

    -- writefile re-adds a trailing newline per line, so drop the one produced
    -- by the entry's own final newline to avoid doubling it on save.
    local lines = vim.split(data, "\n", { plain = true })
    if #lines > 0 and lines[#lines] == "" then
        table.remove(lines)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modified = false
    vim.b[buf].dired_tar_archive = archive
    vim.b[buf].dired_tar_member = name

    -- pick a filetype from the entry name so syntax/indent work as usual
    local ft = vim.filetype.match({ filename = name, buf = buf })
    if ft then
        vim.bo[buf].filetype = ft
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = buf,
        callback = function()
            M.write_entry(buf)
        end,
        desc = "dired: write tar entry",
    })
end

-- Repack the edited buffer back into its tar archive via the sidecar.
function M.write_entry(buf)
    local archive = vim.b[buf].dired_tar_archive
    local member = vim.b[buf].dired_tar_member
    if not (archive and member) then
        return
    end

    local tmp = vim.fn.tempname()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    if vim.fn.writefile(lines, tmp) ~= 0 then
        vim.notify("Dired: could not stage tar entry for write.", vim.log.levels.ERROR)
        return
    end

    local err = core.tar_update(archive, member, tmp)
    vim.fn.delete(tmp)
    if err then
        vim.notify("Dired: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    vim.bo[buf].modified = false
    vim.notify(string.format("Dired: updated %s in %s", member, vim.fn.fnamemodify(archive, ":t")))
end

-- Register the browser and neutralize Vim's tar.vim. Only takes over when the
-- sidecar is present; otherwise tar.vim keeps handling tarballs as before.
function M.setup()
    if vim.fn.executable(core.bin) == 0 then
        return
    end

    -- prevent tar.vim from loading and drop any autocmds it already registered
    vim.g.loaded_tar = 1
    vim.g.loaded_tarPlugin = 1
    pcall(vim.api.nvim_clear_autocmds, { group = "tar" })

    local group = vim.api.nvim_create_augroup("dired_tar", { clear = true })
    vim.api.nvim_create_autocmd("BufReadCmd", {
        group = group,
        pattern = tar_patterns,
        callback = function(ev)
            M.browse(ev.match)
        end,
    })
end

return M
