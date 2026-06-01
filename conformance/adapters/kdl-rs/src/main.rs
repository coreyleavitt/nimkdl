//! kdl-rs conformance adapter — runs the clean-room corpus against the Rust
//! `kdl` crate (the KDL 2.0 reference implementation) and checks agreement with
//! the parser-independent oracle. This is the cross-impl certification: two
//! independent parsers (nkdl + kdl-rs) agreeing with a corpus that contains
//! neither's code means the oracle itself is certified.
//!
//! Compares by VALUE (the neutral JSON model), not canonical text — robust to
//! spelling differences in canonicalization (kdl-rs barewords strings where we
//! quote them; that is a separate canonical-form question). A positive mismatch
//! or a negative acceptance is a real finding: an nkdl/kdl-rs bug, or an oracle
//! / spec-transcription bug.
//!
//! Usage: adapter <corpus-dir>   (default: conformance/corpus)

use kdl::{KdlDocument, KdlIdentifier, KdlNode, KdlValue};
use serde_json::{json, Value};
use std::{fs, process::exit};

/// Mirror of model.valueNormal: a representation-independent canonical value for
/// a finite real — normalized scientific (one leading digit, trailing zeros
/// stripped, signed exponent) — so `12E-56`, `1.2E-55`, `1E+10`/`10000000000`
/// all map to one string. Computed on the decimal digits of the f64 (Rust's
/// Display is shortest-round-trip, no exponent), matching the Nim oracle.
fn value_normal(f: f64) -> String {
    if f.is_nan() {
        return "nan".into();
    }
    if f.is_infinite() {
        return if f < 0.0 { "-inf".into() } else { "inf".into() };
    }
    let s = format!("{f}");
    let neg = s.starts_with('-');
    let body = s.trim_start_matches('-');
    let (int_part, frac_part) = match body.split_once('.') {
        Some((i, fr)) => (i, fr),
        None => (body, ""),
    };
    let mut digits: Vec<i64> = int_part
        .bytes()
        .chain(frac_part.bytes())
        .map(|b| (b - b'0') as i64)
        .collect();
    let mut e10: i64 = -(frac_part.len() as i64);
    let mut lo = 0;
    while lo + 1 < digits.len() && digits[lo] == 0 {
        lo += 1;
    }
    digits.drain(0..lo);
    while digits.len() > 1 && *digits.last().unwrap() == 0 {
        digits.pop();
        e10 += 1;
    }
    if digits.iter().all(|&d| d == 0) {
        return "0".into();
    }
    let e = e10 + (digits.len() as i64 - 1);
    let mut mant = String::new();
    mant.push((b'0' + digits[0] as u8) as char);
    if digits.len() > 1 {
        mant.push('.');
        for &d in &digits[1..] {
            mant.push((b'0' + d as u8) as char);
        }
    }
    let sign = if e < 0 { "-" } else { "+" };
    format!("{}{}E{}{}", if neg { "-" } else { "" }, mant, sign, e.abs())
}

fn ty_json(t: Option<&KdlIdentifier>) -> Value {
    match t {
        Some(i) => json!(i.value()),
        None => Value::Null,
    }
}

fn map_value(v: &KdlValue, ty: Value) -> Value {
    match v {
        KdlValue::Integer(i) => json!({"type": ty, "kind": "int",    "value": i.to_string()}),
        KdlValue::Float(f)   => json!({"type": ty, "kind": "real",   "value": value_normal(*f)}),
        KdlValue::String(s)  => json!({"type": ty, "kind": "string", "value": s}),
        KdlValue::Bool(b)    => json!({"type": ty, "kind": "bool",   "value": b}),
        KdlValue::Null       => json!({"type": ty, "kind": "null",   "value": Value::Null}),
    }
}

fn map_node(n: &KdlNode) -> Value {
    let mut args = Vec::new();
    let mut props = Vec::new();
    for e in n.entries() {
        let vj = map_value(e.value(), ty_json(e.ty()));
        match e.name() {
            None => args.push(vj),
            Some(name) => props.push(json!([name.value(), vj])),
        }
    }
    let children: Vec<Value> = n
        .children()
        .map(|d| d.nodes().iter().map(map_node).collect())
        .unwrap_or_default();
    json!({
        "name": n.name().value(),
        "type": ty_json(n.ty()),
        "args": args,
        "props": props,
        "children": children,
    })
}

fn map_doc(d: &KdlDocument) -> Value {
    Value::Array(d.nodes().iter().map(map_node).collect())
}

fn main() {
    let corpus = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "conformance/corpus".into());

    // ---- positive: parse, map to neutral JSON, compare to expected ----
    let mut pass = 0usize;
    let mut fail = 0usize;
    let mut diffs: Vec<String> = Vec::new();
    let mut inputs: Vec<_> = fs::read_dir(format!("{corpus}/input"))
        .expect("corpus/input")
        .map(|e| e.unwrap().path())
        .collect();
    inputs.sort();
    for p in &inputs {
        let name = p.file_stem().unwrap().to_str().unwrap();
        let src = fs::read_to_string(p).unwrap();
        let expected: Value =
            serde_json::from_str(&fs::read_to_string(format!("{corpus}/expected/{name}.json")).unwrap())
                .unwrap();
        match src.parse::<KdlDocument>() {
            Ok(doc) => {
                let got = map_doc(&doc);
                if got == expected {
                    pass += 1;
                } else {
                    fail += 1;
                    if diffs.len() < 8 {
                        diffs.push(format!("  {name}: GOT {got}\n         EXP {expected}"));
                    }
                }
            }
            Err(e) => {
                fail += 1;
                if diffs.len() < 8 {
                    diffs.push(format!("  {name}: PARSE ERROR {e}"));
                }
            }
        }
    }

    // ---- negative: must reject ----
    let mut npass = 0usize;
    let mut nfail = 0usize;
    let mut ndiffs: Vec<String> = Vec::new();
    if let Ok(rd) = fs::read_dir(format!("{corpus}/negative/input")) {
        let mut negs: Vec<_> = rd.map(|e| e.unwrap().path()).collect();
        negs.sort();
        for p in &negs {
            let name = p.file_stem().unwrap().to_str().unwrap();
            let src = fs::read_to_string(p).unwrap();
            match src.parse::<KdlDocument>() {
                Err(_) => npass += 1,
                Ok(_) => {
                    nfail += 1;
                    if ndiffs.len() < 8 {
                        ndiffs.push(format!("  {name}: WRONGLY ACCEPTED"));
                    }
                }
            }
        }
    }

    println!("=== kdl-rs cross-impl certification ===");
    println!("positive (value): {pass} pass, {fail} fail");
    for d in &diffs {
        println!("{d}");
    }
    println!("negative: {npass} reject-ok, {nfail} wrongly-accepted");
    for d in &ndiffs {
        println!("{d}");
    }
    if fail > 0 || nfail > 0 {
        exit(1);
    }
    println!("ALL GREEN — corpus cross-certified against kdl-rs");
}
