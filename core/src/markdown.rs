//! Qwave Sovereign Markdown Compiler & WaveScene Shell (`qwave_core::markdown`).
//!
//! Zero-dependency Rust port of `MarkdownCompiler.swift`, `WaveScene.swift`,
//! and `InternalPages.markdownHTML`, extended for cross-platform Qwave
//! (Linux, Windows, Chromebook, macOS, iOS) and Antigravity artifacts:
//! - CommonMark blocks (headings with slug anchors, paragraphs, lists, task lists,
//!   blockquotes, fenced code blocks with 3+ or 4+ fences, pipe tables, horizontal rules)
//! - GitHub-style Alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`)
//! - Interactive Carousels (````carousel with `<!-- slide -->` separators)
//! - Display (`$$ ... $$`) and inline (`$ ... $`) KaTeX math
//! - Mermaid diagrams (` ```mermaid `)
//! - `MarkdownTrust::CompilerOutputOnly`: NUL stripping, raw HTML escaping,
//!   and scheme-allowlisted `href` / `src` attributes (`javascript:`, `data:text/html`,
//!   and `vbscript:` are unconditionally neutralized).

/// Trust policy for Markdown compilation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarkdownTrust {
    /// Only tags emitted by this compiler survive; raw HTML in input is escaped.
    CompilerOutputOnly,
}

/// Table of Contents entry extracted from `#`..`####` headings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TocEntry {
    pub level: u8,
    pub text: String,
    pub id: String,
}

/// Compiled Markdown output with extracted metadata.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompiledMarkdown {
    pub title: String,
    pub html: String,
    pub toc: Vec<TocEntry>,
}

/// Escape raw text so it cannot introduce tags or break attributes.
pub fn escape(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len() + 16);
    for ch in raw.chars() {
        match ch {
            '\0' => {}
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(ch),
        }
    }
    out
}

/// Compile Markdown source to safe HTML under `MarkdownTrust::CompilerOutputOnly`.
pub fn compile(markdown: &str, trust: MarkdownTrust) -> String {
    compile_full(markdown, trust, None).html
}

/// Compile Markdown source and extract title + Table of Contents.
/// If `base_dir` is provided, relative/local image paths are routed through `/asset?path=...`.
pub fn compile_full(
    markdown: &str,
    _trust: MarkdownTrust,
    base_dir: Option<&str>,
) -> CompiledMarkdown {
    let clean: String = markdown
        .chars()
        .filter(|&c| c != '\0')
        .collect::<String>()
        .replace("\r\n", "\n")
        .replace('\r', "\n");

    let body = strip_frontmatter(&clean);
    let lines: Vec<&str> = body.split('\n').collect();

    let mut out: Vec<String> = Vec::new();
    let mut toc: Vec<TocEntry> = Vec::new();
    let mut title = String::new();
    let mut i = 0;
    let mut carousel_counter = 0usize;

    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();

        if trimmed.is_empty() {
            i += 1;
            continue;
        }

        // Fenced code block: 3 or more backticks or tildes (e.g. ``` or ````carousel)
        if let Some((fence_char, fence_len, info_raw)) = parse_fence_open(trimmed) {
            let info = info_raw.trim().to_ascii_lowercase();
            let lang_token = info.split_whitespace().next().unwrap_or("");
            i += 1;
            let mut buf: Vec<&str> = Vec::new();
            while i < lines.len() && !is_fence_close(lines[i].trim(), fence_char, fence_len) {
                buf.push(lines[i]);
                i += 1;
            }
            if i < lines.len() {
                i += 1;
            }
            let content = buf.join("\n");
            if lang_token == "mermaid" {
                out.push(format!("<div class=\"mermaid\">{}</div>", escape(&content)));
            } else if lang_token == "carousel" {
                carousel_counter += 1;
                out.push(render_carousel(&content, carousel_counter, base_dir));
            } else if lang_token.is_empty() {
                out.push(format!(
                    "<div class=\"code-block\"><button class=\"code-copy\" data-copy-code title=\"Copy code\">Copy</button><pre><code>{}</code></pre></div>",
                    escape(&content)
                ));
            } else {
                let safe_lang = escape(lang_token);
                out.push(format!(
                    "<div class=\"code-block\"><div class=\"code-head\"><span class=\"code-lang\">{safe_lang}</span><button class=\"code-copy\" data-copy-code title=\"Copy code\">Copy</button></div><pre><code class=\"language-{safe_lang}\">{}</code></pre></div>",
                    escape(&content)
                ));
            }
            continue;
        }

        // Display math: $$ ... $$ (single-line or multi-line)
        if trimmed.starts_with("$$") {
            if trimmed.len() > 4 && trimmed.ends_with("$$") {
                let inner = &trimmed[2..trimmed.len() - 2];
                out.push(format!("<div class=\"math-display\">{}</div>", escape(inner)));
                i += 1;
                continue;
            }
            i += 1;
            let mut buf: Vec<&str> = Vec::new();
            while i < lines.len() && !lines[i].trim().starts_with("$$") {
                buf.push(lines[i]);
                i += 1;
            }
            if i < lines.len() {
                i += 1;
            }
            out.push(format!(
                "<div class=\"math-display\">{}</div>",
                escape(&buf.join("\n"))
            ));
            continue;
        }

        // ATX Heading (# .. ######)
        if let Some((level, heading_text)) = parse_heading(trimmed) {
            let plain = strip_inline_markers(heading_text);
            if title.is_empty() && level == 1 {
                title = plain.clone();
            }
            let slug = slugify(&plain, toc.len());
            if level <= 4 {
                toc.push(TocEntry {
                    level,
                    text: plain,
                    id: slug.clone(),
                });
            }
            out.push(format!(
                "<h{level} id=\"{slug}\"><a class=\"heading-anchor\" href=\"#{slug}\">#</a>{}</h{level}>",
                inline(heading_text, base_dir)
            ));
            i += 1;
            continue;
        }

        // Horizontal rule
        if is_hr(trimmed) {
            out.push("<hr>".to_string());
            i += 1;
            continue;
        }

        // Blockquote or GitHub Alert (> [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING], > [!CAUTION])
        if trimmed.starts_with('>') {
            let mut q: Vec<String> = Vec::new();
            while i < lines.len() && lines[i].trim().starts_with('>') {
                let t = lines[i].trim();
                let after = t.strip_prefix("> ").or_else(|| t.strip_prefix('>')).unwrap_or("");
                q.push(after.to_string());
                i += 1;
            }
            if let Some((alert_kind, alert_title, rest_md)) = parse_github_alert(&q) {
                let inner_compiled = compile_full(&rest_md, MarkdownTrust::CompilerOutputOnly, base_dir).html;
                out.push(format!(
                    "<div class=\"md-alert md-alert-{alert_kind}\"><div class=\"md-alert-title\">{alert_title}</div><div class=\"md-alert-body\">{inner_compiled}</div></div>"
                ));
            } else {
                let inner_compiled = compile_full(&q.join("\n"), MarkdownTrust::CompilerOutputOnly, base_dir).html;
                out.push(format!("<blockquote>{inner_compiled}</blockquote>"));
            }
            continue;
        }

        // Pipe table
        if trimmed.contains('|') && i + 1 < lines.len() && is_table_separator(lines[i + 1].trim())
        {
            let headers = split_row(trimmed);
            let aligns = parse_table_alignments(lines[i + 1].trim());
            i += 2;
            let mut rows: Vec<Vec<String>> = Vec::new();
            while i < lines.len() && lines[i].trim().contains('|') && !lines[i].trim().is_empty() {
                rows.push(split_row(lines[i].trim()));
                i += 1;
            }
            let mut th_html = String::new();
            for (idx, h) in headers.iter().enumerate() {
                let align_attr = aligns.get(idx).copied().unwrap_or("");
                th_html.push_str(&format!("<th{align_attr}>{}</th>", inline(h, base_dir)));
            }
            let mut tb_html = String::new();
            for r in rows {
                tb_html.push_str("<tr>");
                for (idx, cell) in r.iter().enumerate() {
                    let align_attr = aligns.get(idx).copied().unwrap_or("");
                    tb_html.push_str(&format!("<td{align_attr}>{}</td>", inline(cell, base_dir)));
                }
                tb_html.push_str("</tr>");
            }
            out.push(format!(
                "<div class=\"table-wrap\"><table><thead><tr>{th_html}</tr></thead><tbody>{tb_html}</tbody></table></div>"
            ));
            continue;
        }

        // Unordered list (including task list items `- [x]`, `- [ ]`)
        if is_unordered_item(trimmed) {
            let mut items: Vec<String> = Vec::new();
            while i < lines.len() {
                let cur = lines[i].trim();
                if is_unordered_item(cur) {
                    let item_text = &cur[2..];
                    items.push(render_list_item(item_text, base_dir));
                    i += 1;
                } else if !cur.is_empty()
                    && (lines[i].starts_with("  ") || lines[i].starts_with('\t'))
                    && !items.is_empty()
                {
                    // Continuation line inside list item
                    if let Some(last) = items.last_mut() {
                        if let Some(stripped) = last.strip_suffix("</li>") {
                            *last = format!("{stripped} {}</li>", inline(cur, base_dir));
                        }
                    }
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(format!("<ul>{}</ul>", items.join("")));
            continue;
        }

        // Ordered list
        if is_ordered_item(trimmed) {
            let mut items: Vec<String> = Vec::new();
            while i < lines.len() {
                let cur = lines[i].trim();
                if let Some(item_text) = strip_ordered_prefix(cur) {
                    items.push(format!("<li>{}</li>", inline(item_text, base_dir)));
                    i += 1;
                } else if !cur.is_empty()
                    && (lines[i].starts_with("  ") || lines[i].starts_with('\t'))
                    && !items.is_empty()
                {
                    if let Some(last) = items.last_mut() {
                        if let Some(stripped) = last.strip_suffix("</li>") {
                            *last = format!("{stripped} {}</li>", inline(cur, base_dir));
                        }
                    }
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(format!("<ol>{}</ol>", items.join("")));
            continue;
        }

        // Paragraph
        let mut para: Vec<String> = Vec::new();
        while i < lines.len() {
            let t = lines[i].trim();
            if t.is_empty()
                || parse_fence_open(t).is_some()
                || t.starts_with("$$")
                || parse_heading(t).is_some()
                || t.starts_with('>')
                || is_hr(t)
                || is_unordered_item(t)
                || is_ordered_item(t)
                || (t.contains('|')
                    && i + 1 < lines.len()
                    && is_table_separator(lines[i + 1].trim()))
            {
                break;
            }
            para.push(inline(t, base_dir));
            i += 1;
        }
        if !para.is_empty() {
            out.push(format!("<p>{}</p>", para.join(" ")));
        }
    }

    CompiledMarkdown {
        title,
        html: out.join("\n"),
        toc,
    }
}

fn parse_fence_open(trimmed: &str) -> Option<(char, usize, &str)> {
    let first = trimmed.chars().next()?;
    if first != '`' && first != '~' {
        return None;
    }
    let count = trimmed.chars().take_while(|&c| c == first).count();
    if count < 3 {
        return None;
    }
    let rest = &trimmed[count..];
    // Backtick fence info strings cannot contain backticks per CommonMark
    if first == '`' && rest.contains('`') {
        return None;
    }
    Some((first, count, rest))
}

fn is_fence_close(trimmed: &str, fence_char: char, min_len: usize) -> bool {
    let count = trimmed.chars().take_while(|&c| c == fence_char).count();
    count >= min_len && trimmed[count..].trim().is_empty()
}

fn render_carousel(content: &str, id: usize, base_dir: Option<&str>) -> String {
    let slides: Vec<&str> = content.split("<!-- slide -->").collect();
    let total = slides.len();
    let mut slides_html = String::new();
    for (idx, slide_md) in slides.iter().enumerate() {
        let active = if idx == 0 { " active" } else { "" };
        let compiled = compile_full(slide_md.trim(), MarkdownTrust::CompilerOutputOnly, base_dir).html;
        slides_html.push_str(&format!(
            "<div class=\"qwave-slide{active}\" data-slide-idx=\"{idx}\">{compiled}</div>"
        ));
    }
    format!(
        "<div class=\"qwave-carousel\" data-carousel=\"{id}\">\
         <div class=\"qwave-carousel-bar\">\
           <span class=\"qwave-carousel-badge\">CAROUSEL · <strong data-carousel-pos>1 / {total}</strong></span>\
           <div class=\"qwave-carousel-nav\">\
             <button type=\"button\" class=\"escape-btn carousel-btn\" data-carousel-prev>◀ PREV</button>\
             <button type=\"button\" class=\"escape-btn carousel-btn\" data-carousel-next>NEXT ▶</button>\
           </div>\
         </div>\
         <div class=\"qwave-carousel-track\">{slides_html}</div>\
         </div>"
    )
}

fn parse_github_alert(lines: &[String]) -> Option<(&'static str, &'static str, String)> {
    let first = lines.first()?.trim();
    let (tag, kind, title) = if first.starts_with("[!NOTE]") {
        ("[!NOTE]", "note", "ℹ️ NOTE")
    } else if first.starts_with("[!TIP]") {
        ("[!TIP]", "tip", "💡 TIP")
    } else if first.starts_with("[!IMPORTANT]") {
        ("[!IMPORTANT]", "important", "⚡ IMPORTANT")
    } else if first.starts_with("[!WARNING]") {
        ("[!WARNING]", "warning", "⚠️ WARNING")
    } else if first.starts_with("[!CAUTION]") {
        ("[!CAUTION]", "caution", "🛑 CAUTION")
    } else {
        return None;
    };

    let mut body_lines: Vec<String> = Vec::new();
    let first_rem = first[tag.len()..].trim();
    if !first_rem.is_empty() {
        body_lines.push(first_rem.to_string());
    }
    for l in &lines[1..] {
        body_lines.push(l.clone());
    }
    Some((kind, title, body_lines.join("\n")))
}

fn render_list_item(item_text: &str, base_dir: Option<&str>) -> String {
    let t = item_text.trim_start();
    if let Some(rest) = t.strip_prefix("[x] ").or_else(|| t.strip_prefix("[X] ")) {
        format!(
            "<li class=\"task-item task-done\"><input type=\"checkbox\" checked disabled> <span>{}</span></li>",
            inline(rest, base_dir)
        )
    } else if let Some(rest) = t.strip_prefix("[ ] ") {
        format!(
            "<li class=\"task-item\"><input type=\"checkbox\" disabled> <span>{}</span></li>",
            inline(rest, base_dir)
        )
    } else if let Some(rest) = t.strip_prefix("[/] ") {
        format!(
            "<li class=\"task-item task-wip\"><input type=\"checkbox\" disabled> <span class=\"wip-badge\">WIP</span> <span>{}</span></li>",
            inline(rest, base_dir)
        )
    } else {
        format!("<li>{}</li>", inline(t, base_dir))
    }
}

fn parse_heading(trimmed: &str) -> Option<(u8, &str)> {
    let hashes = trimmed.bytes().take_while(|&b| b == b'#').count();
    if (1..=6).contains(&hashes) {
        let rest = &trimmed[hashes..];
        if let Some(stripped) = rest.strip_prefix(' ') {
            return Some((hashes as u8, stripped.trim()));
        }
    }
    None
}

fn is_hr(trimmed: &str) -> bool {
    trimmed == "---" || trimmed == "***" || trimmed == "___" || trimmed == "- - -"
}

fn is_unordered_item(trimmed: &str) -> bool {
    trimmed.starts_with("- ") || trimmed.starts_with("* ") || trimmed.starts_with("+ ")
}

fn is_ordered_item(trimmed: &str) -> bool {
    strip_ordered_prefix(trimmed).is_some()
}

fn strip_ordered_prefix(trimmed: &str) -> Option<&str> {
    let dot = trimmed.find(". ")?;
    if dot == 0 || dot > 9 {
        return None;
    }
    if trimmed[..dot].bytes().all(|b| b.is_ascii_digit()) {
        Some(&trimmed[dot + 2..])
    } else {
        None
    }
}

fn is_table_separator(s: &str) -> bool {
    if !s.contains('-') || !s.contains('|') {
        return false;
    }
    s.chars()
        .all(|c| c == '|' || c == '-' || c == ':' || c == ' ' || c == '\t')
}

fn parse_table_alignments(sep: &str) -> Vec<&'static str> {
    split_row(sep)
        .into_iter()
        .map(|cell| {
            let t = cell.trim();
            match (t.starts_with(':'), t.ends_with(':')) {
                (true, true) => " style=\"text-align:center\"",
                (false, true) => " style=\"text-align:right\"",
                (true, false) => " style=\"text-align:left\"",
                _ => "",
            }
        })
        .collect()
}

fn split_row(row: &str) -> Vec<String> {
    let mut s = row.trim();
    if let Some(stripped) = s.strip_prefix('|') {
        s = stripped;
    }
    if let Some(stripped) = s.strip_suffix('|') {
        s = stripped;
    }
    s.split('|').map(|c| c.trim().to_string()).collect()
}

fn strip_frontmatter(s: &str) -> &str {
    if let Some(after_open) = s.strip_prefix("---\n") {
        if let Some(close_pos) = after_open.find("\n---\n") {
            return &after_open[close_pos + 5..];
        }
    }
    s
}

fn strip_inline_markers(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for ch in s.chars() {
        if !matches!(ch, '`' | '*' | '_' | '~') {
            out.push(ch);
        }
    }
    out
}

fn slugify(text: &str, seq: usize) -> String {
    let mut slug = String::new();
    let mut prev_dash = false;
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            slug.push(ch.to_ascii_lowercase());
            prev_dash = false;
        } else if !prev_dash && !slug.is_empty() {
            slug.push('-');
            prev_dash = true;
        }
    }
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        format!("section-{seq}")
    } else {
        slug
    }
}

/// Inline formatting parser: code spans, inline math, images, links, bold, italic, strikethrough.
fn inline(text: &str, base_dir: Option<&str>) -> String {
    let mut out = String::with_capacity(text.len() + 32);
    let bytes = text.as_bytes();
    let mut i = 0;

    while i < bytes.len() {
        let ch = bytes[i];

        // Inline code: `...`
        if ch == b'`' {
            if let Some(close_rel) = text[i + 1..].find('`') {
                let code_content = &text[i + 1..i + 1 + close_rel];
                out.push_str("<code>");
                out.push_str(&escape(code_content));
                out.push_str("</code>");
                i += 1 + close_rel + 1;
                continue;
            }
        }

        // Inline math: $...$
        if ch == b'$' {
            if let Some(close_rel) = text[i + 1..].find('$') {
                let expr = &text[i + 1..i + 1 + close_rel];
                if !expr.is_empty() && !expr.starts_with(' ') && !expr.ends_with(' ') {
                    out.push_str("<span class=\"math-inline\">");
                    out.push_str(&escape(expr));
                    out.push_str("</span>");
                    i += 1 + close_rel + 1;
                    continue;
                }
            }
        }

        // Image: ![alt](src)
        if ch == b'!' && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
            if let Some((alt, url, next_i)) = parse_bracket_paren(text, i + 1) {
                if let Some(safe) = safe_image_src(url, base_dir) {
                    out.push_str("<img src=\"");
                    out.push_str(&escape(&safe));
                    out.push_str("\" alt=\"");
                    out.push_str(&escape(alt));
                    out.push_str("\" loading=\"lazy\">");
                    i = next_i;
                    continue;
                }
            }
        }

        // Link: [label](href)
        if ch == b'[' {
            if let Some((label, url, next_i)) = parse_bracket_paren(text, i) {
                if let Some((safe, line_badge, is_file_url)) = safe_href_enriched(url) {
                    let cls = if is_file_url {
                        " class=\"qwave-file-link\""
                    } else {
                        ""
                    };
                    out.push_str("<a");
                    out.push_str(cls);
                    out.push_str(" href=\"");
                    out.push_str(&escape(&safe));
                    out.push_str("\" rel=\"noopener noreferrer\">");
                    out.push_str(&inline(label, base_dir));
                    if let Some(badge) = line_badge {
                        out.push_str("<span class=\"file-line-badge\">");
                        out.push_str(&escape(&badge));
                        out.push_str("</span>");
                    }
                    out.push_str("</a>");
                } else {
                    out.push_str(&inline(label, base_dir));
                }
                i = next_i;
                continue;
            }
        }

        // Bold: **...**
        if i + 1 < bytes.len() && ch == b'*' && bytes[i + 1] == b'*' {
            if let Some(close_rel) = text[i + 2..].find("**") {
                let inner = &text[i + 2..i + 2 + close_rel];
                out.push_str("<strong>");
                out.push_str(&inline(inner, base_dir));
                out.push_str("</strong>");
                i += 2 + close_rel + 2;
                continue;
            }
        }

        // Strikethrough: ~~...~~
        if i + 1 < bytes.len() && ch == b'~' && bytes[i + 1] == b'~' {
            if let Some(close_rel) = text[i + 2..].find("~~") {
                let inner = &text[i + 2..i + 2 + close_rel];
                out.push_str("<del>");
                out.push_str(&inline(inner, base_dir));
                out.push_str("</del>");
                i += 2 + close_rel + 2;
                continue;
            }
        }

        // Italic: *...*
        if ch == b'*' {
            if let Some(close_rel) = text[i + 1..].find('*') {
                if close_rel > 0 {
                    let inner = &text[i + 1..i + 1 + close_rel];
                    out.push_str("<em>");
                    out.push_str(&inline(inner, base_dir));
                    out.push_str("</em>");
                    i += 1 + close_rel + 1;
                    continue;
                }
            }
        }

        // Regular character (UTF-8 aware)
        let ch_char = text[i..].chars().next().unwrap_or('\u{FFFD}');
        match ch_char {
            '\0' => {}
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            c => out.push(c),
        }
        i += ch_char.len_utf8();
    }

    out
}

/// Parse `[label](url)` starting at `bracket_start` (which points to `[`).
/// Handles nested inline code inside `label`, e.g. `[`ClassName`](file:///...)`.
fn parse_bracket_paren(text: &str, bracket_start: usize) -> Option<(&str, &str, usize)> {
    let bytes = text.as_bytes();
    if bytes.get(bracket_start) != Some(&b'[') {
        return None;
    }
    let mut idx = bracket_start + 1;
    let mut depth = 1usize;
    let mut in_code = false;
    while idx < bytes.len() {
        let b = bytes[idx];
        if b == b'`' {
            in_code = !in_code;
        } else if !in_code {
            if b == b'[' {
                depth += 1;
            } else if b == b']' {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
        }
        idx += 1;
    }
    if depth != 0 || idx + 1 >= bytes.len() || bytes[idx + 1] != b'(' {
        return None;
    }
    let label = &text[bracket_start + 1..idx];
    let url_start = idx + 2;
    let mut paren_depth = 1usize;
    let mut u_idx = url_start;
    while u_idx < bytes.len() {
        let b = bytes[u_idx];
        if b == b'(' {
            paren_depth += 1;
        } else if b == b')' {
            paren_depth -= 1;
            if paren_depth == 0 {
                break;
            }
        }
        u_idx += 1;
    }
    if paren_depth != 0 {
        return None;
    }
    let url = &text[url_start..u_idx];
    Some((label, url, u_idx + 1))
}

/// Validate link href and enrich `file:///...` links with line-number badge metadata.
pub fn safe_href(raw: &str) -> Option<String> {
    safe_href_enriched(raw).map(|(href, _, _)| href)
}

fn safe_href_enriched(raw: &str) -> Option<(String, Option<String>, bool)> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with('#') || trimmed.starts_with('/') || trimmed.starts_with("./") || trimmed.starts_with("../") {
        return Some((trimmed.to_string(), None, false));
    }
    if let Some(colon) = trimmed.find(':') {
        let scheme = trimmed[..colon].to_ascii_lowercase();
        match scheme.as_str() {
            "http" | "https" | "mailto" | "qwave" | "conversation" => {
                return Some((trimmed.to_string(), None, false));
            }
            "file" => {
                let badge = trimmed.find("#L").map(|pos| trimmed[pos + 1..].to_string());
                return Some((trimmed.to_string(), badge, true));
            }
            _ => return None,
        }
    }
    // Relative path without scheme (e.g. `docs/NETWORK.md`)
    Some((trimmed.to_string(), None, false))
}

/// Validate image `src` and rewrite local file paths when served by Qwave Desktop.
pub fn safe_image_src(raw: &str, base_dir: Option<&str>) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("data:image/") {
        if lower.starts_with("data:image/svg") {
            return None;
        }
        return Some(trimmed.to_string());
    }
    if lower.starts_with("http://") || lower.starts_with("https://") {
        return Some(trimmed.to_string());
    }
    if let Some(file_path) = trimmed.strip_prefix("file://") {
        if base_dir.is_some() {
            return Some(format!("/asset?path={}", url_encode(file_path)));
        }
        return Some(trimmed.to_string());
    }
    if trimmed.starts_with('/') {
        if base_dir.is_some() {
            return Some(format!("/asset?path={}", url_encode(trimmed)));
        }
        return Some(trimmed.to_string());
    }
    if !trimmed.contains(':') {
        if let Some(dir) = base_dir {
            let joined = format!("{}/{}", dir.trim_end_matches('/'), trimmed);
            return Some(format!("/asset?path={}", url_encode(&joined)));
        }
        return Some(trimmed.to_string());
    }
    None
}

fn url_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len() + 16);
    for b in input.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Escape raw Markdown source for embedding inside `<script type="application/json" id="qwave-source">`.
pub fn markdown_source_literal(source: &str) -> String {
    let mut out = String::with_capacity(source.len() + 16);
    out.push('"');
    for ch in source.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '<' => out.push_str("\\u003c"),
            '>' => out.push_str("\\u003e"),
            '&' => out.push_str("\\u0026"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The domain-warped WebGL wave fragment shader ("Lost in the Math" from `WaveScene.swift`).
pub const WAVE_FRAGMENT_SHADER: &str = r#"#ifdef GL_ES
precision highp float;
#endif

uniform float u_time;
uniform vec2 u_resolution;

float random (in vec2 _st) {
    return fract(sin(dot(_st.xy, vec2(12.9898,78.233))) * 43758.5453123);
}

float noise (in vec2 _st) {
    vec2 i = floor(_st);
    vec2 f = fract(_st);
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) +
            (c - a)* u.y * (1.0 - u.x) +
            (d - b) * u.x * u.y;
}

#define NUM_OCTAVES 5
float fbm ( in vec2 _st) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    mat2 rot = mat2(cos(0.5), sin(0.5),
                    -sin(0.5), cos(0.50));
    for (int i = 0; i < NUM_OCTAVES; ++i) {
        v += a * noise(_st);
        _st = rot * _st * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

void main() {
    vec2 st = gl_FragCoord.xy/u_resolution.xy;
    st.x *= u_resolution.x/u_resolution.y;

    vec3 color = vec3(0.0);
    vec2 q = vec2(0.);
    q.x = fbm( st + 0.00*u_time);
    q.y = fbm( st + vec2(1.0));

    vec2 r = vec2(0.);
    r.x = fbm( st + 1.0*q + vec2(1.7,9.2)+ 0.15*u_time );
    r.y = fbm( st + 1.0*q + vec2(8.3,2.8)+ 0.126*u_time);

    float f = fbm(st+r);

    color = mix(vec3(0.101961,0.619608,0.666667),
                vec3(0.666667,0.666667,0.498039),
                clamp((f*f)*4.0,0.0,1.0));

    color = mix(color,
                vec3(0.0,0.0,0.164706),
                clamp(length(q),0.0,1.0));

    color = mix(color,
                vec3(0.666667,1.0,1.0),
                clamp(length(r.x),0.0,1.0));

    gl_FragColor = vec4((f*f*f+.6*f*f+.5*f)*color,1.0);
}
"#;

/// The 30fps demand-controlled WebGL canvas runner from `WaveScene.swift`.
pub const WAVE_CANVAS_SCRIPT: &str = r#"(function () {
  const canvas = document.getElementById("glCanvas");
  if (!canvas) return;
  const gl = canvas.getContext("webgl");
  if (!gl) return;

  const vertexShaderSource = `
    attribute vec2 position;
    void main() { gl_Position = vec4(position, 0.0, 1.0); }
  `;
  const fragmentShaderSource = document.getElementById("fragShader").text;

  function createShader(gl, type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      gl.deleteShader(shader);
      return null;
    }
    return shader;
  }

  const vertexShader = createShader(gl, gl.VERTEX_SHADER, vertexShaderSource);
  const fragmentShader = createShader(gl, gl.FRAGMENT_SHADER, fragmentShaderSource);
  if (!vertexShader || !fragmentShader) return;

  const program = gl.createProgram();
  gl.attachShader(program, vertexShader);
  gl.attachShader(program, fragmentShader);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return;
  gl.useProgram(program);

  const positionLocation = gl.getAttribLocation(program, "position");
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([
    -1, -1,  1, -1, -1,  1,
    -1,  1,  1, -1,  1,  1,
  ]), gl.STATIC_DRAW);
  gl.enableVertexAttribArray(positionLocation);
  gl.vertexAttribPointer(positionLocation, 2, gl.FLOAT, false, 0, 0);

  const uTimeLocation = gl.getUniformLocation(program, "u_time");
  const uResolutionLocation = gl.getUniformLocation(program, "u_resolution");
  const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)");
  let reduce = motionPreference.matches;
  // Default to paused after rendering the initial ocean frame so idle CPU/GPU is 0%;
  // users can toggle live animation anytime via the "🌌 Wave" toolbar button.
  window.__qwaveShaderPaused = true;

  function resize() {
    // Render WebGL FBM backdrop at half resolution (4x fewer fragment shader pixels)
    // while CSS stretches it smoothly across the viewport.
    canvas.width = Math.max(1, Math.floor(window.innerWidth * 0.5));
    canvas.height = Math.max(1, Math.floor(window.innerHeight * 0.5));
    gl.viewport(0, 0, canvas.width, canvas.height);
    if ((reduce || window.__qwaveShaderPaused) && !document.hidden) render(8000);
  }

  function render(time) {
    const seconds = (reduce || window.__qwaveShaderPaused) ? 8.0 : time * 0.001;
    gl.uniform1f(uTimeLocation, seconds);
    gl.uniform2f(uResolutionLocation, canvas.width, canvas.height);
    gl.drawArrays(gl.TRIANGLES, 0, 6);
  }

  const FPS_CAP_MS = 1000 / 20;
  let lastRender = -1000;
  let rafId = 0;

  function frame(time) {
    rafId = 0;
    if (document.hidden || reduce || window.__qwaveShaderPaused) return;
    if (time - lastRender >= FPS_CAP_MS) {
      lastRender = time;
      render(time);
    }
    rafId = requestAnimationFrame(frame);
  }

  function syncAnimation() {
    cancelAnimationFrame(rafId);
    rafId = 0;
    reduce = motionPreference.matches;
    lastRender = -1000;
    if (document.hidden) return;
    if (reduce || window.__qwaveShaderPaused) {
      render(8000);
    } else {
      rafId = requestAnimationFrame(frame);
    }
  }
  window.__qwaveSyncShader = syncAnimation;
  document.addEventListener("visibilitychange", syncAnimation);
  window.addEventListener("resize", resize);
  resize();
  if (!reduce) syncAnimation();
})();"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiler_strips_nul_and_escapes_raw_html() {
        let md = "# Hello\0 <script>alert(1)</script>\n\n[bad](javascript:alert(1)) [ok](file:///tmp/a.md#L10-L20)";
        let compiled = compile_full(md, MarkdownTrust::CompilerOutputOnly, None);
        assert_eq!(compiled.title, "Hello <script>alert(1)</script>");
        assert!(!compiled.html.contains("<script>"));
        assert!(compiled.html.contains("&lt;script&gt;"));
        assert!(!compiled.html.contains("javascript:"));
        assert!(compiled.html.contains("file:///tmp/a.md#L10-L20"));
        assert!(compiled.html.contains("L10-L20"));
    }

    #[test]
    fn compiler_handles_github_alerts_and_carousels() {
        let md = "> [!IMPORTANT]\n> Sovereign core active.\n\n````carousel\nSlide 1\n<!-- slide -->\n```rust\nfn main() {}\n```\n````";
        let html = compile(md, MarkdownTrust::CompilerOutputOnly);
        assert!(html.contains("md-alert-important"));
        assert!(html.contains("Sovereign core active."));
        assert!(html.contains("qwave-carousel"));
        assert!(html.contains("language-rust"));
    }
}
