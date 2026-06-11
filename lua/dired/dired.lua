local fs = require("dired.fs")
local ls = require("dired.ls")
local display = require("dired.display")
local highlight = require("dired.highlight")
local config = require("dired.config")
local funcs = require("dired.functions")
local utils = require("dired.utils")
local marker = require("dired.marker")
local history = require("dired.history")
local clipboard = require("dired.clipboard")

local M = {}

local function normalize_path(path)
    -- remove trailing slashes, except for root
    path = path:gsub("[/\\]+$", "")
    if path == "" then
        path = "/"
    end
    return path
end

local function dired_buffer_name(buffer, path)
    return string.format("dired://%d%s", buffer, path)
end

local function set_dired_path(path)
    path = normalize_path(vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"))
    local buffer = vim.api.nvim_get_current_buf()
    vim.b.dired_path = path
    vim.g.current_dired_path = path
    vim.api.nvim_buf_set_name(buffer, dired_buffer_name(buffer, path))

    if vim.g.dired_override_cwd then
        vim.api.nvim_set_current_dir(path)
    end

    display.render(path)
end

-- initialize dired buffer
function M.init_dired()
    -- preserve altbuffer
    local altbuf = vim.fn.bufnr("#")
    local path = vim.b.dired_path
        or normalize_path(vim.fn.fnamemodify(vim.fn.expand("%"), ":p"):gsub("\\", "/"))

    vim.bo.filetype = "dired"
    vim.bo.swapfile = false
    vim.bo.buftype = "acwrite"
    vim.bo.bufhidden = "hide"
    vim.bo.modifiable = true

    if altbuf ~= -1 then
        vim.fn.setreg("#", altbuf)
    end

    set_dired_path(path)
end

-- open a new directory
function M.open_dir(path)
    if path == "" then
        if vim.bo.filetype == "dired" then
            path = vim.b.dired_path
        else
            path = vim.fn.fnamemodify(vim.fn.expand("%"), ":p"):gsub("\\", "/")
            if not fs.is_directory(path) then
                path = fs.get_parent_path(path)
            end
        end
    end

    if vim.bo.filetype == "dired" and not path:match("^/") and not path:match("^%a:[/\\]") then
        path = fs.join_paths(vim.b.dired_path, path)
    end
    path = normalize_path(vim.fn.fnamemodify(path, ":p"):gsub("\\", "/"))
    if vim.bo.filetype == "dired" then
        if path ~= vim.b.dired_path then
            history.push_path(vim.b.dired_path)
            set_dired_path(path)
        end
        return
    end

    vim.cmd(string.format("noautocmd edit %s", vim.fn.fnameescape(path)))
    M.init_dired()
end

-- open a file or traverse inside a directory
function M.enter_dir()
    if vim.bo.filetype ~= "dired" then
        return
    end

    local dir = vim.g.current_dired_path
    display.cursor_pos = {} -- reset cursor pos
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln(string.format("Dired: invalid filename (%s) for file.", filename))
        return
    end

    if file.filetype == "directory" then
        history.push_path(vim.b.dired_path)
        set_dired_path(file.filepath)
    else
        vim.cmd(string.format("edit %s", vim.fn.fnameescape(file.filepath)))
    end

    -- Directory navigation stays in this buffer. Opening a file hides it so
    -- the alternate-buffer command can return to the same Dired session.
end

-- quit already opened Dired buffer
function M.quit_buf()
    if vim.bo.filetype ~= "dired" then
        return
    end

    local dired_buffer = vim.api.nvim_get_current_buf()
    local alternate = vim.fn.bufnr("#")
    if alternate >= 0 and vim.api.nvim_buf_is_valid(alternate) and alternate ~= dired_buffer then
        vim.api.nvim_set_current_buf(alternate)
    else
        vim.cmd("enew")
    end
    vim.api.nvim_buf_delete(dired_buffer, { force = true })
end

function M.go_back()
    local last_path = history.pop_path()
    if last_path then
        set_dired_path(last_path)
    end
end

function M.go_up()
    local current_path = vim.b.dired_path
    display.goto_filename = fs.get_filename(current_path)
    M.open_dir(fs.get_parent_path(current_path))
end

-- toggle between showing hidden files
function M.toggle_hidden_files()
    display.cursor_pos = {}
    vim.g.dired_show_hidden = not vim.g.dired_show_hidden
    vim.notify(string.format("dired_show_hidden: %s", vim.inspect(vim.g.dired_show_hidden)))
    M.init_dired()
end

-- toggle between showing icons
function M.toggle_show_icons()
    display.cursor_pos = {}
    vim.g.dired_show_icons = not vim.g.dired_show_icons
    vim.notify(string.format("dired_show_icons: %s", vim.inspect(vim.g.dired_show_icons)))
    M.init_dired()
end

-- toggle between hide_details mode
function M.toggle_hide_details()
    display.cursor_pos = {}
    vim.g.dired_hide_details = not vim.g.dired_hide_details
    vim.notify(string.format("dired_hide_details: %s", vim.inspect(vim.g.dired_hide_details)))
    M.init_dired()
end

-- visually highlight the filename on the current line using the same
-- group as marked files, without actually marking it. This is ephemeral
-- and cleared on buffer redraws.
function M.preview_highlight_current_line()
    if vim.bo.filetype ~= "dired" then
        return
    end
    local line_nr = vim.api.nvim_win_get_cursor(0)[1]
    -- clear previous highlight namespace if exists
    if not M._preview_ns then
        M._preview_ns = vim.api.nvim_create_namespace("dired_preview_ns")
    else
        vim.api.nvim_buf_clear_namespace(0, M._preview_ns, 0, -1)
    end

    local hl_group = highlight.PREVIEW
    local opts = {
        line_hl_group = hl_group,
        priority = 200,
    }
    vim.api.nvim_buf_set_extmark(0, M._preview_ns, line_nr - 1, 0, opts)
end

-- change the sort order
function M.toggle_sort_order()
    vim.g.dired_sort_order = config.get_next_sort_order()
    display.render(vim.g.current_dired_path)
    vim.notify(string.format("Dired by %s", vim.g.dired_sort_order))
end

-- change colors
function M.toggle_colors()
    vim.g.dired_show_colors = not vim.g.dired_show_colors
    display.render(vim.g.current_dired_path)
    vim.notify(string.format("dired_show_colors: %s", vim.inspect(vim.g.dired_show_colors)))
end

local function get_operation_files()
    if #marker.marked_files > 0 then
        return marker.marked_files
    end

    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil or filename == "." or filename == ".." then
        vim.notify("Dired: Place the cursor on a file or mark one or more files.", vim.log.levels.ERROR)
        return
    end

    local dir_files = ls.fs_entry.get_directory(vim.g.current_dired_path)
    local file = ls.get_file_by_filename(dir_files, filename)
    if not file then
        vim.notify("Dired: Could not resolve the selected file.", vim.log.levels.ERROR)
        return
    end
    return { file }
end

local function refresh_after_async(buffer, path)
    return function()
        if vim.api.nvim_buf_is_valid(buffer)
            and vim.api.nvim_get_current_buf() == buffer
            and vim.bo[buffer].filetype == "dired"
        then
            display.render(path)
        end
    end
end

function M.compress_files()
    local files = get_operation_files()
    if not files then
        return
    end
    local buffer = vim.api.nvim_get_current_buf()
    local path = vim.g.current_dired_path
    funcs.compress_files(files, path, refresh_after_async(buffer, path))
end

function M.extract_files()
    local files = get_operation_files()
    if not files then
        return
    end
    local buffer = vim.api.nvim_get_current_buf()
    local path = vim.g.current_dired_path
    funcs.extract_files(files, path, refresh_after_async(buffer, path))
end

function M.chmod_files()
    local files = get_operation_files()
    if files and funcs.chmod_files(files) then
        display.render(vim.g.current_dired_path)
    end
end

function M.touch_files()
    local files = get_operation_files()
    if files and funcs.touch_files(files) then
        display.render(vim.g.current_dired_path)
    end
end

-- rename a file
function M.rename_file()
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    if filename == ".." or filename == "." then
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    funcs.rename_file(file)
    display.render(vim.g.current_dired_path)
end

-- create a file
function M.create_file()
    funcs.create_file()
    display.render(vim.g.current_dired_path)
end

-- delete a file
function M.delete_file()
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    for i, fs_t in ipairs(marker.marked_files) do
        if file == fs_t then
            table.remove(marker.marked_files, i)
        end
    end
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = ""
    funcs.delete_file(file, true)
    display.render(vim.g.current_dired_path)
end

-- delete selected files in current dired path
function M.delete_file_range()
    local dir = nil
    dir = vim.g.current_dired_path
    local lines = utils.get_visual_selection()
    vim.notify(string.format("%d files marked for deletion:", #lines))
    local files = {}
    for _, line in ipairs(lines) do
        local filename = display.get_filename_from_listing(line)
        if filename == nil then
            -- vim.api.nvim_err_writeln(
            --     "Dired: Invalid operation. Make sure the selected/marked are of type file/directory."
            -- )
            goto continue
        end
        table.insert(files, filename)
        print(string.format('   {%.2d: "%s"}', _, filename))
        ::continue::
    end
    local prompt = vim.fn.input("Confirm deletion {yes,n(o),q(uit)}: ", "")
    if prompt == "yes" then
        for _, filename in ipairs(files) do
            local dir_files = ls.fs_entry.get_directory(dir)
            local file = ls.get_file_by_filename(dir_files, filename)
            if not file then
                return
            end
            for i, fs_t in ipairs(marker.marked_files) do
                if file.filepath == fs_t.filepath then
                    table.remove(marker.marked_files, i)
                end
            end
            display.cursor_pos = vim.api.nvim_win_get_cursor(0)
            funcs.delete_file(file, false)
        end
        display.goto_filename = ""
        display.render(vim.g.current_dired_path)
        -- else
        --     vim.notify(" DiredDelete: Marked files not deleted", "error")
    end
end

-- mark single file
function M.mark_file()
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    if filename == "." or filename == ".." then
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = filename
    marker.mark_file(file)
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("\"%s\" marked.", file.filename))
end

-- mark range of files
function M.mark_file_range()
    local dir = nil
    dir = vim.g.current_dired_path
    local lines = utils.get_visual_selection()
    local files = {}
    for _, line in ipairs(lines) do
        local filename = display.get_filename_from_listing(line)
        if filename == nil then
            -- vim.api.nvim_err_writeln(
            --     "Dired: Invalid operation. Make sure the selected/marked are of type file/directory."
            -- )
            goto continue
        end
        if filename ~= "." and filename ~= ".." then
            table.insert(files, filename)
        end
        ::continue::
    end
    for _, filename in ipairs(files) do
        local dir_files = ls.fs_entry.get_directory(dir)
        local file = ls.get_file_by_filename(dir_files, filename)
        if file == nil then
            -- vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
            goto continue
        end
        display.cursor_pos = vim.api.nvim_win_get_cursor(0)
        -- print(filename, file)
        marker.mark_file(file)
        ::continue::
    end
    display.goto_filename = files[1]
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("%d files marked.", #files))
end

-- delete marked files and update marked list
function M.delete_marked()
    local marked_files = marker.marked_files
    if #marked_files == 0 then
        vim.notify("No files marked for deletion.")
        return
    end
    vim.notify(string.format("%d files marked for deletion:", #marked_files))
    local files_out_of_cwd = false
    for i, fs_t in ipairs(marked_files) do
        if fs_t.filename == nil then
            vim.api.nvim_err_writeln(
                "Dired: Invalid operation. Make sure the selected/marked are of type file/directory."
            )
            return
        end
        if fs.get_absolute_path(fs.get_parent_path(fs_t.filepath)) ~= fs.get_absolute_path(vim.g.current_dired_path)
        then
            files_out_of_cwd = true
            print(string.format('   {%.2d: "%s"} (file not in cwd)', i, fs_t.filename))
        else
            print(string.format('   {%.2d: "%s"}"', i, fs_t.filename))
        end
    end
    if files_out_of_cwd then
        print("[!] WARNING: You have files marked that are outside of your current working directory.")
    end
    local prompt = vim.fn.input("Confirm deletion {yes,n(o),q(uit)}: ", "")
    if prompt == "yes" then
        for _, fs_t in ipairs(marked_files) do
            display.cursor_pos = vim.api.nvim_win_get_cursor(0)
            display.goto_filename = ""
            funcs.delete_file(fs_t, false)
        end
        marker.marked_files = {}
    end
    display.goto_filename = ""
    display.render(vim.g.current_dired_path)
end

function M.clip_file(action)
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    if filename == "." or filename == ".." then
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = filename
    clipboard.add_file(file, action)
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("\"%s\" marked.", file.filename))
end

function M.clip_file_range(action)
    local dir = vim.g.current_dired_path
    local lines = utils.get_visual_selection()
    local files = {}
    for _, line in ipairs(lines) do
        local filename = display.get_filename_from_listing(line)
        if filename == nil then
        -- vim.api.nvim_err_writeln(
            --     "Dired: Invalid operation. Make sure the selected/marked are of type file/directory."
            -- )
            goto continue
        end
        if filename ~= "." and filename ~= ".." then
            table.insert(files, filename)
        end
        ::continue::
    end
    for _, filename in ipairs(files) do
        local dir_files = ls.fs_entry.get_directory(dir)
        local file = ls.get_file_by_filename(dir_files, filename)
        if file == nil then
            -- vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
            goto continue
        end
        -- print(filename, file)
        clipboard.add_file(file, action)
        ::continue::
    end
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = files[1]
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("%d files marked.", #files))
end

-- copy/move marked files and update marked list
function M.clip_marked(action)
    local files = marker.marked_files
    for _, file in ipairs(files) do
        clipboard.add_file(file, action)
    end
    marker.marked_files = {}
    display.goto_filename = files[1]
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("%d files marked.", #files))
end

function M.paste_file()
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    clipboard.do_action()
    display.render(vim.g.current_dired_path)
    -- vim.notify(string.format("\"%s\" marked.", file.filename))
end

-- duplicate a file
function M.duplicate_file()
    local dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    funcs.duplicate_file(file)
    display.render(vim.g.current_dired_path)
end

-- shell command on a file
function M.shell_cmd()
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure cursor is placed on a file/directory.")
        return
    end
    funcs.shell_cmd(file)
end

function M.shell_cmd_marked()
    local marked_files = marker.marked_files

    if not next(marked_files) then
        vim.notify("Dired: No files are currently marked.", "warn")
        return
    end

    funcs.shell_cmd_on_marked_files(marked_files)

    -- Clear the marked files list after the command is executed or cancelled
    marker.marked_files = {}
    --display.render(vim.g.current_dired_path)
end

function M.unmark_file()
    local dir = nil
    dir = vim.g.current_dired_path
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    if filename == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    local dir_files = ls.fs_entry.get_directory(dir)
    local file = ls.get_file_by_filename(dir_files, filename)
    if file == nil then
        vim.api.nvim_err_writeln("Dired: Invalid operation. Make sure the cursor is placed on a file/directory.")
        return
    end
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = filename
    clipboard.remove_file(file)
    marker.is_marked(file, true)
    display.render(vim.g.current_dired_path)
end

function M.unmark_file_range()
    local dir = nil
    dir = vim.g.current_dired_path
    local lines = utils.get_visual_selection()
    local files = {}
    for _, line in ipairs(lines) do
        local filename = display.get_filename_from_listing(line)
        if filename == nil then
            vim.api.nvim_err_writeln(
                "Dired: Invalid operation. Make sure the selected/marked are of type file/directory."
            )
            goto continue
        end
        if filename ~= "." and filename ~= ".." then
            table.insert(files, filename)
        end
        ::continue::
    end
    for _, filename in ipairs(files) do
        local dir_files = ls.fs_entry.get_directory(dir)
        local file = ls.get_file_by_filename(dir_files, filename)
        if file == nil then
            goto continue
        end
        display.cursor_pos = vim.api.nvim_win_get_cursor(0)
        clipboard.remove_file(file)
        marker.is_marked(file, true)
        ::continue::
    end
    display.goto_filename = files[1]
    display.render(vim.g.current_dired_path)
end

function M.unmark_all()
    local filename = display.get_filename_from_listing(vim.api.nvim_get_current_line())
    display.cursor_pos = vim.api.nvim_win_get_cursor(0)
    display.goto_filename = filename
    clipboard.clipboard = {}
    marker.marked_files = {}
    display.render(vim.g.current_dired_path)
end

return M
