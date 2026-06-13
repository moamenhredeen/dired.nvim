//! Archive creation/extraction. Replaces the tar/bsdtar/zip/unzip detection
//! dance in lua/dired/functions.lua with bundled implementations.
//!
//! Semantics parity with the system-tool fallback:
//! - create: entry paths relative to `cwd` (like running the tool with cwd set)
//! - tar extract: overwrites existing files (`tar -xf`)
//! - zip extract: skips existing files (`unzip -n`)

use std::fs::File;
use std::io::{self, Read, Write};
use std::path::Path;

#[derive(Clone, Copy, PartialEq, Debug)]
enum Format {
    Zip,
    Tar,
    TarGz,
    TarBz2,
    TarXz,
}

// Longer extensions first so `.tar.gz` wins over `.gz`-style suffix checks.
const EXTENSIONS: &[(&str, Format)] = &[
    (".tar.bz2", Format::TarBz2),
    (".tar.gz", Format::TarGz),
    (".tar.xz", Format::TarXz),
    (".tbz2", Format::TarBz2),
    (".tgz", Format::TarGz),
    (".txz", Format::TarXz),
    (".tar", Format::Tar),
    (".zip", Format::Zip),
];

fn detect_format(path: &str) -> Option<Format> {
    let lower = path.to_lowercase();
    EXTENSIONS
        .iter()
        .find(|(ext, _)| lower.ends_with(ext))
        .map(|(_, format)| *format)
}

fn io_err(path: &Path, err: impl std::fmt::Display) -> String {
    format!("{}: {}", path.display(), err)
}

/// Create `archive` containing `files` (paths relative to `cwd`).
pub fn create(archive: &str, files: &[String], cwd: &str) -> Result<(), String> {
    let format = detect_format(archive)
        .ok_or_else(|| format!("unsupported archive extension: {}", archive))?;
    let archive_path = Path::new(archive);
    let out = File::create(archive_path).map_err(|e| io_err(archive_path, e))?;
    let cwd = Path::new(cwd);

    match format {
        Format::Zip => zip_create(out, files, cwd),
        Format::Tar => tar_create(out, files, cwd).map(|_| ()),
        Format::TarGz => {
            let encoder = flate2::write::GzEncoder::new(out, flate2::Compression::default());
            let encoder = tar_create(encoder, files, cwd)?;
            encoder.finish().map(|_| ()).map_err(|e| e.to_string())
        }
        Format::TarBz2 => {
            let encoder = bzip2::write::BzEncoder::new(out, bzip2::Compression::default());
            let encoder = tar_create(encoder, files, cwd)?;
            encoder.finish().map(|_| ()).map_err(|e| e.to_string())
        }
        Format::TarXz => {
            let encoder = xz2::write::XzEncoder::new(out, 6);
            let encoder = tar_create(encoder, files, cwd)?;
            encoder.finish().map(|_| ()).map_err(|e| e.to_string())
        }
    }
}

/// Extract `archive` into `dest` (created if missing).
pub fn extract(archive: &str, dest: &str) -> Result<(), String> {
    let format = detect_format(archive)
        .ok_or_else(|| format!("unsupported archive extension: {}", archive))?;
    let archive_path = Path::new(archive);
    let file = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    let dest = Path::new(dest);
    std::fs::create_dir_all(dest).map_err(|e| io_err(dest, e))?;

    if format == Format::Zip {
        return zip_extract(file, dest);
    }

    let reader: Box<dyn Read> = match format {
        Format::Tar => Box::new(file),
        Format::TarGz => Box::new(flate2::read::GzDecoder::new(file)),
        Format::TarBz2 => Box::new(bzip2::read::BzDecoder::new(file)),
        Format::TarXz => Box::new(xz2::read::XzDecoder::new(file)),
        Format::Zip => unreachable!(),
    };
    let mut tar = tar::Archive::new(reader);
    tar.set_preserve_permissions(true);
    // unpack guards against path traversal and overwrites like `tar -xf`
    tar.unpack(dest).map_err(|e| e.to_string())
}

fn tar_create<W: Write>(writer: W, files: &[String], cwd: &Path) -> Result<W, String> {
    let mut builder = tar::Builder::new(writer);
    builder.follow_symlinks(false);
    for name in files {
        let path = cwd.join(name);
        let meta = std::fs::symlink_metadata(&path).map_err(|e| io_err(&path, e))?;
        if meta.is_dir() {
            builder.append_dir_all(name, &path).map_err(|e| io_err(&path, e))?;
        } else {
            builder
                .append_path_with_name(&path, name)
                .map_err(|e| io_err(&path, e))?;
        }
    }
    builder.into_inner().map_err(|e| e.to_string())
}

fn zip_create(out: File, files: &[String], cwd: &Path) -> Result<(), String> {
    let mut zip = zip::ZipWriter::new(out);
    for name in files {
        zip_add(&mut zip, cwd, name)?;
    }
    zip.finish().map(|_| ()).map_err(|e| e.to_string())
}

fn zip_add(zip: &mut zip::ZipWriter<File>, cwd: &Path, rel: &str) -> Result<(), String> {
    let path = cwd.join(rel);
    let meta = std::fs::symlink_metadata(&path).map_err(|e| io_err(&path, e))?;

    #[allow(unused_mut)] // mutated only on unix to carry permission bits
    let mut options = zip::write::SimpleFileOptions::default();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        options = options.unix_permissions(meta.permissions().mode() & 0o7777);
    }
    // zip spec mandates forward slashes
    let entry_name = rel.replace('\\', "/");

    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(&path).map_err(|e| io_err(&path, e))?;
        zip.add_symlink(entry_name, target.to_string_lossy(), options)
            .map_err(|e| io_err(&path, e))?;
    } else if meta.is_dir() {
        zip.add_directory(entry_name, options)
            .map_err(|e| io_err(&path, e))?;
        let entries = std::fs::read_dir(&path).map_err(|e| io_err(&path, e))?;
        for entry in entries {
            let entry = entry.map_err(|e| io_err(&path, e))?;
            let child = format!("{}/{}", rel, entry.file_name().to_string_lossy());
            zip_add(zip, cwd, &child)?;
        }
    } else {
        zip.start_file(entry_name, options)
            .map_err(|e| io_err(&path, e))?;
        let mut file = File::open(&path).map_err(|e| io_err(&path, e))?;
        io::copy(&mut file, zip).map_err(|e| io_err(&path, e))?;
    }
    Ok(())
}

fn zip_extract(file: File, dest: &Path) -> Result<(), String> {
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| e.to_string())?;
        // None = unsafe path (zip-slip); skip such entries entirely
        let Some(rel) = entry.enclosed_name() else {
            continue;
        };
        let out = dest.join(rel);

        if entry.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| io_err(&out, e))?;
            continue;
        }
        // `unzip -n` parity: never overwrite existing files
        if out.symlink_metadata().is_ok() {
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
        }

        #[cfg(unix)]
        let mode = entry.unix_mode();
        #[cfg(unix)]
        if mode.is_some_and(|m| m & 0o170000 == 0o120000) {
            let mut target = String::new();
            entry
                .read_to_string(&mut target)
                .map_err(|e| io_err(&out, e))?;
            std::os::unix::fs::symlink(&target, &out).map_err(|e| io_err(&out, e))?;
            continue;
        }

        let mut writer = File::create(&out).map_err(|e| io_err(&out, e))?;
        io::copy(&mut entry, &mut writer).map_err(|e| io_err(&out, e))?;
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode & 0o7777));
        }
    }
    Ok(())
}
