// Memory-footprint harness for facet-kdl. ONE fixture per invocation.
//
// Usage:  facet-kdl-mem <fixture-path>
// Output: facet-kdl  <fixture>  input=<KB> baseline=<KB> peak=<KB> delta=<KB>
//
// API note: facet-kdl exposes ONLY a typed `from_str::<T>` entry
// point. There is no untyped/AST path. The only fixture in our matrix
// that has a defined typed shape (ServiceDoc) is
// homogeneous-services-100.kdl. For other fixtures (tree-d8-b3,
// realistic-config) the harness prints a SKIPPED line — parsing them
// through facet-kdl's transitive kdl-rs dependency would just
// duplicate the kdl-rs numbers, so we declare the asymmetry honestly
// instead.
//
// Implementation note: facet-kdl pulls kdl-rs in transitively (it IS
// facet-kdl's parser), so the baseline RSS is close to kdl-rs's and
// the held-doc cost is bounded below by what kdl-rs would hold for
// the same input.
use std::env;
use std::fs;
use std::path::Path;
use facet::Facet;
use facet_kdl as kdl;
use facet_kdl::from_str;

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

#[allow(dead_code)]
#[derive(Facet, Debug)]
struct ServiceDoc {
    #[facet(kdl::children)]
    services: Vec<Service>,
}

fn vm_peak_kb() -> i64 {
    let status = fs::read_to_string("/proc/self/status").unwrap_or_default();
    for line in status.lines() {
        if line.starts_with("VmPeak:") {
            for tok in line.split_whitespace() {
                if let Ok(n) = tok.parse::<i64>() { return n; }
            }
        }
    }
    -1
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: facet-kdl-mem <fixture-path>");
        std::process::exit(2);
    }
    let path = &args[1];
    if !Path::new(path).exists() {
        eprintln!("missing fixture: {}", path);
        std::process::exit(2);
    }
    let content = fs::read_to_string(path).expect("read fixture");
    let fixture = Path::new(path).file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "?".into());
    let input_kb = (content.len() + 1023) / 1024;

    if !fixture.starts_with("homogeneous-services") {
        println!(
            "  facet-kdl {fixture:<33} input {input_kb:>5} KB   (skipped: facet-kdl has no untyped path; would duplicate kdl-rs numbers)"
        );
        return;
    }

    let iters: usize = if content.len() > 200_000 { 20 } else { 200 };
    let baseline = vm_peak_kb();

    let mut held: Option<ServiceDoc> = None;
    for _ in 0..iters {
        if let Ok(d) = from_str::<ServiceDoc>(&content) { held = Some(d); }
    }
    let peak = vm_peak_kb();
    let _ = held;

    println!(
        "  facet-kdl {fixture:<33} input {input_kb:>5} KB   baseline {baseline:>6} KB   peak {peak:>6} KB   delta {:>6} KB",
        peak - baseline
    );
}
