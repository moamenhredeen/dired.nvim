-- Installs the native sidecar binary (bin/dired-core[.exe]). Used as the
-- lazy.nvim `build` step: downloads the prebuilt binary for this platform from
-- the GitHub release, and compiles with cargo if that fails.
local M = {}

local REPO = "moamenhredeen/dired.nvim"
-- Release to download binaries from. "nightly" is a rolling prerelease rebuilt
-- on every push to main, so a `branch = "main"` install always gets a current
-- binary. Point at a "vX.Y.Z" tag instead to pin to a stable release.
local RELEASE = "nightly"

-- (asset name on the release, local filename) for this platform.
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
        return ("dired-core-%s-unknown-linux-gnu"):format(arch), "dired-core"
    elseif sys == "Darwin" then
        return ("dired-core-%s-apple-darwin"):format(arch), "dired-core"
    elseif sys:find("Windows") then
        if arch ~= "x86_64" then
            return nil, nil, "unsupported Windows architecture: " .. uname.machine
        end
        return "dired-core-x86_64-pc-windows-msvc.exe", "dired-core.exe"
    end
    return nil, nil, "unsupported OS: " .. sys
end

local function plugin_root()
    -- this file is <root>/lua/dired/install.lua
    return vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
end

local function download(asset, dest)
    local url = ("https://github.com/%s/releases/download/%s/%s"):format(REPO, RELEASE, asset)
    if vim.fn.executable("curl") == 0 then
        return false, "curl not found"
    end
    local res = vim.system({ "curl", "-fsSL", "-o", dest, url }):wait()
    if res.code ~= 0 then
        return false, res.stderr
    end
    vim.uv.fs_chmod(dest, 493) -- 0755
    return true
end

local function cargo_build(root, localname)
    if vim.fn.executable("cargo") == 0 then
        return false, "cargo not found (install a Rust toolchain from https://rustup.rs)"
    end
    local res = vim.system({ "cargo", "build", "--release" }, { cwd = root .. "/rust" }):wait()
    if res.code ~= 0 then
        return false, res.stderr
    end
    local produced = root .. "/rust/target/release/" .. localname
    if not vim.uv.fs_stat(produced) then
        return false, "build succeeded but binary not found at " .. produced
    end
    local ok, err = vim.uv.fs_copyfile(produced, root .. "/bin/" .. localname)
    return ok == true, err
end

-- Install the native core into <root>/bin/. `root` defaults to this plugin's
-- directory; lazy.nvim passes the plugin spec, so prefer plugin.dir there.
function M.install(root)
    root = root or plugin_root()
    local asset, localname, err = target()
    if not asset then
        error("dired.nvim: " .. err)
    end
    vim.fn.mkdir(root .. "/bin", "p")
    local dest = root .. "/bin/" .. localname

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
