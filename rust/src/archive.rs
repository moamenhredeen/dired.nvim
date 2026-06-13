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

    let mut tar = tar::Archive::new(tar_reader(file, format));
    tar.set_preserve_permissions(true);
    // unpack guards against path traversal and overwrites like `tar -xf`
    tar.unpack(dest).map_err(|e| e.to_string())
}

/// Wrap `file` in the right decompressor for `format` so the result yields raw
/// tar bytes. `format` must be a tar variant (Zip has no tar stream).
fn tar_reader(file: File, format: Format) -> Box<dyn Read> {
    match format {
        Format::Tar => Box::new(file),
        Format::TarGz => Box::new(flate2::read::GzDecoder::new(file)),
        Format::TarBz2 => Box::new(bzip2::read::BzDecoder::new(file)),
        Format::TarXz => Box::new(xz2::read::XzDecoder::new(file)),
        Format::Zip => unreachable!("tar_reader called with zip format"),
    }
}

/// Open `archive` as a tar stream, rejecting zip and unknown extensions.
fn open_tar(archive: &str) -> Result<(tar::Archive<Box<dyn Read>>, Format), String> {
    let format = detect_format(archive)
        .ok_or_else(|| format!("unsupported archive extension: {}", archive))?;
    if format == Format::Zip {
        return Err(format!("not a tar archive: {}", archive));
    }
    let archive_path = Path::new(archive);
    let file = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    Ok((tar::Archive::new(tar_reader(file, format)), format))
}

fn entry_display_name(entry: &tar::Entry<'_, Box<dyn Read>>) -> Result<String, String> {
    let path = entry.path().map_err(|e| e.to_string())?;
    let mut name = path.to_string_lossy().replace('\\', "/");
    // mark directories with a trailing slash so the browser can tell them apart
    if entry.header().entry_type().is_dir() && !name.ends_with('/') {
        name.push('/');
    }
    Ok(name)
}

/// List entry names of a tar archive, one per line. Directory entries keep a
/// trailing `/`. Handles plain `.tar` and gz/bz2/xz variants transparently.
pub fn tar_list(archive: &str) -> Result<Vec<String>, String> {
    let (mut tar, _) = open_tar(archive)?;
    let mut names = Vec::new();
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        names.push(entry_display_name(&entry)?);
    }
    Ok(names)
}

/// Stream one entry's bytes to `out`.
pub fn tar_read<W: Write>(archive: &str, member: &str, out: &mut W) -> Result<(), String> {
    let (mut tar, _) = open_tar(archive)?;
    for entry in tar.entries().map_err(|e| e.to_string())? {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let name = entry.path().map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
        if name == member {
            io::copy(&mut entry, out).map_err(|e| e.to_string())?;
            return Ok(());
        }
    }
    Err(format!("entry not found in archive: {}", member))
}

/// Remove `member` from the archive in place, rebuilding the tar stream.
pub fn tar_delete(archive: &str, member: &str) -> Result<(), String> {
    tar_rewrite(archive, member, None)
}

/// Add or replace `member` in the archive, reading the new content from `src`.
pub fn tar_update(archive: &str, member: &str, src: &str) -> Result<(), String> {
    tar_rewrite(archive, member, Some(src))
}

/// Rebuild `archive` copying every entry except `member`, then (if `src` is set)
/// append a fresh `member` from `src`. Recompresses to match the original format
/// and atomically replaces it.
fn tar_rewrite(archive: &str, member: &str, src: Option<&str>) -> Result<(), String> {
    let (mut reader, format) = open_tar(archive)?;
    let archive_path = Path::new(archive);
    let tmp_path = archive_path.with_extension("dired-tar-tmp");
    let out = File::create(&tmp_path).map_err(|e| io_err(&tmp_path, e))?;

    let result = (|| -> Result<(), String> {
        let mut builder = tar::Builder::new(tar_writer(out, format));
        builder.follow_symlinks(false);
        for entry in reader.entries().map_err(|e| e.to_string())? {
            let mut entry = entry.map_err(|e| e.to_string())?;
            let name = entry.path().map_err(|e| e.to_string())?.to_string_lossy().replace('\\', "/");
            if name == member {
                continue;
            }
            let header = entry.header().clone();
            builder
                .append(&header, &mut entry)
                .map_err(|e| e.to_string())?;
        }
        if let Some(src) = src {
            let src_path = Path::new(src);
            let mut file = File::open(src_path).map_err(|e| io_err(src_path, e))?;
            builder
                .append_file(member, &mut file)
                .map_err(|e| io_err(src_path, e))?;
        }
        // into_inner flushes the tar; finish_encoder completes any compressor
        let encoder = builder.into_inner().map_err(|e| e.to_string())?;
        finish_encoder(encoder)
    })();

    if result.is_err() {
        let _ = std::fs::remove_file(&tmp_path);
        return result;
    }
    std::fs::rename(&tmp_path, archive_path).map_err(|e| io_err(archive_path, e))
}

/// A tar output sink that recompresses to match `format` on `finish_encoder`.
enum TarWriter {
    Plain(File),
    Gz(flate2::write::GzEncoder<File>),
    Bz2(bzip2::write::BzEncoder<File>),
    Xz(xz2::write::XzEncoder<File>),
}

impl Write for TarWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            TarWriter::Plain(w) => w.write(buf),
            TarWriter::Gz(w) => w.write(buf),
            TarWriter::Bz2(w) => w.write(buf),
            TarWriter::Xz(w) => w.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            TarWriter::Plain(w) => w.flush(),
            TarWriter::Gz(w) => w.flush(),
            TarWriter::Bz2(w) => w.flush(),
            TarWriter::Xz(w) => w.flush(),
        }
    }
}

fn tar_writer(out: File, format: Format) -> TarWriter {
    match format {
        Format::Tar => TarWriter::Plain(out),
        Format::TarGz => {
            TarWriter::Gz(flate2::write::GzEncoder::new(out, flate2::Compression::default()))
        }
        Format::TarBz2 => TarWriter::Bz2(bzip2::write::BzEncoder::new(out, bzip2::Compression::default())),
        Format::TarXz => TarWriter::Xz(xz2::write::XzEncoder::new(out, 6)),
        Format::Zip => unreachable!("tar_writer called with zip format"),
    }
}

fn finish_encoder(writer: TarWriter) -> Result<(), String> {
    match writer {
        TarWriter::Plain(_) => Ok(()),
        TarWriter::Gz(w) => w.finish().map(|_| ()).map_err(|e| e.to_string()),
        TarWriter::Bz2(w) => w.finish().map(|_| ()).map_err(|e| e.to_string()),
        TarWriter::Xz(w) => w.finish().map(|_| ()).map_err(|e| e.to_string()),
    }
}

/// List entry names of a zip archive, one per line (unzip -Z1 parity).
/// Directory entries keep their trailing `/` so callers can tell them apart.
pub fn zip_list(archive: &str) -> Result<Vec<String>, String> {
    let archive_path = Path::new(archive);
    let file = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let mut names = Vec::with_capacity(zip.len());
    for i in 0..zip.len() {
        let entry = zip.by_index(i).map_err(|e| e.to_string())?;
        names.push(entry.name().to_string());
    }
    Ok(names)
}

/// Stream one entry's bytes to `out` (unzip -p parity).
pub fn zip_read<W: Write>(archive: &str, name: &str, out: &mut W) -> Result<(), String> {
    let archive_path = Path::new(archive);
    let file = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let mut entry = zip
        .by_name(name)
        .map_err(|_| format!("entry not found in archive: {}", name))?;
    io::copy(&mut entry, out).map_err(|e| e.to_string())?;
    Ok(())
}

/// Extract one entry to `dest_dir`, preserving its in-archive path and
/// overwriting any existing file (unzip -o parity).
pub fn zip_extract_entry(archive: &str, name: &str, dest_dir: &Path) -> Result<(), String> {
    let archive_path = Path::new(archive);
    let file = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| e.to_string())?;
    let mut entry = zip
        .by_name(name)
        .map_err(|_| format!("entry not found in archive: {}", name))?;
    // None = unsafe path (zip-slip); refuse rather than escape dest_dir
    let rel = entry
        .enclosed_name()
        .ok_or_else(|| format!("unsafe entry path: {}", name))?;
    let out = dest_dir.join(rel);
    if entry.is_dir() {
        std::fs::create_dir_all(&out).map_err(|e| io_err(&out, e))?;
        return Ok(());
    }
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent).map_err(|e| io_err(parent, e))?;
    }
    let mut writer = File::create(&out).map_err(|e| io_err(&out, e))?;
    io::copy(&mut entry, &mut writer).map_err(|e| io_err(&out, e))?;
    #[cfg(unix)]
    if let Some(mode) = entry.unix_mode() {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode & 0o7777));
    }
    Ok(())
}

/// Remove `name` from the archive in place (zip -d parity). Rebuilds the
/// archive copying every other entry verbatim.
pub fn zip_delete(archive: &str, name: &str) -> Result<(), String> {
    zip_rewrite(archive, &[name], None)
}

/// Add or replace `name` in the archive, reading the new content from
/// `cwd/name` (zip -u parity). Any existing entry with that name is dropped
/// first so the result holds a single, current copy.
pub fn zip_update(archive: &str, name: &str, cwd: &Path) -> Result<(), String> {
    zip_rewrite(archive, &[name], Some((name, cwd)))
}

/// Copy `archive` into a sibling temp file, skipping entries in `drop`, then
/// optionally append a fresh file, then atomically replace the original.
fn zip_rewrite(archive: &str, drop: &[&str], add: Option<(&str, &Path)>) -> Result<(), String> {
    let archive_path = Path::new(archive);
    let src = File::open(archive_path).map_err(|e| io_err(archive_path, e))?;
    let mut reader = zip::ZipArchive::new(src).map_err(|e| e.to_string())?;

    let tmp_path = archive_path.with_extension("dired-zip-tmp");
    let tmp = File::create(&tmp_path).map_err(|e| io_err(&tmp_path, e))?;
    let mut writer = zip::ZipWriter::new(tmp);

    let result = (|| -> Result<(), String> {
        for i in 0..reader.len() {
            let entry = reader.by_index_raw(i).map_err(|e| e.to_string())?;
            if drop.contains(&entry.name()) {
                continue;
            }
            // raw_copy keeps the original compressed bytes and metadata
            writer.raw_copy_file(entry).map_err(|e| e.to_string())?;
        }
        if let Some((name, cwd)) = add {
            zip_add(&mut writer, cwd, name)?;
        }
        writer.finish().map(|_| ()).map_err(|e| e.to_string())
    })();

    if result.is_err() {
        let _ = std::fs::remove_file(&tmp_path);
        return result;
    }
    std::fs::rename(&tmp_path, archive_path).map_err(|e| io_err(archive_path, e))
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
