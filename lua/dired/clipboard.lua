local fs = require("dired.fs")
local ls = require("dired.ls")

local M = {}

M.clipboard = {}

function M.get_action(fs_t)
    for i, e in ipairs(M.clipboard) do
        if e.fs_t.filepath == fs_t.filepath then
            return e.action
        end
    end
    return nil
end

-- action can be copy or paste
function M.add_file(fs_t, action)
    local idx = nil
    for i, e in ipairs(M.clipboard) do
        if e.fs_t.filepath == fs_t.filepath then
            idx = i
        end
    end
    if idx ~= nil then
        M.clipboard[idx].action = action
        return
    end
    local entry = {}
    entry.fs_t = fs_t
    entry.action = action
    table.insert(M.clipboard, entry)
end

function M.remove_file(fs_t)
    for i, e in ipairs(M.clipboard) do
        if e.fs_t.filepath == fs_t.filepath then
            table.remove(M.clipboard, i)
        end
    end
end

-- copy files to current directory; callback(all_ok) fires once every copy
-- finished (failures do not abort the batch)
function M.copy_files(files, callback)
    callback = callback or function() end
    -- should we check if user is trying to copy paste in the same directory?
    -- idk yet.
    local curren_files = ls.fs_entry.get_directory(vim.g.current_dired_path)
    local copy_files = {}

    for _, fs_t in ipairs(files) do
        -- sanity check
        if fs_t.filename == nil then
            vim.api.nvim_err_writeln(
                "Dired: Invalid operation make sure the selected/marked are of type file/directory."
            )
            callback(false)
            return
        end

        -- check #1
        if
            fs.get_simplified_path(fs.get_parent_path(fs_t.filepath)) ~= fs.get_simplified_path(vim.g.current_dired_path)
        then
            -- check #2
            local already_in_cwd = false
            for _, ds_t in ipairs(curren_files) do
                if fs_t.filename == ds_t.filename then
                    local prompt =
                        vim.fn.input(string.format('Overwrite "%s"? {yes,n(o),q(uit)}: ', fs_t.filename), "no")
                    prompt = string.lower(prompt)
                    already_in_cwd = true
                    if string.sub(prompt, 1, 3) == "yes" then
                        table.insert(copy_files, fs_t)
                    end
                    break
                end
            end
            if not already_in_cwd then
                table.insert(copy_files, fs_t)
            end
        end
    end
    local index, all_ok = 1, true
    local function copy_next()
        local fs_t = copy_files[index]
        if not fs_t then
            callback(all_ok)
            return
        end
        fs.do_copy(fs_t.filepath, fs.join_paths(vim.g.current_dired_path, fs_t.filename), function(success)
            all_ok = all_ok and success
            index = index + 1
            copy_next()
        end)
    end
    copy_next()
end

-- move files to current directory; callback(all_ok) fires once every move
-- finished (failures do not abort the batch)
function M.move_files(files, callback)
    callback = callback or function() end
    -- should we check if user is trying to move paste in the same directory?
    -- idk yet.
    local curren_files = ls.fs_entry.get_directory(vim.g.current_dired_path)
    local move_files = {}

    for _, fs_t in ipairs(files) do
        -- sanity check
        if fs_t.filename == nil then
            vim.api.nvim_err_writeln(
                "Dired: Invalid operation make sure the selected/marked are of type file/directory."
            )
            callback(false)
            return
        end

        -- check #1
        if
            fs.get_simplified_path(fs.get_parent_path(fs_t.filepath)) ~= fs.get_simplified_path(vim.g.current_dired_path)
        then
            -- check #2
            local already_in_cwd = false
            for _, ds_t in ipairs(curren_files) do
                if fs_t.filename == ds_t.filename then
                    local prompt =
                        vim.fn.input(string.format('Overwrite "%s"? {yes,n(o),q(uit)}: ', fs_t.filename), "no")
                    prompt = string.lower(prompt)
                    already_in_cwd = true
                    if string.sub(prompt, 1, 3) == "yes" then
                        table.insert(move_files, fs_t)
                    end
                    break
                end
            end
            if not already_in_cwd then
                table.insert(move_files, fs_t)
            end
        end
    end
    local uv = vim.uv or vim.loop
    local index, all_ok = 1, true
    local function move_next()
        local fs_t = move_files[index]
        if not fs_t then
            callback(all_ok)
            return
        end
        uv.fs_rename(fs_t.filepath, fs.join_paths(vim.g.current_dired_path, fs_t.filename), function(err)
            vim.schedule(function()
                all_ok = all_ok and err == nil
                index = index + 1
                move_next()
            end)
        end)
    end
    move_next()
end

-- process the clipboard; callback(all_ok) fires once after both the copy and
-- move batches complete
function M.do_action(callback)
    callback = callback or function() end
    local copyf = {}
    local movef = {}
    for i, file in ipairs(M.clipboard) do
        if file.action == "copy" then
            table.insert(copyf, file.fs_t)
        elseif file.action == "move" then
            table.insert(movef, file.fs_t)
        end
    end
    M.clipboard = {}

    local function after_copy(copy_ok)
        if #movef > 0 then
            M.move_files(movef, function(move_ok)
                callback(copy_ok and move_ok)
            end)
        else
            callback(copy_ok)
        end
    end

    if #copyf > 0 then
        M.copy_files(copyf, after_copy)
    else
        after_copy(true)
    end
end

return M
