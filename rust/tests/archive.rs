use std::fs;
use std::path::Path;

use dired_core::archive;

fn setup_tree(dir: &Path) {
    fs::create_dir_all(dir.join("src/sub")).unwrap();
    fs::write(dir.join("a.txt"), "alpha").unwrap();
    fs::write(dir.join("src/b.txt"), "bravo").unwrap();
    fs::write(dir.join("src/sub/c.txt"), "charlie").unwrap();
}

fn roundtrip(ext: &str) {
    let tmp = tempfile::tempdir().unwrap();
    let cwd = tmp.path().join("in");
    setup_tree(&cwd);

    let archive_path = tmp.path().join(format!("out{}", ext));
    archive::create(
        archive_path.to_str().unwrap(),
        &["a.txt".to_string(), "src".to_string()],
        cwd.to_str().unwrap(),
    )
    .unwrap();
    assert!(archive_path.metadata().unwrap().len() > 0);

    let dest = tmp.path().join("dest");
    archive::extract(archive_path.to_str().unwrap(), dest.to_str().unwrap()).unwrap();

    assert_eq!(fs::read_to_string(dest.join("a.txt")).unwrap(), "alpha");
    assert_eq!(fs::read_to_string(dest.join("src/b.txt")).unwrap(), "bravo");
    assert_eq!(
        fs::read_to_string(dest.join("src/sub/c.txt")).unwrap(),
        "charlie"
    );
}

#[test]
fn zip_roundtrip() {
    roundtrip(".zip");
}

#[test]
fn tar_roundtrip() {
    roundtrip(".tar");
}

#[test]
fn tar_gz_roundtrip() {
    roundtrip(".tar.gz");
}

#[test]
fn tgz_roundtrip() {
    roundtrip(".tgz");
}

#[test]
fn tar_bz2_roundtrip() {
    roundtrip(".tbz2");
}

#[test]
fn tar_xz_roundtrip() {
    roundtrip(".tar.xz");
}

#[test]
fn zip_extract_skips_existing() {
    let tmp = tempfile::tempdir().unwrap();
    let cwd = tmp.path().join("in");
    fs::create_dir_all(&cwd).unwrap();
    fs::write(cwd.join("a.txt"), "from-archive").unwrap();

    let archive_path = tmp.path().join("out.zip");
    archive::create(
        archive_path.to_str().unwrap(),
        &["a.txt".to_string()],
        cwd.to_str().unwrap(),
    )
    .unwrap();

    let dest = tmp.path().join("dest");
    fs::create_dir_all(&dest).unwrap();
    fs::write(dest.join("a.txt"), "pre-existing").unwrap();

    archive::extract(archive_path.to_str().unwrap(), dest.to_str().unwrap()).unwrap();
    // `unzip -n` parity: existing file untouched
    assert_eq!(
        fs::read_to_string(dest.join("a.txt")).unwrap(),
        "pre-existing"
    );
}

#[test]
fn unsupported_extension_errors() {
    let tmp = tempfile::tempdir().unwrap();
    let err = archive::create(
        tmp.path().join("out.rar").to_str().unwrap(),
        &[],
        tmp.path().to_str().unwrap(),
    )
    .unwrap_err();
    assert!(err.contains("unsupported archive extension"));

    let err =
        archive::extract(tmp.path().join("in.rar").to_str().unwrap(), "/tmp/x").unwrap_err();
    assert!(err.contains("unsupported archive extension"));
}

#[test]
#[cfg(unix)]
fn tar_preserves_symlinks() {
    let tmp = tempfile::tempdir().unwrap();
    let cwd = tmp.path().join("in");
    fs::create_dir_all(&cwd).unwrap();
    fs::write(cwd.join("real.txt"), "data").unwrap();
    std::os::unix::fs::symlink("real.txt", cwd.join("link.txt")).unwrap();

    let archive_path = tmp.path().join("out.tar.gz");
    archive::create(
        archive_path.to_str().unwrap(),
        &["real.txt".to_string(), "link.txt".to_string()],
        cwd.to_str().unwrap(),
    )
    .unwrap();

    let dest = tmp.path().join("dest");
    archive::extract(archive_path.to_str().unwrap(), dest.to_str().unwrap()).unwrap();
    let link = fs::read_link(dest.join("link.txt")).unwrap();
    assert_eq!(link.to_str().unwrap(), "real.txt");
}

// Build a zip from setup_tree and hand back (tempdir, archive path string) for
// the zip.vim shim tests below.
fn make_zip() -> (tempfile::TempDir, String) {
    let tmp = tempfile::tempdir().unwrap();
    let cwd = tmp.path().join("in");
    setup_tree(&cwd);
    let archive_path = tmp.path().join("out.zip");
    archive::create(
        archive_path.to_str().unwrap(),
        &["a.txt".to_string(), "src".to_string()],
        cwd.to_str().unwrap(),
    )
    .unwrap();
    let path = archive_path.to_str().unwrap().to_string();
    (tmp, path)
}

#[test]
fn zip_list_includes_dirs_and_files() {
    let (_tmp, zip) = make_zip();
    let names = archive::zip_list(&zip).unwrap();
    assert!(names.contains(&"a.txt".to_string()));
    assert!(names.contains(&"src/b.txt".to_string()));
    assert!(names.contains(&"src/sub/c.txt".to_string()));
    // directory entries keep their trailing slash for zip.vim's dir detection
    assert!(names.iter().any(|n| n.ends_with('/')));
}

#[test]
fn zip_read_streams_entry() {
    let (_tmp, zip) = make_zip();
    let mut buf = Vec::new();
    archive::zip_read(&zip, "src/b.txt", &mut buf).unwrap();
    assert_eq!(buf, b"bravo");
    assert!(archive::zip_read(&zip, "missing.txt", &mut Vec::new()).is_err());
}

#[test]
fn zip_extract_entry_preserves_path() {
    let (tmp, zip) = make_zip();
    let dest = tmp.path().join("out");
    fs::create_dir_all(&dest).unwrap();
    archive::zip_extract_entry(&zip, "src/sub/c.txt", &dest).unwrap();
    assert_eq!(
        fs::read_to_string(dest.join("src/sub/c.txt")).unwrap(),
        "charlie"
    );
}

#[test]
fn zip_update_replaces_entry() {
    let (tmp, zip) = make_zip();
    // stage the new content at cwd/<name>, as zip.vim does before `zip -u`
    let cwd = tmp.path().join("edit");
    fs::create_dir_all(cwd.join("src")).unwrap();
    fs::write(cwd.join("src/b.txt"), "BRAVO2").unwrap();
    archive::zip_update(&zip, "src/b.txt", &cwd).unwrap();

    let mut buf = Vec::new();
    archive::zip_read(&zip, "src/b.txt", &mut buf).unwrap();
    assert_eq!(buf, b"BRAVO2");
    // untouched entries survive the rewrite, with no duplicate of the updated one
    let names = archive::zip_list(&zip).unwrap();
    assert!(names.contains(&"a.txt".to_string()));
    assert_eq!(names.iter().filter(|n| *n == "src/b.txt").count(), 1);
}

#[test]
fn zip_delete_removes_entry() {
    let (_tmp, zip) = make_zip();
    archive::zip_delete(&zip, "a.txt").unwrap();
    let names = archive::zip_list(&zip).unwrap();
    assert!(!names.contains(&"a.txt".to_string()));
    // surviving entries still readable -> archive remains valid
    let mut buf = Vec::new();
    archive::zip_read(&zip, "src/b.txt", &mut buf).unwrap();
    assert_eq!(buf, b"bravo");
}
