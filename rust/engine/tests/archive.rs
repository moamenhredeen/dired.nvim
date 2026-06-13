use std::fs;
use std::path::Path;

use dired_engine::archive;

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
