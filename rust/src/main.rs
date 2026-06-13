//! Sidecar CLI for dired.nvim. Invoked by the plugin via `vim.system`.
//! Handles only what Neovim can't do natively: bundled archive create/extract.
//!
//! Subcommands:
//!   archive-create <archive> <cwd> <file>...   create archive of files under cwd
//!   archive-extract <archive> <dest>           extract archive into dest
//!
//! It also acts as a drop-in `unzip`/`zip` shim for Vim's built-in zip.vim
//! plugin (point g:zip_unzipcmd / g:zip_zipcmd / g:zip_extractcmd at this
//! binary), so browsing into a .zip works on Windows without system unzip/zip.
//! zip#Browse runs `executable(g:zip_unzipcmd)` on the *whole* string, so the
//! vars must be the bare binary with no subcommand word; instead we dispatch on
//! the leading flag, which is unambiguous (unzip and zip flags don't overlap):
//!   <bin> -Z1 -- <zip>          list entry names (Browse)
//!   <bin> -p  -- <zip> <name>   stream one entry to stdout (Read)
//!   <bin> -o     <zip> <name>   extract one entry into cwd (Extract)
//!   <bin> -d     <zip> <name>   delete one entry (Write)
//!   <bin> -u     <zip> <name>   add/replace one entry from cwd (Write)
//!
//! On failure: prints a message to stderr and exits non-zero.

use std::io::{self, Write};
use std::path::Path;
use std::process::ExitCode;

use dired_core::archive;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("archive-create") => archive_create(&args[1..]),
        Some("archive-extract") => archive_extract(&args[1..]),
        // zip.vim invokes us as bare unzip/zip; those calls lead with a flag
        Some(first) if first.starts_with('-') => zip_shim(&args),
        Some(other) => Err(format!("unknown subcommand: {}", other)),
        None => Err("missing subcommand".to_string()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("{}", msg);
            ExitCode::FAILURE
        }
    }
}

fn archive_create(args: &[String]) -> Result<(), String> {
    let (archive, cwd, files) = match args {
        [archive, cwd, files @ ..] => (archive, cwd, files),
        _ => return Err("usage: archive-create <archive> <cwd> <file>...".to_string()),
    };
    archive::create(archive, files, cwd)
}

fn archive_extract(args: &[String]) -> Result<(), String> {
    match args {
        [archive, dest] => archive::extract(archive, dest),
        _ => Err("usage: archive-extract <archive> <dest>".to_string()),
    }
}

/// Split zip.vim's argv into the operation flag and its positional operands,
/// ignoring the `--` end-of-options marker and any flags we don't model.
fn split_flag(args: &[String]) -> (Option<&str>, Vec<&str>) {
    let mut flag = None;
    let mut positional = Vec::new();
    for arg in args {
        match arg.as_str() {
            "--" => {}
            "-Z1" | "-p" | "-o" | "-d" | "-u" if flag.is_none() => flag = Some(arg.as_str()),
            other if other.starts_with('-') => {}
            other => positional.push(other),
        }
    }
    (flag, positional)
}

fn zip_shim(args: &[String]) -> Result<(), String> {
    let (flag, pos) = split_flag(args);
    match (flag, pos.as_slice()) {
        (Some("-Z1"), [archive]) => {
            let names = archive::zip_list(archive)?;
            let stdout = io::stdout();
            let mut out = stdout.lock();
            for name in names {
                writeln!(out, "{}", name).map_err(|e| e.to_string())?;
            }
            Ok(())
        }
        (Some("-p"), [archive, name]) => {
            let stdout = io::stdout();
            let mut out = stdout.lock();
            archive::zip_read(archive, name, &mut out)
        }
        (Some("-o"), [archive, name]) => archive::zip_extract_entry(archive, name, Path::new(".")),
        (Some("-d"), [archive, name]) => archive::zip_delete(archive, name),
        (Some("-u"), [archive, name]) => archive::zip_update(archive, name, Path::new(".")),
        _ => Err("usage: -Z1 <zip> | -p|-o|-d|-u <zip> <name>".to_string()),
    }
}
