local fs = require("dired.fs")
local config = require("dired.config")
local display = require("dired.display")

local M = {}

M.path_separator = config.get("path_separator")

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

function M.delete_file(fs_t, ask)
    if fs_t.filename == "." or fs_t.filename == ".." then
        vim.notify(string.format(' Cannot Delete "%s"', fs_t.filepath), "error")
        return
    end
    if ask ~= true then
        if fs_t.filetype == "directory" then
            fs.do_delete(fs_t.filepath)
        else
            vim.loop.fs_unlink(fs_t.filepath)
        end
        return
    end
    local prompt = vim.fn.input(
        string.format("Confirm deletion of (%s) {yes,n(o),q(uit)}: ", fs_t.filename),
        ""
    )
    if prompt == "yes" then
        if fs_t.filetype == "directory" then
            fs.do_delete(fs_t.filepath)
        else
            vim.loop.fs_unlink(fs_t.filepath)
        end
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

function M.duplicate_file(fs_t)
    if fs_t.filename == "." or fs_t.filename == ".." then
        vim.notify(' Cannot duplicate "." or ".."', "error")
        return
    end

    local new_name = vim.fn.input({
        prompt = string.format("Duplicate %s as: ", fs_t.filename),
        default = fs_t.filename,
    })

    if new_name == "" or new_name == fs_t.filename then
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
        return
    end

    local success, errmsg = fs.do_copy(source_path, destination_path)
    if not success then
        vim.notify(
            string.format(' DiredDuplicate: Could not duplicate "%s" to "%s". %s',
                fs_t.filename, new_name, errmsg or ""),
            "error"
        )
        return
    end

    display.goto_filename = new_name
    vim.notify(
        string.format(' DiredDuplicate: "%s" duplicated as "%s"', fs_t.filename, new_name)
    )
end

return M
