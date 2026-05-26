// kdl-rs bench. KdlDocument::parse_v2 — the canonical Rust impl.
// Reads every fixture from /fixtures/ (vendored by run.sh from the
// repo's benchmarks/fixtures/ directory) so the inputs are byte-
// identical across every harness in the comparison.
use std::fs;
use std::time::Instant;

fn bench(name: &str, content: &str, iters: u64) {
    if iters >= 100 {
        for _ in 0..100 { let _ = kdl::KdlDocument::parse_v2(content); }
    }
    let start = Instant::now();
    for _ in 0..iters { let _ = kdl::KdlDocument::parse_v2(content); }
    let el = start.elapsed().as_secs_f64();
    let us = el / iters as f64 * 1_000_000.0;
    let ops = iters as f64 / el;
    println!("  {:<45} {:>10.1}us avg   {:>10.1}K ops/s   {} bytes",
        name, us, ops / 1000.0, content.len());
}

fn main() {
    println!("=== kdl-rs parse_v2 (release+LTO) ===\n");
    let cases: Vec<(&str, &str, u64)> = vec![
        // Real-world
        ("realistic-config.kdl",          "/fixtures/realistic-config.kdl",            5_000),
        ("Cargo.kdl",                     "/fixtures/Cargo.kdl",                      10_000),
        ("ci.kdl",                        "/fixtures/ci.kdl",                          5_000),
        ("website.kdl",                   "/fixtures/website.kdl",                     5_000),
        // Large
        ("flat-deps-100.kdl",             "/fixtures/flat-deps-100.kdl",               2_000),
        ("tree-d8-b3.kdl",                "/fixtures/tree-d8-b3.kdl",                    200),
        // Regression / stress
        ("deep-chain-100.kdl",            "/fixtures/deep-chain-100.kdl",              1_000),
        ("unicode-heavy.kdl",             "/fixtures/unicode-heavy.kdl",               2_000),
        // Typed-decode comparison input (kdl-rs has no typed path beyond AST)
        ("homogeneous-services-100.kdl",  "/fixtures/homogeneous-services-100.kdl",    5_000),
    ];
    for (name, path, iters) in cases {
        let content = match fs::read_to_string(path) { Ok(c) => c, Err(_) => continue };
        bench(name, &content, iters);
    }
}
