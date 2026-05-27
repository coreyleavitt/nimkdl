// facet-kdl bench. facet-kdl is the spiritual successor to knus per
// knus's own README. Type-driven via the `facet::Facet` derive.
// No exposed AST-only path; only typed deserialize.
//
// Note: facet-kdl is built on top of kdl-rs (depends on kdl ^6.5.0),
// so its parse cost is bounded by kdl-rs + facet's deserialize layer.
//
// The crate-rename `use facet_kdl as kdl;` is how the `#[facet(kdl::*)]`
// attribute namespace resolves; pattern lifted from facet-kdl's own
// test suite (tests/basic.rs).
use std::fs;
use std::time::Instant;
use facet::Facet;
use facet_kdl as kdl;
use facet_kdl::{from_str, to_string};

#[allow(dead_code)]
#[derive(Facet, Debug)]
struct Service {
    #[facet(kdl::argument)]
    name: String,
    #[facet(kdl::property)]
    port: u16,
    #[facet(kdl::property)]
    replicas: u16,
    #[facet(kdl::property)]
    enabled: bool,
}

// facet-kdl requires a Doc wrapper around Vec<T> for a list of
// homogeneous top-level nodes — that's the pattern in their own tests.
#[allow(dead_code)]
#[derive(Facet, Debug)]
struct ServiceDoc {
    #[facet(kdl::children)]
    services: Vec<Service>,
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
    println!("=== facet-kdl typed ServiceDoc on homogeneous services fixture ===\n");
    let content = match fs::read_to_string("/fixtures/homogeneous-services-100.kdl") {
        Ok(c) => c, Err(_) => { eprintln!("homogeneous-services-100.kdl missing"); return; }
    };
    let el = time(5_000, || {
        let _: Result<ServiceDoc, _> = from_str(&content);
    });
    report("typed ServiceDoc (~100 nodes)", content.len(), 5_000, el);

    println!("\n=== facet-kdl encode (to_string from typed ServiceDoc, canonical) ===\n");
    // Parse once, then time the encode loop. facet-kdl's to_string
    // serializes from a typed value back to KDL — canonical output
    // (no trivia preservation since the typed value discarded format
    // info at decode time). Comparable to nimkdl's emPretty.
    let doc: ServiceDoc = from_str(&content).unwrap();
    let el = time(5_000, || {
        let _: Result<String, _> = to_string(&doc);
    });
    report("encode ServiceDoc -> string", content.len(), 5_000, el);
}
