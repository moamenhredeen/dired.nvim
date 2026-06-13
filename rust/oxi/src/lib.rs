//! Entry point for the `dired_core` cdylib loaded by nvim via
//! `require("dired_core")` (see lua/dired/core.lua).
//!
//! Callbacks follow the libuv convention used by lua/dired/async.lua:
//! `cb(nil)` on success, `cb(message)` on failure.

use std::sync::mpsc;
use std::thread;

use nvim_oxi::libuv::AsyncHandle;
use nvim_oxi::{schedule, Dictionary, Function, Object};

/// Run `work` on a background thread, then invoke `on_done(err)` on the main
/// thread. The AsyncHandle is intentionally leaked (one uv handle per
/// operation; archive operations are rare enough not to matter).
fn run_async(
    on_done: Function<(Option<String>,), ()>,
    work: impl FnOnce() -> Result<(), String> + Send + 'static,
) -> nvim_oxi::Result<()> {
    let (tx, rx) = mpsc::channel::<Result<(), String>>();
    let handle = AsyncHandle::new(move || {
        let result = rx.recv().unwrap_or_else(|e| Err(e.to_string()));
        let on_done = on_done.clone();
        schedule(move |_| {
            let _ = on_done.call((result.err(),));
        });
    })?;
    thread::spawn(move || {
        let result = work();
        let _ = tx.send(result);
        let _ = handle.send();
    });
    Ok(())
}

fn user_name((uid,): (u32,)) -> Option<String> {
    dired_engine::owner::user_name(uid)
}

fn group_name((gid,): (u32,)) -> Option<String> {
    dired_engine::owner::group_name(gid)
}

fn archive_create(
    (archive, files, cwd, on_done): (
        String,
        Vec<String>,
        String,
        Function<(Option<String>,), ()>,
    ),
) -> nvim_oxi::Result<()> {
    run_async(on_done, move || {
        dired_engine::archive::create(&archive, &files, &cwd)
    })
}

fn archive_extract(
    (archive, dest, on_done): (String, String, Function<(Option<String>,), ()>),
) -> nvim_oxi::Result<()> {
    run_async(on_done, move || {
        dired_engine::archive::extract(&archive, &dest)
    })
}

#[nvim_oxi::plugin]
fn dired_core() -> Dictionary {
    Dictionary::from_iter([
        (
            "user_name",
            Object::from(Function::<_, Option<String>>::from_fn(user_name)),
        ),
        (
            "group_name",
            Object::from(Function::<_, Option<String>>::from_fn(group_name)),
        ),
        (
            "archive_create",
            Object::from(Function::<_, ()>::from_fn(archive_create)),
        ),
        (
            "archive_extract",
            Object::from(Function::<_, ()>::from_fn(archive_extract)),
        ),
    ])
}
