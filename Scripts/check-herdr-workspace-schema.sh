#!/bin/sh
# Validate a workspace document using unmodified, pinned upstream Rust modules.
# Defaults to Santty's synthetic fixture; pass a doc.get value to check a published document.
# Does not launch an App, connect to a core or read any user workspace.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture=${1:-"$root/Santty/Tests/Fixtures/herdr-workspace-v0.1.14.json"}
revision=2405bf388c568c3ed479f05b8e405ccfa44b3f2c
command -v git >/dev/null
command -v cargo >/dev/null
scratch=$(mktemp -d "${TMPDIR:-/tmp}/santty-herdr-schema.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git -c advice.detachedHead=false clone --quiet --depth 1 --branch v0.1.14 \
    https://github.com/herdrdev/herdr-app.git "$scratch/herdr-app"
[ "$(git -C "$scratch/herdr-app" rev-parse HEAD)" = "$revision" ] || {
    echo 'The upstream tag no longer matches the reviewed revision' >&2
    exit 1
}
mkdir -p "$scratch/parser/src"
cat > "$scratch/parser/Cargo.toml" <<'TOML'
[package]
name = "santty-herdr-schema-probe"
version = "0.0.0"
edition = "2024"

[dependencies]
serde = { version = "=1.0.229", features = ["derive"] }
serde_json = "=1.0.151"
TOML
cat > "$scratch/parser/src/main.rs" <<'RUST'
#![allow(dead_code)]
#[path = "../../herdr-app/src/layout.rs"] mod layout;
#[path = "../../herdr-app/src/model.rs"] mod model;
#[path = "../../herdr-app/src/mirror.rs"] mod mirror;

fn main() {
    let path = std::env::args().nth(1).expect("fixture path");
    let bytes = std::fs::read(path).unwrap();
    let expected: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    let document: mirror::Document = serde_json::from_slice(&bytes).unwrap();
    let mut model = model::Model::default();
    document.replace(&mut model, None);
    let terminals = model.all_addresses();
    let captured = serde_json::to_value(mirror::Document::capture(&model, None)).unwrap();
    // layout.rs stores weights as f32, so a document written with f64 weights keeps its structure
    // but re-serializes at f32 precision. Compare numbers with an f32-appropriate tolerance.
    fn same(left: &serde_json::Value, right: &serde_json::Value) -> bool {
        match (left, right) {
            (serde_json::Value::Number(a), serde_json::Value::Number(b)) => match (a.as_f64(), b.as_f64()) {
                (Some(a), Some(b)) => (a - b).abs() <= 1e-6 * a.abs().max(b.abs()).max(1.0),
                _ => a == b,
            },
            (serde_json::Value::Array(a), serde_json::Value::Array(b)) => {
                a.len() == b.len() && a.iter().zip(b).all(|(a, b)| same(a, b))
            }
            (serde_json::Value::Object(a), serde_json::Value::Object(b)) => {
                a.len() == b.len() && a.iter().all(|(k, v)| b.get(k).is_some_and(|w| same(v, w)))
            }
            _ => left == right,
        }
    }
    assert!(same(&captured, &expected), "structure changed: {captured} vs {expected}");
    let exact = captured == expected;
    println!(
        "PASS: upstream v0.1.14 Document -> Model -> Document; {} space(s), {} tab(s), {} terminal(s); {} structure",
        model.spaces.len(),
        model.tabs().count(),
        terminals.len(),
        if exact { "lossless" } else { "lossless (weights normalized to f32)" }
    );
}
RUST
CARGO_TARGET_DIR="$scratch/target" cargo run --quiet --manifest-path "$scratch/parser/Cargo.toml" -- "$fixture"
