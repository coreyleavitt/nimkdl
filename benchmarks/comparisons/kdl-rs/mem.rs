// Memory-footprint harness for kdl-rs. ONE fixture per invocation —
// VmPeak is monotonic per-process so a fresh process per measurement
// is the only way to get clean per-fixture deltas.
//
// Usage: kdlrs-mem <fixture-path>
// Output: kdl-rs <fixture> input=<KB> baseline=<KB> peak=<KB> delta=<KB>
//
// Same methodology as the nimkdl/mem.nim: read fixture, snapshot
// VmPeak as baseline, parse N times holding final, snapshot VmPeak
// again, report delta.
use std::env;
use std::fs;
use std::path::Path;

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
        eprintln!("usage: kdlrs-mem <fixture-path>");
        std::process::exit(2);
    }
    let path = &args[1];
    if !Path::new(path).exists() {
        eprintln!("missing fixture: {}", path);
        std::process::exit(2);
    }
    let content = fs::read_to_string(path).expect("read fixture");
    let iters = if content.len() > 200_000 { 20 } else { 200 };
    let baseline = vm_peak_kb();
    let mut held: Option<kdl::KdlDocument> = None;
    for _ in 0..iters {
        held = kdl::KdlDocument::parse_v2(&content).ok();
    }
    let peak = vm_peak_kb();
    let _ = held;  // hold is the point
    let fixture = Path::new(path).file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "?".into());
    let input_kb = (content.len() + 1023) / 1024;
    println!(
        "  kdl-rs  {fixture:<35} input {input_kb:>5} KB   baseline {baseline:>6} KB   peak {peak:>6} KB   delta {:>6} KB",
        peak - baseline
    );
}
