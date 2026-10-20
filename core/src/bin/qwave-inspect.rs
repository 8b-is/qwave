// qwave-inspect — sovereign core CLI inspector (zero dependencies).
//
// Usage:
//   qwave-inspect egress <host>
//   qwave-inspect quanttern <valence> <arousal> <dominance> [threshold]
//   qwave-inspect badge <member_hash_hex> <tier:free|supporter|patron|team|oneoff> <since_epoch> <until_epoch> [now_epoch]
//   qwave-inspect scrub <url>

use std::env;
use std::fmt::Write;
use std::process::ExitCode;

use qwave_core::badge::{Badge, Channel, Tier, decide_channel};
use qwave_core::egress;
use qwave_core::quanttern::{DEFAULT_THRESHOLD, Vad, encode, pack_vad_byte};
use qwave_core::telemetry;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let Some(cmd) = args.first().map(String::as_str) else {
        print_usage();
        return ExitCode::from(2);
    };

    match cmd {
        "egress" => cmd_egress(&args[1..]),
        "quanttern" => cmd_quanttern(&args[1..]),
        "badge" => cmd_badge(&args[1..]),
        "scrub" => cmd_scrub(&args[1..]),
        "-h" | "--help" | "help" => {
            print_usage();
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("error: unknown subcommand `{other}`");
            print_usage();
            ExitCode::from(2)
        }
    }
}

fn cmd_egress(args: &[String]) -> ExitCode {
    let Some(host) = args.first() else {
        eprintln!("usage: qwave-inspect egress <host>");
        return ExitCode::from(2);
    };
    let permitted = egress::permits(host);
    println!(
        "{{\"host\":{},\"permitted\":{permitted}}}",
        json_string(host)
    );
    if permitted {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    }
}

/// Quote arbitrary input as a JSON string without changing its contents.
fn json_string(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len() + 2);
    encoded.push('"');
    for ch in value.chars() {
        match ch {
            '"' => encoded.push_str("\\\""),
            '\\' => encoded.push_str("\\\\"),
            '\n' => encoded.push_str("\\n"),
            '\r' => encoded.push_str("\\r"),
            '\t' => encoded.push_str("\\t"),
            ch if ch <= '\u{1f}' => {
                write!(encoded, "\\u{:04x}", ch as u32).expect("writing to a String cannot fail");
            }
            ch => encoded.push(ch),
        }
    }
    encoded.push('"');
    encoded
}

fn cmd_quanttern(args: &[String]) -> ExitCode {
    if args.len() < 3 {
        eprintln!("usage: qwave-inspect quanttern <valence> <arousal> <dominance> [threshold]");
        return ExitCode::from(2);
    }
    let Ok(v) = args[0].parse::<f32>() else {
        eprintln!("error: invalid valence `{}`", args[0]);
        return ExitCode::from(2);
    };
    let Ok(a) = args[1].parse::<f32>() else {
        eprintln!("error: invalid arousal `{}`", args[1]);
        return ExitCode::from(2);
    };
    let Ok(d) = args[2].parse::<f32>() else {
        eprintln!("error: invalid dominance `{}`", args[2]);
        return ExitCode::from(2);
    };
    let threshold = args
        .get(3)
        .and_then(|s| s.parse::<f32>().ok())
        .unwrap_or(DEFAULT_THRESHOLD);

    let vad = Vad::new(v, a, d);
    let code = encode(vad, threshold);
    let packed = pack_vad_byte(vad, threshold);
    let (wave_v, wave_a) = code.wave_fields();
    println!(
        "{{\"hex\":\"{}\",\"packed_byte\":\"0x{:02x}\",\"trits\":[{},{},{}],\"magnitude\":{},\"wave_valence\":\"{}/{}\",\"wave_arousal\":\"{}/{}\"}}",
        code.hex,
        packed,
        code.trits[0].raw(),
        code.trits[1].raw(),
        code.trits[2].raw(),
        code.magnitude(),
        wave_v.num,
        wave_v.den,
        wave_a.num,
        wave_a.den,
    );
    ExitCode::SUCCESS
}

fn cmd_badge(args: &[String]) -> ExitCode {
    if args.len() < 4 {
        eprintln!(
            "usage: qwave-inspect badge <member_hash_hex> <tier:free|supporter|patron|team|oneoff> <since_epoch> <until_epoch> [now_epoch]"
        );
        return ExitCode::from(2);
    };
    let raw_hash = args[0].trim_start_matches("0x").trim_start_matches("0X");
    let Ok(member_hash) = u64::from_str_radix(raw_hash, 16) else {
        eprintln!("error: invalid hex member_hash `{}`", args[0]);
        return ExitCode::from(2);
    };
    let tier = match args[1].to_ascii_lowercase().as_str() {
        "free" | "0" => Tier::Free,
        "supporter" | "1" => Tier::Supporter,
        "patron" | "2" => Tier::Patron,
        "team" | "3" => Tier::Team,
        "oneoff" | "one-off" | "4" => Tier::OneOff,
        other => {
            eprintln!("error: unknown tier `{other}`");
            return ExitCode::from(2);
        }
    };
    let Ok(since) = args[2].parse::<u64>() else {
        eprintln!("error: invalid since_epoch `{}`", args[2]);
        return ExitCode::from(2);
    };
    let Ok(until) = args[3].parse::<u64>() else {
        eprintln!("error: invalid until_epoch `{}`", args[3]);
        return ExitCode::from(2);
    };
    let now = args
        .get(4)
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(since);

    let badge = Badge::issue(member_hash, tier, since, until);
    let witness = badge.witness();
    let stable = decide_channel(Channel::Stable, Some(&badge), now).is_permitted();
    let beta = decide_channel(Channel::Beta, Some(&badge), now).is_permitted();
    let nightly = decide_channel(Channel::Nightly, Some(&badge), now).is_permitted();

    println!(
        "{{\"member_hash\":\"0x{:016x}\",\"tier\":{},\"monthly_euro_cents\":{},\"witness_seal\":\"0x{:016x}\",\"valid_witness\":{},\"channels\":{{\"stable\":{stable},\"beta\":{beta},\"nightly\":{nightly}}},\"notice\":\"{}\"}}",
        badge.member_hash,
        badge.tier as u8,
        badge.tier.monthly_euro_cents(),
        badge.witness_seal,
        witness.can_commit(),
        Channel::Nightly.notice(),
    );
    ExitCode::SUCCESS
}

fn cmd_scrub(args: &[String]) -> ExitCode {
    let Some(url) = args.first() else {
        eprintln!("usage: qwave-inspect scrub <url>");
        return ExitCode::from(2);
    };
    let scrubbed = telemetry::scrub_url(url);
    if scrubbed.is_empty() {
        eprintln!("error: could not scrub url");
        ExitCode::from(1)
    } else {
        println!("{scrubbed}");
        ExitCode::SUCCESS
    }
}

fn print_usage() {
    eprintln!(
        "qwave-inspect — sovereign core inspector\n\
         \n\
         Subcommands:\n\
         \x20 egress <host>\n\
         \x20 quanttern <valence> <arousal> <dominance> [threshold]\n\
         \x20 badge <member_hash_hex> <tier> <since_epoch> <until_epoch> [now_epoch]\n\
         \x20 scrub <url>"
    );
}

#[cfg(test)]
mod tests {
    use super::json_string;

    #[test]
    fn json_strings_escape_quotes_backslashes_and_control_characters() {
        assert_eq!(
            json_string("a\"\\\n\r\t\u{0}\u{8}\u{c}\u{1f}"),
            "\"a\\\"\\\\\\n\\r\\t\\u0000\\u0008\\u000c\\u001f\""
        );
    }

    #[test]
    fn json_strings_preserve_unicode_and_empty_input() {
        assert_eq!(json_string("東京.example"), "\"東京.example\"");
        assert_eq!(json_string(""), "\"\"");
    }
}
