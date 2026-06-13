-- Installs the native core (lua/dired_core.so|dll). Used as the lazy.nvim
-- `build` step: tries the prebuilt binary for this platform from the GitHub
-- release, and compiles with cargo if that fails.
local M = {}

local REPO = "moamenhredeen/dired.nvim"
-- Tag of the release whose binaries match this source. Bump on every release.
local VERSION = "v0.1.0"

-- (asset name on the release, local filename on cpath) for this platform.
local function target()
    local uname = vim.uv.os_uname()
    local machine = uname.machine:lower()
    local arch
    if machine == "x86_64" or machine == "amd64" then
        arch = "x86_64"
    elseif machine == "aarch64" or machine == "arm64" then
        arch = "aarch64"
    else
        return nil, nil, "unsupported architecture: " .. uname.machine
    end

    local sys = uname.sysname
    if sys == "Linux" then
        return ("dired_core-%s-unknown-linux-gnu.so"):format(arch), "dired_core.so"
    elseif sys == "Darwin" then
        return ("dired_core-%s-apple-darwin.so"):format(arch), "dired_core.so"
    elseif sys:find("Windows") then
        if arch ~= "x86_64" then
            return nil, nil, "unsupported Windows architecture: " .. uname.machine
        end
        return "dired_core-x86_64-pc-windows-msvc.dll", "dired_core.dll"
    end
    return nil, nil, "unsupported OS: " .. sys
end

local function plugin_root()
    -- this file is <root>/lua/dired/install.lua
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
end

local function download(asset, dest)
    local url = ("https://github.com/%s/releases/download/%s/%s"):format(REPO, VERSION, asset)
    if vim.fn.executable("curl") == 0 then
        return false, "curl not found"
    end
    local res = vim.system({ "curl", "-fsSL", "-o", dest, url }):wait()
    return res.code == 0, res.stderr
end

local function cargo_build(root, localname)
    if vim.fn.executable("cargo") == 0 then
        return false, "cargo not found (install a Rust toolchain from https://rustup.rs)"
    end
    local res = vim.system({
        "cargo",
        "build",
        "--release",
        "--manifest-path",
        root .. "/rust/Cargo.toml",
        "-p",
        "dired-core",
    }):wait()
    if res.code ~= 0 then
        return false, res.stderr
    end
    local release_dir = root .. "/rust/target/release/"
    for _, name in ipairs({ "libdired_core.so", "libdired_core.dylib", "dired_core.dll" }) do
        if vim.uv.fs_stat(release_dir .. name) then
            local ok, err = vim.uv.fs_copyfile(release_dir .. name, root .. "/lua/" .. localname)
            return ok == true, err
        end
    end
    return false, "build succeeded but no artifact found in " .. release_dir
end

-- Install the native core into <root>/lua/. `root` defaults to this plugin's
-- directory; lazy.nvim passes the plugin spec, so prefer plugin.dir there.
function M.install(root)
    root = root or plugin_root()
    local asset, localname, err = target()
    if not asset then
        error("dired.nvim: " .. err)
    end
    local dest = root .. "/lua/" .. localname

    local ok, derr = download(asset, dest)
    if ok then
        print("dired.nvim: installed prebuilt core (" .. asset .. ")")
        return
    end
    print("dired.nvim: prebuilt download failed (" .. tostring(derr) .. "), building with cargo")

    local built, berr = cargo_build(root, localname)
    if not built then
        error("dired.nvim: could not install native core: " .. tostring(berr))
    end
    print("dired.nvim: built native core with cargo")
end

return M
