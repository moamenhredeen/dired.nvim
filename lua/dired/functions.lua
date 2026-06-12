local fs = require("dired.fs")
local config = require("dired.config")
local display = require("dired.display")

local M = {}

M.path_separator = config.get("path_separator")

local archive_formats = {
    [".zip"] = { kind = "zip" },
    [".tar"] = { kind = "tar", create_flag = "-cf" },
    [".tar.gz"] = { kind = "tar", create_flag = "-czf" },
    [".tgz"] = { kind = "tar", create_flag = "-czf" },
    [".tar.bz2"] = { kind = "tar", create_flag = "-cjf" },
    [".tbz2"] = { kind = "tar", create_flag = "-cjf" },
    [".tar.xz"] = { kind = "tar", create_flag = "-cJf" },
    [".txz"] = { kind = "tar", create_flag = "-cJf" },
}

local archive_extensions = { ".tar.bz2", ".tar.gz", ".tar.xz", ".tbz2", ".tgz", ".txz", ".tar", ".zip" }

local function get_archive_format(path)
    local lower_path = path:lower()
    for _, extension in ipairs(archive_extensions) do
        if lower_path:sub(-#extension) == extension then
            return archive_formats[extension], extension
        end
    end
end

local function is_absolute_path(path)
    local first = path:sub(1, 1)
    if first == "/" or first == "\\" then
        return true
    end
    return path:match("^%a:[/\\]") ~= nil
end

-- bsdtar (Windows 10+, macOS) reads and writes zip archives; GNU tar (most
-- Linux distros) does not, so zip support there needs the zip/unzip tools.
local tar_is_bsd
local function has_bsdtar()
    if tar_is_bsd == nil then
        if vim.fn.executable("tar") == 1 then
            tar_is_bsd = vim.fn.system({ "tar", "--version" }):lower():find("bsdtar", 1, true) ~= nil
        else
            tar_is_bsd = false
        end
    end
    return tar_is_bsd
end

local function tar_exists()
    if vim.fn.executable("tar") == 1 then
        return true
    end
    vim.notify("Dired: `tar` is required for this operation.", vim.log.levels.ERROR)
    return false
end

-- returns the create command with the archive path appended, or nil
local function get_create_command(format, archive_path)
    if format.kind == "zip" then
        if vim.fn.executable("zip") == 1 then
            return { "zip", "-r", archive_path }
        end
        if has_bsdtar() then
            return { "tar", "-a", "-cf", archive_path }
        end
        vim.notify("Dired: `zip` or bsdtar is required to create zip archives.", vim.log.levels.ERROR)
        return nil
    end
    if not tar_exists() then
        return nil
    end
    return { "tar", format.create_flag, archive_path }
end

-- returns the full extract command, or nil
local function get_extract_command(format, archive_path, destination)
    if format.kind == "zip" then
        if vim.fn.executable("unzip") == 1 then
            return { "unzip", "-n", archive_path, "-d", destination }
        end
        if has_bsdtar() then
            -- -k skips existing files, matching unzip -n
            return { "tar", "-xkf", archive_path, "-C", destination }
        end
        vim.notify("Dired: `unzip` or bsdtar is required to extract zip archives.", vim.log.levels.ERROR)
        return nil
    end
    if not tar_exists() then
        return nil
    end
    return { "tar", "-xf", archive_path, "-C", destination }
end

local function run_process(args, cwd, callback)
    vim.system(args, { cwd = cwd, text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                local message = result.stderr ~= "" and result.stderr or result.stdout
                vim.notify(vim.trim(message or "Command failed"), vim.log.levels.ERROR)
                callback(false)
                return
            end
            callback(true)
        end)
    end)
end

function M.compress_files(files, directory, callback)
    callback = callback or function() end
    for _, file in ipairs(files) do
        if fs.get_simplified_path(file.parent_dir) ~= fs.get_simplified_path(directory) then
            vim.notify("Dired: Compression only supports files in the current directory.", vim.log.levels.ERROR)
            callback(false)
            return
        end
    end

    local default_name = #files == 1 and (files[1].filename .. ".zip") or "archive.zip"
    local archive_name = vim.fn.input("Archive name: ", default_name, "file")
    if archive_name == "" then
        callback(false)
        return
    end

    local archive_path = archive_name
    if not is_absolute_path(archive_name) then
        archive_path = fs.join_paths(directory, archive_name)
    end
    archive_path = vim.fn.fnamemodify(archive_path, ":p")
    local format, extension = get_archive_format(archive_path)
    if not format then
        vim.notify("Dired: Unsupported archive extension.", vim.log.levels.ERROR)
        callback(false)
        return
    end
    local archive_exists = fs.file_exists(archive_path)
    if archive_exists then
        local choice = vim.fn.confirm("Archive already exists. Replace it?", "&Yes\n&No", 2)
        if choice ~= 1 then
            callback(false)
            return
        end
    end

    local temporary_path = archive_path .. ".dired-tmp" .. extension
    if fs.file_exists(temporary_path) then
        vim.loop.fs_unlink(temporary_path)
    end
    local args = get_create_command(format, temporary_path)
    if not args then
        callback(false)
        return
    end
    table.insert(args, "--")
    for _, file in ipairs(files) do
        table.insert(args, file.filename)
    end

    run_process(args, directory, function(success)
        if not success then
            vim.loop.fs_unlink(temporary_path)
            callback(false)
            return
        end

        local backup_path = archive_path .. ".dired-backup"
        if archive_exists then
            if fs.file_exists(backup_path) then
                vim.loop.fs_unlink(backup_path)
            end
            local backed_up, backup_err = vim.loop.fs_rename(archive_path, backup_path)
            if not backed_up then
                vim.loop.fs_unlink(temporary_path)
                vim.notify("Dired: Could not replace archive: " .. tostring(backup_err), vim.log.levels.ERROR)
                callback(false)
                return
            end
        end
        local renamed, rename_err = vim.loop.fs_rename(temporary_path, archive_path)
        if not renamed then
            if archive_exists then
                vim.loop.fs_rename(backup_path, archive_path)
            end
            vim.loop.fs_unlink(temporary_path)
            vim.notify("Dired: Could not finalize archive: " .. tostring(rename_err), vim.log.levels.ERROR)
            callback(false)
            return
        end
        if archive_exists then
            vim.loop.fs_unlink(backup_path)
        end

        if fs.get_simplified_path(vim.fn.fnamemodify(archive_path, ":h")) == fs.get_simplified_path(directory) then
            display.goto_filename = vim.fn.fnamemodify(archive_path, ":t")
        end
        vim.notify(string.format("Dired: Created %s", archive_path))
        callback(true)
    end)
end

function M.extract_files(files, directory, callback)
    callback = callback or function() end
    local destination = vim.fn.input("Extract to: ", directory, "dir")
    if destination == "" then
        callback(false)
        return
    end
    if not is_absolute_path(destination) then
        destination = fs.join_paths(directory, destination)
    end
    destination = vim.fn.fnamemodify(destination, ":p")
    if vim.fn.isdirectory(destination) == 0 and vim.fn.mkdir(destination, "p") == 0 then
        vim.notify("Dired: Could not create extraction directory.", vim.log.levels.ERROR)
        callback(false)
        return
    end

    local index = 1
    local function extract_next()
        local file = files[index]
        if not file then
            vim.notify(string.format("Dired: Extracted %d archive(s) to %s", #files, destination))
            callback(true)
            return
        end

        local format = get_archive_format(file.filepath)
        if not format then
            vim.notify(string.format("Dired: Unsupported archive: %s", file.filename), vim.log.levels.ERROR)
            callback(false)
            return
        end
        local args = get_extract_command(format, file.filepath, destination)
        if not args then
            callback(false)
            return
        end

        run_process(args, directory, function(success)
            if not success then
                callback(false)
                return
            end
            index = index + 1
            extract_next()
        end)
    end

    extract_next()
end

function M.chmod_files(files)
    local stat = vim.loop.fs_stat(files[1].filepath)
    if not stat then
        vim.notify("Dired: Could not read the current mode.", vim.log.levels.ERROR)
        return false
    end
    local current_mode = stat.mode % 512
    local input = vim.fn.input("Mode (octal): ", string.format("%03o", current_mode))
    if input == "" then
        return false
    end
    if not input:match("^[0-7][0-7][0-7][0-7]?$") then
        vim.notify("Dired: Mode must be three or four octal digits.", vim.log.levels.ERROR)
        return false
    end

    local mode = tonumber(input, 8)
    for _, file in ipairs(files) do
        local success, err = vim.loop.fs_chmod(file.filepath, mode)
        if not success then
            vim.notify(string.format("Dired: chmod failed for %s: %s", file.filename, err), vim.log.levels.ERROR)
            return false
        end
    end
    vim.notify(string.format("Dired: Changed mode on %d item(s).", #files))
    return true
end

function M.touch_files(files)
    local timestamp = os.time()
    for _, file in ipairs(files) do
        local success, err = vim.loop.fs_utime(file.filepath, timestamp, timestamp)
        if not success then
            vim.notify(string.format("Dired: touch failed for %s: %s", file.filename, err), vim.log.levels.ERROR)
            return false
        end
    end
    vim.notify(string.format("Dired: Updated timestamps on %d item(s).", #files))
    return true
end

local function run_in_compile_mode(command, directory)
    vim.api.nvim_create_autocmd("FileType", {
        pattern = "compilation",
        once = true,
        callback = function(args)
            vim.schedule(function()
                local windows = vim.fn.win_findbuf(args.buf)
                if windows[1] and vim.api.nvim_win_is_valid(windows[1]) then
                    vim.api.nvim_set_current_win(windows[1])
                end
            end)
        end,
    })

    vim.g.compilation_directory = directory
    require("compile-mode").compile({
        args = command,
        smods = { split = "botright" },
    })
end

function M.rename_file(fs_t)
    local new_name = vim.fn.input({
        prompt = string.format("Enter New Name (%s): ", fs_t.filename),
        default = fs_t.filename,
    })
    if new_name == "" then
        return
    end
    local old_path = fs_t.filepath
    local new_path = fs.join_paths(fs_t.parent_dir, new_name)
    local success = vim.loop.fs_rename(old_path, new_path)
    if not success then
        vim.notify(
            string.format(' DiredRename: Could not rename "%s" to "%s".', fs_t.filename, new_name)
        )
        return
    end
    display.goto_filename = new_name
end

function M.create_file()
    local filename = vim.fn.input("Enter Filename: ")
    if filename == "" then
        return
    end
    local default_dir_mode = tonumber("775", 8)
    local default_file_mode = tonumber("644", 8)

    if filename:sub(-1, -1) == M.path_separator then
        -- create a directory
        filename = filename:sub(1, -2)
        local dir = vim.g.current_dired_path
        local fd = vim.loop.fs_mkdir(fs.join_paths(dir, filename), default_dir_mode)

        if not fd then
            vim.notify(string.format(' DiredCreate: Could not create Directory "%s".', filename))
            return
        end
    else
        local dir = vim.g.current_dired_path
        local fd, err = vim.loop.fs_open(fs.join_paths(dir, filename), "w+", default_file_mode)

        if not fd or err ~= nil then
            vim.notify(string.format(' DiredCreate: Could not create file "%s".', filename))
            return
        end

        vim.loop.fs_close(fd)
    end
    display.goto_filename = filename
end

-- delete fs_t asynchronously; callback(success, errmsg) is always invoked,
-- synchronously on refusal/cancel paths
function M.delete_file(fs_t, ask, callback)
    callback = callback or function() end
    if fs_t.filename == "." or fs_t.filename == ".." then
        vim.notify(string.format(' Cannot Delete "%s"', fs_t.filepath), "error")
        callback(false, "refused")
        return
    end

    local uv = vim.uv or vim.loop
    local function start()
        if fs_t.filetype == "directory" then
            fs.do_delete(fs_t.filepath, callback)
        else
            uv.fs_unlink(fs_t.filepath, function(err)
                vim.schedule(function()
                    callback(err == nil, err)
                end)
            end)
        end
    end

    if ask ~= true then
        start()
        return
    end
    local prompt = vim.fn.input(
        string.format("Confirm deletion of (%s) {yes,n(o),q(uit)}: ", fs_t.filename),
        ""
    )
    if prompt == "yes" then
        start()
    else
        callback(false, "cancelled")
    end
end

function M.shell_cmd(fs_t)
    local cmd = vim.fn.input("Enter command: ", "", "shellcmd")
    if cmd == "" then
        return
    end
    local xcmd = cmd .. " " .. vim.fn.shellescape(fs_t.filepath)
    run_in_compile_mode(xcmd, fs_t.parent_dir)
end

function M.shell_cmd_on_marked_files(fs_t_list)
    if not fs_t_list or not next(fs_t_list) then
        return
    end

    local cmd = vim.fn.input("Enter command: ", "", "shellcmd")
    if cmd == "" then
        return
    end

    local file_list = {}
    for _, fs_t in ipairs(fs_t_list) do
        table.insert(file_list, vim.fn.shellescape(fs_t.filepath))
    end

    local xcmd = cmd .. " " .. table.concat(file_list, " ")
    run_in_compile_mode(xcmd, vim.g.current_dired_path)
end

-- duplicate fs_t asynchronously; callback(success, errmsg) is always invoked,
-- synchronously on refusal/cancel paths
function M.duplicate_file(fs_t, callback)
    callback = callback or function() end
    if fs_t.filename == "." or fs_t.filename == ".." then
        vim.notify(' Cannot duplicate "." or ".."', "error")
        callback(false, "refused")
        return
    end

    local new_name = vim.fn.input({
        prompt = string.format("Duplicate %s as: ", fs_t.filename),
        default = fs_t.filename,
    })

    if new_name == "" or new_name == fs_t.filename then
        callback(false, "cancelled")
        return
    end

    local source_path = fs_t.filepath
    local destination_path = fs.join_paths(fs_t.parent_dir, new_name)

    -- Check if destination already exists
    if fs.file_exists(destination_path) then
        vim.notify(
            string.format(' DiredDuplicate: File "%s" already exists.', new_name),
            "error"
        )
        callback(false, "exists")
        return
    end

    fs.do_copy(source_path, destination_path, function(success, errmsg)
        if not success then
            vim.notify(
                string.format(' DiredDuplicate: Could not duplicate "%s" to "%s". %s',
                    fs_t.filename, new_name, errmsg or ""),
                "error"
            )
            callback(false, errmsg)
            return
        end

        display.goto_filename = new_name
        vim.notify(
            string.format(' DiredDuplicate: "%s" duplicated as "%s"', fs_t.filename, new_name)
        )
        callback(true)
    end)
end

return M
