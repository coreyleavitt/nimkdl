// knus bench — three paths to test each API as the docs intend.
//
// 1. parse_ast: parser-only, returns a knus AST. Closest to ckdl's
//    event drain and to nimkdl's parse(). This is what knus's
//    public `parse_ast` function is for.
//
// 2. typed Vec<T>: schema-driven decode of a homogeneous node list.
//    Reads the vendored homogeneous-services-100.kdl fixture so
//    every harness consumes byte-identical input.
//
// 3. typed enum: discriminated union for heterogeneous top-level
//    nodes — the pattern the knus docs recommend for parsing real
//    configs with mixed node types.
use std::fs;
use std::time::Instant;
use knus::Decode;

#[derive(Decode, Debug)]
struct Service {
    #[knus(argument)]
    _name: String,
    #[knus(property)]
    _port: u16,
    #[knus(property, default = 1)]
    _replicas: u16,
    #[knus(property, default = true)]
    _enabled: bool,
}

// Discriminated union for realistic-config's mixed top-level nodes.
#[derive(Decode, Debug)]
#[allow(dead_code)]
enum ConfigNode {
    Defaults(Defaults),
    EnvVars(EnvVars),
    Services(Services),
}

#[derive(Decode, Debug)]
#[allow(dead_code)]
struct Defaults { #[knus(children)] children: Vec<KV> }
#[derive(Decode, Debug)]
#[allow(dead_code)]
struct EnvVars  { #[knus(children)] children: Vec<KV> }
#[derive(Decode, Debug)]
#[allow(dead_code)]
struct Services { #[knus(children)] children: Vec<KV> }
#[derive(Decode, Debug)]
#[allow(dead_code)]
struct KV {
    #[knus(node_name)] _name: String,
    #[knus(arguments)] _args: Vec<String>,
}

fn time<F: FnMut()>(iters: u64, mut f: F) -> f64 {
    for _ in 0..100.min(iters) { f(); }
    let start = Instant::now();
    for _ in 0..iters { f(); }
    start.elapsed().as_secs_f64()
}

fn report(name: &str, content_len: usize, iters: u64, elapsed: f64) {
    let us = elapsed / iters as f64 * 1_000_000.0;
    let ops = iters as f64 / elapsed;
    println!("  {:<45} {:>10.1}us avg   {:>10.1}K ops/s   {} bytes",
        name, us, ops / 1000.0, content_len);
}

fn main() {
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
    ];

    println!("=== knus parse_ast (AST only, no schema) ===\n");
    for (name, path, iters) in &cases {
        let content = match fs::read_to_string(*path) { Ok(c) => c, Err(_) => continue };
        let el = time(*iters, || {
            let _: Result<knus::ast::Document<knus::span::Span>, _> =
                knus::parse_ast(name, &content);
        });
        report(name, content.len(), *iters, el);
    }

    println!("\n=== knus typed Vec<Service> on homogeneous services fixture ===\n");
    let content = match fs::read_to_string("/fixtures/homogeneous-services-100.kdl") {
        Ok(c) => c, Err(_) => { eprintln!("homogeneous-services-100.kdl missing"); return; }
    };
    let el = time(5_000, || {
        let _ = knus::parse::<Vec<Service>>("homogeneous-services-100.kdl", &content);
    });
    report("typed Vec<Service> (~100 nodes)", content.len(), 5_000, el);

    println!("\n=== knus typed enum (discriminated union, idiomatic) ===\n");
    let content = match fs::read_to_string("/fixtures/realistic-config.kdl") {
        Ok(c) => c, Err(_) => return,
    };
    let el = time(5_000, || {
        let _ = knus::parse::<Vec<ConfigNode>>("realistic-config.kdl", &content);
    });
    report("typed Vec<ConfigNode> on realistic", content.len(), 5_000, el);
}
