// muguet - io.rs
// Constantin Clerc (c22dev) - 0.1

use crate::mem_base_len;
use std::collections::HashMap;
use std::fs::File;
use std::os::unix::fs::FileExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;
use wasmtime::SharedMemory;

static STARTED: AtomicBool = AtomicBool::new(false);
const MAX_OPEN: usize = 1024;

pub fn data_dir() -> PathBuf {
    PathBuf::from(std::env::var("MUGUET_DATA").unwrap_or_default())
}

pub struct Merged {
    pub json: Vec<u8>,
    pub files: Vec<(String, u64, PathBuf)>,
}

fn walk(dir: &std::path::Path, rel: &str, out: &mut Vec<(String, PathBuf, u64)>) {
    let mut entries: Vec<_> = std::fs::read_dir(dir).into_iter().flatten().flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') { continue; }
        let r = if rel.is_empty() { name } else { format!("{rel}/{name}") };
        let Ok(md) = e.metadata() else { continue };
        if md.is_dir() { walk(&e.path(), &r, out); } else if md.is_file() { out.push((r, e.path(), md.len())); }
    }
}

/// The game's file list with mods applied: every file under `<support>/mods/<ModName>/` replaces
/// the game file at the same path (case-insensitive), or is added if the game has no such file.
/// Mods are applied in alphabetical order, so later ones win.
pub fn merged() -> &'static Merged {
    static M: std::sync::LazyLock<Merged> = std::sync::LazyLock::new(|| {
        let text = std::fs::read_to_string(data_dir().join("manifest.json")).expect("manifest.json");
        let mut v: serde_json::Value = serde_json::from_str(&text).expect("manifest json");
        let root = data_dir();
        let arr = v["files"].as_array_mut().expect("files");
        let mut files: Vec<(String, u64, PathBuf)> = arr.iter().map(|f| {
            let p = f[0].as_str().unwrap_or("").to_string();
            let full = root.join(&p);
            (p, f[1].as_u64().unwrap_or(0), full)
        }).collect();
        let mods = crate::config::mods_dir();
        let mut mod_dirs: Vec<_> = std::fs::read_dir(&mods).into_iter().flatten().flatten().filter(|e| e.path().is_dir()).collect();
        mod_dirs.sort_by_key(|e| e.file_name());
        let mut index: HashMap<String, usize> = files.iter().enumerate().map(|(k, f)| (f.0.to_lowercase(), k)).collect();
        for m in mod_dirs {
            let mname = m.file_name().to_string_lossy().into_owned();
            if mname.starts_with('.') { continue; }
            let mut found = Vec::new();
            walk(&m.path(), "", &mut found);
            for (rel, full, size) in found {
                match index.get(&rel.to_lowercase()) {
                    Some(&k) => { files[k].1 = size; files[k].2 = full; eprintln!("[mods] {mname}: replaces {rel}"); }
                    None => {
                        index.insert(rel.to_lowercase(), files.len());
                        files.push((rel.clone(), size, full));
                        eprintln!("[mods] {mname}: adds {rel}");
                    }
                }
            }
        }
        let list: Vec<serde_json::Value> = files.iter().map(|(p, s, _)| serde_json::json!([p, s, 0])).collect();
        // keep original mtimes for untouched entries
        let orig: HashMap<String, serde_json::Value> = arr.iter().map(|f| (f[0].as_str().unwrap_or("").to_string(), f[2].clone())).collect();
        let list: Vec<serde_json::Value> = list.into_iter().map(|mut e| { if let Some(t) = orig.get(e[0].as_str().unwrap_or("")) { e[2] = t.clone(); } e }).collect();
        v["files"] = serde_json::Value::Array(list);
        Merged { json: serde_json::to_vec(&v).expect("manifest"), files }
    });
    &M
}

fn atomic_i32(mem: &SharedMemory, addr: u64) -> &AtomicI32 {
    let (base, len) = mem_base_len(mem);
    assert!((addr as usize) + 4 <= len && addr % 4 == 0);
    unsafe { &*(base.add(addr as usize) as *const AtomicI32) }
}

pub fn start(mem: &SharedMemory, table: u64) {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let mem = mem.clone();
    std::thread::Builder::new()
        .name("io".into())
        .spawn(move || serve_loop(mem, table))
        .expect("spawn io thread");
    eprintln!("[io] native I/O thread started (table=0x{table:x})");
}

fn serve_loop(mem: SharedMemory, table: u64) {
    let files = &merged().files;
    let mut handles: HashMap<i32, File> = HashMap::new();
    let mut served: u64 = 0;
    let mut bytes: u64 = 0;
    loop {
        let seen = atomic_i32(&mem, table).load(Ordering::SeqCst);
        let n = atomic_i32(&mem, table + 4).load(Ordering::SeqCst).max(0) as u64;
        for slot in 0..n {
            let w = table + 64 + 64 * slot;
            if atomic_i32(&mem, w).compare_exchange(1, 3, Ordering::SeqCst, Ordering::SeqCst).is_err() {
                continue;
            }
            let word = |k: u64| atomic_i32(&mem, w + 4 * k).load(Ordering::SeqCst) as u32 as u64;
            let id = word(1) as i32;
            let off = word(2) | (word(3) << 32);
            let dst = word(4) | (word(5) << 32);
            let mut len = word(6);
            let result: i64 = match files.get(id as usize) {
                None => -1,
                Some((path, size, full)) => {
                    if off >= *size {
                        0
                    } else {
                        len = len.min(size - off);

                        if !handles.contains_key(&id) {
                            if handles.len() >= MAX_OPEN { handles.clear(); }
                            match File::open(full) {
                                Ok(f) => { handles.insert(id, f); }
                                Err(e) => eprintln!("[io] open {path}: {e}"),
                            }
                        }
                        let (base, mlen) = mem_base_len(&mem);
                        let Some(f) = handles.get(&id) else {
                            atomic_i32(&mem, w + 28).store(-1, Ordering::SeqCst);
                            atomic_i32(&mem, w).store(2, Ordering::SeqCst);
                            let _ = mem.atomic_notify(w, 1);
                            continue;
                        };
                        if (dst + len) as usize > mlen {
                            -1
                        } else {
                            crate::heapcheck::note(dst, len, "file read");
                            let buf = unsafe { std::slice::from_raw_parts_mut(base.add(dst as usize), len as usize) };
                            match f.read_exact_at(buf, off) {
                                Ok(()) => len as i64,
                                Err(e) => { eprintln!("[io] read {path}@{off}+{len}: {e}"); -1 }
                            }
                        }
                    }
                }
            };
            served += 1;
            if result > 0 { bytes += result as u64; }
            if served % 2000 == 0 {
                eprintln!("[io] {served} reads, {} MB", bytes >> 20);
            }
            atomic_i32(&mem, w + 28).store(result as i32, Ordering::SeqCst);
            atomic_i32(&mem, w).store(2, Ordering::SeqCst);
            let _ = mem.atomic_notify(w, 1);
        }

        let _ = mem.atomic_wait32(table, seen as u32, Some(Duration::from_millis(20)));
    }
}
