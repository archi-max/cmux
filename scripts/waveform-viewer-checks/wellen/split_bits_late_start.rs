// cmux regression test for wellen 0.25.7 (2026-11-01; run by check.sh): split 1-bit vars `valid [0]`, `valid [1]` merged into valid[1:0]
// must start each bit at its first value even when no bit changes at the first time-table entry.
use std::io::Write;

fn merged_changes(vcd: &str) -> Vec<(u64, String)> {
    let mut file = tempfile_path();
    std::fs::File::create(&file).unwrap().write_all(vcd.as_bytes()).unwrap();
    let mut wave = wellen::simple::read(&file).unwrap();
    let h = wave.hierarchy();
    let var = h.lookup_var(&["tb"], &"valid").expect("tb.valid");
    let signal = h[var].signal_ref();
    wave.load_signals(&[signal]);
    let times = wave.time_table().to_vec();
    let out = wave.get_signal(signal).unwrap().iter_changes()
        .map(|(t, v)| (times[t as usize], v.to_bit_string().unwrap())).collect();
    std::fs::remove_file(&mut file).ok();
    out
}

fn tempfile_path() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("wellen-split-{}-{:?}.vcd", std::process::id(), std::thread::current().id()))
}

const HEAD: &str = "$timescale 1ns $end\n$scope module tb $end\n$var wire 1 ! clk $end\n$var wire 1 \" valid [0] $end\n$var wire 1 # valid [1] $end\n$upscope $end\n$enddefinitions $end\n";

#[test]
fn split_bits_start_at_their_first_value_when_late() {
    // The clock alone at #0; the valid bits from #5 (x), then 1/0 at #35, then bit 1 at #42.
    let vcd = format!("{HEAD}#0\n0!\n#5\nx\"\nx#\n#35\n1\"\n0#\n#42\n1#\n");
    let got = merged_changes(&vcd);
    assert_eq!(got[0], (5, "xx".to_string()), "{got:?}");
    assert_eq!(got[1], (35, "01".to_string()), "{got:?}");
    assert_eq!(got[2], (42, "11".to_string()), "{got:?}");
}

#[test]
fn split_bits_with_values_at_the_first_time() {
    let vcd = format!("{HEAD}#0\n0!\nx\"\nx#\n#35\n1\"\n0#\n");
    let got = merged_changes(&vcd);
    assert_eq!(got[0], (0, "xx".to_string()), "{got:?}");
    assert_eq!(got[1], (35, "01".to_string()), "{got:?}");
}

#[test]
fn a_bit_that_starts_later_than_the_others_is_x_then_its_values() {
    // Bit 0 from #35, bit 1 only from #42 (no x written): x until then, then its own changes.
    let vcd = format!("{HEAD}#0\n0!\n#35\n0\"\n#42\n0#\n#50\n1#\n#60\n1\"\n");
    let got = merged_changes(&vcd);
    assert_eq!(got, vec![(35, "x0".to_string()), (42, "00".to_string()), (50, "10".to_string()), (60, "11".to_string())], "{got:?}");
}
