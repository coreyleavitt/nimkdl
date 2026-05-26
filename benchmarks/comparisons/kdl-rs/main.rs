use std::fs;
use std::time::Instant;
fn bench(name: &str, content: &str, iters: u64) -> f64 {
    if iters >= 100 {
        for _ in 0..100 { let _ = kdl::KdlDocument::parse_v2(content); }
    }
    let start = Instant::now();
    for _ in 0..iters { let _ = kdl::KdlDocument::parse_v2(content); }
    let el = start.elapsed().as_secs_f64();
    let us = el / iters as f64 * 1_000_000.0;
    let ops = iters as f64 / el;
    println!("  {:<40}{:>10.1}us avg   {:>10.1}K ops/s   {} bytes",
        name, us, ops / 1000.0, content.len());
    el
}
fn main() {
    println!("=== kdl-rs parse_v2 (release+LTO) ===\n");
    let cases: Vec<(&str, &str, u64)> = vec![
        ("realistic-config.kdl", "/fixtures/realistic-config.kdl",  5_000),
        ("Cargo.kdl",            "/fixtures/Cargo.kdl",            10_000),
        ("ci.kdl",               "/fixtures/ci.kdl",                5_000),
        ("website.kdl",          "/fixtures/website.kdl",           5_000),
        ("unicode-heavy.kdl",    "/fixtures/unicode-heavy.kdl",     5_000),
    ];
    for (name, path, iters) in cases {
        let content = match fs::read_to_string(path) { Ok(c) => c, Err(_) => continue };
        let _ = bench(name, &content, iters);
    }
    let synth = "node1 \"arg1\" prop1=\"val1\"\nnode2 123 prop2=456\nnode3 3.14 prop3=\"value\"\n".repeat(10);
    let _ = bench("Synthetic (30 nodes)", &synth, 10_000);
    let mut deep20 = String::new();
    for i in 1..=20 { deep20.push_str(&format!("level{} {{\n", i)); }
    deep20.push_str("leaf \"value\"\n");
    for _ in 1..=20 { deep20.push_str("}\n"); }
    let _ = bench("Synthetic (deep nesting, 20)", &deep20, 10_000);
    let mut deep100 = String::new();
    for i in 1..=100 { deep100.push_str(&format!("level{i} arg{i} key{i}={i} {{\n")); }
    deep100.push_str("leaf \"bottom\" depth=100\n");
    for _ in 1..=100 { deep100.push_str("}\n"); }
    let _ = bench("Synthetic (deep chain, 100)", &deep100, 2_000);
    fn build_tree(depth: i32, branch: i32, prefix: &str) -> String {
        if depth == 0 {
            return format!("{}leaf \"{}\" idx=0\n", prefix, prefix);
        }
        let mut out = String::new();
        for b in 0..branch {
            let name = format!("{}n{}", prefix, b);
            out.push_str(&format!("{}{} arg=\"v\" depth={} {{\n", prefix, name, depth));
            out.push_str(&build_tree(depth - 1, branch, &format!("{}  ", prefix)));
            out.push_str(&format!("{}}}\n", prefix));
        }
        out
    }
    let big_tree = build_tree(8, 3, "");
    let _ = bench("Synthetic (tree d=8 b=3, ~9.8k nodes)", &big_tree, 200);
    let mut wide = String::new();
    for i in 1..=100 { wide.push_str(&format!("node{} \"arg\" key=\"val\"\n", i)); }
    let _ = bench("Synthetic (100 nodes wide)", &wide, 5_000);
}
