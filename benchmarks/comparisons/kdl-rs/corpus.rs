// Real-trace replay: parse every file in the kdl-org conformance
// corpus (338 community-curated KDL files) and report aggregate
// throughput. kdl-rs is the canonical Rust impl — kdl-org tests
// against this directly.
//
// Usage: kdlrs-corpus <corpus-dir>
use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let dir = match env::args().nth(1) {
        Some(d) => PathBuf::from(d),
        None => { eprintln!("usage: kdlrs-corpus <corpus-dir>"); std::process::exit(2); }
    };
    if !dir.is_dir() {
        eprintln!("missing corpus dir: {}", dir.display());
        std::process::exit(2);
    }

    let mut files: Vec<(String, String)> = Vec::new();
    let mut total_bytes: usize = 0;
    for ent in fs::read_dir(&dir).expect("read_dir") {
        let ent = match ent { Ok(e) => e, Err(_) => continue };
        let p = ent.path();
        if p.extension().and_then(|s| s.to_str()) != Some("kdl") { continue; }
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        let content = match fs::read_to_string(&p) { Ok(c) => c, Err(_) => continue };
        total_bytes += content.len();
        files.push((name, content));
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));

    const ITERS: usize = 50;
    let mut ok_count = 0usize;
    let start = Instant::now();
    for _ in 0..ITERS {
        ok_count = 0;
        for (_name, content) in &files {
            match kdl::KdlDocument::parse_v2(content) {
                Ok(_) => ok_count += 1,
                Err(_) => (),
            }
        }
    }
    let elapsed = start.elapsed().as_secs_f64();

    let total_parses = (files.len() * ITERS) as f64;
    let us_per_file = elapsed * 1e6 / total_parses;
    let files_per_sec = total_parses / elapsed;
    let kb_per_sec = (total_bytes as f64 * ITERS as f64) / (elapsed * 1024.0);
    println!("  kdl-rs  corpus  files={}  bytes={}  iters={}  us/file={:.2}  files/s={:.1}K  KB/s={:.0}  ok={}/{}",
        files.len(), total_bytes, ITERS, us_per_file, files_per_sec / 1000.0, kb_per_sec, ok_count, files.len());
}
