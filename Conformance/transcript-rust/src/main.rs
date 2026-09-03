//! Differential-conformance harness: the hegel-rust mirror of
//! ../transcript-swift. Same seed, same settings, same draw sequence with
//! identical arguments — the transcripts must match byte for byte. One
//! program per invocation: `transcript-rust <program>`; an unknown name
//! exits 2.

use hegel::generators as gs;
use hegel::stateful::{Rule, StateMachine};
use hegel::{Hegel, Settings, TestCase, Verbosity};

fn settings(cases: u64) -> Settings {
    Settings::new()
        .test_cases(cases)
        .seed(Some(42))
        .derandomize(true)
        .database(None)
        .verbosity(Verbosity::Quiet)
        .stateful_step_count(6)
}

fn run(cases: u64, f: impl FnMut(TestCase)) {
    Hegel::new(f).settings(settings(cases)).run();
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn list<T: std::fmt::Display>(xs: &[T]) -> String {
    let parts: Vec<String> = xs.iter().map(|x| x.to_string()).collect();
    format!("[{}]", parts.join(","))
}

fn primitives() {
    run(32, |tc| {
        let a = tc.draw(gs::integers::<i64>().min_value(0).max_value(1000));
        let b = tc.draw(gs::integers::<i64>());
        let c = tc.draw(gs::booleans());
        let d = tc.draw(gs::floats::<f64>().min_value(0.0).max_value(1.0));
        let e = tc.draw(gs::binary().max_size(16));
        println!("case a={a} b={b} c={c} d={:016x} e={}", d.to_bits(), hex(&e));
    });
}

fn bigints() {
    run(32, |tc| {
        let f = tc.draw(gs::integers::<u64>());
        println!("case f={f}");
    });
}

fn text() {
    run(32, |tc| {
        let t = tc.draw(gs::text().max_size(8));
        println!("case t={}", hex(t.as_bytes()));
    });
}

fn strings() {
    run(32, |tc| {
        let a = tc.draw(gs::text().max_size(8).codec("ascii"));
        let r = tc.draw(gs::from_regex("[a-z]{1,4}").fullmatch(true));
        let e = tc.draw(gs::emails());
        println!(
            "case a={} r={} e={}",
            hex(a.as_bytes()),
            hex(r.as_bytes()),
            hex(e.as_bytes())
        );
    });
}

fn lists() {
    run(32, |tc| {
        let l = tc.draw(gs::vecs(gs::integers::<i64>().min_value(0).max_value(9)).max_size(4));
        let m = tc.draw(gs::vecs(gs::booleans()).min_size(1).max_size(3));
        println!("case l={} m={}", list(&l), list(&m));
    });
}

/// The counter; `reject` gives reset an assumption so a selected rule can
/// be rejected.
struct Counter {
    n: i64,
    reject: bool,
}

fn add(m: &mut Counter, tc: TestCase) {
    let k = tc.draw(gs::integers::<i64>().min_value(1).max_value(9));
    m.n += k;
    println!("step add {k} -> {}", m.n);
}

fn reset(m: &mut Counter, tc: TestCase) {
    if m.reject && m.n == 0 {
        println!("step reset rejected");
        tc.assume(false);
    }
    m.n = 0;
    println!("step reset -> 0");
}

fn non_neg(m: &mut Counter, _: TestCase) {
    assert!(m.n >= 0);
}

impl StateMachine for Counter {
    fn rules(&self) -> Vec<Rule<Self>> {
        vec![Rule::new("RuleAdd", add), Rule::new("RuleReset", reset)]
    }
    fn invariants(&self) -> Vec<Rule<Self>> {
        vec![Rule::new("InvariantNonNeg", non_neg)]
    }
}

fn stateful(reject: bool) {
    run(8, |tc| {
        println!("case");
        hegel::stateful::run(Counter { n: 0, reject }, tc);
    });
}

fn main() {
    let program = std::env::args().nth(1).unwrap_or_default();
    match program.as_str() {
        "primitives" => primitives(),
        "bigints" => bigints(),
        "text" => text(),
        "strings" => strings(),
        "lists" => lists(),
        "stateful" => stateful(false),
        "stateful-reject" => stateful(true),
        _ => {
            eprintln!("transcript-rust: no program named '{program}'");
            std::process::exit(2);
        }
    }
}
