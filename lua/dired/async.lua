-- Minimal coroutine-based async helper for libuv fs operations.
local M = {}

local unpack = unpack or table.unpack

-- Suspend the running coroutine until uv_fn's callback fires.
-- Must be called from inside M.run. Pass uv_fn's arguments WITHOUT the
-- trailing callback; returns whatever the callback receives (err, result, ...).
-- The resume is wrapped in vim.schedule so resumed code never runs in
-- fast-event context (vim.notify and the nvim API are safe after await).
function M.await(uv_fn, ...)
    local co = assert(coroutine.running(), "async.await must be called inside async.run")
    local args = { ... }
    -- pack callback results with explicit n: err is nil on success and would
    -- otherwise truncate unpack
    args[select("#", ...) + 1] = function(...)
        local cb_args = { n = select("#", ...), ... }
        vim.schedule(function()
            coroutine.resume(co, unpack(cb_args, 1, cb_args.n))
        end)
    end
    uv_fn(unpack(args))
    return coroutine.yield()
end

-- Run fn() on a fresh coroutine; call on_done(fn's return values) when it
-- finishes. Errors raised by fn (at any resume point) are caught and turned
-- into on_done(false, errmsg) -- on_done is ALWAYS invoked exactly once.
function M.run(fn, on_done)
    local co = coroutine.create(function()
        -- LuaJIT allows yield across pcall, so this catches errors raised
        -- after any await as well
        local ok, success, errmsg = pcall(fn)
        if on_done then
            if ok then
                on_done(success, errmsg)
            else
                vim.notify("Dired: " .. tostring(success), vim.log.levels.ERROR)
                on_done(false, tostring(success))
            end
        end
    end)
    coroutine.resume(co)
end

return M
