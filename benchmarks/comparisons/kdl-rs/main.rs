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

// Encode-side bench. kdl-rs's KdlDocument has Display impl that
// renders the doc back to text. By default it preserves whatever
// trivia (per-token whitespace + comments) was carried on parsed
// nodes — kdl-rs's analog of nimkdl's emPreserve. Calling
// .autoformat() before to_string() canonicalizes, comparable to
// nimkdl's emPretty.
fn bench_encode_preserve(name: &str, content: &str, iters: u64) {
    let doc = match kdl::KdlDocument::parse_v2(content) {
        Ok(d) => d, Err(_) => return,
    };
    for _ in 0..100.min(iters) { let _ = doc.to_string(); }
    let start = Instant::now();
    for _ in 0..iters { let _ = doc.to_string(); }
    let el = start.elapsed().as_secs_f64();
    let us = el / iters as f64 * 1_000_000.0;
    let ops = iters as f64 / el;
    println!("  {:<45} {:>10.1}us avg   {:>10.1}K ops/s   {} bytes",
        name, us, ops / 1000.0, content.len());
}

fn bench_encode_canonical(name: &str, content: &str, iters: u64) {
    let mut doc = match kdl::KdlDocument::parse_v2(content) {
        Ok(d) => d, Err(_) => return,
    };
    doc.autoformat();
    for _ in 0..100.min(iters) { let _ = doc.to_string(); }
    let start = Instant::now();
    for _ in 0..iters { let _ = doc.to_string(); }
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
    for (name, path, iters) in &cases {
        let content = match fs::read_to_string(*path) { Ok(c) => c, Err(_) => continue };
        bench(name, &content, *iters);
    }

    println!("\n=== kdl-rs encode (to_string, trivia-preserving — analog of emPreserve) ===\n");
    // Subset of fixtures for encode; small ones get noisy.
    let encode_cases: Vec<(&str, &str, u64)> = vec![
        ("realistic-config.kdl", "/fixtures/realistic-config.kdl", 5_000),
        ("ci.kdl",               "/fixtures/ci.kdl",                5_000),
        ("website.kdl",          "/fixtures/website.kdl",           5_000),
        ("tree-d8-b3.kdl",       "/fixtures/tree-d8-b3.kdl",          200),
    ];
    for (name, path, iters) in &encode_cases {
        let content = match fs::read_to_string(*path) { Ok(c) => c, Err(_) => continue };
        bench_encode_preserve(name, &content, *iters);
    }

    println!("\n=== kdl-rs encode (autoformat + to_string, canonical — analog of emPretty) ===\n");
    for (name, path, iters) in &encode_cases {
        let content = match fs::read_to_string(*path) { Ok(c) => c, Err(_) => continue };
        bench_encode_canonical(name, &content, *iters);
    }
}
