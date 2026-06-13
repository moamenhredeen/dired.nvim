//! Sidecar CLI for dired.nvim. Invoked by the plugin via `vim.system`.
//! Handles only what Neovim can't do natively: bundled archive create/extract.
//!
//! Subcommands:
//!   archive-create <archive> <cwd> <file>...   create archive of files under cwd
//!   archive-extract <archive> <dest>           extract archive into dest
//!
//! On failure: prints a message to stderr and exits non-zero.

use std::process::ExitCode;

use dired_core::archive;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("archive-create") => archive_create(&args[1..]),
        Some("archive-extract") => archive_extract(&args[1..]),
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
