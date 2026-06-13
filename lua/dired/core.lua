-- Rust core (lua/dired_core.so, built by `make core`). Required: archive
-- operations and owner lookups are implemented in Rust.
local ok, lib = pcall(require, "dired_core")
if not ok then
    error(
        "dired.nvim: native core not found. Install it with "
            .. "`:lua require('dired.install').install()` or `make core`.\n"
            .. tostring(lib)
    )
end
return lib
