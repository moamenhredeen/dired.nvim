-- Adapter over the native sidecar binary (bin/dired-core[.exe]), built or
-- downloaded by dired.install. The sidecar handles what Neovim can't do
-- natively without external tar/zip/unzip: bundled archive create/extract, the
-- zip.vim unzip/zip shim, and the tar browser (list/read/update/delete). It is
-- optional -- the rest of the plugin works without it; only archive operations
-- require it and fail gracefully with an install hint when it is missing.
local M = {}

local function plugin_root()
    -- this file is <root>/lua/dired/core.lua
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
end

local is_windows = vim.uv.os_uname().sysname:find("Windows") ~= nil
local bin = plugin_root() .. "/bin/" .. (is_windows and "dired-core.exe" or "dired-core")

M.bin = bin

local missing_message = "native core not found at "
    .. bin
    .. ". Install it with `:lua require('dired.install').install()` or `make core`."

-- Asynchronous archive operations. cb(err) runs on the main loop with err = nil
-- on success or an error message string on failure (including a missing binary).
local function run_async(args, cb)
    if vim.fn.executable(bin) == 0 then
        cb(missing_message)
        return
    end
    vim.system(args, { text = true }, function(res)
        vim.schedule(function()
            if res.code ~= 0 then
                local msg = vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
                cb(msg ~= "" and msg or "archive operation failed")
            else
                cb(nil)
            end
        end)
    end)
end

function M.archive_create(archive, files, cwd, cb)
    local args = { bin, "archive-create", archive, cwd }
    vim.list_extend(args, files)
    run_async(args, cb)
end

function M.archive_extract(archive, dest, cb)
    run_async({ bin, "archive-extract", archive, dest }, cb)
end

-- Synchronous sidecar call used by the tar browser, where the work happens
-- inside BufReadCmd/BufWriteCmd and must complete before the buffer is shown.
-- Returns (stdout, nil) on success or (nil, message) on failure. text=false so
-- archive bytes survive intact.
local function run_sync(args)
    if vim.fn.executable(bin) == 0 then
        return nil, missing_message
    end
    local res = vim.system(args, { text = false }):wait()
    if res.code ~= 0 then
        local msg = vim.trim((res.stderr or "") ~= "" and res.stderr or (res.stdout or ""))
        return nil, msg ~= "" and msg or "archive operation failed"
    end
    return res.stdout or "", nil
end

-- List tar entry names. Returns (names_table, nil) or (nil, message).
function M.tar_list(archive)
    local out, err = run_sync({ bin, "tar-list", archive })
    if not out then
        return nil, err
    end
    local names = {}
    for line in out:gmatch("[^\n]+") do
        names[#names + 1] = line
    end
    return names, nil
end

-- Read one tar entry's raw bytes. Returns (data, nil) or (nil, message).
function M.tar_read(archive, member)
    return run_sync({ bin, "tar-read", archive, member })
end

-- Add/replace a tar entry from file `src`. Returns nil on success or a message.
function M.tar_update(archive, member, src)
    local _, err = run_sync({ bin, "tar-update", archive, member, src })
    return err
end

-- Remove a tar entry. Returns nil on success or a message.
function M.tar_delete(archive, member)
    local _, err = run_sync({ bin, "tar-delete", archive, member })
    return err
end

return M
