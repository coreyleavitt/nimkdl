// Memory-footprint harness for knus. ONE fixture per invocation —
// VmPeak is monotonic per-process.
//
// Usage:  knus-mem <fixture-path>
// Output: knus  <fixture>  input=<KB> baseline=<KB> peak=<KB> delta=<KB>
//
// API choice:
//   - homogeneous-services-100.kdl → parse::<Vec<Service>>  (typed)
//   - everything else              → parse_ast              (AST)
// This mirrors what knus's own README says is the idiomatic use of
// each entry point. The held value is the final typed/AST result.
//
// Iter count: knus's parse_ast on tree-d8-b3 is slow (~250ms each in
// the speed bench), so cap iters very low for huge files.
use std::env;
use std::fs;
use std::path::Path;
use knus::Decode;

#[derive(Decode, Debug)]
#[allow(dead_code)]
struct Service {
    #[knus(argument)]
    name: String,
    #[knus(property)]
    port: u16,
    #[knus(property, default = 1)]
    replicas: u16,
    #[knus(property, default = true)]
    enabled: bool,
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

// Hold either a typed Vec<Service> or an AST Document so the held-doc
// cost is captured alongside transient peak.
enum Held {
    Typed(Vec<Service>),
    Ast(knus::ast::Document<knus::span::Span>),
    None,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: knus-mem <fixture-path>");
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

    // Tuned iter counts. knus parse_ast on tree-d8-b3 is on the
    // order of 250ms/iter, so use 5 there to keep the bench bounded.
    let iters: usize = if content.len() > 500_000 {
        5
    } else if content.len() > 200_000 {
        20
    } else {
        200
    };

    let baseline = vm_peak_kb();

    let mut held = Held::None;
    if fixture.starts_with("homogeneous-services") {
        for _ in 0..iters {
            match knus::parse::<Vec<Service>>(&fixture, &content) {
                Ok(v) => held = Held::Typed(v),
                Err(_) => {}
            }
        }
    } else {
        for _ in 0..iters {
            let r: Result<knus::ast::Document<knus::span::Span>, _> =
                knus::parse_ast(&fixture, &content);
            if let Ok(d) = r { held = Held::Ast(d); }
        }
    }
    let peak = vm_peak_kb();
    // Discriminator-keeping use of held so it isn't dropped early.
    let _hold_tag: u8 = match &held {
        Held::Typed(_) => 1,
        Held::Ast(_) => 2,
        Held::None => 0,
    };

    let input_kb = (content.len() + 1023) / 1024;
    println!(
        "  knus    {fixture:<35} input {input_kb:>5} KB   baseline {baseline:>6} KB   peak {peak:>6} KB   delta {:>6} KB",
        peak - baseline
    );
}
