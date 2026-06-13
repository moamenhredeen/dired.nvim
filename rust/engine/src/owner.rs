//! uid/gid -> name lookups. Replaces the `id -nu` / `dscl` / `/etc/group`
//! shell-outs in lua/dired/utils.lua.

#[cfg(unix)]
pub fn user_name(uid: u32) -> Option<String> {
    uzers::get_user_by_uid(uid).map(|u| u.name().to_string_lossy().into_owned())
}

#[cfg(unix)]
pub fn group_name(gid: u32) -> Option<String> {
    uzers::get_group_by_gid(gid).map(|g| g.name().to_string_lossy().into_owned())
}

// Windows has no uid/gid; mirror the current Lua behavior (USERNAME env var,
// no group concept).
#[cfg(windows)]
pub fn user_name(_uid: u32) -> Option<String> {
    std::env::var("USERNAME").ok()
}

#[cfg(windows)]
pub fn group_name(_gid: u32) -> Option<String> {
    None
}

#[cfg(test)]
mod tests {
    #[test]
    #[cfg(unix)]
    fn resolves_root() {
        assert_eq!(super::user_name(0).as_deref(), Some("root"));
        assert!(super::group_name(0).is_some());
    }
}
