//! Built-in Sovereign `.pdf` and `.tex` (LaTeX) Reader, Compiler & Spoken Narrator for Qwave.
//!
//! 100% pure Rust, zero external crates, and zero floating-point operations (`f32`/`f64` forbidden).
//! - Includes an embedded RFC 1950 (ZLIB) / RFC 1951 (DEFLATE) bitstream inflater for `/FlateDecode`
//!   PDF streams.
//! - Extracts structured Markdown, headings (for Qwave's Wave Index TOC), paragraphs, and
//!   spoken narration text from `.pdf` documents (supporting both TeX/OT1/T1 `[(...) -kern (...)] TJ`
//!   streams with ligature decoding and `/ToUnicode` CMap `<hex>` streams).
//! - Compiles `.tex` (LaTeX) manuscripts into Qwave Markdown + KaTeX math, expanding custom
//!   `\newcommand` / `\DeclareMathOperator` macros, converting `\section`/`\subsection`/`\paragraph`,
//!   `abstract`/`theorem`/`proposition`/`lemma`/`definition`/`remark`/`proof` environments,
//!   `tabular`/`longtable` tables, `itemize`/`enumerate` lists, and `thebibliography` citations.

use std::collections::BTreeMap;

/// Result of compiling a `.pdf` document into Qwave Markdown + spoken narration text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PdfDocumentReport {
    pub title: String,
    pub page_count: usize,
    pub extracted_streams: usize,
    pub word_count: usize,
    pub markdown: String,
    pub spoken_text: String,
}

/// Result of compiling a `.tex` (LaTeX) document into Qwave Markdown + spoken narration text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TexDocumentReport {
    pub title: String,
    pub author: String,
    pub date: String,
    pub section_count: usize,
    pub macro_count: usize,
    pub markdown: String,
    pub spoken_text: String,
}

// ============================================================================
// 1. Pure-Rust Zero-Dependency RFC 1950 (ZLIB) & RFC 1951 (DEFLATE) Inflater
// ============================================================================

struct BitReader<'a> {
    data: &'a [u8],
    byte_pos: usize,
    bit_buf: u32,
    bit_cnt: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_buf: 0,
            bit_cnt: 0,
        }
    }

    fn ensure_bits(&mut self, n: u8) -> bool {
        while self.bit_cnt < n {
            if self.byte_pos >= self.data.len() {
                return false;
            }
            self.bit_buf |= (self.data[self.byte_pos] as u32) << self.bit_cnt;
            self.byte_pos += 1;
            self.bit_cnt += 8;
        }
        true
    }

    fn read_bits(&mut self, n: u8) -> Option<u32> {
        if n == 0 {
            return Some(0);
        }
        if !self.ensure_bits(n) {
            return None;
        }
        let val = self.bit_buf & ((1u32 << n) - 1);
        self.bit_buf >>= n;
        self.bit_cnt -= n;
        Some(val)
    }

    fn align_byte(&mut self) {
        let drop_bits = self.bit_cnt & 7;
        self.bit_buf >>= drop_bits;
        self.bit_cnt -= drop_bits;
    }

    fn read_u16_le(&mut self) -> Option<u16> {
        let lo = self.read_bits(8)? as u16;
        let hi = self.read_bits(8)? as u16;
        Some(lo | (hi << 8))
    }
}

struct HuffmanTable {
    counts: [u16; 16],
    symbols: Vec<u16>,
    max_bits: u8,
}

impl HuffmanTable {
    fn from_lengths(lengths: &[u8]) -> Option<Self> {
        let mut counts = [0u16; 16];
        let mut max_bits = 0u8;
        for &len in lengths {
            if len > 15 {
                return None;
            }
            if len > 0 {
                counts[len as usize] += 1;
                if len > max_bits {
                    max_bits = len;
                }
            }
        }
        let mut offsets = [0u16; 16];
        let mut total = 0u16;
        for bits in 1..=15 {
            offsets[bits] = total;
            total += counts[bits];
        }
        let mut symbols = vec![0u16; total as usize];
        for (sym, &len) in lengths.iter().enumerate() {
            if len > 0 {
                let idx = offsets[len as usize] as usize;
                if idx < symbols.len() {
                    symbols[idx] = sym as u16;
                    offsets[len as usize] += 1;
                }
            }
        }
        Some(Self {
            counts,
            symbols,
            max_bits,
        })
    }

    fn decode(&self, reader: &mut BitReader<'_>) -> Option<u16> {
        let mut code: i32 = 0;
        let mut first: i32 = 0;
        let mut index: i32 = 0;
        for len in 1..=self.max_bits {
            code |= reader.read_bits(1)? as i32;
            let count = self.counts[len as usize] as i32;
            if code - count < first {
                let sym_idx = (index + (code - first)) as usize;
                return self.symbols.get(sym_idx).copied();
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        None
    }
}

fn fixed_huffman_tables() -> (HuffmanTable, HuffmanTable) {
    let mut lit_lengths = [0u8; 288];
    for i in 0..=143 {
        lit_lengths[i] = 8;
    }
    for i in 144..=255 {
        lit_lengths[i] = 9;
    }
    for i in 256..=279 {
        lit_lengths[i] = 7;
    }
    for i in 280..=287 {
        lit_lengths[i] = 8;
    }
    let dist_lengths = [5u8; 32];
    (
        HuffmanTable::from_lengths(&lit_lengths).unwrap(),
        HuffmanTable::from_lengths(&dist_lengths).unwrap(),
    )
}

/// Inflate raw RFC 1951 DEFLATE bitstream into `out` (capped at `max_out` bytes for safety).
pub fn deflate_decompress(data: &[u8], max_out: usize) -> Option<Vec<u8>> {
    const LEN_BASE: [u16; 29] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258,
    ];
    const LEN_EXTRA: [u8; 29] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ];
    const DIST_BASE: [u16; 30] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
        2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
    ];
    const DIST_EXTRA: [u8; 30] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
        13, 13,
    ];
    const CL_ORDER: [usize; 19] = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ];

    let mut reader = BitReader::new(data);
    let mut out = Vec::with_capacity(data.len().saturating_mul(2).min(65536));

    loop {
        let bfinal = reader.read_bits(1)?;
        let btype = reader.read_bits(2)?;
        match btype {
            0 => {
                reader.align_byte();
                let len = reader.read_u16_le()? as usize;
                let _nlen = reader.read_u16_le()?;
                if out.len().saturating_add(len) > max_out {
                    return None;
                }
                for _ in 0..len {
                    let b = reader.read_bits(8)? as u8;
                    out.push(b);
                }
            }
            1 | 2 => {
                let (lit_table, dist_table) = if btype == 1 {
                    fixed_huffman_tables()
                } else {
                    let hlit = (reader.read_bits(5)? as usize) + 257;
                    let hdist = (reader.read_bits(5)? as usize) + 1;
                    let hclen = (reader.read_bits(4)? as usize) + 4;
                    let mut cl_lengths = [0u8; 19];
                    for i in 0..hclen {
                        cl_lengths[CL_ORDER[i]] = reader.read_bits(3)? as u8;
                    }
                    let cl_table = HuffmanTable::from_lengths(&cl_lengths)?;
                    let total_codes = hlit + hdist;
                    let mut lengths = Vec::with_capacity(total_codes);
                    while lengths.len() < total_codes {
                        let sym = cl_table.decode(&mut reader)?;
                        match sym {
                            0..=15 => lengths.push(sym as u8),
                            16 => {
                                let prev = *lengths.last()?;
                                let rep = (reader.read_bits(2)? as usize) + 3;
                                for _ in 0..rep {
                                    if lengths.len() < total_codes {
                                        lengths.push(prev);
                                    }
                                }
                            }
                            17 => {
                                let rep = (reader.read_bits(3)? as usize) + 3;
                                for _ in 0..rep {
                                    if lengths.len() < total_codes {
                                        lengths.push(0);
                                    }
                                }
                            }
                            18 => {
                                let rep = (reader.read_bits(7)? as usize) + 11;
                                for _ in 0..rep {
                                    if lengths.len() < total_codes {
                                        lengths.push(0);
                                    }
                                }
                            }
                            _ => return None,
                        }
                    }
                    let lt = HuffmanTable::from_lengths(&lengths[..hlit])?;
                    let dt = HuffmanTable::from_lengths(&lengths[hlit..total_codes])?;
                    (lt, dt)
                };

                loop {
                    let sym = lit_table.decode(&mut reader)?;
                    if sym < 256 {
                        if out.len() >= max_out {
                            return None;
                        }
                        out.push(sym as u8);
                    } else if sym == 256 {
                        break;
                    } else {
                        let len_idx = (sym as usize).checked_sub(257)?;
                        if len_idx >= LEN_BASE.len() {
                            return None;
                        }
                        let extra_len = reader.read_bits(LEN_EXTRA[len_idx])? as usize;
                        let length = (LEN_BASE[len_idx] as usize) + extra_len;

                        let dist_sym = dist_table.decode(&mut reader)? as usize;
                        if dist_sym >= DIST_BASE.len() {
                            return None;
                        }
                        let extra_dist = reader.read_bits(DIST_EXTRA[dist_sym])? as usize;
                        let distance = (DIST_BASE[dist_sym] as usize) + extra_dist;
                        if distance == 0 || distance > out.len() {
                            return None;
                        }
                        if out.len().saturating_add(length) > max_out {
                            return None;
                        }
                        for _ in 0..length {
                            let b = out[out.len() - distance];
                            out.push(b);
                        }
                    }
                }
            }
            _ => return None,
        }
        if bfinal == 1 {
            break;
        }
    }
    Some(out)
}

/// Decompress a `/FlateDecode` PDF stream (handles both 2-byte RFC 1950 ZLIB header and raw DEFLATE).
pub fn zlib_or_deflate_decompress(stream_bytes: &[u8]) -> Option<Vec<u8>> {
    let mut trimmed = stream_bytes;
    while let Some(&first) = trimmed.first() {
        if first == b'\r' || first == b'\n' {
            trimmed = &trimmed[1..];
        } else {
            break;
        }
    }
    while let Some(&last) = trimmed.last() {
        if last == b'\r' || last == b'\n' || last == b' ' {
            trimmed = &trimmed[..trimmed.len() - 1];
        } else {
            break;
        }
    }
    if trimmed.len() < 2 {
        return None;
    }
    let max_out = 8 * 1024 * 1024;
    // Check RFC 1950 ZLIB header: CMF & 0x0F == 8 (DEFLATE) and (CMF*256 + FLG) % 31 == 0
    let cmf = trimmed[0] as u16;
    let flg = trimmed[1] as u16;
    if (cmf & 0x0f) == 8 && ((cmf << 8) | flg) % 31 == 0 {
        let fdict = (flg & 0x20) != 0;
        let hdr_len = if fdict { 6 } else { 2 };
        if trimmed.len() > hdr_len {
            if let Some(dec) = deflate_decompress(&trimmed[hdr_len..], max_out) {
                return Some(dec);
            }
        }
    }
    deflate_decompress(trimmed, max_out)
}

// ============================================================================
// 2. Built-in Sovereign PDF Reader & Structure Extractor
// ============================================================================

fn parse_milli_int(token: &str) -> Option<i64> {
    let s = token.trim();
    if s.is_empty() {
        return None;
    }
    let (neg, rest) = if let Some(r) = s.strip_prefix('-') {
        (true, r)
    } else if let Some(r) = s.strip_prefix('+') {
        (false, r)
    } else {
        (false, s)
    };
    if rest.is_empty() || !rest.bytes().all(|b| b.is_ascii_digit() || b == b'.') {
        return None;
    }
    let (int_part, frac_part) = match rest.split_once('.') {
        Some((i, f)) => (i, f),
        None => (rest, ""),
    };
    let whole = if int_part.is_empty() {
        0i64
    } else {
        int_part.parse::<i64>().ok()?
    };
    let mut frac = 0i64;
    let mut scale = 100i64;
    for b in frac_part.bytes().take(3) {
        if b.is_ascii_digit() {
            frac += ((b - b'0') as i64) * scale;
            scale /= 10;
        }
    }
    let val = whole.saturating_mul(1000).saturating_add(frac);
    Some(if neg { -val } else { val })
}

fn parse_hex_u16(hex: &str) -> Option<u16> {
    let clean: String = hex.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if clean.is_empty() || clean.len() > 4 {
        return None;
    }
    u16::from_str_radix(&clean, 16).ok()
}

fn decode_hex_utf16be_or_latin1(hex: &str) -> String {
    let clean: Vec<u8> = hex
        .bytes()
        .filter_map(|b| match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        })
        .collect();
    let mut bytes = Vec::with_capacity(clean.len() / 2);
    let mut i = 0;
    while i + 1 < clean.len() {
        bytes.push((clean[i] << 4) | clean[i + 1]);
        i += 2;
    }
    if bytes.len() >= 2 && bytes.len() % 2 == 0 {
        let mut u16s = Vec::with_capacity(bytes.len() / 2);
        for chunk in bytes.chunks_exact(2) {
            u16s.push(u16::from_be_bytes([chunk[0], chunk[1]]));
        }
        if let Ok(s) = String::from_utf16(&u16s) {
            if !s.is_empty() {
                return s;
            }
        }
    }
    bytes.into_iter().map(|b| b as char).collect()
}

/// Extract `<src> <dst>` and `<start> <end> <dst>` entries from a `/ToUnicode` CMap stream.
fn parse_tounicode_cmap(stream_str: &str, cmap: &mut BTreeMap<u16, String>) {
    // 1. beginbfchar ... endbfchar
    let mut rest = stream_str;
    while let Some(start_idx) = rest.find("beginbfchar") {
        let after = &rest[start_idx + "beginbfchar".len()..];
        let Some(end_idx) = after.find("endbfchar") else {
            break;
        };
        let block = &after[..end_idx];
        for line in block.lines() {
            let mut tokens = Vec::new();
            let mut cur = line.trim();
            while let Some(open) = cur.find('<') {
                let tail = &cur[open + 1..];
                if let Some(close) = tail.find('>') {
                    tokens.push(&tail[..close]);
                    cur = &tail[close + 1..];
                } else {
                    break;
                }
            }
            if tokens.len() >= 2 {
                if let Some(src_code) = parse_hex_u16(tokens[0]) {
                    let dst_str = decode_hex_utf16be_or_latin1(tokens[1]);
                    if !dst_str.is_empty() {
                        cmap.insert(src_code, dst_str);
                    }
                }
            }
        }
        rest = &after[end_idx + "endbfchar".len()..];
    }

    // 2. beginbfrange ... endbfrange
    let mut rest_r = stream_str;
    while let Some(start_idx) = rest_r.find("beginbfrange") {
        let after = &rest_r[start_idx + "beginbfrange".len()..];
        let Some(end_idx) = after.find("endbfrange") else {
            break;
        };
        let block = &after[..end_idx];
        for line in block.lines() {
            let mut tokens = Vec::new();
            let mut cur = line.trim();
            while let Some(open) = cur.find('<') {
                let tail = &cur[open + 1..];
                if let Some(close) = tail.find('>') {
                    tokens.push(&tail[..close]);
                    cur = &tail[close + 1..];
                } else {
                    break;
                }
            }
            if tokens.len() >= 3 {
                if let (Some(lo), Some(hi), Some(base_dst)) = (
                    parse_hex_u16(tokens[0]),
                    parse_hex_u16(tokens[1]),
                    parse_hex_u16(tokens[2]),
                ) {
                    if hi >= lo && (hi - lo) <= 512 {
                        for offset in 0..=(hi - lo) {
                            if let Some(ch) = char::from_u32((base_dst as u32) + (offset as u32)) {
                                cmap.insert(lo + offset, ch.to_string());
                            }
                        }
                    }
                }
            }
        }
        rest_r = &after[end_idx + "endbfrange".len()..];
    }
}

fn map_pdf_literal_byte(b: u8, out: &mut String) {
    match b {
        0x00 => out.push('−'),
        0x01 => out.push('·'),
        0x02 => out.push('×'),
        0x03 => out.push('∗'),
        0x0b => out.push_str("ff"),
        0x0c => out.push_str("fi"),
        0x0d => out.push_str("fl"),
        0x0e => out.push_str("ffi"),
        0x0f => out.push_str("ffl"),
        0x10 => out.push('ı'),
        0x12 => out.push('`'),
        0x13 => out.push('\''),
        0x19 => out.push('ß'),
        0x1a => out.push_str("æ"),
        0x1b => out.push_str("œ"),
        0x1c => out.push('ø'),
        0x1d => out.push_str("Æ"),
        0x1e => out.push_str("Œ"),
        0x1f => out.push('Ø'),
        0x20..=0x7a => out.push(b as char),
        0x7b => out.push('–'),
        0x7c => out.push('—'),
        0x7d => out.push('"'),
        0x7e => out.push('~'),
        0x80..=0xff => {
            // Common Windows-1252 / PDFDocEncoding smart punctuation
            match b {
                0x85 => out.push('…'),
                0x91 => out.push('‘'),
                0x92 => out.push('’'),
                0x93 => out.push('“'),
                0x94 => out.push('”'),
                0x95 => out.push('•'),
                0x96 => out.push('–'),
                0x97 => out.push('—'),
                other => out.push(other as char),
            }
        }
        _ => {}
    }
}

/// Parse a PDF literal string starting right after `(` and return `(decoded_string, bytes_consumed_including_closing_paren)`.
fn parse_pdf_paren_string(bytes: &[u8]) -> (String, usize) {
    let mut out = String::new();
    let mut i = 0usize;
    let mut depth = 1i32;

    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' {
            i += 1;
            if i >= bytes.len() {
                break;
            }
            let esc = bytes[i];
            match esc {
                b'n' => {
                    out.push('\n');
                    i += 1;
                }
                b'r' => {
                    out.push('\r');
                    i += 1;
                }
                b't' => {
                    out.push('\t');
                    i += 1;
                }
                b'b' | b'f' => {
                    i += 1;
                }
                b'(' => {
                    out.push('(');
                    i += 1;
                }
                b')' => {
                    out.push(')');
                    i += 1;
                }
                b'\\' => {
                    out.push('\\');
                    i += 1;
                }
                b'\r' => {
                    i += 1;
                    if i < bytes.len() && bytes[i] == b'\n' {
                        i += 1;
                    }
                }
                b'\n' => {
                    i += 1;
                }
                b'0'..=b'7' => {
                    let mut oct: u8 = esc - b'0';
                    i += 1;
                    for _ in 0..2 {
                        if i < bytes.len() && (b'0'..=b'7').contains(&bytes[i]) {
                            oct = oct.wrapping_mul(8).wrapping_add(bytes[i] - b'0');
                            i += 1;
                        } else {
                            break;
                        }
                    }
                    map_pdf_literal_byte(oct, &mut out);
                }
                other => {
                    map_pdf_literal_byte(other, &mut out);
                    i += 1;
                }
            }
        } else if b == b'(' {
            depth += 1;
            out.push('(');
            i += 1;
        } else if b == b')' {
            depth -= 1;
            i += 1;
            if depth == 0 {
                break;
            }
            out.push(')');
        } else {
            map_pdf_literal_byte(b, &mut out);
            i += 1;
        }
    }
    (out, i)
}

/// Parse a PDF `<hex>` string starting right after `<` and return `(decoded_string, bytes_consumed)`.
fn parse_pdf_hex_string(bytes: &[u8], cmap: &BTreeMap<u16, String>) -> (String, usize) {
    let mut hex_digits = Vec::new();
    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        i += 1;
        if b == b'>' {
            break;
        }
        let nib = match b {
            b'0'..=b'9' => Some(b - b'0'),
            b'a'..=b'f' => Some(b - b'a' + 10),
            b'A'..=b'F' => Some(b - b'A' + 10),
            _ => None,
        };
        if let Some(n) = nib {
            hex_digits.push(n);
        }
    }
    if hex_digits.len() % 2 == 1 {
        hex_digits.push(0);
    }
    let mut raw_bytes = Vec::with_capacity(hex_digits.len() / 2);
    for pair in hex_digits.chunks_exact(2) {
        raw_bytes.push((pair[0] << 4) | pair[1]);
    }

    let mut out = String::new();
    if !cmap.is_empty() && raw_bytes.len() % 2 == 0 {
        let mut all_mapped = true;
        let mut mapped_str = String::new();
        for chunk in raw_bytes.chunks_exact(2) {
            let code = u16::from_be_bytes([chunk[0], chunk[1]]);
            if let Some(s) = cmap.get(&code) {
                mapped_str.push_str(s);
            } else if (0x20..=0x7e).contains(&code) {
                mapped_str.push((code as u8) as char);
            } else {
                all_mapped = false;
                break;
            }
        }
        if all_mapped && !mapped_str.is_empty() {
            return (mapped_str, i);
        }
    }
    if !cmap.is_empty() {
        for &b in &raw_bytes {
            if let Some(s) = cmap.get(&(b as u16)) {
                out.push_str(s);
            } else {
                map_pdf_literal_byte(b, &mut out);
            }
        }
        return (out, i);
    }
    for &b in &raw_bytes {
        map_pdf_literal_byte(b, &mut out);
    }
    (out, i)
}

/// Parse a `[...]` array for `TJ` starting right after `[` and return `(decoded_string, bytes_consumed)`.
fn parse_pdf_tj_array(bytes: &[u8], cmap: &BTreeMap<u16, String>) -> (String, usize) {
    let mut out = String::new();
    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b']' {
            i += 1;
            break;
        } else if b == b'(' {
            let (s, used) = parse_pdf_paren_string(&bytes[i + 1..]);
            out.push_str(&s);
            i += 1 + used;
        } else if b == b'<' && i + 1 < bytes.len() && bytes[i + 1] != b'<' {
            let (s, used) = parse_pdf_hex_string(&bytes[i + 1..], cmap);
            out.push_str(&s);
            i += 1 + used;
        } else if b == b'-' || b == b'+' || b.is_ascii_digit() || b == b'.' {
            let start = i;
            i += 1;
            while i < bytes.len()
                && (bytes[i].is_ascii_digit() || bytes[i] == b'.' || bytes[i] == b'-')
            {
                i += 1;
            }
            if let Ok(num_str) = std::str::from_utf8(&bytes[start..i]) {
                if let Some(milli) = parse_milli_int(num_str) {
                    // Kerning <= -140 units (-140_000 milli-units) represents an inter-word space
                    if milli <= -140_000 && !out.ends_with(' ') && !out.is_empty() {
                        out.push(' ');
                    }
                }
            }
        } else {
            i += 1;
        }
    }
    (out, i)
}

#[derive(Debug, Clone)]
struct PdfTextLine {
    font_milli_pt: i64,
    text: String,
    new_para_before: bool,
}

/// Extract structured lines from a single decompressed PDF content stream.
fn extract_lines_from_pdf_content_stream(
    bytes: &[u8],
    cmap: &BTreeMap<u16, String>,
) -> Vec<PdfTextLine> {
    let mut lines: Vec<PdfTextLine> = Vec::new();
    let mut cur_line = String::new();
    let mut cur_font_milli: i64 = 11_000;
    let mut line_font_milli: i64 = 11_000;
    let mut next_is_new_para = false;
    let mut last_tm_y_milli: Option<i64> = None;
    let mut num_stack: Vec<i64> = Vec::with_capacity(8);

    let flush_line = |lines: &mut Vec<PdfTextLine>,
                      cur_line: &mut String,
                      line_font_milli: i64,
                      next_is_new_para: &mut bool| {
        let trimmed = cur_line.trim();
        if !trimmed.is_empty() {
            lines.push(PdfTextLine {
                font_milli_pt: line_font_milli,
                text: trimmed.to_string(),
                new_para_before: *next_is_new_para,
            });
            *next_is_new_para = false;
        }
        cur_line.clear();
    };

    let mut i = 0usize;
    while i < bytes.len() {
        let b = bytes[i];
        if b.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if b == b'%' {
            while i < bytes.len() && bytes[i] != b'\n' && bytes[i] != b'\r' {
                i += 1;
            }
            continue;
        }
        if b == b'(' {
            let (s, used) = parse_pdf_paren_string(&bytes[i + 1..]);
            i += 1 + used;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i + 1 < bytes.len() && bytes[i] == b'T' && bytes[i + 1] == b'j' {
                if cur_line.is_empty() {
                    line_font_milli = cur_font_milli;
                }
                cur_line.push_str(&s);
                i += 2;
            } else if i < bytes.len() && (bytes[i] == b'\'' || bytes[i] == b'"') {
                flush_line(
                    &mut lines,
                    &mut cur_line,
                    line_font_milli,
                    &mut next_is_new_para,
                );
                line_font_milli = cur_font_milli;
                cur_line.push_str(&s);
                i += 1;
            }
            num_stack.clear();
            continue;
        }
        if b == b'<' && i + 1 < bytes.len() && bytes[i + 1] != b'<' {
            let (s, used) = parse_pdf_hex_string(&bytes[i + 1..], cmap);
            i += 1 + used;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i + 1 < bytes.len() && bytes[i] == b'T' && bytes[i + 1] == b'j' {
                if cur_line.is_empty() {
                    line_font_milli = cur_font_milli;
                }
                cur_line.push_str(&s);
                i += 2;
            }
            num_stack.clear();
            continue;
        }
        if b == b'[' {
            let (s, used) = parse_pdf_tj_array(&bytes[i + 1..], cmap);
            i += 1 + used;
            while i < bytes.len() && bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            if i + 1 < bytes.len() && bytes[i] == b'T' && bytes[i + 1] == b'J' {
                if cur_line.is_empty() {
                    line_font_milli = cur_font_milli;
                }
                cur_line.push_str(&s);
                i += 2;
            }
            num_stack.clear();
            continue;
        }
        if b == b'<' && i + 1 < bytes.len() && bytes[i + 1] == b'<' {
            i += 2;
            continue;
        }
        if b == b'>' && i + 1 < bytes.len() && bytes[i + 1] == b'>' {
            i += 2;
            continue;
        }

        // Tokenize operator or number
        let start = i;
        while i < bytes.len()
            && !bytes[i].is_ascii_whitespace()
            && !matches!(bytes[i], b'(' | b')' | b'[' | b']' | b'<' | b'>' | b'%')
        {
            if i > start && bytes[i] == b'/' {
                break;
            }
            i += 1;
        }
        let tok = match std::str::from_utf8(&bytes[start..i]) {
            Ok(s) => s,
            Err(_) => continue,
        };

        if let Some(milli) = parse_milli_int(tok) {
            if num_stack.len() >= 8 {
                num_stack.remove(0);
            }
            num_stack.push(milli);
            continue;
        }

        match tok {
            "BT" => {
                num_stack.clear();
            }
            "ET" => {
                flush_line(
                    &mut lines,
                    &mut cur_line,
                    line_font_milli,
                    &mut next_is_new_para,
                );
                num_stack.clear();
            }
            "Tf" => {
                if let Some(&sz) = num_stack.last() {
                    if sz > 0 {
                        cur_font_milli = sz;
                    }
                }
                num_stack.clear();
            }
            "Td" | "TD" => {
                if num_stack.len() >= 2 {
                    let ty = num_stack[num_stack.len() - 1];
                    let tx = num_stack[num_stack.len() - 2];
                    if ty <= -6_000 || ty >= 6_000 {
                        flush_line(
                            &mut lines,
                            &mut cur_line,
                            line_font_milli,
                            &mut next_is_new_para,
                        );
                        // Paragraph break on vertical gap > 20pt OR first-line paragraph indent (tx >= 10pt)
                        if ty <= -20_500 || (ty <= -11_000 && tx >= 10_000) {
                            next_is_new_para = true;
                        }
                    } else if tx >= 150_000 && !cur_line.ends_with(' ') && !cur_line.is_empty() {
                        cur_line.push(' ');
                    }
                }
                num_stack.clear();
            }
            "Tm" => {
                if num_stack.len() >= 6 {
                    let y = num_stack[num_stack.len() - 1];
                    if let Some(prev_y) = last_tm_y_milli {
                        let dy = (y - prev_y).abs();
                        if dy >= 6_000 {
                            flush_line(
                                &mut lines,
                                &mut cur_line,
                                line_font_milli,
                                &mut next_is_new_para,
                            );
                            if dy >= 21_000 {
                                next_is_new_para = true;
                            }
                        } else if !cur_line.is_empty() && !cur_line.ends_with(' ') {
                            cur_line.push(' ');
                        }
                    }
                    last_tm_y_milli = Some(y);
                }
                num_stack.clear();
            }
            "T*" => {
                flush_line(
                    &mut lines,
                    &mut cur_line,
                    line_font_milli,
                    &mut next_is_new_para,
                );
                num_stack.clear();
            }
            _ => {
                if !tok.starts_with('/') {
                    num_stack.clear();
                }
            }
        }
    }

    flush_line(
        &mut lines,
        &mut cur_line,
        line_font_milli,
        &mut next_is_new_para,
    );
    lines
}

fn is_likely_section_heading(line: &str, font_milli: i64) -> Option<u8> {
    let t = line.trim();
    if t.len() < 3 || t.len() > 110 {
        return None;
    }
    if t.chars().all(|c| c.is_ascii_digit() || c.is_whitespace()) {
        return None;
    }
    if font_milli >= 16_500 {
        return Some(1);
    }
    if font_milli >= 13_400 {
        return Some(2);
    }
    let lower = t.to_ascii_lowercase();
    if matches!(
        lower.as_str(),
        "abstract" | "introduction" | "conclusion" | "references" | "bibliography" | "appendix"
    ) {
        return Some(2);
    }
    // Check numbered section like "1 Introduction" or "2.1 Formal Model" with larger/bold font
    if font_milli >= 11_800 {
        let mut parts = t.splitn(2, ' ');
        if let (Some(num_tok), Some(rest_title)) = (parts.next(), parts.next()) {
            let valid_num = num_tok
                .bytes()
                .all(|b| b.is_ascii_digit() || b == b'.')
                && num_tok.bytes().any(|b| b.is_ascii_digit());
            let starts_upper = rest_title
                .chars()
                .next()
                .map(|c| c.is_ascii_uppercase())
                .unwrap_or(false);
            if valid_num && starts_upper && !t.ends_with('.') {
                return Some(if num_tok.contains('.') { 3 } else { 2 });
            }
        }
    }
    None
}

/// Extract structured Qwave Markdown + spoken narration from raw `.pdf` bytes.
pub fn extract_pdf_to_markdown(
    pdf_bytes: &[u8],
    file_name: &str,
    asset_url: Option<&str>,
) -> PdfDocumentReport {
    let mut decompressed_streams: Vec<(String, Vec<u8>)> = Vec::new();
    let mut cmap: BTreeMap<u16, String> = BTreeMap::new();

    // Scan all `stream` ... `endstream` blocks
    let mut pos = 0usize;
    while pos + 16 < pdf_bytes.len() {
        let Some(rel_s) = find_subslice(&pdf_bytes[pos..], b"stream") else {
            break;
        };
        let s_idx = pos + rel_s;
        // Verify `stream` is preceded by `>>` or whitespace
        let hdr_start = s_idx.saturating_sub(260);
        let dict_header = String::from_utf8_lossy(&pdf_bytes[hdr_start..s_idx]).to_string();

        let mut data_start = s_idx + 6;
        if data_start < pdf_bytes.len() && pdf_bytes[data_start] == b'\r' {
            data_start += 1;
        }
        if data_start < pdf_bytes.len() && pdf_bytes[data_start] == b'\n' {
            data_start += 1;
        } else {
            pos = s_idx + 6;
            continue;
        }

        let Some(rel_end) = find_subslice(&pdf_bytes[data_start..], b"endstream") else {
            break;
        };
        let data_end = data_start + rel_end;
        let raw_slice = &pdf_bytes[data_start..data_end];

        let decoded = if dict_header.contains("/FlateDecode")
            || (raw_slice.len() >= 2 && (raw_slice[0] & 0x0f) == 8)
        {
            zlib_or_deflate_decompress(raw_slice)
        } else {
            Some(raw_slice.to_vec())
        };

        if let Some(buf) = decoded {
            let s_latin = buf.iter().map(|&b| b as char).collect::<String>();
            if s_latin.contains("begincmap")
                || s_latin.contains("beginbfchar")
                || s_latin.contains("beginbfrange")
            {
                parse_tounicode_cmap(&s_latin, &mut cmap);
            }
            decompressed_streams.push((dict_header, buf));
        }
        pos = data_end + 9;
    }

    let mut pages_markdown: Vec<String> = Vec::new();
    let mut spoken_paragraphs: Vec<String> = Vec::new();
    let mut detected_title = String::new();
    let mut page_num = 0usize;

    for (dict_hdr, buf) in &decompressed_streams {
        // Skip object streams (`/Type /ObjStm`), XRef streams, images, and font binaries
        if dict_hdr.contains("/ObjStm")
            || dict_hdr.contains("/XRef")
            || dict_hdr.contains("/Image")
            || dict_hdr.contains("/Subtype /Type1C")
            || dict_hdr.contains("/Length1")
        {
            continue;
        }
        if find_subslice(buf, b"BT").is_none() || find_subslice(buf, b"ET").is_none() {
            continue;
        }

        let raw_lines = extract_lines_from_pdf_content_stream(buf, &cmap);
        if raw_lines.is_empty() {
            continue;
        }

        // Filter out standalone page-number footers
        let mut page_blocks: Vec<String> = Vec::new();
        let mut cur_para = String::new();

        for (idx, line) in raw_lines.iter().enumerate() {
            let t = line.text.trim();
            if t.is_empty() {
                continue;
            }
            // Skip lonely page number at the very end of the stream
            if idx + 1 == raw_lines.len()
                && t.len() <= 4
                && t.bytes().all(|b| b.is_ascii_digit())
            {
                continue;
            }

            if let Some(level) = is_likely_section_heading(t, line.font_milli_pt) {
                if !cur_para.trim().is_empty() {
                    page_blocks.push(cur_para.trim().to_string());
                    spoken_paragraphs.push(cur_para.trim().to_string());
                    cur_para.clear();
                }
                if level == 1 && detected_title.is_empty() && page_num == 0 {
                    detected_title = t.to_string();
                    page_blocks.push(format!("# {t}"));
                } else if level == 2 && page_num == 0 && page_blocks.len() <= 2 && !t.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false) && t.to_ascii_lowercase() != "abstract" {
                    page_blocks.push(format!("### *{t}*"));
                } else {
                    let hashes = "#".repeat(level.clamp(2, 4) as usize);
                    page_blocks.push(format!("{hashes} {t}"));
                }
                spoken_paragraphs.push(format!("{t}."));
                continue;
            }

            if line.new_para_before && !cur_para.trim().is_empty() {
                page_blocks.push(cur_para.trim().to_string());
                spoken_paragraphs.push(cur_para.trim().to_string());
                cur_para.clear();
            }

            // Rejoin hyphenated line wraps (`word-` followed by lowercase continuation)
            if cur_para.ends_with('-')
                && t.chars()
                    .next()
                    .map(|c| c.is_ascii_lowercase())
                    .unwrap_or(false)
            {
                cur_para.pop();
                cur_para.push_str(t);
            } else {
                if !cur_para.is_empty() && !cur_para.ends_with(' ') {
                    cur_para.push(' ');
                }
                cur_para.push_str(t);
            }
        }

        if !cur_para.trim().is_empty() {
            page_blocks.push(cur_para.trim().to_string());
            spoken_paragraphs.push(cur_para.trim().to_string());
        }

        if !page_blocks.is_empty() {
            page_num += 1;
            let mut page_md = String::new();
            if page_num > 1 {
                page_md.push_str(&format!("\n---\n\n#### 📄 Page {page_num}\n\n"));
            }
            page_md.push_str(&page_blocks.join("\n\n"));
            pages_markdown.push(page_md);
        }
    }

    if detected_title.is_empty() {
        detected_title = file_name
            .strip_suffix(".pdf")
            .or_else(|| file_name.strip_suffix(".PDF"))
            .unwrap_or(file_name)
            .replace(['_', '-'], " ");
    }

    let full_spoken = spoken_paragraphs.join(" ");
    let word_count = full_spoken.split_whitespace().count();

    let mut md = String::new();
    if !pages_markdown
        .first()
        .map(|p| p.trim_start().starts_with("# "))
        .unwrap_or(false)
    {
        md.push_str(&format!("# {detected_title}\n\n"));
    }

    let embed_note = if let Some(url) = asset_url {
        format!(
            " · [🖼️ Open Raw PDF]({url})"
        )
    } else {
        String::new()
    };

    md.push_str(&format!(
        "> [!NOTE]\n> **Sovereign PDF Reader & ALEXIAI Narrator** · `{file_name}` · **{page_num} pages** · **{word_count} words**{embed_note}\n> Click **🔊 Read Aloud** in the toolbar (or ask Aye-Aye *\"read this aloud\"*) to listen while you work!\n\n"
    ));

    if pages_markdown.is_empty() {
        md.push_str(
            "> [!WARNING]\n> This PDF contains scanned images or non-text vector paths without embedded text streams. Use the embedded PDF canvas to view pages.\n",
        );
    } else {
        md.push_str(&pages_markdown.join("\n\n"));
    }

    PdfDocumentReport {
        title: detected_title,
        page_count: page_num,
        extracted_streams: decompressed_streams.len(),
        word_count,
        markdown: md,
        spoken_text: full_spoken,
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

// ============================================================================
// 3. Built-in Sovereign `.tex` (LaTeX) Reader, Macro Expander & Compiler
// ============================================================================

/// Strip `%` comments from LaTeX source while preserving escaped `\%`.
fn strip_tex_comments(src: &str) -> String {
    let mut out = String::with_capacity(src.len());
    for line in src.lines() {
        let bytes = line.as_bytes();
        let mut cut = bytes.len();
        let mut i = 0usize;
        while i < bytes.len() {
            if bytes[i] == b'\\' {
                i += 2;
                continue;
            }
            if bytes[i] == b'%' {
                cut = i;
                break;
            }
            i += 1;
        }
        let kept = &line[..cut];
        if cut < bytes.len() && kept.trim().is_empty() {
            continue;
        }
        out.push_str(kept);
        out.push('\n');
    }
    out
}

/// Extract brace-delimited `{...}` content starting at `open_brace_idx` (where `s.as_bytes()[open_brace_idx] == b'{'`).
fn extract_braced(s: &str, open_brace_idx: usize) -> Option<(&str, usize)> {
    let bytes = s.as_bytes();
    if open_brace_idx >= bytes.len() || bytes[open_brace_idx] != b'{' {
        return None;
    }
    let mut depth = 0i32;
    let mut i = open_brace_idx;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'{' {
            depth += 1;
        } else if bytes[i] == b'}' {
            depth -= 1;
            if depth == 0 {
                return Some((&s[open_brace_idx + 1..i], i + 1));
            }
        }
        i += 1;
    }
    None
}

fn find_command_arg(s: &str, cmd: &str) -> Option<String> {
    let idx = s.find(cmd)?;
    let after = &s[idx + cmd.len()..];
    let trimmed = after.trim_start();
    let ws_skipped = after.len() - trimmed.len();
    let (inner, _) = extract_braced(after, ws_skipped)?;
    Some(inner.trim().to_string())
}

/// Parse zero-argument `\newcommand{\foo}{bar}`, `\renewcommand{\foo}{bar}`, and
/// `\DeclareMathOperator*{\foo}{bar}` definitions from a `.tex` preamble.
fn parse_tex_preamble_macros(preamble: &str) -> Vec<(String, String)> {
    let mut macros: Vec<(String, String)> = Vec::new();
    for starter in [
        "\\newcommand",
        "\\renewcommand",
        "\\providecommand",
        "\\DeclareMathOperator*",
        "\\DeclareMathOperator",
    ] {
        let is_math_op = starter.starts_with("\\DeclareMathOperator");
        let mut search = preamble;
        while let Some(pos) = search.find(starter) {
            let after = &search[pos + starter.len()..];
            let mut cursor = 0usize;
            while cursor < after.len() && (after.as_bytes()[cursor].is_ascii_whitespace() || after.as_bytes()[cursor] == b'*') {
                cursor += 1;
            }
            if cursor >= after.len() || after.as_bytes()[cursor] != b'{' {
                search = &after[cursor.max(1)..];
                continue;
            }
            let Some((name_raw, next_pos)) = extract_braced(after, cursor) else {
                break;
            };
            cursor = next_pos;
            while cursor < after.len() && after.as_bytes()[cursor].is_ascii_whitespace() {
                cursor += 1;
            }
            // Skip macros with `[n]` arguments so we only expand zero-arg macros safely
            if cursor < after.len() && after.as_bytes()[cursor] == b'[' {
                search = &after[cursor + 1..];
                continue;
            }
            if cursor >= after.len() || after.as_bytes()[cursor] != b'{' {
                search = &after[cursor.max(1)..];
                continue;
            }
            let Some((body_raw, end_pos)) = extract_braced(after, cursor) else {
                break;
            };
            let cmd_name = name_raw.trim().to_string();
            if cmd_name.starts_with('\\') && cmd_name.len() > 1 {
                let replacement = if is_math_op {
                    format!("\\operatorname{{{}}}", body_raw.trim())
                } else {
                    body_raw.trim().to_string()
                };
                macros.push((cmd_name, replacement));
            }
            search = &after[end_pos..];
        }
    }
    // Sort longest macro names first so `\Hbar` is replaced before `\H`
    macros.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    macros
}

/// Expand custom zero-argument macros (`\E`, `\Var`, `\Hbar`, `\Independent`, etc.) where not followed by ASCII letters.
fn expand_tex_macros(input: &str, macros: &[(String, String)]) -> String {
    let mut cur = input.to_string();
    for (name, repl) in macros {
        if !cur.contains(name) {
            continue;
        }
        let mut next = String::with_capacity(cur.len() + 32);
        let mut i = 0usize;
        let bytes = cur.as_bytes();
        let nlen = name.len();
        while i < bytes.len() {
            if cur[i..].starts_with(name) {
                let after_idx = i + nlen;
                let followed_by_alpha = after_idx < bytes.len() && bytes[after_idx].is_ascii_alphabetic();
                if !followed_by_alpha {
                    next.push_str(repl);
                    i = after_idx;
                    continue;
                }
            }
            let ch = cur[i..].chars().next().unwrap();
            next.push(ch);
            i += ch.len_utf8();
        }
        cur = next;
    }
    cur
}

fn convert_tex_tabular_to_markdown(table_body: &str) -> String {
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut cleaned = table_body.to_string();
    // Strip column spec `{lll}` or `{p{...}p{...}}` at the start if present
    let trimmed_start = cleaned.trim_start();
    let mut skip = cleaned.len() - trimmed_start.len();
    while skip < cleaned.len() && cleaned.as_bytes()[skip] == b'{' {
        if let Some((_, next)) = extract_braced(&cleaned, skip) {
            skip = next;
            while skip < cleaned.len() && cleaned.as_bytes()[skip].is_ascii_whitespace() {
                skip += 1;
            }
        } else {
            break;
        }
    }
    cleaned = cleaned[skip..].to_string();

    for raw_row in cleaned.split("\\\\") {
        let mut row_str = raw_row.to_string();
        for noise in [
            "\\hline",
            "\\toprule",
            "\\midrule",
            "\\bottomrule",
            "\\endhead",
            "\\endfirsthead",
            "\\centering",
            "\\small",
        ] {
            row_str = row_str.replace(noise, " ");
        }
        let t = row_str.trim();
        if t.is_empty() || t.starts_with("\\caption") || t.starts_with("\\label") {
            continue;
        }
        if t.contains('&') {
            let cells: Vec<String> = t
                .split('&')
                .map(|c| convert_tex_inline(c.trim()).replace('\n', " "))
                .collect();
            rows.push(cells);
        }
    }

    if rows.is_empty() {
        return String::new();
    }
    let cols = rows.iter().map(|r| r.len()).max().unwrap_or(1).max(1);
    let mut out = String::new();
    for (r_idx, r) in rows.iter().enumerate() {
        out.push('|');
        for c_idx in 0..cols {
            let cell = r.get(c_idx).map(|s| s.as_str()).unwrap_or("");
            out.push(' ');
            out.push_str(cell.trim());
            out.push_str(" |");
        }
        out.push('\n');
        if r_idx == 0 {
            out.push('|');
            for _ in 0..cols {
                out.push_str(" --- |");
            }
            out.push('\n');
        }
    }
    out
}

/// Convert inline LaTeX commands (`\emph`, `\textbf`, `\textit`, `\texttt`, `\cite`, `\ref`, quotes, dashes)
/// while leaving `$...$` inline math intact for KaTeX.
fn convert_tex_inline(input: &str) -> String {
    let mut s = input
        .replace("\\%", "%")
        .replace("\\&", "&")
        .replace("\\$", "$")
        .replace("\\_", "_")
        .replace("\\#", "#")
        .replace("\\(", "$")
        .replace("\\)", "$")
        .replace("``", "“")
        .replace("''", "”")
        .replace("---", "—")
        .replace("--", "–")
        .replace('~', " ")
        .replace("\\noindent", "")
        .replace("\\bigskip", "")
        .replace("\\medskip", "")
        .replace("\\smallskip", "")
        .replace("\\clearpage", "")
        .replace("\\newpage", "")
        .replace("\\tableofcontents", "");

    // Replace single-arg inline macros
    for (cmd, open_md, close_md) in [
        ("\\textbf", "**", "**"),
        ("\\emph", "*", "*"),
        ("\\textit", "*", "*"),
        ("\\textsc", "**", "**"),
        ("\\texttt", "`", "`"),
        ("\\url", "<", ">"),
        ("\\cite", "[", "]"),
        ("\\ref", "§", ""),
        ("\\eqref", "Eq. (", ")"),
        ("\\footnote", " *(", ")*"),
    ] {
        while let Some(pos) = s.find(cmd) {
            let after_idx = pos + cmd.len();
            if after_idx < s.len() && s.as_bytes()[after_idx].is_ascii_alphabetic() {
                break;
            }
            let mut brace_idx = after_idx;
            while brace_idx < s.len() && s.as_bytes()[brace_idx].is_ascii_whitespace() {
                brace_idx += 1;
            }
            // Handle optional `\cite[e.g.]{key}`
            let mut opt_note = String::new();
            if brace_idx < s.len() && s.as_bytes()[brace_idx] == b'[' {
                if let Some(close_b) = s[brace_idx + 1..].find(']') {
                    opt_note = s[brace_idx + 1..brace_idx + 1 + close_b].trim().to_string();
                    brace_idx += close_b + 2;
                    while brace_idx < s.len() && s.as_bytes()[brace_idx].is_ascii_whitespace() {
                        brace_idx += 1;
                    }
                }
            }
            if let Some((inner, end_rel)) = extract_braced(&s[brace_idx..], 0) {
                let replacement = if !opt_note.is_empty() && cmd == "\\cite" {
                    format!("[{}, {}]", inner.trim(), opt_note)
                } else {
                    format!("{open_md}{}{close_md}", inner.trim())
                };
                let full_end = brace_idx + end_rel;
                s.replace_range(pos..full_end, &replacement);
            } else {
                s.replace_range(pos..after_idx, "");
            }
        }
    }

    // Strip `\label{...}` outside display math
    while let Some(pos) = s.find("\\label{") {
        if let Some((_, end_rel)) = extract_braced(&s[pos + 6..], 0) {
            s.replace_range(pos..pos + 6 + end_rel, "");
        } else {
            break;
        }
    }

    s
}

/// Compile a `.tex` (LaTeX) manuscript into Qwave Markdown + KaTeX + spoken narration text.
pub fn compile_tex_to_markdown(tex_src: &str, file_name: &str) -> TexDocumentReport {
    let uncommented = strip_tex_comments(tex_src);
    let (preamble, raw_body) = match uncommented.split_once("\\begin{document}") {
        Some((pre, rest)) => {
            let b = rest
                .split_once("\\end{document}")
                .map(|(inner, _)| inner)
                .unwrap_or(rest);
            (pre, b)
        }
        None => ("", uncommented.as_str()),
    };

    let macros = parse_tex_preamble_macros(preamble);
    let expanded_body = expand_tex_macros(raw_body, &macros);

    let title_raw = find_command_arg(&uncommented, "\\title")
        .unwrap_or_else(|| {
            file_name
                .strip_suffix(".tex")
                .or_else(|| file_name.strip_suffix(".tex.bin"))
                .unwrap_or(file_name)
                .replace(['_', '-'], " ")
        });
    let title = convert_tex_inline(&title_raw.replace("\\\\", " — ").replace('\n', " "))
        .trim()
        .to_string();

    let author = find_command_arg(&uncommented, "\\author")
        .map(|a| {
            convert_tex_inline(&a.replace("\\\\", " · ").replace("\\and", " & ").replace('\n', " "))
                .trim()
                .to_string()
        })
        .unwrap_or_default();

    let date = find_command_arg(&uncommented, "\\date")
        .map(|d| convert_tex_inline(&d.replace("\\today", "2026")).trim().to_string())
        .unwrap_or_default();

    let mut work = expanded_body.replace("\\maketitle", "");

    // 1. Convert `\[ ... \]` into `\n$$\n...\n$$\n`
    while let Some(open) = work.find("\\[") {
        if let Some(close_rel) = work[open + 2..].find("\\]") {
            let math_inner = work[open + 2..open + 2 + close_rel].trim().to_string();
            let repl = format!("\n$$\n{math_inner}\n$$\n");
            work.replace_range(open..open + 2 + close_rel + 2, &repl);
        } else {
            break;
        }
    }

    // 2. Convert math environments (`equation`, `equation*`, `align`, `align*`, `gather`, `gather*`) into `$$\n...\n$$`
    for env_name in [
        "equation*",
        "equation",
        "align*",
        "align",
        "gather*",
        "gather",
        "multline*",
        "multline",
    ] {
        let open_tag = format!("\\begin{{{env_name}}}");
        let close_tag = format!("\\end{{{env_name}}}");
        while let Some(open) = work.find(&open_tag) {
            let after = open + open_tag.len();
            if let Some(close_rel) = work[after..].find(&close_tag) {
                let mut inner = work[after..after + close_rel].trim().to_string();
                while let Some(lpos) = inner.find("\\label{") {
                    if let Some((_, lend)) = extract_braced(&inner[lpos + 6..], 0) {
                        inner.replace_range(lpos..lpos + 6 + lend, "");
                    } else {
                        break;
                    }
                }
                let wrapped = if env_name.starts_with("align") {
                    format!("\n$$\n\\begin{{aligned}}\n{}\n\\end{{aligned}}\n$$\n", inner.trim())
                } else {
                    format!("\n$$\n{}\n$$\n", inner.trim())
                };
                work.replace_range(open..after + close_rel + close_tag.len(), &wrapped);
            } else {
                break;
            }
        }
    }

    // 3. Convert `tabular` and `longtable` environments into Markdown pipe tables
    for tbl_env in ["longtable", "tabular"] {
        let open_tag = format!("\\begin{{{tbl_env}}}");
        let close_tag = format!("\\end{{{tbl_env}}}");
        while let Some(open) = work.find(&open_tag) {
            let after = open + open_tag.len();
            if let Some(close_rel) = work[after..].find(&close_tag) {
                let inner = &work[after..after + close_rel];
                let md_tbl = convert_tex_tabular_to_markdown(inner);
                work.replace_range(
                    open..after + close_rel + close_tag.len(),
                    &format!("\n\n{md_tbl}\n\n"),
                );
            } else {
                break;
            }
        }
    }
    work = work
        .replace("\\begin{table}[htbp]", "")
        .replace("\\begin{table}", "")
        .replace("\\end{table}", "");

    // 4. Convert `abstract`, `theorem`, `proposition`, `lemma`, `corollary`, `definition`, `remark`, `proof`, `quote`
    let mut env_counters: BTreeMap<&'static str, usize> = BTreeMap::new();
    for (env_name, alert_tag, label_title) in [
        ("abstract", "[!NOTE]", "Abstract"),
        ("theorem", "[!IMPORTANT]", "Theorem"),
        ("proposition", "[!IMPORTANT]", "Proposition"),
        ("lemma", "[!IMPORTANT]", "Lemma"),
        ("corollary", "[!IMPORTANT]", "Corollary"),
        ("definition", "[!TIP]", "Definition"),
        ("assumption", "[!TIP]", "Assumption"),
        ("remark", "[!NOTE]", "Remark"),
        ("example", "[!NOTE]", "Example"),
        ("proof", "", "Proof"),
        ("quote", "", ""),
        ("quotation", "", ""),
    ] {
        let open_tag = format!("\\begin{{{env_name}}}");
        let close_tag = format!("\\end{{{env_name}}}");
        while let Some(open) = work.find(&open_tag) {
            let after = open + open_tag.len();
            let Some(close_rel) = work[after..].find(&close_tag) else {
                break;
            };
            let mut body_slice = work[after..after + close_rel].trim();
            let mut opt_subtitle = String::new();
            if body_slice.starts_with('[') {
                if let Some(close_b) = body_slice.find(']') {
                    opt_subtitle = body_slice[1..close_b].trim().to_string();
                    body_slice = body_slice[close_b + 1..].trim();
                }
            }
            let clean_body = convert_tex_inline(body_slice);
            let mut quoted = String::new();
            if !alert_tag.is_empty() {
                quoted.push_str(&format!("> {alert_tag}\n"));
                let heading = if env_name == "abstract" {
                    "**Abstract.**".to_string()
                } else {
                    let c = env_counters.entry(env_name).or_insert(0);
                    *c += 1;
                    if opt_subtitle.is_empty() {
                        format!("**{label_title} {c}.**")
                    } else {
                        format!("**{label_title} {c} ({opt_subtitle}).**")
                    }
                };
                quoted.push_str(&format!("> {heading} "));
            } else if env_name == "proof" {
                quoted.push_str("> *Proof.* ");
            } else {
                quoted.push_str("> ");
            }
            for (l_idx, line) in clean_body.lines().enumerate() {
                if l_idx > 0 {
                    quoted.push_str("\n> ");
                }
                quoted.push_str(line.trim());
            }
            if env_name == "proof" {
                quoted.push_str(" ∎");
            }
            work.replace_range(
                open..after + close_rel + close_tag.len(),
                &format!("\n\n{quoted}\n\n"),
            );
        }
    }

    // 5. Convert `thebibliography` into `## References`
    while let Some(open) = work.find("\\begin{thebibliography}") {
        let after = open + "\\begin{thebibliography}".len();
        let Some(close_rel) = work[after..].find("\\end{thebibliography}") else {
            break;
        };
        let mut bib_slice = &work[after..after + close_rel];
        if bib_slice.trim_start().starts_with('{') {
            let ws = bib_slice.len() - bib_slice.trim_start().len();
            if let Some((_, next)) = extract_braced(bib_slice, ws) {
                bib_slice = &bib_slice[next..];
            }
        }
        let mut refs_md = String::from("\n\n## References\n\n");
        for item in bib_slice.split("\\bibitem") {
            let t = item.trim();
            if t.is_empty() {
                continue;
            }
            if t.starts_with('{') {
                if let Some((key, rest_idx)) = extract_braced(t, 0) {
                    let citation_text = convert_tex_inline(t[rest_idx..].trim()).replace('\n', " ");
                    refs_md.push_str(&format!("- **[{}]** {}\n", key.trim(), citation_text.trim()));
                }
            }
        }
        work.replace_range(
            open..after + close_rel + "\\end{thebibliography}".len(),
            &refs_md,
        );
    }

    // 6. Convert `itemize` / `enumerate` / `description` lists
    for list_env in ["itemize", "enumerate", "description"] {
        let open_tag = format!("\\begin{{{list_env}}}");
        let close_tag = format!("\\end{{{list_env}}}");
        while let Some(open) = work.find(&open_tag) {
            let after = open + open_tag.len();
            let Some(close_rel) = work[after..].find(&close_tag) else {
                break;
            };
            let list_body = &work[after..after + close_rel];
            let mut list_md = String::from("\n\n");
            let mut idx_num = 0usize;
            for part in list_body.split("\\item") {
                let p = part.trim();
                if p.is_empty() {
                    continue;
                }
                idx_num += 1;
                let (opt_label, item_rest) = if p.starts_with('[') {
                    if let Some(cb) = p.find(']') {
                        (Some(p[1..cb].trim()), p[cb + 1..].trim())
                    } else {
                        (None, p)
                    }
                } else {
                    (None, p)
                };
                let cleaned_item = convert_tex_inline(item_rest).replace('\n', " ");
                if let Some(lbl) = opt_label {
                    list_md.push_str(&format!(
                        "- **{}** {}\n",
                        convert_tex_inline(lbl),
                        cleaned_item.trim()
                    ));
                } else if list_env == "enumerate" {
                    list_md.push_str(&format!("{idx_num}. {}\n", cleaned_item.trim()));
                } else {
                    list_md.push_str(&format!("- {}\n", cleaned_item.trim()));
                }
            }
            list_md.push('\n');
            work.replace_range(open..after + close_rel + close_tag.len(), &list_md);
        }
    }

    // 7. Convert `\part`, `\section`, `\subsection`, `\subsubsection`, `\paragraph`
    let mut sec_num = 0usize;
    let mut subsec_num = 0usize;
    let mut section_count = 0usize;
    let mut final_lines: Vec<String> = Vec::new();
    let mut in_display_math = false;

    for raw_line in work.lines() {
        let trimmed = raw_line.trim();
        if trimmed == "$$" {
            in_display_math = !in_display_math;
            final_lines.push("$$".to_string());
            continue;
        }
        if in_display_math {
            final_lines.push(raw_line.to_string());
            continue;
        }

        if let Some(arg) = find_command_arg(trimmed, "\\part*")
            .or_else(|| find_command_arg(trimmed, "\\part"))
        {
            section_count += 1;
            final_lines.push(format!("\n## Part: {}\n", convert_tex_inline(&arg)));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\section*") {
            section_count += 1;
            final_lines.push(format!("\n## {}\n", convert_tex_inline(&arg)));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\section") {
            sec_num += 1;
            subsec_num = 0;
            section_count += 1;
            final_lines.push(format!(
                "\n## {sec_num}. {}\n",
                convert_tex_inline(&arg)
            ));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\subsection*") {
            section_count += 1;
            final_lines.push(format!("\n### {}\n", convert_tex_inline(&arg)));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\subsection") {
            subsec_num += 1;
            section_count += 1;
            final_lines.push(format!(
                "\n### {sec_num}.{subsec_num} {}\n",
                convert_tex_inline(&arg)
            ));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\subsubsection*")
            .or_else(|| find_command_arg(trimmed, "\\subsubsection"))
        {
            section_count += 1;
            final_lines.push(format!("\n#### {}\n", convert_tex_inline(&arg)));
            continue;
        }
        if let Some(arg) = find_command_arg(trimmed, "\\paragraph") {
            let after_para = trimmed
                .find('}')
                .map(|i| trimmed[i + 1..].trim())
                .unwrap_or("");
            final_lines.push(format!(
                "\n#### {}\n{}",
                convert_tex_inline(&arg),
                convert_tex_inline(after_para)
            ));
            continue;
        }

        final_lines.push(convert_tex_inline(raw_line));
    }

    let mut md = String::new();
    md.push_str(&format!("# {title}\n\n"));
    let mut meta_parts = Vec::new();
    if !author.is_empty() {
        meta_parts.push(format!("**Author:** {author}"));
    }
    if !date.is_empty() {
        meta_parts.push(format!("**Date:** {date}"));
    }
    meta_parts.push(format!(
        "**Source:** `{file_name}` ({section_count} sections · {} macros expanded)",
        macros.len()
    ));
    md.push_str(&format!(
        "> [!NOTE]\n> **Sovereign LaTeX (`.tex`) Reader, KaTeX Compiler & ALEXIAI Narrator**\n> {}\n> Click **🔊 Read Aloud** in the toolbar (or ask Aye-Aye *\"read this aloud\"*) to listen while you work!\n\n",
        meta_parts.join(" · ")
    ));
    md.push_str(&final_lines.join("\n"));

    let spoken_text = markdown_to_spoken_narration(&md);
    TexDocumentReport {
        title,
        author,
        date,
        section_count,
        macro_count: macros.len(),
        markdown: md,
        spoken_text,
    }
}

/// Convert Qwave Markdown / LaTeX into smooth, natural English narration for ALEXIAI TTS
/// (converting math expressions into spoken words and stripping raw formatting markers).
pub fn markdown_to_spoken_narration(md: &str) -> String {
    let mut s = md.to_string();
    // Replace common LaTeX math macros with natural spoken words
    for (pat, spoken) in [
        ("\\mathbb{E}", " expected value "),
        ("\\operatorname{Var}", " variance "),
        ("\\to", " to "),
        ("\\rightarrow", " to "),
        ("\\longrightarrow", " leads to "),
        ("\\Rightarrow", " implies "),
        ("\\iff", " if and only if "),
        ("\\ge", " greater than or equal to "),
        ("\\geq", " greater than or equal to "),
        ("\\le", " less than or equal to "),
        ("\\leq", " less than or equal to "),
        ("\\neq", " not equal to "),
        ("\\approx", " approximately "),
        ("\\sim", " distributed as "),
        ("\\in", " in "),
        ("\\subseteq", " subset of "),
        ("\\subset", " subset of "),
        ("\\times", " times "),
        ("\\cdot", " dot "),
        ("\\infty", " infinity "),
        ("\\sum", " sum "),
        ("\\int", " integral "),
        ("\\partial", " partial "),
        ("\\Delta", " Delta "),
        ("\\alpha", " alpha "),
        ("\\beta", " beta "),
        ("\\gamma", " gamma "),
        ("\\delta", " delta "),
        ("\\lambda", " lambda "),
        ("\\mu", " mu "),
        ("\\sigma", " sigma "),
        ("\\pi", " pi "),
        ("\\phi", " phi "),
    ] {
        s = s.replace(pat, spoken);
    }

    let mut out_lines = Vec::new();
    let mut in_code = false;
    for line in s.lines() {
        let t = line.trim();
        if t.starts_with("```") {
            in_code = !in_code;
            continue;
        }
        if in_code || t.is_empty() || t.starts_with("| ---") || t == "$$" {
            continue;
        }
        if t.starts_with("> [!") {
            continue;
        }
        let cleaned: String = t
            .trim_start_matches('#')
            .trim_start_matches('>')
            .trim()
            .chars()
            .filter(|&c| !matches!(c, '*' | '`' | '$' | '\\' | '{' | '}' | '^' | '_'))
            .collect();
        if !cleaned.trim().is_empty() {
            out_lines.push(cleaned.trim().to_string());
        }
    }
    out_lines.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_deflate_uncompressed_and_fixed_huffman() {
        // RFC 1950 zlib stream for "Hello Sovereign PDF & TeX!"
        // Python: zlib.compress(b"Hello Sovereign PDF & TeX!")
        let compressed: [u8; 34] = [
            0x78, 0x9c, 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x08, 0xce, 0x2f, 0x4b, 0x2d, 0x4a,
            0xcd, 0x4c, 0xcf, 0x53, 0x08, 0x70, 0x71, 0x53, 0x50, 0x53, 0x08, 0x49, 0x8d, 0x50,
            0x04, 0x00, 0x7f, 0x96, 0x08, 0x89,
        ];
        let dec = zlib_or_deflate_decompress(&compressed).expect("zlib decompress");
        assert_eq!(dec, b"Hello Sovereign PDF & TeX!");
    }

    #[test]
    fn test_pdf_tj_ligatures_and_kerning() {
        let stream = b"BT /F38 18.0 Tf 100 700 Td [(When)-302(Correction)-302(Becomes)-302(Rep)1(r)-1(o)-26(duction)]TJ /F39 11.955 Tf 0 -24.0 Td [(The)-317(de\\014nition)-317(of)-317(con\\015ict.)]TJ ET";
        let cmap = BTreeMap::new();
        let lines = extract_lines_from_pdf_content_stream(stream, &cmap);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text, "When Correction Becomes Reproduction");
        assert_eq!(lines[1].text, "The definition of conflict.");
        assert!(lines[1].new_para_before);
    }

    #[test]
    fn test_compile_tex_to_markdown_expands_macros_and_sections() {
        let sample_tex = r#"
\documentclass[11pt]{article}
\newcommand{\E}{\mathbb{E}}
\DeclareMathOperator*{\argmax}{arg\,max}
\title{Revenue Without Returns:\\Platform Income}
\author{Flyxion}
\date{October 2026}
\begin{document}
\maketitle
\begin{abstract}
We study $\E[R]$ under platform extraction.
\end{abstract}
\section{Introduction}
Consider the objective:
\[
x^* = \argmax_x \E[u(x)]
\]
\begin{proposition}[Extraction Bound]
Every equilibrium satisfies $\E[R] \le 0$.
\end{proposition}
\end{document}
"#;
        let rep = compile_tex_to_markdown(sample_tex, "revenue_without_returns.tex");
        assert!(rep.title.contains("Revenue Without Returns"));
        assert_eq!(rep.author, "Flyxion");
        assert!(rep.markdown.contains("## 1. Introduction"));
        assert!(rep.markdown.contains("\\mathbb{E}[R]"));
        assert!(rep.markdown.contains("\\operatorname{arg\\,max}"));
        assert!(rep.markdown.contains("**Proposition 1 (Extraction Bound).**"));
    }
}
