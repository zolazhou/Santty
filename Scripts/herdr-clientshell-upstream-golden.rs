// Include as a #[cfg(test)] module in the pinned Herdr crate, not in Santty.
// Uses herdrdev/herdr 2563803dca97c040beaf3dc3acdcb5a3221b4238 (Apache-2.0).
// Unlike herdr-clientshell-golden.rs, these are actual upstream types and codecs.
use crate::protocol::{self, CellData, PaneSurfaceFrame, PaneSurfacePatch, PaneSurfacePatchRow, ServerMessage};
use serde_json::{json, Value};

fn cell(symbol: &str) -> CellData {
    CellData { symbol: symbol.into(), fg: 0, bg: 0, modifier: 0, skip: false, hyperlink: None }
}

fn record(records: &mut Vec<Value>, decoder: &mut protocol::surface_reuse::Decoder,
          name: &str, message: ServerMessage, expected: &PaneSurfaceFrame) {
    let bytes = bincode::serde::encode_to_vec(&message, bincode::config::standard()).unwrap();
    let decoded = decoder.decode(message).unwrap();
    if let ServerMessage::PaneSurface(surface) = &decoded {
        assert_eq!(surface, expected, "{name}");
    }
    records.push(json!({
        "name": name,
        "payload_hex": bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>(),
        "decoded": decoded,
        "expected_surface": expected,
    }));
}

#[test]
fn write_santty_mixed_surface_goldens() {
    let output = std::env::var("SANTTY_UPSTREAM_GOLDEN_OUTPUT")
        .expect("Set an explicit output path; this generator is never run as part of ordinary tests");
    let input: Value = serde_json::from_str(include_str!("../Santty/Tests/Fixtures/herdr-clientshell-reuse-v1.json")).unwrap();
    let mut base: PaneSurfaceFrame = serde_json::from_value(input["surface"].clone()).unwrap();
    let width = 80usize;
    let height = 24usize;
    base.projection_revision = 251;
    base.surface_revision = 65536;
    base.frame.width = width as u16;
    base.frame.height = height as u16;
    base.frame.cells = (0..height).flat_map(|y| vec![cell(&char::from(b'a' + y as u8).to_string()); width]).collect();
    base.frame.cursor = None;
    base.panes[0].rect.width = width as u16;
    base.panes[0].rect.height = height as u16;
    base.panes[0].inner_rect = base.panes[0].rect;
    base.panes[0].pixel_width = width as u32 * 8;
    base.panes[0].pixel_height = height as u32 * 16;
    let mut decoder = protocol::surface_reuse::Decoder::new(true, true);
    let mut records = Vec::new();
    record(&mut records, &mut decoder, "full", ServerMessage::PaneSurface(base.clone()), &base);

    let patch = PaneSurfacePatch { boot_id: base.boot_id.clone(), projection_revision: base.projection_revision,
        base_surface_revision: base.surface_revision, surface_revision: base.surface_revision + 1,
        rows: vec![PaneSurfacePatchRow { x: 0, y: 0, cells: vec![cell("X")] }],
        panes: base.panes.clone(), cursor: None };
    base.frame.cells[0] = cell("X");
    base.surface_revision += 1;
    // Assets are delivery data, not a promise to resend pixels in every subsequent scene.
    base.graphics.assets.clear();
    record(&mut records, &mut decoder, "patch", ServerMessage::PaneSurfacePatch(patch), &base);

    let old_serial = base.surface_revision;
    base.surface_revision += 1;
    base.projection_revision += 1;
    let reuse = protocol::surface_reuse::message(old_serial, &mut base).unwrap().expect("reuse must fit");
    record(&mut records, &mut decoder, "reuse", reuse, &base);

    let previous = base.clone();
    base.frame.cells[2 * width + 5] = cell("Z");
    base.popup.as_mut().unwrap().frame.cells[0] = cell("Q");
    base.surface_revision += 1;
    base.projection_revision += 1;
    let mut full = ServerMessage::PaneSurface(base.clone());
    let delta = protocol::surface_delta::message(&previous, &mut full).unwrap().expect("sparse delta must beat full");
    record(&mut records, &mut decoder, "delta_popup", delta, &base);

    let previous = base.clone();
    base.frame.cells.rotate_left(width);
    base.frame.cells[(height - 1) * width..].fill(cell("R"));
    base.surface_revision += 1;
    let rows = base.frame.cells.chunks(width).enumerate().map(|(y, cells)|
        PaneSurfacePatchRow { x: 0, y: y as u16, cells: cells.to_vec() }).collect();
    let patch = PaneSurfacePatch { boot_id: base.boot_id.clone(), projection_revision: base.projection_revision,
        base_surface_revision: previous.surface_revision, surface_revision: base.surface_revision,
        rows, panes: base.panes.clone(), cursor: None };
    let scroll = protocol::surface_scroll::message(&previous, &patch).expect("scroll must beat row diff");
    record(&mut records, &mut decoder, "scroll", scroll, &base);

    let old_serial = base.surface_revision;
    base.surface_revision += 1;
    base.projection_revision += 1;
    let reuse = protocol::surface_reuse::message(old_serial, &mut base).unwrap().expect("final reuse must fit");
    record(&mut records, &mut decoder, "reuse_after_scroll", reuse, &base);
    let document = json!({
        "source_revision": "2563803dca97c040beaf3dc3acdcb5a3221b4238",
        "serializer": "upstream ServerMessage, bincode serde standard",
        "records": records,
    });
    std::fs::write(output, serde_json::to_vec_pretty(&document).unwrap()).unwrap();
}
