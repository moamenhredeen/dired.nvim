-- functions for fetching files and directories information
local config = require("dired.config")
local async = require("dired.async")

local uv = vim.uv or vim.loop

local M = {}

-- masks to identify files.
M.fs_masks = {
    S_IFMT = 61440,
    S_IFSOCK = 49152,
    S_IFLNK = 40960,
    S_IFREG = 32768,
    S_IFBLK = 24576,
    S_IFDIR = 16384,
    S_IFCHR = 8192,
    S_IFIFO = 4096,
    S_ISUID = 2048,
    S_ISGID = 1024,
    S_ISVTX = 512,
    S_IRUSR = 256,
    S_IWUSR = 128,
    S_IXUSR = 64,
    S_IRGRP = 32,
    S_IWGRP = 16,
    S_IXGRP = 8,
    S_IROTH = 4,
    S_IWOTH = 2,
    S_IXOTH = 1,
}

M.path_separator = config.get("path_separator")

-- is filepath a directory or just a file
function M.is_directory(filepath)
    return vim.fn.isdirectory(filepath) == 1
end

-- is filepath a hidden directory/file
function M.is_hidden(filename)
    return string.sub(filename, 1, 1) == "."
end

-- get filename from absolute path
function M.get_filename(filepath)
    local fname = filepath:match("^.+" .. M.path_separator .. "(.+)$")
    if fname == nil then
        fname = string.sub(filepath, 2, #filepath)
    end
    return fname
end

-- canonical form for path comparisons: absolute, forward slashes, no
-- trailing separator (on Windows fnamemodify mixes "/" and "\" depending on
-- the input, so equality checks need this normalization)
function M.get_simplified_path(filepath)
    filepath = vim.fn.simplify(vim.fn.fnamemodify(filepath, ":p")):gsub("\\", "/")
    if filepath:sub(-1, -1) == "/" then
        filepath = vim.fn.fnamemodify(filepath, ":h"):gsub("\\", "/")
    end

    return filepath
end

-- get parent path
function M.get_parent_path(path)
    local sep = M.path_separator
    sep = sep or "/"
    return path:match("(.*" .. sep .. ")")
end

-- get absolute path
function M.get_absolute_path(path)
    if M.is_directory(path) then
        return vim.fn.fnamemodify(path, ":p")
    else
        return vim.fn.fnamemodify(path, ":h:p")
    end
end

-- join_paths
function M.join_paths(...)
    local string_builder = {}
    for _, path in ipairs({ ... }) do
        if path:sub(-1, -1) == M.path_separator then
            path = path:sub(0, -2)
        end
        table.insert(string_builder, path)
    end
    return table.concat(string_builder, M.path_separator)
end

function M.file_exists(filepath)
    local stat, err = vim.loop.fs_lstat(filepath)
    if stat == nil and err ~= nil then
        return false
    end
    return true
end

function M.get_symlink(filepath)
    local link = vim.loop.fs_readlink(filepath)
    if not link then
        return nil
    end
    return link
end

-- recursive workers below run inside async.run: every libuv operation goes
-- through async.await so the main loop stays free during large trees.

local function delete_recursive(path)
    local err, handle = async.await(uv.fs_scandir, path)
    if not handle then
        return false, err
    end

    while true do
        local name, t = uv.fs_scandir_next(handle)
        if not name then
            break
        end

        local child = M.join_paths(path, name)

        if t == "directory" then
            local success, cerr = delete_recursive(child)
            if not success then
                return false, cerr
            end
        else
            local uerr = async.await(uv.fs_unlink, child)
            if uerr then
                return false, uerr
            end
        end
    end

    local rerr = async.await(uv.fs_rmdir, path)
    if rerr then
        return false, rerr
    end
    return true
end

local function copy_recursive(source, destination)
    local serr, source_stats = async.await(uv.fs_stat, source)
    if not source_stats then
        vim.notify(string.format("do_copy fs_stat '%s' failed '%s'", source, serr), vim.log.levels.ERROR)
        return false, serr
    end

    if source == destination then
        vim.notify("do_copy source and destination are the same, exiting early", vim.log.levels.WARN)
        return true
    end

    if source_stats.type == "file" then
        -- flags passed explicitly as 0: avoids a nil hole in await's varargs
        local cerr = async.await(uv.fs_copyfile, source, destination, 0)
        if cerr then
            vim.notify(string.format("do_copy fs_copyfile failed '%s'", cerr), vim.log.levels.ERROR)
            return false, cerr
        end
        return true
    elseif source_stats.type == "directory" then
        local err, handle = async.await(uv.fs_scandir, source)
        if not handle then
            vim.notify(string.format("do_copy fs_scandir '%s' failed '%s'", source, err), vim.log.levels.ERROR)
            return false, err
        end

        local merr = async.await(uv.fs_mkdir, destination, source_stats.mode)
        if merr then
            -- destination exists: wipe it and retry, continuing into the
            -- child loop regardless of the retry result
            delete_recursive(destination)
            async.await(uv.fs_mkdir, destination, source_stats.mode)
        end

        while true do
            local name, _ = uv.fs_scandir_next(handle)
            if not name then
                break
            end

            local success, cerr = copy_recursive(M.join_paths(source, name), M.join_paths(destination, name))
            if not success then
                return false, cerr
            end
        end
        return true
    else
        local errmsg = string.format("'%s' illegal file type '%s'", source, source_stats.type)
        vim.notify("do_copy " .. errmsg, vim.log.levels.ERROR)
        return false, errmsg
    end
end

-- delete path recursively without blocking the UI; callback(success, errmsg)
function M.do_delete(path, callback)
    async.run(function()
        return delete_recursive(path)
    end, function(success, errmsg)
        if not success and errmsg then
            vim.notify(string.format("Dired: delete '%s' failed: %s", path, errmsg), vim.log.levels.ERROR)
        end
        callback(success, errmsg)
    end)
end

-- copy source to destination recursively without blocking the UI;
-- callback(success, errmsg)
function M.do_copy(source, destination, callback)
    async.run(function()
        return copy_recursive(source, destination)
    end, callback)
end

return M
