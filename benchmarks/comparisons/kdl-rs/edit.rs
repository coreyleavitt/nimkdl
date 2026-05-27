// Edit-then-encode bench for kdl-rs. Mirrors nimkdl/edit.nim:
// full cycle of parse → mutate one node → to_string per iteration.
// Matches the realistic "editor open → edit → save" workflow.
//
// kdl-rs strategy: per-token whitespace storage on every node; on
// to_string() the tree is walked emitting carried trivia per token
// regardless of which subtree was mutated.
use std::env;
use std::fs;
use std::path::Path;
use std::time::Instant;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 { eprintln!("usage: kdlrs-edit <fixture-path>"); std::process::exit(2); }
    let path = &args[1];
    if !Path::new(path).exists() {
        eprintln!("missing fixture: {}", path); std::process::exit(2);
    }
    let src = fs::read_to_string(path).expect("read fixture");

    let iters: u64 = 5_000;
    // Warmup
    for _ in 0..100 {
        let mut doc = kdl::KdlDocument::parse_v2(&src).expect("parse");
        {
            let n = &mut doc.nodes_mut()[0];
            let entry = kdl::KdlEntry::new_prop("bench-mark", "edited");
            n.push(entry);
        }
        let _ = doc.to_string();
    }
    let start = Instant::now();
    for _ in 0..iters {
        let mut doc = kdl::KdlDocument::parse_v2(&src).expect("parse");
        {
            let n = &mut doc.nodes_mut()[0];
            let entry = kdl::KdlEntry::new_prop("bench-mark", "edited");
            n.push(entry);
        }
        let _ = doc.to_string();
    }
    let el = start.elapsed().as_secs_f64();
    let us = el / iters as f64 * 1_000_000.0;
    let ops = iters as f64 / el;
    let fixture = Path::new(path).file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "?".into());
    println!(
        "  kdl-rs  edit-encode  {fixture:<30} {us:>8.1}us avg   {:>8.1}K ops/s   {} bytes",
        ops / 1000.0, src.len()
    );
}
