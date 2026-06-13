-- Adapter over the native sidecar binary (bin/dired-core[.exe]), built or
-- downloaded by dired.install. The sidecar handles only what Neovim can't do
-- natively: bundled archive create/extract (no external tar/zip/unzip). It is
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

return M
