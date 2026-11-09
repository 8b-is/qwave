//! Sovereign TeX / LaTeX Compiler & PDF Document Reader (`qwave_core::tex_pdf`).
//!
//! Zero-dependency, 100% integer Rust engine for reading, rendering, and narrating
//! `.tex` / `.ltx` / `.latex` / `.bib` and `.pdf` documents inside Qwave:
//! - Full LaTeX-to-Sovereign-Markdown/KaTeX compiler (`compile_tex_to_markdown`, `compile_tex_full`):
//!   * Preamble macro extraction & expansion (`\newcommand`, `\renewcommand`, `\providecommand`,
//!     `\DeclareMathOperator`, `\def`) for 0-arg, 1-arg, and 2-arg macros
//!   * Multi-line `\title{...}`, `\author{...}`, `\date{...}`, and `\begin{abstract}...\end{abstract}`
//!   * Section hierarchy (`\part`, `\chapter`, `\section`, `\subsection`, `\subsubsection`, `\paragraph`)
//!   * Theorem/proof environments (`proposition`, `theorem`, `lemma`, `corollary`, `definition`,
//!     `remark`, `example`, `note`, `proof`) rendered as Sovereign Callout Alerts
//!   * Display (`\[...\]`, `equation`, `align`, `gather`, `multline`) & inline (`\(...\)`, `$...$`) KaTeX math
//!   * Lists (`itemize`, `enumerate`, `description`), tables (`tabular`), figures (`\includegraphics`),
//!     and bibliography (`thebibliography` / `\bibitem` + `\cite`, `\citep`, `\citet` resolution)
//! - Built-in PDF Reader & Reflow Engine (`extract_pdf_text_pure_rust`, `format_pdf_to_markdown`):
//!   * Pure-Rust zero-dependency PDF parser + RFC 1950/1951 Zlib/Deflate stream decompressor
//!     (`BT ... ET`, `Tj`, `TJ`, `'`, `"`) for standalone extraction without external tools
//!   * Intelligent academic PDF reflow: strips running page footers, rejoins hyphenated words
//!     and hard-wrapped lines across page boundaries, promotes `Abstract`, `References`, and
//!     numbered sections (`1 Introduction`, `2.1 ...`) to TOC headings, and adds `#page-N` anchors
//! - Spoken Narration Cleaner (`extract_spoken_narration`):
//!   * Converts LaTeX math symbols & Markdown formatting into smooth natural speech for
//!     `qwave --speak <file.pdf|file.tex|file.md>` and the Qwave Studio Read-Aloud player.

use crate::markdown::{CompiledMarkdown, MarkdownTrust, compile_full};

/// Returns `true` if `ext` (case-insensitive, without leading dot) is a TeX/LaTeX/BibTeX file.
pub fn is_tex_extension(ext: &str) -> bool {
    matches!(
        ext.trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str(),
        "tex" | "ltx" | "latex" | "bib" | "sty" | "cls"
    )
}

/// Returns `true` if `ext` (case-insensitive, without leading dot) is a PDF file.
pub fn is_pdf_extension(ext: &str) -> bool {
    ext.trim()
        .trim_start_matches('.')
        .eq_ignore_ascii_case("pdf")
}

/// Returns `true` if `ext` (case-insensitive, without leading dot) is an Audio file.
pub fn is_audio_extension(ext: &str) -> bool {
    matches!(
        ext.trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str(),
        "wav" | "mp3" | "flac" | "ogg" | "m4a" | "aac" | "opus" | "8a"
    )
}

/// Returns `true` if `ext` (case-insensitive, without leading dot) is a Video file.
pub fn is_video_extension(ext: &str) -> bool {
    matches!(
        ext.trim()
            .trim_start_matches('.')
            .to_ascii_lowercase()
            .as_str(),
        "mp4" | "mkv" | "webm" | "mov" | "avi" | "m4v" | "ts" | "ogv"
    )
}

/// Returns `true` if `ext` is an Audio or Video file.
pub fn is_media_extension(ext: &str) -> bool {
    is_audio_extension(ext) || is_video_extension(ext)
}

#[derive(Clone, Debug)]
struct TexMacro {
    name: String,
    arity: usize,
    body: String,
}

#[derive(Clone, Debug)]
struct BibItem {
    key: String,
    label: String,
    content: String,
}

/// Compile a `.tex` / `.ltx` / `.latex` (or `.bib`) source string into Sovereign HTML + TOC.
pub fn compile_tex_full(tex_source: &str, base_dir: Option<&str>) -> CompiledMarkdown {
    let md = compile_tex_to_markdown(tex_source);
    compile_full(&md, MarkdownTrust::CompilerOutputOnly, base_dir)
}

/// Convert TeX / LaTeX (or BibTeX) source into Sovereign Markdown with KaTeX math and callout blocks.
pub fn compile_tex_to_markdown(tex_source: &str) -> String {
    compile_tex_to_markdown_with_mem8(tex_source, &[])
}

/// Convert TeX / LaTeX source into Sovereign Markdown enriched with a MEM|8 Personalized Summary
/// and PhoeniX'd High-Resolution Distillation block.
pub fn compile_tex_to_markdown_with_mem8(tex_source: &str, mem8_anchors: &[String]) -> String {
    let clean_nul: String = tex_source
        .chars()
        .filter(|&c| c != '\0')
        .collect::<String>()
        .replace("\r\n", "\n")
        .replace('\r', "\n");

    // Check if this is a standalone BibTeX (.bib) file
    let trimmed_all = clean_nul.trim_start();
    if !trimmed_all.contains("\\begin{document}")
        && !trimmed_all.contains("\\section")
        && (trimmed_all.starts_with('@')
            || trimmed_all.contains("\n@article{")
            || trimmed_all.contains("\n@book{")
            || trimmed_all.contains("\n@inproceedings{"))
    {
        return compile_bibtex_to_markdown(&clean_nul);
    }

    // 1. Strip unescaped `%` comments line by line
    let uncommented = strip_tex_comments(&clean_nul);

    // 2. Extract preamble macros (\newcommand, \renewcommand, \providecommand, \DeclareMathOperator, \def)
    let macros = extract_tex_macros(&uncommented);

    // 3. Extract metadata (\title, \author, \date) before \begin{document} (or anywhere in doc)
    let raw_title = extract_tex_command_arg(&uncommented, "\\title").unwrap_or_default();
    let raw_author = extract_tex_command_arg(&uncommented, "\\author").unwrap_or_default();
    let raw_date = extract_tex_command_arg(&uncommented, "\\date").unwrap_or_default();

    // 4. Isolate body inside \begin{document} ... \end{document} if present
    let body_raw = if let Some(start_idx) = uncommented.find("\\begin{document}") {
        let after_start = &uncommented[start_idx + "\\begin{document}".len()..];
        if let Some(end_idx) = after_start.rfind("\\end{document}") {
            &after_start[..end_idx]
        } else {
            after_start
        }
    } else {
        uncommented.as_str()
    };

    // 5. Expand user-defined macros across the body
    let expanded_body = expand_tex_macros(body_raw, &macros);

    // 6. Extract bibliography items (\bibitem[label]{key} ...) so citations in text resolve nicely
    let (body_without_bib, bib_items) = extract_thebibliography(&expanded_body);

    let mut out = Vec::<String>::new();

    // 7. Emit Title / Author / Date header if extracted
    let clean_title = clean_tex_metadata_str(&expand_tex_macros(&raw_title, &macros), &bib_items);
    let clean_author = clean_tex_metadata_str(&expand_tex_macros(&raw_author, &macros), &bib_items);
    let clean_date = clean_tex_metadata_str(&expand_tex_macros(&raw_date, &macros), &bib_items);

    if !clean_title.is_empty() {
        out.push(format!("# {clean_title}"));
        let mut meta_parts = Vec::new();
        if !clean_author.is_empty() {
            meta_parts.push(format!("✍️ **{}**", clean_author));
        }
        if !clean_date.is_empty() {
            meta_parts.push(format!("📅 {}", clean_date));
        }
        meta_parts.push("📐 *Compiled by Qwave Sovereign TeX + PhoeniX Engine*".to_string());
        out.push(meta_parts.join(" · "));
        out.push(String::new());
    }

    // 8. Convert body blocks (abstract, sections, theorem/proof environments, math, lists, tables, paragraphs)
    let converted_body = convert_tex_body(&body_without_bib, &bib_items);

    // 8b. Generate MEM|8 Personalized Summary & PhoeniX High-Res Distillation if document has multiple sections/paragraphs
    if converted_body.len() > 320 {
        let summary_title = if clean_title.is_empty() {
            "LaTeX Document"
        } else {
            &clean_title
        };
        let summary = summarize_markdown_with_mem8(
            summary_title,
            &clean_author,
            &converted_body,
            mem8_anchors,
        );
        out.push(format_summary_and_phoenix_markdown(&summary));
        out.push(String::new());
    }

    out.push(converted_body);

    // 9. Emit References section if bibliography items exist
    if !bib_items.is_empty() {
        out.push(String::new());
        out.push("## References".to_string());
        out.push(String::new());
        for item in &bib_items {
            let formatted = convert_tex_inline(&item.content, &bib_items);
            if !item.label.is_empty() {
                out.push(format!("- **[{}]** {}", item.label, formatted.trim()));
            } else {
                out.push(format!("- **[{}]** {}", item.key, formatted.trim()));
            }
        }
    }

    out.join("\n")
}

fn strip_tex_comments(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for line in input.split('\n') {
        let bytes = line.as_bytes();
        let mut cut = line.len();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' {
                // Count preceding backslashes
                let mut bs = 0usize;
                let mut j = i;
                while j > 0 && bytes[j - 1] == b'\\' {
                    bs += 1;
                    j -= 1;
                }
                if bs % 2 == 0 {
                    cut = i;
                    break;
                }
            }
            i += 1;
        }
        let kept = &line[..cut];
        // If the entire line was a comment (only whitespace before `%`), skip adding blank noise
        if cut < line.len() && kept.trim().is_empty() {
            continue;
        }
        out.push_str(kept);
        out.push('\n');
    }
    out
}

/// Find balanced `{ ... }` starting at or after `pos` (skipping whitespace).
/// Returns `(inner_slice, index_after_closing_brace)`.
fn parse_balanced_braces(s: &str, start_pos: usize) -> Option<(&str, usize)> {
    let bytes = s.as_bytes();
    let mut i = start_pos;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t' || bytes[i] == b'\n') {
        i += 1;
    }
    if i >= bytes.len() || bytes[i] != b'{' {
        return None;
    }
    let content_start = i + 1;
    let mut depth = 1usize;
    i += 1;
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
                return Some((&s[content_start..i], i + 1));
            }
        }
        i += 1;
    }
    None
}

/// Find optional `[ ... ]` starting at `start_pos` (skipping spaces/tabs).
fn parse_optional_brackets(s: &str, start_pos: usize) -> Option<(&str, usize)> {
    let bytes = s.as_bytes();
    let mut i = start_pos;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    if i >= bytes.len() || bytes[i] != b'[' {
        return None;
    }
    let content_start = i + 1;
    let mut depth = 1usize;
    i += 1;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'[' {
            depth += 1;
        } else if bytes[i] == b']' {
            depth -= 1;
            if depth == 0 {
                return Some((&s[content_start..i], i + 1));
            }
        }
        i += 1;
    }
    None
}

fn extract_tex_command_arg(source: &str, cmd: &str) -> Option<String> {
    let mut search_from = 0usize;
    while let Some(rel) = source[search_from..].find(cmd) {
        let idx = search_from + rel;
        let after_cmd = idx + cmd.len();
        // Ensure `cmd` is not a prefix of a longer command (e.g. `\titleformat` vs `\title`)
        if let Some(next_ch) = source[after_cmd..].chars().next() {
            if next_ch.is_ascii_alphabetic() {
                search_from = after_cmd;
                continue;
            }
        }
        let mut cursor = after_cmd;
        if source[cursor..].starts_with('*') {
            cursor += 1;
        }
        if let Some((_, after_opt)) = parse_optional_brackets(source, cursor) {
            cursor = after_opt;
        }
        if let Some((arg, _)) = parse_balanced_braces(source, cursor) {
            return Some(arg.trim().to_string());
        }
        search_from = after_cmd;
    }
    None
}

fn extract_tex_macros(source: &str) -> Vec<TexMacro> {
    let mut macros = Vec::new();
    for cmd in ["\\newcommand", "\\renewcommand", "\\providecommand"] {
        let mut search_from = 0usize;
        while let Some(rel) = source[search_from..].find(cmd) {
            let idx = search_from + rel;
            let mut cursor = idx + cmd.len();
            if source[cursor..].starts_with('*') {
                cursor += 1;
            }
            if let Some((name_raw, after_name)) = parse_balanced_braces(source, cursor) {
                let name = name_raw.trim().to_string();
                let mut next_cur = after_name;
                let mut arity = 0usize;
                if let Some((arity_str, after_arity)) = parse_optional_brackets(source, next_cur) {
                    arity = arity_str.trim().parse().unwrap_or(0);
                    next_cur = after_arity;
                    // Optional default arg `[...]`
                    if let Some((_, after_def)) = parse_optional_brackets(source, next_cur) {
                        next_cur = after_def;
                    }
                }
                if let Some((body_raw, after_body)) = parse_balanced_braces(source, next_cur) {
                    if name.starts_with('\\') && name.len() > 1 {
                        macros.push(TexMacro {
                            name,
                            arity,
                            body: body_raw.trim().to_string(),
                        });
                    }
                    search_from = after_body;
                    continue;
                }
            }
            search_from = cursor;
        }
    }

    // Also support \DeclareMathOperator{\Foo}{Bar}
    for cmd in ["\\DeclareMathOperator*", "\\DeclareMathOperator"] {
        let mut search_from = 0usize;
        while let Some(rel) = source[search_from..].find(cmd) {
            let idx = search_from + rel;
            let cursor = idx + cmd.len();
            if let Some((name_raw, after_name)) = parse_balanced_braces(source, cursor) {
                if let Some((op_raw, after_op)) = parse_balanced_braces(source, after_name) {
                    let name = name_raw.trim().to_string();
                    if name.starts_with('\\') && name.len() > 1 {
                        macros.push(TexMacro {
                            name,
                            arity: 0,
                            body: format!("\\operatorname{{{}}}", op_raw.trim()),
                        });
                    }
                    search_from = after_op;
                    continue;
                }
            }
            search_from = cursor;
        }
    }

    macros
}

fn expand_tex_macros(input: &str, macros: &[TexMacro]) -> String {
    if macros.is_empty() {
        return input.to_string();
    }
    let mut current = input.to_string();
    for m in macros {
        if m.arity == 0 {
            let mut out = String::with_capacity(current.len());
            let mut search = 0usize;
            while let Some(rel) = current[search..].find(&m.name) {
                let idx = search + rel;
                out.push_str(&current[search..idx]);
                let after = idx + m.name.len();
                let next_is_alpha = current[after..]
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic())
                    .unwrap_or(false);
                if next_is_alpha {
                    out.push_str(&m.name);
                } else {
                    out.push_str(&m.body);
                }
                search = after;
            }
            out.push_str(&current[search..]);
            current = out;
        } else if m.arity == 1 {
            let mut out = String::with_capacity(current.len());
            let mut search = 0usize;
            while let Some(rel) = current[search..].find(&m.name) {
                let idx = search + rel;
                out.push_str(&current[search..idx]);
                let after = idx + m.name.len();
                let next_is_alpha = current[after..]
                    .chars()
                    .next()
                    .map(|c| c.is_ascii_alphabetic())
                    .unwrap_or(false);
                if !next_is_alpha {
                    if let Some((arg1, after_arg1)) = parse_balanced_braces(&current, after) {
                        let expanded = m.body.replace("#1", arg1);
                        out.push_str(&expanded);
                        search = after_arg1;
                        continue;
                    }
                }
                out.push_str(&m.name);
                search = after;
            }
            out.push_str(&current[search..]);
            current = out;
        }
    }
    current
}

fn extract_thebibliography(input: &str) -> (String, Vec<BibItem>) {
    let Some(start) = input.find("\\begin{thebibliography}") else {
        return (input.to_string(), Vec::new());
    };
    let after_begin = start + "\\begin{thebibliography}".len();
    let body_start = if let Some((_, after_arg)) = parse_balanced_braces(input, after_begin) {
        after_arg
    } else {
        after_begin
    };
    let (bib_block, rest_start) =
        if let Some(end_rel) = input[body_start..].find("\\end{thebibliography}") {
            let end_idx = body_start + end_rel;
            (
                &input[body_start..end_idx],
                end_idx + "\\end{thebibliography}".len(),
            )
        } else {
            (&input[body_start..], input.len())
        };

    let mut items = Vec::new();
    let mut cursor = 0usize;
    while let Some(rel) = bib_block[cursor..].find("\\bibitem") {
        let idx = cursor + rel;
        let mut after_cmd = idx + "\\bibitem".len();
        let mut label = String::new();
        if let Some((opt_label, after_opt)) = parse_optional_brackets(bib_block, after_cmd) {
            label = opt_label.trim().to_string();
            after_cmd = after_opt;
        }
        if let Some((key_raw, after_key)) = parse_balanced_braces(bib_block, after_cmd) {
            let key = key_raw.trim().to_string();
            let next_bibitem = bib_block[after_key..]
                .find("\\bibitem")
                .map(|r| after_key + r)
                .unwrap_or(bib_block.len());
            let content = bib_block[after_key..next_bibitem]
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            items.push(BibItem {
                key,
                label,
                content,
            });
            cursor = next_bibitem;
        } else {
            cursor = after_cmd;
        }
    }

    let mut remaining = String::with_capacity(input.len());
    remaining.push_str(&input[..start]);
    remaining.push_str(&input[rest_start..]);
    (remaining, items)
}

fn clean_tex_metadata_str(raw: &str, bib_items: &[BibItem]) -> String {
    let mut s = raw.replace("\\today", "2026");
    // Strip \\[0.3em] or \\ line breaks inside title/author
    while let Some(pos) = s.find("\\\\") {
        let after = pos + 2;
        if let Some((_, after_opt)) = parse_optional_brackets(&s, after) {
            s.replace_range(pos..after_opt, " — ");
        } else {
            s.replace_range(pos..after, " · ");
        }
    }
    for noise in [
        "\\large",
        "\\Large",
        "\\LARGE",
        "\\huge",
        "\\Huge",
        "\\normalsize",
        "\\small",
        "\\bfseries",
        "\\normalfont",
        "\\centering",
        "\\noindent",
    ] {
        s = s.replace(noise, " ");
    }
    let inline_conv = convert_tex_inline(&s, bib_items);
    inline_conv.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn convert_tex_body(body: &str, bib_items: &[BibItem]) -> String {
    let mut s = body.to_string();

    // 1. Remove standalone layout commands that take no visible prose
    for cmd in [
        "\\maketitle",
        "\\tableofcontents",
        "\\newpage",
        "\\clearpage",
        "\\pagebreak",
        "\\noindent",
        "\\bigskip",
        "\\medskip",
        "\\smallskip",
        "\\centering",
    ] {
        s = s.replace(cmd, "");
    }

    // Remove \addcontentsline{...}{...}{...} and \label{...}
    s = strip_command_with_n_braces(&s, "\\addcontentsline", 3);
    s = strip_command_with_n_braces(&s, "\\vspace*", 1);
    s = strip_command_with_n_braces(&s, "\\vspace", 1);
    s = strip_command_with_n_braces(&s, "\\hspace*", 1);
    s = strip_command_with_n_braces(&s, "\\hspace", 1);
    s = strip_command_with_n_braces(&s, "\\thispagestyle", 1);
    s = strip_command_with_n_braces(&s, "\\pagestyle", 1);
    s = strip_command_with_n_braces(&s, "\\bibliographystyle", 1);

    // 2. Convert \[ ... \] display math to $$\n...\n$$
    s = convert_bracket_display_math(&s);

    // 3. Convert math environments: equation, equation*, align, align*, gather, gather*, multline
    for env in [
        "equation*",
        "equation",
        "displaymath",
        "align*",
        "align",
        "gather*",
        "gather",
        "multline*",
        "multline",
        "eqnarray*",
        "eqnarray",
    ] {
        s = convert_math_environment(&s, env);
    }

    // 4. Convert \begin{abstract} ... \end{abstract}
    s = convert_named_environment(&s, "abstract", |opt_title, inner| {
        let title_str = opt_title.unwrap_or("Abstract");
        let converted = convert_tex_inline(inner.trim(), bib_items);
        let lines: Vec<String> = converted
            .lines()
            .map(|l| format!("> {}", l.trim()))
            .collect();
        format!("\n> [!NOTE]\n> **{title_str}**\n>\n{}\n", lines.join("\n"))
    });

    // 5. Convert Theorem / Proposition / Lemma / Corollary / Definition / Remark / Proof environments
    for (env, kind_label, alert_tag, italic_body, qed) in [
        ("theorem", "Theorem", "[!IMPORTANT]", true, false),
        ("proposition", "Proposition", "[!IMPORTANT]", true, false),
        ("lemma", "Lemma", "[!IMPORTANT]", true, false),
        ("corollary", "Corollary", "[!IMPORTANT]", true, false),
        ("conjecture", "Conjecture", "[!IMPORTANT]", true, false),
        ("claim", "Claim", "[!IMPORTANT]", true, false),
        ("definition", "Definition", "[!NOTE]", false, false),
        ("assumption", "Assumption", "[!NOTE]", false, false),
        ("axiom", "Axiom", "[!NOTE]", false, false),
        ("remark", "Remark", "[!TIP]", false, false),
        ("example", "Example", "[!TIP]", false, false),
        ("note", "Note", "[!TIP]", false, false),
        ("proof", "Proof", "[!NOTE]", false, true),
    ] {
        let mut counter = 0usize;
        s = convert_named_environment(&s, env, |opt_title, inner| {
            counter += 1;
            let header = if qed {
                match opt_title {
                    Some(t) if !t.is_empty() => format!("*{t}.*"),
                    _ => "*Proof.*".to_string(),
                }
            } else {
                match opt_title {
                    Some(t) if !t.is_empty() => format!("**{kind_label} {counter} ({t}).**"),
                    _ => format!("**{kind_label} {counter}.**"),
                }
            };
            let converted = convert_tex_inline(inner.trim(), bib_items);
            let suffix = if qed { " ∎" } else { "" };
            let body_formatted = if italic_body {
                format!("*{converted}*{suffix}")
            } else {
                format!("{converted}{suffix}")
            };
            let quoted_lines: Vec<String> = body_formatted
                .lines()
                .map(|l| {
                    if l.trim().is_empty() {
                        ">".to_string()
                    } else {
                        format!("> {}", l.trim())
                    }
                })
                .collect();
            format!("\n> {alert_tag}\n> {header}\n{}\n", quoted_lines.join("\n"))
        });
    }

    // 6. Convert verbatim / lstlisting environments to fenced code blocks
    for env in ["verbatim", "lstlisting"] {
        s = convert_named_environment(&s, env, |_opt, inner| {
            format!("\n```\n{}\n```\n", inner.trim_matches('\n'))
        });
    }

    // 7. Convert quote / quotation environments
    for env in ["quote", "quotation"] {
        s = convert_named_environment(&s, env, |_opt, inner| {
            let converted = convert_tex_inline(inner.trim(), bib_items);
            let quoted: Vec<String> = converted
                .lines()
                .map(|l| format!("> {}", l.trim()))
                .collect();
            format!("\n{}\n", quoted.join("\n"))
        });
    }

    // 8. Convert itemize / enumerate / description lists
    s = convert_list_environment(&s, "itemize", false, bib_items);
    s = convert_list_environment(&s, "enumerate", true, bib_items);
    s = convert_description_environment(&s, bib_items);

    // 9. Convert tabular environments to Markdown pipe tables
    s = convert_tabular_environments(&s, bib_items);

    // 10. Convert sectioning commands (\part, \chapter, \section, \subsection, \subsubsection, \paragraph)
    s = convert_section_commands(&s, bib_items);

    // 11. Convert remaining inline LaTeX commands paragraph-by-paragraph (preserving fenced blocks & $$ math)
    convert_tex_paragraphs(&s, bib_items)
}

fn strip_command_with_n_braces(input: &str, cmd: &str, n_braces: usize) -> String {
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find(cmd) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let mut cur = idx + cmd.len();
        let next_is_alpha = input[cur..]
            .chars()
            .next()
            .map(|c| c.is_ascii_alphabetic())
            .unwrap_or(false);
        if next_is_alpha {
            out.push_str(cmd);
            search = cur;
            continue;
        }
        let mut matched = true;
        for _ in 0..n_braces {
            if let Some((_, next_pos)) = parse_balanced_braces(input, cur) {
                cur = next_pos;
            } else {
                matched = false;
                break;
            }
        }
        if !matched {
            out.push_str(cmd);
            search = idx + cmd.len();
        } else {
            search = cur;
        }
    }
    out.push_str(&input[search..]);
    out
}

fn convert_bracket_display_math(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find("\\[") {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let math_start = idx + 2;
        if let Some(close_rel) = input[math_start..].find("\\]") {
            let math_end = math_start + close_rel;
            let expr = input[math_start..math_end].trim();
            out.push_str("\n$$\n");
            out.push_str(expr);
            out.push_str("\n$$\n");
            search = math_end + 2;
        } else {
            out.push_str("\\[");
            search = math_start;
        }
    }
    out.push_str(&input[search..]);
    out
}

fn convert_math_environment(input: &str, env: &str) -> String {
    let open_tag = format!("\\begin{{{env}}}");
    let close_tag = format!("\\end{{{env}}}");
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find(&open_tag) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let inner_start = idx + open_tag.len();
        if let Some(close_rel) = input[inner_start..].find(&close_tag) {
            let inner_end = inner_start + close_rel;
            let raw_math =
                strip_command_with_n_braces(input[inner_start..inner_end].trim(), "\\label", 1);
            let wrapped = if env.starts_with("align") || env.starts_with("eqnarray") {
                format!("\\begin{{aligned}}\n{}\n\\end{{aligned}}", raw_math.trim())
            } else if env.starts_with("gather") || env.starts_with("multline") {
                format!(
                    "\\begin{{gathered}}\n{}\n\\end{{gathered}}",
                    raw_math.trim()
                )
            } else {
                raw_math.trim().to_string()
            };
            out.push_str("\n$$\n");
            out.push_str(&wrapped);
            out.push_str("\n$$\n");
            search = inner_end + close_tag.len();
        } else {
            out.push_str(&open_tag);
            search = inner_start;
        }
    }
    out.push_str(&input[search..]);
    out
}

fn convert_named_environment<F>(input: &str, env: &str, mut render: F) -> String
where
    F: FnMut(Option<&str>, &str) -> String,
{
    let open_tag = format!("\\begin{{{env}}}");
    let close_tag = format!("\\end{{{env}}}");
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find(&open_tag) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let mut inner_start = idx + open_tag.len();
        let mut opt_title: Option<String> = None;
        if let Some((opt, after_opt)) = parse_optional_brackets(input, inner_start) {
            opt_title = Some(opt.trim().to_string());
            inner_start = after_opt;
        }
        if let Some(close_rel) = input[inner_start..].find(&close_tag) {
            let inner_end = inner_start + close_rel;
            let inner = &input[inner_start..inner_end];
            out.push_str(&render(opt_title.as_deref(), inner));
            search = inner_end + close_tag.len();
        } else {
            out.push_str(&open_tag);
            search = idx + open_tag.len();
        }
    }
    out.push_str(&input[search..]);
    out
}

fn convert_list_environment(
    input: &str,
    env: &str,
    ordered: bool,
    bib_items: &[BibItem],
) -> String {
    convert_named_environment(input, env, |_opt, inner| {
        let mut items = Vec::new();
        let parts: Vec<&str> = inner.split("\\item").collect();
        for (idx, part) in parts.iter().enumerate() {
            if idx == 0 && part.trim().is_empty() {
                continue;
            }
            if idx == 0 {
                continue;
            }
            let mut cur_text = part.trim();
            let mut custom_bullet: Option<String> = None;
            if let Some((opt_label, after_opt)) = parse_optional_brackets(cur_text, 0) {
                custom_bullet = Some(opt_label.trim().to_string());
                cur_text = cur_text[after_opt..].trim();
            }
            let cleaned = convert_tex_inline(cur_text, bib_items)
                .lines()
                .map(str::trim)
                .filter(|l| !l.is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            if let Some(lbl) = custom_bullet {
                items.push(format!("- **{lbl}** {cleaned}"));
            } else if ordered {
                items.push(format!("{idx}. {cleaned}"));
            } else {
                items.push(format!("- {cleaned}"));
            }
        }
        format!("\n{}\n", items.join("\n"))
    })
}

fn convert_description_environment(input: &str, bib_items: &[BibItem]) -> String {
    convert_list_environment(input, "description", false, bib_items)
}

fn convert_tabular_environments(input: &str, bib_items: &[BibItem]) -> String {
    let open_tag = "\\begin{tabular}";
    let close_tag = "\\end{tabular}";
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find(open_tag) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let mut inner_start = idx + open_tag.len();
        if let Some((_, after_pos)) = parse_optional_brackets(input, inner_start) {
            inner_start = after_pos;
        }
        if let Some((_, after_cols)) = parse_balanced_braces(input, inner_start) {
            inner_start = after_cols;
        }
        if let Some(close_rel) = input[inner_start..].find(close_tag) {
            let inner_end = inner_start + close_rel;
            let raw_table = &input[inner_start..inner_end];
            let cleaned_table = raw_table
                .replace("\\toprule", "")
                .replace("\\midrule", "")
                .replace("\\bottomrule", "")
                .replace("\\hline", "");
            let mut rows = Vec::<Vec<String>>::new();
            for raw_row in cleaned_table.split("\\\\") {
                let r = raw_row.trim();
                if r.is_empty() {
                    continue;
                }
                let cells: Vec<String> = r
                    .split('&')
                    .map(|c| convert_tex_inline(c.trim(), bib_items))
                    .collect();
                if cells.iter().any(|c| !c.is_empty()) {
                    rows.push(cells);
                }
            }
            if let Some(first_row) = rows.first() {
                let cols = first_row.len().max(1);
                out.push('\n');
                out.push_str(&format!("| {} |\n", first_row.join(" | ")));
                let sep = vec!["---"; cols].join(" | ");
                out.push_str(&format!("| {sep} |\n"));
                for row in rows.iter().skip(1) {
                    let mut padded = row.clone();
                    while padded.len() < cols {
                        padded.push(String::new());
                    }
                    out.push_str(&format!("| {} |\n", padded.join(" | ")));
                }
                out.push('\n');
            }
            search = inner_end + close_tag.len();
        } else {
            out.push_str(open_tag);
            search = inner_start;
        }
    }
    out.push_str(&input[search..]);
    out
}

fn convert_section_commands(input: &str, bib_items: &[BibItem]) -> String {
    let mut current = input.to_string();
    let specs = [
        ("\\part*", "#"),
        ("\\part", "#"),
        ("\\chapter*", "#"),
        ("\\chapter", "#"),
        ("\\section*", "##"),
        ("\\section", "##"),
        ("\\subsection*", "###"),
        ("\\subsection", "###"),
        ("\\subsubsection*", "####"),
        ("\\subsubsection", "####"),
    ];

    for (cmd, hashes) in specs {
        let mut out = String::with_capacity(current.len());
        let mut search = 0usize;
        while let Some(rel) = current[search..].find(cmd) {
            let idx = search + rel;
            out.push_str(&current[search..idx]);
            let mut cursor = idx + cmd.len();
            if !cmd.ends_with('*') {
                let next_ch = current[cursor..].chars().next();
                if next_ch == Some('*') || next_ch.map(|c| c.is_ascii_alphabetic()).unwrap_or(false)
                {
                    out.push_str(cmd);
                    search = cursor;
                    continue;
                }
            }
            if let Some((_, after_opt)) = parse_optional_brackets(&current, cursor) {
                cursor = after_opt;
            }
            if let Some((heading_raw, after_brace)) = parse_balanced_braces(&current, cursor) {
                let heading_clean = clean_tex_metadata_str(heading_raw, bib_items);
                out.push_str(&format!("\n{hashes} {heading_clean}\n\n"));
                search = after_brace;
            } else {
                out.push_str(cmd);
                search = cursor;
            }
        }
        out.push_str(&current[search..]);
        current = out;
    }

    // Also handle \paragraph{...} and \paragraph*{...} as bold lead-ins
    for cmd in ["\\paragraph*", "\\paragraph"] {
        let mut out = String::with_capacity(current.len());
        let mut search = 0usize;
        while let Some(rel) = current[search..].find(cmd) {
            let idx = search + rel;
            out.push_str(&current[search..idx]);
            let cursor = idx + cmd.len();
            if !cmd.ends_with('*') {
                let next_ch = current[cursor..].chars().next();
                if next_ch == Some('*') || next_ch.map(|c| c.is_ascii_alphabetic()).unwrap_or(false)
                {
                    out.push_str(cmd);
                    search = cursor;
                    continue;
                }
            }
            if let Some((title_raw, after_brace)) = parse_balanced_braces(&current, cursor) {
                let clean = clean_tex_metadata_str(title_raw, bib_items);
                out.push_str(&format!("\n**{clean}.** "));
                search = after_brace;
            } else {
                out.push_str(cmd);
                search = cursor;
            }
        }
        out.push_str(&current[search..]);
        current = out;
    }

    current
}

fn convert_tex_paragraphs(input: &str, bib_items: &[BibItem]) -> String {
    let lines: Vec<&str> = input.split('\n').collect();
    let mut out = Vec::<String>::new();
    let mut i = 0usize;

    while i < lines.len() {
        let trimmed = lines[i].trim();

        // Preserve fenced code blocks verbatim
        if trimmed.starts_with("```") {
            out.push(lines[i].to_string());
            i += 1;
            while i < lines.len() && !lines[i].trim().starts_with("```") {
                out.push(lines[i].to_string());
                i += 1;
            }
            if i < lines.len() {
                out.push(lines[i].to_string());
                i += 1;
            }
            continue;
        }

        // Preserve display math $$ ... $$ blocks verbatim
        if trimmed == "$$" {
            out.push("$$".to_string());
            i += 1;
            while i < lines.len() && lines[i].trim() != "$$" {
                out.push(lines[i].to_string());
                i += 1;
            }
            if i < lines.len() {
                out.push("$$".to_string());
                i += 1;
            }
            continue;
        }

        // Already-converted headings, blockquotes, list items, or table rows
        if trimmed.starts_with('#')
            || trimmed.starts_with('>')
            || trimmed.starts_with("- ")
            || trimmed.starts_with("| ")
        {
            out.push(lines[i].to_string());
            i += 1;
            continue;
        }

        out.push(convert_tex_inline(lines[i], bib_items));
        i += 1;
    }

    out.join("\n")
}

/// Convert inline LaTeX commands (`\textit`, `\textbf`, `\emph`, `\texttt`, `\cite`, `\citep`,
/// `\citet`, `\href`, `\url`, `\footnote`, `\(...\)`, quotes, dashes, escapes) while keeping
/// `$ ... $` inline math intact for KaTeX.
fn convert_tex_inline(input: &str, bib_items: &[BibItem]) -> String {
    // 1. Convert \( ... \) to $ ... $
    let mut s = String::with_capacity(input.len());
    let mut search = 0usize;
    while let Some(rel) = input[search..].find("\\(") {
        let idx = search + rel;
        s.push_str(&input[search..idx]);
        let start = idx + 2;
        if let Some(close_rel) = input[start..].find("\\)") {
            let end = start + close_rel;
            s.push('$');
            s.push_str(input[start..end].trim());
            s.push('$');
            search = end + 2;
        } else {
            s.push_str("\\(");
            search = start;
        }
    }
    s.push_str(&input[search..]);

    // 2. Split by inline math `$ ... $` so we never corrupt LaTeX commands inside math!
    let mut out = String::with_capacity(s.len() + 16);
    let bytes = s.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'$' && (i == 0 || bytes[i - 1] != b'\\') {
            if let Some(close_rel) = find_unescaped_dollar(&s[i + 1..]) {
                let end = i + 1 + close_rel + 1;
                out.push_str(&s[i..end]);
                i = end;
                continue;
            }
        }
        // Find next unescaped `$`
        let next_dollar = find_unescaped_dollar(&s[i..])
            .map(|r| i + r)
            .unwrap_or(bytes.len());
        let prose_chunk = &s[i..next_dollar];
        out.push_str(&convert_tex_prose_segment(prose_chunk, bib_items));
        i = next_dollar;
    }
    out
}

fn find_unescaped_dollar(s: &str) -> Option<usize> {
    let bytes = s.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 2;
            continue;
        }
        if bytes[i] == b'$' {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn convert_tex_prose_segment(segment: &str, bib_items: &[BibItem]) -> String {
    let mut s = segment.to_string();

    // Formatting commands with 1 brace argument (iterated so nested commands unwrap cleanly)
    for _pass in 0..3 {
        let mut changed = false;
        for (cmd, open_md, close_md) in [
            ("\\textbf", "**", "**"),
            ("\\textit", "*", "*"),
            ("\\emph", "*", "*"),
            ("\\textsc", "*", "*"),
            ("\\textsl", "*", "*"),
            ("\\underline", "*", "*"),
            ("\\texttt", "`", "`"),
        ] {
            if let Some(updated) = replace_1arg_cmd(&s, cmd, |inner| {
                format!(
                    "{open_md}{}{close_md}",
                    convert_tex_inline(inner, bib_items)
                )
            }) {
                s = updated;
                changed = true;
            }
        }
        if let Some(updated) = replace_1arg_cmd(&s, "\\url", |inner| {
            let u = inner.trim();
            format!("[{u}]({u})")
        }) {
            s = updated;
            changed = true;
        }
        if let Some(updated) = replace_1arg_cmd(&s, "\\footnote", |inner| {
            format!(" *(Note: {})*", convert_tex_inline(inner.trim(), bib_items))
        }) {
            s = updated;
            changed = true;
        }
        if let Some(updated) = replace_2arg_cmd(&s, "\\href", |url, label| {
            format!(
                "[{}]({})",
                convert_tex_inline(label.trim(), bib_items),
                url.trim()
            )
        }) {
            s = updated;
            changed = true;
        }
        if !changed {
            break;
        }
    }

    // Citations: \citep{...}, \citet{...}, \citealt{...}, \cite{...}
    for cmd in ["\\citep", "\\citet", "\\citealt", "\\citeauthor", "\\cite"] {
        while let Some(updated) = replace_citation_cmd(&s, cmd, bib_items) {
            s = updated;
        }
    }

    // Cross-references: \eqref{...}, \autoref{...}, \ref{...}, \label{...}
    for cmd in ["\\eqref", "\\autoref", "\\cref", "\\Cref", "\\ref"] {
        if let Some(updated) = replace_1arg_cmd(&s, cmd, |lbl| format!("({})", lbl.trim())) {
            s = updated;
        }
    }
    if let Some(updated) = replace_1arg_cmd(&s, "\\label", |_lbl| String::new()) {
        s = updated;
    }

    // Typography & TeX ligatures / escapes in prose
    s = s
        .replace("``", "“")
        .replace("''", "”")
        .replace("---", "—")
        .replace("--", "–")
        .replace('~', " ")
        .replace("\\&", "&")
        .replace("\\%", "%")
        .replace("\\$", "$")
        .replace("\\#", "#")
        .replace("\\_", "_")
        .replace("\\{", "{")
        .replace("\\}", "}")
        .replace("\\dots", "…")
        .replace("\\ldots", "…");

    s
}

fn replace_1arg_cmd<F>(input: &str, cmd: &str, mut f: F) -> Option<String>
where
    F: FnMut(&str) -> String,
{
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    let mut any = false;
    while let Some(rel) = input[search..].find(cmd) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let after = idx + cmd.len();
        let next_is_alpha = input[after..]
            .chars()
            .next()
            .map(|c| c.is_ascii_alphabetic())
            .unwrap_or(false);
        if !next_is_alpha {
            if let Some((arg, after_brace)) = parse_balanced_braces(input, after) {
                out.push_str(&f(arg));
                search = after_brace;
                any = true;
                continue;
            }
        }
        out.push_str(cmd);
        search = after;
    }
    if !any {
        return None;
    }
    out.push_str(&input[search..]);
    Some(out)
}

fn replace_2arg_cmd<F>(input: &str, cmd: &str, mut f: F) -> Option<String>
where
    F: FnMut(&str, &str) -> String,
{
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    let mut any = false;
    while let Some(rel) = input[search..].find(cmd) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let after = idx + cmd.len();
        let next_is_alpha = input[after..]
            .chars()
            .next()
            .map(|c| c.is_ascii_alphabetic())
            .unwrap_or(false);
        if !next_is_alpha {
            if let Some((arg1, after1)) = parse_balanced_braces(input, after) {
                if let Some((arg2, after2)) = parse_balanced_braces(input, after1) {
                    out.push_str(&f(arg1, arg2));
                    search = after2;
                    any = true;
                    continue;
                }
            }
        }
        out.push_str(cmd);
        search = after;
    }
    if !any {
        return None;
    }
    out.push_str(&input[search..]);
    Some(out)
}

fn replace_citation_cmd(input: &str, cmd: &str, bib_items: &[BibItem]) -> Option<String> {
    let mut out = String::with_capacity(input.len());
    let mut search = 0usize;
    let mut any = false;
    while let Some(rel) = input[search..].find(cmd) {
        let idx = search + rel;
        out.push_str(&input[search..idx]);
        let mut cursor = idx + cmd.len();
        let next_is_alpha = input[cursor..]
            .chars()
            .next()
            .map(|c| c.is_ascii_alphabetic())
            .unwrap_or(false);
        if next_is_alpha {
            out.push_str(cmd);
            search = cursor;
            continue;
        }
        let mut opt_note = String::new();
        if let Some((opt1, after_opt1)) = parse_optional_brackets(input, cursor) {
            opt_note = opt1.trim().to_string();
            cursor = after_opt1;
            if let Some((opt2, after_opt2)) = parse_optional_brackets(input, cursor) {
                opt_note = opt2.trim().to_string();
                cursor = after_opt2;
            }
        }
        if let Some((keys_raw, after_brace)) = parse_balanced_braces(input, cursor) {
            let resolved: Vec<String> = keys_raw
                .split(',')
                .map(|k| {
                    let key = k.trim();
                    bib_items
                        .iter()
                        .find(|b| b.key == key)
                        .map(|b| {
                            if !b.label.is_empty() {
                                b.label.clone()
                            } else {
                                b.key.clone()
                            }
                        })
                        .unwrap_or_else(|| key.to_string())
                })
                .collect();
            if opt_note.is_empty() {
                out.push_str(&format!("[{}]", resolved.join("; ")));
            } else {
                out.push_str(&format!("[{}, {}]", resolved.join("; "), opt_note));
            }
            search = after_brace;
            any = true;
        } else {
            out.push_str(cmd);
            search = cursor;
        }
    }
    if !any {
        return None;
    }
    out.push_str(&input[search..]);
    Some(out)
}

fn compile_bibtex_to_markdown(bib_source: &str) -> String {
    let mut out = vec![
        "# 📚 BibTeX Bibliography".to_string(),
        String::new(),
        "> [!NOTE]".to_string(),
        "> Rendered by **Qwave Sovereign TeX & BibTeX Engine**".to_string(),
        String::new(),
    ];
    for chunk in bib_source.split("\n@") {
        let trimmed = chunk.trim().trim_start_matches('@');
        if trimmed.is_empty() {
            continue;
        }
        if let Some(brace_idx) = trimmed.find('{') {
            let entry_kind = trimmed[..brace_idx].trim();
            let rest = &trimmed[brace_idx + 1..];
            let key = rest.split(',').next().unwrap_or("entry").trim();
            out.push(format!("## `{key}` ({entry_kind})"));
            out.push(format!("```bibtex\n@{trimmed}\n```"));
            out.push(String::new());
        }
    }
    out.join("\n")
}

// ============================================================================
// SOVEREIGN PDF READER, REFLOW ENGINE & PURE-RUST ZLIB/DEFLATE STREAM PARSER
// ============================================================================

/// Extracted PDF metadata and per-page text.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PdfExtract {
    pub title: String,
    pub author: String,
    pub date: String,
    pub page_count: usize,
    pub pages: Vec<String>,
}

/// Format an extracted PDF (`PdfExtract`) into Sovereign Markdown with:
/// - Detected paper title & author header
/// - Interactive `qwave-pdf` viewer switcher dock (Reader + Original PDF + Split View)
/// - Reflowed paragraphs across hard-wrapped lines & page breaks
/// - Promoted `Abstract`, `References`, and numbered section headings (`## 1. ...`)
/// - Direct `#page-N` TOC landmarks
pub fn format_pdf_to_markdown(
    filename: &str,
    pdf_asset_url: Option<&str>,
    extract: &PdfExtract,
) -> String {
    format_pdf_to_markdown_with_mem8(filename, pdf_asset_url, extract, &[])
}

/// Format an extracted PDF (`PdfExtract`) into Sovereign Markdown enriched with:
/// - Interactive `qwave-pdf` Studio Dock (`⚡ Summary`, `🔥 PhoeniX'd`, `📖 Full Reader`, `🌗 Split`, `📄 Original PDF`)
/// - `## 🧠 Executive Summary & MEM|8 Personalized Lens` (adapted to the user's MEM|8 memory anchors)
/// - `## 🔥 PhoeniX'd High-Resolution Distillation` (Custodian de-duplicated crystal sections & formal invariants)
/// - `## 📖 Full Sovereign Document` (reflowed pages, promoted section headings, and `#page-N` landmarks)
pub fn format_pdf_to_markdown_with_mem8(
    filename: &str,
    pdf_asset_url: Option<&str>,
    extract: &PdfExtract,
    mem8_anchors: &[String],
) -> String {
    let total_pages = extract.page_count.max(extract.pages.len()).max(1);

    // 1. Detect paper title & author from Page 1 if PDF Info dict was empty
    let (detected_title, detected_author, detected_date, page1_skip_lines) =
        detect_pdf_frontmatter(filename, extract);

    let mut out = Vec::<String>::new();
    out.push(format!("# {detected_title}"));

    let mut meta_badges = Vec::new();
    if !detected_author.is_empty() {
        meta_badges.push(format!("✍️ **{detected_author}**"));
    }
    if !detected_date.is_empty() {
        meta_badges.push(format!("📅 {detected_date}"));
    }
    meta_badges.push(format!("📄 **{total_pages} Pages**"));
    meta_badges.push("🔊 *Qwave Sovereign PDF + PhoeniX & MEM|8 Studio*".to_string());
    out.push(meta_badges.join(" · "));
    out.push(String::new());

    // 2. Interactive PDF View Switcher block (compiled by `qwave_core::markdown` into the PDF dock)
    if let Some(asset_url) = pdf_asset_url {
        out.push("```qwave-pdf".to_string());
        out.push(format!("src={asset_url}"));
        out.push(format!("pages={total_pages}"));
        out.push(format!("title={detected_title}"));
        out.push("```".to_string());
        out.push(String::new());
    }

    // 3. Reflow and structure each page into clean sections & paragraphs
    let mut body_pages = Vec::<String>::new();
    for (idx, raw_page) in extract.pages.iter().enumerate() {
        let page_num = idx + 1;
        if page_num > 1 || total_pages > 1 {
            body_pages.push(format!("#### 📄 Page {page_num}"));
            body_pages.push(String::new());
        }
        let skip = if idx == 0 { page1_skip_lines } else { 0 };
        let reflowed = reflow_pdf_page_text(raw_page, page_num, skip);
        if !reflowed.trim().is_empty() {
            body_pages.push(reflowed);
            body_pages.push(String::new());
        }
    }

    let full_body = body_pages.join("\n");
    if full_body.len() > 280 {
        let summary = summarize_markdown_with_mem8(
            &detected_title,
            &detected_author,
            &full_body,
            mem8_anchors,
        );
        out.push(format_summary_and_phoenix_markdown(&summary));
        out.push(String::new());
    }

    out.push(full_body);

    if extract.pages.is_empty() || extract.pages.iter().all(|p| p.trim().is_empty()) {
        out.push("> [!NOTE]".to_string());
        out.push("> This PDF contains scanned images or custom vector glyphs without embedded text streams. Use the **📄 Original PDF Canvas** or **🌗 Split View** above to inspect the full visual pages.".to_string());
    }

    out.join("\n")
}

fn detect_pdf_frontmatter(filename: &str, extract: &PdfExtract) -> (String, String, String, usize) {
    let fallback_title = filename
        .strip_suffix(".pdf")
        .or_else(|| filename.strip_suffix(".PDF"))
        .unwrap_or(filename)
        .replace(['_', '-'], " ");

    let Some(first_page) = extract.pages.first() else {
        let t = if extract.title.trim().is_empty() {
            fallback_title
        } else {
            extract.title.trim().to_string()
        };
        return (t, extract.author.clone(), extract.date.clone(), 0);
    };

    let non_empty: Vec<(usize, &str)> = first_page
        .lines()
        .enumerate()
        .map(|(i, l)| (i, l.trim()))
        .filter(|(_, l)| !l.is_empty())
        .collect();

    // Look for "Abstract" in the first 12 non-empty lines (classic academic paper layout)
    if let Some(abs_pos) = non_empty
        .iter()
        .take(12)
        .position(|(_, l)| l.eq_ignore_ascii_case("abstract"))
    {
        if abs_pos >= 1 {
            let header_lines: Vec<&str> = non_empty[..abs_pos].iter().map(|(_, l)| *l).collect();
            let title = if !extract.title.trim().is_empty() {
                extract.title.trim().to_string()
            } else if header_lines.len() >= 2 && header_lines[1].len() > 24 {
                format!("{}: {}", header_lines[0], header_lines[1])
            } else {
                header_lines[0].to_string()
            };
            let mut author = extract.author.trim().to_string();
            let mut date = extract.date.trim().to_string();
            let start_meta = if header_lines.len() >= 2 && header_lines[1].len() > 24 {
                2
            } else {
                1
            };
            for &hl in &header_lines[start_meta..] {
                if date.is_empty() && looks_like_date_line(hl) {
                    date = hl.to_string();
                } else if author.is_empty() {
                    author = hl.to_string();
                } else if !looks_like_date_line(hl) && author.len() < 60 {
                    author.push_str(" · ");
                    author.push_str(hl);
                }
            }
            let skip_raw_lines = non_empty[abs_pos].0;
            return (title, author, date, skip_raw_lines);
        }
    }

    let title = if !extract.title.trim().is_empty() {
        extract.title.trim().to_string()
    } else if let Some((_, first_line)) = non_empty.first() {
        if first_line.len() <= 110 {
            (*first_line).to_string()
        } else {
            fallback_title
        }
    } else {
        fallback_title
    };

    (title, extract.author.clone(), extract.date.clone(), 0)
}

fn looks_like_date_line(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    for month in [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ] {
        if lower.contains(month) && s.len() <= 40 {
            return true;
        }
    }
    s.len() == 4 && s.bytes().all(|b| b.is_ascii_digit())
}

fn reflow_pdf_page_text(raw_page: &str, page_num: usize, skip_first_n_lines: usize) -> String {
    let mut raw_lines: Vec<&str> = raw_page.lines().skip(skip_first_n_lines).collect();

    // Strip trailing page number footer (e.g. `1` at bottom of Page 1)
    while let Some(last) = raw_lines.last() {
        if last.trim().is_empty() {
            raw_lines.pop();
        } else if last.trim() == page_num.to_string() {
            raw_lines.pop();
            break;
        } else {
            break;
        }
    }

    let mut out_blocks = Vec::<String>::new();
    let mut current_para = String::new();
    let mut in_abstract = false;
    let mut abstract_buf = Vec::<String>::new();

    let flush_para = |para: &mut String,
                      in_abs: &mut bool,
                      abs_buf: &mut Vec<String>,
                      blocks: &mut Vec<String>| {
        let trimmed = para.trim();
        if trimmed.is_empty() {
            para.clear();
            return;
        }
        if *in_abs {
            abs_buf.push(trimmed.to_string());
            // Abstract is typically 1 paragraph
            let quoted: Vec<String> = abs_buf.iter().map(|p| format!("> {p}")).collect();
            blocks.push(format!(
                "> [!NOTE]\n> **Abstract**\n>\n{}",
                quoted.join("\n>\n")
            ));
            abs_buf.clear();
            *in_abs = false;
        } else {
            blocks.push(trimmed.to_string());
        }
        para.clear();
    };

    let mut i = 0usize;
    while i < raw_lines.len() {
        let line = raw_lines[i].trim();

        if line.is_empty() {
            flush_para(
                &mut current_para,
                &mut in_abstract,
                &mut abstract_buf,
                &mut out_blocks,
            );
            i += 1;
            continue;
        }

        // Detect standalone "Abstract"
        if line.eq_ignore_ascii_case("abstract") {
            flush_para(
                &mut current_para,
                &mut in_abstract,
                &mut abstract_buf,
                &mut out_blocks,
            );
            in_abstract = true;
            i += 1;
            continue;
        }

        // Detect standalone "References" or "Bibliography" or "Acknowledgments"
        if matches!(
            line.to_ascii_lowercase().as_str(),
            "references" | "bibliography" | "acknowledgments" | "acknowledgements" | "appendix"
        ) {
            flush_para(
                &mut current_para,
                &mut in_abstract,
                &mut abstract_buf,
                &mut out_blocks,
            );
            out_blocks.push(format!("## {line}"));
            i += 1;
            continue;
        }

        // Detect two-line pdfTeX section heading:
        // Line i: `1` or `2.1`
        // Line i+1 (or after blank line): `Introduction: ...` (possibly wrapped onto a 2nd title line)
        if is_section_number_token(line) {
            let mut next_idx = i + 1;
            while next_idx < raw_lines.len() && raw_lines[next_idx].trim().is_empty() {
                next_idx += 1;
            }
            if next_idx < raw_lines.len() {
                let title_line1 = raw_lines[next_idx].trim();
                if looks_like_section_title(title_line1) {
                    flush_para(
                        &mut current_para,
                        &mut in_abstract,
                        &mut abstract_buf,
                        &mut out_blocks,
                    );
                    let mut full_sec_title = title_line1.to_string();
                    let mut consumed_to = next_idx + 1;
                    // Check if the heading wraps onto one more short title line before a blank line
                    if consumed_to < raw_lines.len() {
                        let title_line2 = raw_lines[consumed_to].trim();
                        let line_after_2_empty = consumed_to + 1 >= raw_lines.len()
                            || raw_lines[consumed_to + 1].trim().is_empty();
                        if !title_line2.is_empty()
                            && title_line2.len() <= 56
                            && !title_line2.ends_with('.')
                            && line_after_2_empty
                        {
                            full_sec_title.push(' ');
                            full_sec_title.push_str(title_line2);
                            consumed_to += 1;
                        }
                    }
                    let hashes = if line.contains('.') { "###" } else { "##" };
                    out_blocks.push(format!("{hashes} {line}. {full_sec_title}"));
                    i = consumed_to;
                    continue;
                }
            }
        }

        // Detect single-line numbered section heading: `1 Introduction` or `2.1 Non-retroactivity`
        if let Some((sec_num, sec_title)) = parse_single_line_section_heading(line) {
            let next_is_blank = i + 1 >= raw_lines.len() || raw_lines[i + 1].trim().is_empty();
            if current_para.is_empty() && next_is_blank {
                let hashes = if sec_num.contains('.') { "###" } else { "##" };
                out_blocks.push(format!("{hashes} {sec_num} {sec_title}"));
                i += 1;
                continue;
            }
        }

        // Detect Theorem / Proposition / Definition / Lemma / Proof lead-in lines
        if current_para.is_empty() && starts_with_theorem_keyword(line) {
            current_para.push_str("**");
            if let Some(dot_pos) = line.find(". ") {
                current_para.push_str(&line[..dot_pos + 1]);
                current_para.push_str("** ");
                current_para.push_str(&line[dot_pos + 2..]);
            } else {
                current_para.push_str(line);
                current_para.push_str("**");
            }
            i += 1;
            continue;
        }

        // Reflow line into `current_para` (de-hyphenating `word-\ncontinuation`)
        if current_para.is_empty() {
            current_para.push_str(line);
        } else if current_para.ends_with('-')
            && current_para.len() >= 2
            && current_para
                .as_bytes()
                .get(current_para.len() - 2)
                .map(|b| b.is_ascii_alphabetic())
                .unwrap_or(false)
            && line
                .chars()
                .next()
                .map(|c| c.is_ascii_lowercase())
                .unwrap_or(false)
        {
            current_para.pop(); // remove trailing hyphen
            current_para.push_str(line);
        } else {
            current_para.push(' ');
            current_para.push_str(line);
        }

        i += 1;
    }

    flush_para(
        &mut current_para,
        &mut in_abstract,
        &mut abstract_buf,
        &mut out_blocks,
    );
    out_blocks.join("\n\n")
}

fn is_section_number_token(s: &str) -> bool {
    if s.is_empty() || s.len() > 8 {
        return false;
    }
    let first = s.as_bytes()[0];
    if !first.is_ascii_digit() {
        return false;
    }
    s.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && !s.starts_with('0')
        && s.parse::<u32>().map(|n| n <= 35).unwrap_or(true)
}

fn looks_like_section_title(s: &str) -> bool {
    if s.is_empty() || s.len() > 88 || s.ends_with('.') {
        return false;
    }
    let first = s.chars().next().unwrap_or(' ');
    first.is_ascii_uppercase()
}

fn parse_single_line_section_heading(s: &str) -> Option<(&str, &str)> {
    let (num, rest) = s.split_once(' ')?;
    let num_clean = num.trim_end_matches('.');
    if !is_section_number_token(num_clean) {
        return None;
    }
    let title = rest.trim();
    if looks_like_section_title(title) && title.len() <= 78 {
        Some((num, title))
    } else {
        None
    }
}

fn starts_with_theorem_keyword(s: &str) -> bool {
    for kw in [
        "Proposition ",
        "Theorem ",
        "Lemma ",
        "Corollary ",
        "Definition ",
        "Remark ",
        "Proof.",
        "Proof ",
    ] {
        if s.starts_with(kw) {
            return true;
        }
    }
    false
}

/// Pure-Rust zero-dependency PDF text & metadata extractor.
/// Handles uncompressed streams AND `/FlateDecode` (zlib / RFC 1951 deflate) streams.
pub fn extract_pdf_text_pure_rust(pdf_bytes: &[u8]) -> PdfExtract {
    let mut extract = PdfExtract::default();
    if pdf_bytes.len() < 16 {
        return extract;
    }

    let lossy = String::from_utf8_lossy(pdf_bytes);
    extract.title = extract_pdf_dict_string(&lossy, "/Title").unwrap_or_default();
    extract.author = extract_pdf_dict_string(&lossy, "/Author").unwrap_or_default();

    // Count `/Type /Page` (excluding `/Type /Pages`)
    let mut page_count = 0usize;
    let mut search = 0usize;
    while let Some(rel) = lossy[search..].find("/Type") {
        let idx = search + rel + 5;
        let rest = lossy[idx..].trim_start();
        if let Some(after_page) = rest.strip_prefix("/Page") {
            let next_ch = after_page.chars().next().unwrap_or(' ');
            if !next_ch.is_ascii_alphabetic() {
                page_count += 1;
            }
        }
        search = idx;
    }

    // Scan all `stream` ... `endstream` blocks and extract `BT ... ET` text operators
    let mut current_page_lines = Vec::<String>::new();
    let mut pos = 0usize;
    while let Some(stream_rel) = find_subslice(&pdf_bytes[pos..], b"stream") {
        let stream_kw = pos + stream_rel;
        let hdr_start = stream_kw.saturating_sub(280);
        let dict_window = String::from_utf8_lossy(&pdf_bytes[hdr_start..stream_kw]);

        let mut data_start = stream_kw + 6;
        if pdf_bytes.get(data_start) == Some(&b'\r')
            && pdf_bytes.get(data_start + 1) == Some(&b'\n')
        {
            data_start += 2;
        } else if pdf_bytes.get(data_start) == Some(&b'\n')
            || pdf_bytes.get(data_start) == Some(&b'\r')
        {
            data_start += 1;
        } else {
            pos = data_start;
            continue;
        }

        let Some(end_rel) = find_subslice(&pdf_bytes[data_start..], b"endstream") else {
            break;
        };
        let mut data_end = data_start + end_rel;
        while data_end > data_start
            && (pdf_bytes[data_end - 1] == b'\n' || pdf_bytes[data_end - 1] == b'\r')
        {
            data_end -= 1;
        }
        let raw_stream = &pdf_bytes[data_start..data_end];
        pos = data_start + end_rel + 9;

        // Skip non-content streams (images, fonts, metadata)
        if dict_window.contains("/Subtype /Image")
            || dict_window.contains("/Subtype/Image")
            || dict_window.contains("/FontFile")
            || dict_window.contains("/Type /XRef")
        {
            continue;
        }

        let decoded_opt = if dict_window.contains("/FlateDecode") {
            inflate_zlib_or_deflate(raw_stream)
        } else {
            Some(raw_stream.to_vec())
        };

        if let Some(decoded) = decoded_opt {
            let text_chunk = extract_bt_et_text(&decoded);
            if !text_chunk.trim().is_empty() {
                current_page_lines.push(text_chunk);
            }
        }
    }

    if !current_page_lines.is_empty() {
        extract.pages = current_page_lines;
    }
    extract.page_count = page_count.max(extract.pages.len());
    extract
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn extract_pdf_dict_string(lossy: &str, key: &str) -> Option<String> {
    let idx = lossy.find(key)?;
    let rest = lossy[idx + key.len()..].trim_start();
    if !rest.starts_with('(') {
        return None;
    }
    let (decoded, _) = parse_pdf_literal_string(rest.as_bytes(), 0)?;
    let trimmed = decoded.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn parse_pdf_literal_string(bytes: &[u8], start: usize) -> Option<(String, usize)> {
    if bytes.get(start) != Some(&b'(') {
        return None;
    }
    let mut out = Vec::<u8>::new();
    let mut depth = 1usize;
    let mut i = start + 1;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'\\' {
            i += 1;
            if i >= bytes.len() {
                break;
            }
            match bytes[i] {
                b'n' => out.push(b'\n'),
                b'r' => out.push(b'\r'),
                b't' => out.push(b'\t'),
                b'b' => out.push(8),
                b'f' => out.push(12),
                b'(' => out.push(b'('),
                b')' => out.push(b')'),
                b'\\' => out.push(b'\\'),
                b'\r' | b'\n' => {}
                d if (b'0'..=b'7').contains(&d) => {
                    let mut oct = (d - b'0') as u32;
                    for _ in 0..2 {
                        if i + 1 < bytes.len() && (b'0'..=b'7').contains(&bytes[i + 1]) {
                            i += 1;
                            oct = (oct * 8) + (bytes[i] - b'0') as u32;
                        } else {
                            break;
                        }
                    }
                    out.push((oct & 0xFF) as u8);
                }
                other => out.push(other),
            }
            i += 1;
            continue;
        }
        if b == b'(' {
            depth += 1;
            out.push(b);
        } else if b == b')' {
            depth -= 1;
            if depth == 0 {
                // Check for UTF-16BE BOM (0xFE 0xFF)
                if out.len() >= 2 && out[0] == 0xFE && out[1] == 0xFF {
                    let mut u16s = Vec::with_capacity(out.len() / 2);
                    let mut j = 2;
                    while j + 1 < out.len() {
                        u16s.push(u16::from_be_bytes([out[j], out[j + 1]]));
                        j += 2;
                    }
                    return Some((String::from_utf16_lossy(&u16s), i + 1));
                }
                return Some((String::from_utf8_lossy(&out).into_owned(), i + 1));
            }
            out.push(b);
        } else {
            out.push(b);
        }
        i += 1;
    }
    None
}

fn extract_bt_et_text(content: &[u8]) -> String {
    let mut out = String::new();
    let mut i = 0usize;
    while i < content.len() {
        // Look for `(` literal strings or `[` TJ arrays inside content stream
        if content[i] == b'(' {
            if let Some((s, next_i)) = parse_pdf_literal_string(content, i) {
                out.push_str(&s);
                i = next_i;
                continue;
            }
        } else if content[i] == b'[' {
            let mut j = i + 1;
            while j < content.len() && content[j] != b']' {
                if content[j] == b'(' {
                    if let Some((s, next_j)) = parse_pdf_literal_string(content, j) {
                        out.push_str(&s);
                        j = next_j;
                        continue;
                    }
                } else if content[j] == b'-' {
                    // Large negative kerning inside TJ array (e.g. -250) represents an inter-word space
                    let mut k = j + 1;
                    let mut val = 0i32;
                    while k < content.len() && content[k].is_ascii_digit() {
                        val = val.saturating_mul(10) + (content[k] - b'0') as i32;
                        k += 1;
                    }
                    if val >= 120 {
                        out.push(' ');
                    }
                    j = k;
                    continue;
                }
                j += 1;
            }
            i = (j + 1).min(content.len());
            continue;
        } else if i + 2 <= content.len()
            && (&content[i..i + 2] == b"Td"
                || &content[i..i + 2] == b"TD"
                || &content[i..i + 2] == b"T*"
                || &content[i..i + 2] == b"ET")
        {
            if !out.ends_with('\n') && !out.is_empty() {
                out.push('\n');
            }
            i += 2;
            continue;
        }
        i += 1;
    }
    out
}

// Minimal Pure-Rust RFC 1950 (zlib) + RFC 1951 (DEFLATE) decompressor
fn inflate_zlib_or_deflate(input: &[u8]) -> Option<Vec<u8>> {
    if input.len() < 2 {
        return None;
    }
    // Check for 2-byte zlib header (CMF/FLG)
    let cmf = input[0] as u16;
    let flg = input[1] as u16;
    let start = if (cmf & 0x0F) == 8 && ((cmf << 8) + flg) % 31 == 0 {
        if (flg & 0x20) != 0 { 6 } else { 2 }
    } else {
        0
    };
    if start >= input.len() {
        return None;
    }
    inflate_raw_deflate(&input[start..])
}

struct BitReader<'a> {
    data: &'a [u8],
    byte_pos: usize,
    bit_pos: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            byte_pos: 0,
            bit_pos: 0,
        }
    }

    fn read_bit(&mut self) -> Option<u32> {
        if self.byte_pos >= self.data.len() {
            return None;
        }
        let bit = ((self.data[self.byte_pos] >> self.bit_pos) & 1) as u32;
        self.bit_pos += 1;
        if self.bit_pos == 8 {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
        Some(bit)
    }

    fn read_bits(&mut self, count: u8) -> Option<u32> {
        let mut val = 0u32;
        for i in 0..count {
            val |= self.read_bit()? << i;
        }
        Some(val)
    }

    fn align_byte(&mut self) {
        if self.bit_pos != 0 {
            self.bit_pos = 0;
            self.byte_pos += 1;
        }
    }
}

#[derive(Clone)]
struct HuffmanTable {
    counts: [u16; 16],
    symbols: Vec<u16>,
}

impl HuffmanTable {
    fn build(lengths: &[u8]) -> Option<Self> {
        let mut counts = [0u16; 16];
        for &len in lengths {
            if len as usize >= 16 {
                return None;
            }
            if len > 0 {
                counts[len as usize] += 1;
            }
        }
        let mut offsets = [0u16; 16];
        let mut total = 0u16;
        for bits in 1..16 {
            offsets[bits] = total;
            total += counts[bits];
        }
        let mut symbols = vec![0u16; total as usize];
        for (sym, &len) in lengths.iter().enumerate() {
            if len > 0 {
                let idx = offsets[len as usize] as usize;
                if idx < symbols.len() {
                    symbols[idx] = sym as u16;
                }
                offsets[len as usize] += 1;
            }
        }
        Some(Self { counts, symbols })
    }

    fn decode(&self, reader: &mut BitReader<'_>) -> Option<u16> {
        let mut code = 0i32;
        let mut first = 0i32;
        let mut index = 0i32;
        for len in 1..16 {
            code |= reader.read_bit()? as i32;
            let count = self.counts[len] as i32;
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

fn inflate_raw_deflate(data: &[u8]) -> Option<Vec<u8>> {
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
    let mut out = Vec::<u8>::with_capacity(data.len().saturating_mul(2).min(4 * 1024 * 1024));

    loop {
        let bfinal = reader.read_bit()?;
        let btype = reader.read_bits(2)?;
        match btype {
            0 => {
                reader.align_byte();
                let len = reader.read_bits(16)? as usize;
                let _nlen = reader.read_bits(16)?;
                if reader.byte_pos + len > reader.data.len() {
                    return None;
                }
                out.extend_from_slice(&reader.data[reader.byte_pos..reader.byte_pos + len]);
                reader.byte_pos += len;
            }
            1 | 2 => {
                let (lit_table, dist_table) = if btype == 1 {
                    let mut lit_lengths = [0u8; 288];
                    lit_lengths[..144].fill(8);
                    lit_lengths[144..256].fill(9);
                    lit_lengths[256..280].fill(7);
                    lit_lengths[280..288].fill(8);
                    let dist_lengths = [5u8; 32];
                    (
                        HuffmanTable::build(&lit_lengths)?,
                        HuffmanTable::build(&dist_lengths)?,
                    )
                } else {
                    let hlit = reader.read_bits(5)? as usize + 257;
                    let hdist = reader.read_bits(5)? as usize + 1;
                    let hclen = reader.read_bits(4)? as usize + 4;
                    let mut cl_lengths = [0u8; 19];
                    for i in 0..hclen {
                        cl_lengths[CL_ORDER[i]] = reader.read_bits(3)? as u8;
                    }
                    let cl_table = HuffmanTable::build(&cl_lengths)?;
                    let mut unpacked = Vec::with_capacity(hlit + hdist);
                    while unpacked.len() < hlit + hdist {
                        let sym = cl_table.decode(&mut reader)?;
                        match sym {
                            0..=15 => unpacked.push(sym as u8),
                            16 => {
                                let prev = *unpacked.last()?;
                                let rep = reader.read_bits(2)? as usize + 3;
                                unpacked.extend(std::iter::repeat_n(prev, rep));
                            }
                            17 => {
                                let rep = reader.read_bits(3)? as usize + 3;
                                unpacked.extend(std::iter::repeat_n(0, rep));
                            }
                            18 => {
                                let rep = reader.read_bits(7)? as usize + 11;
                                unpacked.extend(std::iter::repeat_n(0, rep));
                            }
                            _ => return None,
                        }
                    }
                    if unpacked.len() < hlit + hdist {
                        return None;
                    }
                    let lit_t = HuffmanTable::build(&unpacked[..hlit])?;
                    let dist_t = HuffmanTable::build(&unpacked[hlit..hlit + hdist])?;
                    (lit_t, dist_t)
                };

                loop {
                    let sym = lit_table.decode(&mut reader)?;
                    if sym < 256 {
                        out.push(sym as u8);
                    } else if sym == 256 {
                        break;
                    } else {
                        let len_idx = (sym as usize).checked_sub(257)?;
                        if len_idx >= LEN_BASE.len() {
                            return None;
                        }
                        let length = LEN_BASE[len_idx] as usize
                            + reader.read_bits(LEN_EXTRA[len_idx])? as usize;
                        let dist_sym = dist_table.decode(&mut reader)? as usize;
                        if dist_sym >= DIST_BASE.len() {
                            return None;
                        }
                        let distance = DIST_BASE[dist_sym] as usize
                            + reader.read_bits(DIST_EXTRA[dist_sym])? as usize;
                        if distance == 0 || distance > out.len() {
                            return None;
                        }
                        for _ in 0..length {
                            let b = out[out.len() - distance];
                            out.push(b);
                        }
                    }
                    if out.len() > 16 * 1024 * 1024 {
                        return Some(out);
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

// ============================================================================
// SPOKEN NARRATION CLEANER FOR TTS / READ ALOUD (`--speak <file>` & UI Player)
// ============================================================================

/// Convert Markdown or TeX source into smooth, natural human speech text for TTS narration.
pub fn extract_spoken_narration(source: &str, is_tex: bool) -> String {
    let md = if is_tex {
        compile_tex_to_markdown(source)
    } else {
        source.to_string()
    };

    let mut spoken_lines = Vec::<String>::new();
    let lines: Vec<&str> = md.lines().collect();
    let mut i = 0usize;
    while i < lines.len() {
        let t = lines[i].trim();
        if t.is_empty() {
            i += 1;
            continue;
        }
        // Skip fenced code / qwave-pdf / mermaid blocks in spoken narration
        if t.starts_with("```") {
            i += 1;
            while i < lines.len() && !lines[i].trim().starts_with("```") {
                i += 1;
            }
            i += 1;
            continue;
        }
        // Skip page marker headings ("#### 📄 Page 2") so narration flows continuously across pages!
        if t.starts_with("#### 📄 Page ") {
            i += 1;
            continue;
        }
        // Skip alert tags like `> [!NOTE]`
        if t.starts_with("> [!") {
            i += 1;
            continue;
        }

        let cleaned = clean_line_for_speech(t);
        if !cleaned.is_empty() {
            spoken_lines.push(cleaned);
        }
        i += 1;
    }

    spoken_lines.join(" ")
}

fn clean_line_for_speech(line: &str) -> String {
    let mut s = line
        .trim_start_matches('#')
        .trim_start_matches('>')
        .trim_start_matches("- ")
        .trim()
        .to_string();

    if s.is_empty() || s == "$$" {
        return String::new();
    }

    // Translate common LaTeX math macros to natural English words
    for (pat, rep) in [
        ("\\iff", " if and only if "),
        ("\\Longleftrightarrow", " if and only if "),
        ("\\Longrightarrow", " implies "),
        ("\\implies", " implies "),
        ("\\Rightarrow", " implies "),
        ("\\to", " to "),
        ("\\rightarrow", " to "),
        ("\\ge", " is at least "),
        ("\\geq", " is at least "),
        ("\\le", " is at most "),
        ("\\leq", " is at most "),
        ("\\neq", " is not equal to "),
        ("\\approx", " is approximately "),
        ("\\in", " in "),
        ("\\supseteq", " contains "),
        ("\\subseteq", " is a subset of "),
        ("\\mid", " given "),
        ("\\sum", " the sum of "),
        ("\\Delta", " delta "),
        ("\\theta", " theta "),
        ("\\lambda", " lambda "),
        ("\\gamma", " gamma "),
        ("\\tau", " tau "),
        ("\\rho", " rho "),
        ("\\Pi", " pi "),
        ("\\mathbb{E}", " expected value "),
        ("\\operatorname{Auth}", " Auth "),
        ("\\operatorname{Poss}", " Poss "),
        ("\\operatorname{Reach}", " Reach "),
        ("\\operatorname{Sust}", " Sust "),
        ("\\operatorname{W}", " Warrant "),
    ] {
        s = s.replace(pat, rep);
    }

    // Strip Markdown links `[label](url)` -> `label`
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(
            c,
            '*' | '`'
                | '$'
                | '{'
                | '}'
                | '\\'
                | '📄'
                | '\u{270D}'
                | '\u{FE0F}'
                | '📅'
                | '📐'
                | '🔊'
                | '∎'
                | '⚡'
                | '🔥'
                | '🧠'
                | '🌊'
                | '🎬'
                | '🎵'
        ) {
            continue;
        }
        out.push(c);
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

// ============================================================================
// SOVEREIGN SUMMARIZER, MEM|8 PERSONALIZED LENS & PHOENIX HIGH-RES DISTILLER
// ============================================================================

/// Structured summary, MEM|8 personalized synthesis, and PhoeniX high-resolution distillation.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DocumentSummary {
    pub title: String,
    pub author: String,
    pub total_sections: usize,
    pub total_sentences: usize,
    pub phoenix_kept_sentences: usize,
    pub custodian_dropped_duplicates: usize,
    pub executive_thesis: String,
    pub key_claims: Vec<String>,
    pub formal_invariants: Vec<String>,
    pub section_digest: Vec<(String, String)>,
    pub phoenix_crystal_sections: Vec<(String, Vec<String>)>,
    pub mem8_bridges: Vec<String>,
    pub personalized_briefing: String,
}

/// Summarize a Markdown / PDF / TeX document and adapt its reading to the user's MEM|8 memory anchors
/// using 100% integer salience scoring and the Phoenix Custodian novelty gate.
pub fn summarize_markdown_with_mem8(
    title: &str,
    author: &str,
    markdown: &str,
    mem8_anchors: &[String],
) -> DocumentSummary {
    use crate::phoenix::{Custodian, content_hash, tokens};

    let mut summary = DocumentSummary {
        title: title.to_string(),
        author: author.to_string(),
        ..Default::default()
    };

    // 1. Parse sections (`## ...` or `### ...`), skipping `#### 📄 Page N`
    let mut sections: Vec<(String, Vec<String>)> = Vec::new();
    let mut current_sec = String::from("Overview & Abstract");
    let mut current_paras: Vec<String> = Vec::new();
    let mut in_fence = false;

    for raw_line in markdown.lines() {
        let t = raw_line.trim();
        if t.starts_with("```") {
            in_fence = !in_fence;
            continue;
        }
        if in_fence || t.is_empty() || t.starts_with("#### 📄 Page ") {
            continue;
        }
        if let Some(h2) = t.strip_prefix("## ") {
            if !current_paras.is_empty() {
                sections.push((current_sec.clone(), std::mem::take(&mut current_paras)));
            }
            current_sec = h2.trim().to_string();
            continue;
        }
        if let Some(h3) = t.strip_prefix("### ") {
            if !current_paras.is_empty() {
                sections.push((current_sec.clone(), std::mem::take(&mut current_paras)));
            }
            current_sec = h3.trim().to_string();
            continue;
        }
        if t.starts_with("# ") {
            continue;
        }
        let clean_line = t
            .strip_prefix("> ")
            .or_else(|| t.strip_prefix('>'))
            .unwrap_or(t)
            .trim();
        if clean_line.starts_with("[!") || clean_line.is_empty() {
            continue;
        }
        // Collect formal propositions / theorems / equations
        if (clean_line.starts_with("**Proposition")
            || clean_line.starts_with("**Theorem")
            || clean_line.starts_with("**Lemma")
            || clean_line.starts_with("**Corollary")
            || clean_line.starts_with("**Definition")
            || (clean_line.contains("\\iff") && clean_line.len() < 180))
            && summary.formal_invariants.len() < 10
        {
            summary.formal_invariants.push(clean_line.to_string());
        }
        current_paras.push(clean_line.to_string());
    }
    if !current_paras.is_empty() {
        sections.push((current_sec, current_paras));
    }

    summary.total_sections = sections.len();

    // 2. Run Phoenix Custodian & integer Marine Salience Gate across all sentences
    let mut custodian = Custodian::new();
    let mut accepted_token_sets: Vec<Vec<String>> = Vec::new();
    let mut all_scored_sentences: Vec<(i64, String)> = Vec::new();

    for (sec_name, paras) in &sections {
        if sec_name.eq_ignore_ascii_case("references")
            || sec_name.eq_ignore_ascii_case("bibliography")
        {
            continue;
        }
        let joined = paras.join(" ");
        let sentences = split_into_sentences(&joined);
        let mut sec_scored: Vec<(i64, String)> = Vec::new();

        for sent in sentences {
            let s_trim = sent.trim();
            if s_trim.len() < 32 || s_trim.len() > 420 {
                continue;
            }
            summary.total_sentences += 1;
            let norm_key = s_trim.to_ascii_lowercase();
            let h = content_hash(&norm_key);
            if !custodian.adjudicate(h) {
                summary.custodian_dropped_duplicates += 1;
                continue;
            }

            // Integer novelty & salience score (Q10 = 0..2048)
            let sent_toks: Vec<String> = tokens(s_trim)
                .into_iter()
                .map(str::to_ascii_lowercase)
                .collect();
            if sent_toks.len() < 5 {
                continue;
            }
            let max_overlap_q10 = max_token_overlap_q10(&sent_toks, &accepted_token_sets);
            if max_overlap_q10 > 740 {
                // Near-duplicate restatement (>72% token overlap) -> dropped by Phoenix clarity gate
                summary.custodian_dropped_duplicates += 1;
                continue;
            }

            let novelty_q10 = 1024 - max_overlap_q10;
            let signal_bonus_q10 = score_causal_signal_q10(s_trim);
            let total_score = novelty_q10 + signal_bonus_q10;

            accepted_token_sets.push(sent_toks);
            sec_scored.push((total_score, s_trim.to_string()));
            all_scored_sentences.push((total_score, s_trim.to_string()));
        }

        if let Some((_, best_sent)) = sec_scored.iter().max_by_key(|(sc, _)| *sc) {
            if summary.section_digest.len() < 18 {
                summary
                    .section_digest
                    .push((sec_name.clone(), best_sent.clone()));
            }
        }

        // PhoeniX Crystal keep: top 2 highest-signal sentences per section
        sec_scored.sort_by_key(|b| std::cmp::Reverse(b.0));
        let kept: Vec<String> = sec_scored.into_iter().take(2).map(|(_, s)| s).collect();
        summary.phoenix_kept_sentences += kept.len();
        if !kept.is_empty() && summary.phoenix_crystal_sections.len() < 16 {
            summary
                .phoenix_crystal_sections
                .push((sec_name.clone(), kept));
        }
    }

    // 3. Executive Thesis (first high-salience sentence from Overview/Abstract or #1 overall)
    if let Some((_, first_sec_sent)) = summary.section_digest.first() {
        summary.executive_thesis = first_sec_sent.clone();
    } else if let Some((_, top_sent)) = all_scored_sentences.first() {
        summary.executive_thesis = top_sent.clone();
    }

    // 4. Top 6 Key Claims across the document
    all_scored_sentences.sort_by_key(|b| std::cmp::Reverse(b.0));
    let mut claim_tokens: Vec<Vec<String>> = Vec::new();
    for (_, cand) in &all_scored_sentences {
        if cand == &summary.executive_thesis {
            continue;
        }
        let toks: Vec<String> = tokens(cand)
            .into_iter()
            .map(str::to_ascii_lowercase)
            .collect();
        if max_token_overlap_q10(&toks, &claim_tokens) < 420 {
            claim_tokens.push(toks);
            summary.key_claims.push(cand.clone());
            if summary.key_claims.len() >= 6 {
                break;
            }
        }
    }

    // 5. Build MEM|8 Personalized Lens ("Read in a way that's best for you")
    let (bridges, briefing) =
        synthesize_mem8_personalized_lens(title, author, markdown, &summary, mem8_anchors);
    summary.mem8_bridges = bridges;
    summary.personalized_briefing = briefing;

    summary
}

fn split_into_sentences(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let chars: Vec<char> = text.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        cur.push(c);
        if matches!(c, '.' | '?' | '!') {
            let next_is_space = i + 1 >= chars.len() || chars[i + 1].is_whitespace();
            let next_after_is_upper = i + 2 < chars.len() && chars[i + 2].is_ascii_uppercase();
            if next_is_space && (i + 1 >= chars.len() || next_after_is_upper || cur.len() > 75) {
                let trimmed = cur.trim().to_string();
                if !trimmed.is_empty() {
                    out.push(trimmed);
                }
                cur.clear();
            }
        }
        i += 1;
    }
    let rem = cur.trim().to_string();
    if !rem.is_empty() {
        out.push(rem);
    }
    out
}

fn max_token_overlap_q10(cand: &[String], existing: &[Vec<String>]) -> i64 {
    if cand.is_empty() || existing.is_empty() {
        return 0;
    }
    let mut best_q10 = 0i64;
    for ex in existing {
        if ex.is_empty() {
            continue;
        }
        let mut inter = 0i64;
        for w in cand {
            if ex.iter().any(|e| e == w) {
                inter += 1;
            }
        }
        let union = (cand.len() + ex.len()) as i64 - inter;
        if union > 0 {
            let q10 = (inter * 1024) / union;
            if q10 > best_q10 {
                best_q10 = q10;
            }
        }
    }
    best_q10
}

fn score_causal_signal_q10(sentence: &str) -> i64 {
    let lower = sentence.to_ascii_lowercase();
    let mut bonus = 0i64;
    for (kw, pts) in [
        ("this essay", 320i64),
        ("this paper", 320),
        ("we argue", 280),
        ("we show", 280),
        ("necessary condition", 300),
        ("sufficient", 220),
        ("reproduce", 240),
        ("reproduction", 240),
        ("correction", 220),
        ("repair", 240),
        ("recursive blame", 280),
        ("warrant", 260),
        ("retroactive", 260),
        ("feasibility", 220),
        ("mechanism", 240),
        ("architecture", 220),
        ("feedback", 200),
        ("invariant", 240),
        ("therefore", 180),
        ("because", 140),
        ("requires", 180),
        ("fails when", 260),
    ] {
        if lower.contains(kw) {
            bonus += pts;
        }
    }
    bonus.min(960)
}

fn synthesize_mem8_personalized_lens(
    title: &str,
    author: &str,
    markdown: &str,
    summary: &DocumentSummary,
    mem8_anchors: &[String],
) -> (Vec<String>, String) {
    let lower_all = format!("{} {}", title, markdown).to_ascii_lowercase();
    let mut bridges = Vec::<String>::new();

    // 1. Structural Resonance Bridges mapped directly to Hue's Sovereign Engineering & MEM|8 Lattice
    if lower_all.contains("correction")
        || lower_all.contains("blame")
        || lower_all.contains("repair")
        || lower_all.contains("reproduction")
        || lower_all.contains("punishment")
    {
        bridges.push(
            "**Anicca Self-Healing (`QWPORTAL001`) vs. Recursive Blame**: Just as Flyxion shows that punitive 'corrective' loops reproduce the very failure they target when they ignore environmental topology, Qwave's Anicca mesh never punishes a dead Wi-Fi portal with infinite blind retries—it updates the structural condition (`ttl_q8` decay + `Forget` after 3 failures + fallback to a working route)."
                .to_string(),
        );
        bridges.push(
            "**Android Phone Removal / AyeOS (`BLU G75`) as Structural Repair**: Removing surveillance-heavy vendor bloatware rather than endlessly 'configuring permissions' inside a hostile OS is the exact difference between *perpetrator-centered patching* and *structural condition repair*."
                .to_string(),
        );
    }

    if lower_all.contains("warrant")
        || lower_all.contains("retroactive")
        || lower_all.contains("possibility")
        || lower_all.contains("demonstration")
        || lower_all.contains("unauthorized")
    {
        bridges.push(
            "**WUPZ 32B & MEM|8 79B Witness Sealing (Non-Retroactive Warrant)**: Flyxion's *Non-Retroactivity Proposition* (`Auth(a | E_t)` depends strictly on evidence available at commit time `t`, never on lucky post-hoc outcomes `E_{t+k}`) is the exact formal foundation of Qwave's `qw_mem16_admit` pre-flight gate and WUPZ cryptographic receipts."
                .to_string(),
        );
    }

    if lower_all.contains("noise")
        || lower_all.contains("signal")
        || lower_all.contains("compression")
        || lower_all.contains("equilibrium")
        || lower_all.contains("feedback")
        || bridges.is_empty()
    {
        bridges.push(
            "**Zero-Float Exact Rational (`p/q`) & PhoeniX Custodian Architecture**: Eliminating silent floating-point drift (`Rational(num, den)`) and dropping repetitive low-novelty noise (`Custodian::adjudicate`) keeps the system's feedback loop phase-locked to reality."
                .to_string(),
        );
    }

    // Match user's live MEM|8 anchors from disk (`~/.mem8/anchors.jsonl` / `waves.jsonl`)
    for anchor in mem8_anchors.iter().take(4) {
        let a_lower = anchor.to_ascii_lowercase();
        if (a_lower.contains("blu g75") || a_lower.contains("ayeos"))
            && !bridges.iter().any(|b| b.contains("BLU G75"))
        {
            bridges.push(
                "**Live MEM|8 Anchor (`BLU G75 / AyeOS Slot-B` @ 432 Hz)**: While you strip Android vendor layers down to deterministic Rust/ASM capsules, this work's core invariant applies directly: own the substrate so repair is one-shot and permanent."
                    .to_string(),
            );
        } else if (a_lower.contains("constellation") || a_lower.contains("medusa"))
            && !bridges
                .iter()
                .any(|b| b.contains("4-Node Sovereign Constellation"))
        {
            bridges.push(
                "**Live MEM|8 Anchor (`4-Node Sovereign Constellation` @ 528 Hz)**: Distributed fault repair across `ADA`, `VAK`, `OMN`, and `SUN:TDECK` succeeds because each node shares verified state (`MemnetCapsule64`) instead of cascading blame."
                    .to_string(),
            );
        }
    }

    let author_clause = if author.trim().is_empty() {
        String::new()
    } else {
        format!(" by {}", author.trim())
    };
    let top_claim_1 = summary
        .key_claims
        .first()
        .cloned()
        .unwrap_or_else(|| summary.executive_thesis.clone());
    let top_claim_2 = summary.key_claims.get(1).cloned().unwrap_or_default();

    let briefing = format!(
        "For Hue (MEM|8 Mechanism-First Briefing): \"{title}\"{author_clause} strips away surface narrative to expose a single structural law. {thesis} {c1} {c2} In your sovereign stack terms: don't patch symptoms inside a broken loop—change the boundary condition so the failure mode cannot reproduce.",
        title = title,
        author_clause = author_clause,
        thesis = summary.executive_thesis,
        c1 = top_claim_1,
        c2 = top_claim_2,
    );

    (bridges, briefing)
}

/// Render `DocumentSummary` into two Sovereign Markdown sections (`## 🧠 Executive Summary & MEM|8 Personalized Lens`
/// and `## 🔥 PhoeniX'd High-Resolution Distillation`) ready to prepend to any PDF, TeX, or Media view.
pub fn format_summary_and_phoenix_markdown(summary: &DocumentSummary) -> String {
    let mut out = Vec::<String>::new();

    out.push("## 🧠 Executive Summary & MEM|8 Personalized Lens".to_string());
    out.push(String::new());

    // 1. Personalized For-You Briefing Box (spoken first when clicking "Listen: For You")
    out.push("> [!TIP]".to_string());
    out.push("> **🎧 Spoken For You (MEM|8 Cognitive Lens — Mechanism-First)**".to_string());
    out.push(">".to_string());
    out.push(format!("> {}", summary.personalized_briefing));
    out.push(String::new());

    // 2. Core Thesis & High-Salience Claims
    if !summary.executive_thesis.is_empty() {
        out.push("> [!IMPORTANT]".to_string());
        out.push(format!("> **Core Thesis:** {}", summary.executive_thesis));
        out.push(String::new());
    }

    if !summary.key_claims.is_empty() {
        out.push("### ⚡ High-Salience Structural Claims".to_string());
        out.push(String::new());
        for claim in &summary.key_claims {
            out.push(format!("- {claim}"));
        }
        out.push(String::new());
    }

    // 3. MEM|8 Memory Resonance Bridges
    if !summary.mem8_bridges.is_empty() {
        out.push("### 🌊 MEM|8 Memory Resonance Bridges".to_string());
        out.push(String::new());
        for bridge in &summary.mem8_bridges {
            out.push(format!("- {bridge}"));
        }
        out.push(String::new());
    }

    // 4. Section-by-Section Rapid Digest
    if !summary.section_digest.is_empty() {
        out.push("### 🗺️ Section-by-Section Rapid Map".to_string());
        out.push(String::new());
        for (sec, digest) in &summary.section_digest {
            out.push(format!("- **{sec}** — {digest}"));
        }
        out.push(String::new());
    }

    // 5. PhoeniX'd High-Resolution Distillation Section
    out.push("## 🔥 PhoeniX'd High-Resolution Distillation".to_string());
    out.push(String::new());
    out.push("> [!NOTE]".to_string());
    out.push(format!(
        "> **PhoeniX Custodian & Marine Salience Receipt:** Distilled **{} sentences** down to **{} high-resolution crystal claims** (**{} sections**, **{} repetitive/low-novelty sentences dropped** by the Custodian).",
        summary.total_sentences,
        summary.phoenix_kept_sentences,
        summary.total_sections,
        summary.custodian_dropped_duplicates
    ));
    out.push(String::new());

    if !summary.formal_invariants.is_empty() {
        out.push("### 📐 Formal Propositions & Invariants".to_string());
        out.push(String::new());
        for inv in &summary.formal_invariants {
            out.push(format!("- {inv}"));
        }
        out.push(String::new());
    }

    for (sec, crystal_sents) in &summary.phoenix_crystal_sections {
        out.push(format!("### 🔹 {sec}"));
        out.push(String::new());
        for s in crystal_sents {
            out.push(format!("- {s}"));
        }
        out.push(String::new());
    }

    out.push("---".to_string());
    out.push(String::new());
    out.push("## 📖 Full Sovereign Document".to_string());
    out.push(String::new());

    out.join("\n")
}

// ============================================================================
// SOVEREIGN AUDIO & VIDEO MEDIA SUMMARIZER + PHOENIX 768kHz STUDIO FORMATTER
// ============================================================================

/// Extracted Audio / Video metadata, chapters, transcript, and PhoeniX Sound 768kHz receipt.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MediaExtract {
    pub filename: String,
    pub is_video: bool,
    pub duration_secs: u64,
    pub container_format: String,
    pub video_codec: String,
    pub width: u32,
    pub height: u32,
    pub fps_desc: String,
    pub audio_codec: String,
    pub sample_rate_hz: u32,
    pub channels: u16,
    pub bitrate_kbps: u32,
    pub title: String,
    pub artist: String,
    pub chapters: Vec<(String, String)>,
    pub transcript_segments: Vec<(String, String)>,
    pub phoenix_receipt: Option<crate::phoenix_sound::PhoenixSoundReceipt>,
}

/// Format an extracted Audio or Video file (`MediaExtract`) into Sovereign Markdown with:
/// - Interactive `qwave-media` Studio Dock (Original vs **PhoeniX'd 768 kHz / 16× Catmull-Rom + φ432** player)
/// - Exact Rational (`p/q`) PhoeniX Sound Telemetry table
/// - MEM|8 Personalized Summary & PhoeniX High-Resolution Notes
/// - Full timestamped transcript & chapter breakdown
pub fn format_media_to_markdown(
    asset_url: &str,
    phoenix_url: &str,
    extract: &MediaExtract,
    mem8_anchors: &[String],
) -> String {
    let display_title = if !extract.title.trim().is_empty() {
        extract.title.trim().to_string()
    } else {
        extract.filename.clone()
    };
    let mins = extract.duration_secs / 60;
    let secs = extract.duration_secs % 60;
    let dur_str = format!("{mins}:{secs:02}");
    let kind_str = if extract.is_video { "video" } else { "audio" };
    let icon = if extract.is_video { "🎬" } else { "🎵" };

    let mut out = Vec::<String>::new();
    out.push(format!("# {icon} {display_title}"));

    let mut badges = Vec::new();
    if !extract.artist.trim().is_empty() {
        badges.push(format!("✍️ **{}**", extract.artist.trim()));
    }
    badges.push(format!("⏱️ **{dur_str}**"));
    if extract.is_video && extract.width > 0 && extract.height > 0 {
        badges.push(format!(
            "📐 **{}×{} ({})**",
            extract.width, extract.height, extract.video_codec
        ));
    }
    if extract.sample_rate_hz > 0 {
        badges.push(format!(
            "🔊 **{} Hz · {}ch ({}) → 768 kHz 16× PhoeniX Grid**",
            extract.sample_rate_hz, extract.channels, extract.audio_codec
        ));
    }
    out.push(badges.join(" · "));
    out.push(String::new());

    // 1. Interactive `qwave-media` Studio Dock
    out.push("```qwave-media".to_string());
    out.push(format!("src={asset_url}"));
    out.push(format!("phoenix_src={phoenix_url}"));
    out.push(format!("kind={kind_str}"));
    out.push(format!("duration={dur_str}"));
    out.push(format!("title={display_title}"));
    out.push("```".to_string());
    out.push(String::new());

    // 2. PhoeniX Sound 768 kHz Exact Rational (`p/q`) Telemetry Receipt
    if let Some(rcpt) = &extract.phoenix_receipt {
        out.push("## 🔥 PhoeniX'd 768 kHz Sound Revelation Telemetry".to_string());
        out.push(String::new());
        out.push("> [!IMPORTANT]".to_string());
        out.push(format!(
            "> **Stage 1–3 Integer Catmull-Rom + 768 kHz `S+N+T` + 432 Hz / φ Revelation Complete:** Repaired **{} clipped/dropped samples**, discovered dominant fundamental **`{}/{}` Hz** (`~{} Hz`) with golden-ratio companions **`{}/{}` Hz** (`f/φ`) and **`{}/{}` Hz** (`f·φ`), and Soul Authenticity **`{}/{}`**.",
            rcpt.catmull_rom_restored_samples,
            rcpt.dominant_freq_hz.num,
            rcpt.dominant_freq_hz.den,
            rcpt.dominant_freq_hz.num / rcpt.dominant_freq_hz.den.max(1) as i32,
            rcpt.phi_lower_hz.num,
            rcpt.phi_lower_hz.den,
            rcpt.phi_upper_hz.num,
            rcpt.phi_upper_hz.den,
            rcpt.soul_authenticity.num,
            rcpt.soul_authenticity.den
        ));
        out.push(String::new());
        out.push(
            "| Metric | Exact Rational (`p/q`) / Integer Value | Sovereign Meaning |".to_string(),
        );
        out.push("| :--- | :--- | :--- |".to_string());
        out.push(format!(
            "| **Virtual Oversampling Grid** | `{} Hz` (`16×` over `{} Hz`) | Sub-sample zero-crossing & cubic Hermite grid |",
            rcpt.internal_oversample_hz, rcpt.sample_rate_hz
        ));
        out.push(format!(
            "| **Catmull-Rom Restored Samples** | `{}` samples | Clipped peaks & burst dropouts reconstructed |",
            rcpt.catmull_rom_restored_samples
        ));
        out.push(format!(
            "| **Dominant Fundamental (`f₀`)** | `{}/{}` Hz | Exact rational pitch on the 768 kHz grid |",
            rcpt.dominant_freq_hz.num, rcpt.dominant_freq_hz.den
        ));
        out.push(format!(
            "| **Golden Companions (`f/φ`, `f·φ`)** | `{}/{}` Hz · `{}/{}` Hz | Sympathetic φ-harmonic bloom anchors |",
            rcpt.phi_lower_hz.num,
            rcpt.phi_lower_hz.den,
            rcpt.phi_upper_hz.num,
            rcpt.phi_upper_hz.den
        ));
        out.push(format!(
            "| **Marine `S + N + T` Frames** | `S={}` · `N={}` · `T={}` · `Sil={}` | Harmonic Sinusoid / Stochastic Air / Dirac Attack |",
            rcpt.harmonic_s_frames,
            rcpt.stochastic_n_frames,
            rcpt.dirac_t_frames,
            rcpt.silence_frames
        ));
        out.push(format!(
            "| **Soul Authenticity & Bloom** | `Soul={}/{}` · `Bloom={}/{}` | Organic micro-jitter & crest revelation ratio |",
            rcpt.soul_authenticity.num,
            rcpt.soul_authenticity.den,
            rcpt.harmonic_bloom_ratio.num,
            rcpt.harmonic_bloom_ratio.den
        ));
        out.push(format!(
            "| **`.8a` (`8a∞`) Capsule Stream** | `{}` bytes (`FNV-1a: 0x{:016x}`) | Deterministic harmonic opcode stream |",
            rcpt.eight_a_bytes, rcpt.pcm_fnv1a_hash
        ));
        out.push(String::new());
    }

    // 3. Build transcript / chapter text for summarization
    let mut prose_lines = Vec::<String>::new();
    for (ts, ch_title) in &extract.chapters {
        prose_lines.push(format!("## {ts} {ch_title}"));
    }
    for (_ts, seg_text) in &extract.transcript_segments {
        prose_lines.push(seg_text.clone());
    }
    let combined_prose = if prose_lines.is_empty() {
        format!(
            "## Acoustic & Container Overview\n{} ({}) runs for {} at {} Hz ({} channels). Use the 🔥 PhoeniX'd High-Res button above to switch the live stream into 768 kHz 16x Catmull-Rom + 432 Hz / phi harmonic revelation.",
            display_title,
            extract.container_format,
            dur_str,
            extract.sample_rate_hz.max(48000),
            extract.channels.max(2)
        )
    } else {
        prose_lines.join("\n\n")
    };

    let summary = summarize_markdown_with_mem8(
        &display_title,
        &extract.artist,
        &combined_prose,
        mem8_anchors,
    );
    out.push(format_summary_and_phoenix_markdown(&summary));

    if !extract.chapters.is_empty() {
        out.push("### 📑 Chapters & Timeline".to_string());
        out.push(String::new());
        for (ts, ch) in &extract.chapters {
            out.push(format!("- **`{ts}`** — {ch}"));
        }
        out.push(String::new());
    }

    if !extract.transcript_segments.is_empty() {
        out.push("### 📜 Full Spoken Transcript".to_string());
        out.push(String::new());
        for (ts, seg) in &extract.transcript_segments {
            if ts.is_empty() {
                out.push(seg.clone());
            } else {
                out.push(format!("**`[{ts}]`** {seg}"));
            }
            out.push(String::new());
        }
    } else {
        out.push(combined_prose);
    }

    out.join("\n")
}

/// Extract spoken narration according to `mode`:
/// - `"summary"` or `"for-me"`: speaks ONLY the MEM|8 Personalized Briefing, Core Thesis, Key Claims, and Section Map
/// - `"phoenix"`: speaks the PhoeniX'd High-Resolution Crystal Distillation
/// - `"full"` (default): speaks the entire document
pub fn extract_spoken_narration_mode(
    source: &str,
    is_tex: bool,
    mode: &str,
    mem8_anchors: &[String],
) -> String {
    let md = if is_tex {
        compile_tex_to_markdown_with_mem8(source, mem8_anchors)
    } else {
        source.to_string()
    };

    let mode_norm = mode.trim().to_ascii_lowercase();
    if mode_norm == "summary" || mode_norm == "for-me" || mode_norm == "personal" {
        if let Some(start) = md.find("## 🧠 Executive Summary") {
            let sub = &md[start..];
            let end = sub
                .find("## 🔥 PhoeniX'd High-Resolution Distillation")
                .or_else(|| sub.find("## 📖 Full Sovereign Document"))
                .unwrap_or(sub.len());
            return extract_spoken_narration(&sub[..end], false);
        }
    } else if mode_norm == "phoenix" || mode_norm == "crystal" {
        if let Some(start) = md.find("## 🔥 PhoeniX'd High-Resolution Distillation") {
            let sub = &md[start..];
            let end = sub
                .find("## 📖 Full Sovereign Document")
                .unwrap_or(sub.len());
            return extract_spoken_narration(&sub[..end], false);
        }
    }

    extract_spoken_narration(&md, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tex_compiler_handles_macros_theorems_math_and_citations() {
        let tex = r#"
\documentclass[11pt]{article}
\newcommand{\Poss}{\operatorname{Poss}}
\newcommand{\Auth}{\operatorname{Auth}}
\title{Unauthorized Futures:\\ Possibility and Warrant}
\author{Flyxion\\ \textit{Independent Researcher}}
\date{October 2026}
\begin{document}
\maketitle
\begin{abstract}
\noindent
This essay studies $\Poss(F)$ and $\Auth(a \mid E_t)$ following \citep{clifford1877}.
\end{abstract}
\section{Introduction}
We ask whether $\Poss(F)$ suffices.
\[
\Auth(a \mid E_t) \iff W \ge \theta(a)
\]
\begin{proposition}[Non-retroactivity]
Later evidence cannot repair earlier warrant.
\end{proposition}
\begin{proof}
Immediate by definition.
\end{proof}
\begin{thebibliography}{9}
\bibitem[Clifford(1877)]{clifford1877}
Clifford, W.~K. (1877). The ethics of belief. \textit{Contemporary Review}.
\end{thebibliography}
\end{document}
"#;
        let compiled = compile_tex_full(tex, None);
        assert!(compiled.title.contains("Unauthorized Futures"));
        assert!(compiled.html.contains("Flyxion"));
        assert!(compiled.html.contains("md-alert-note"));
        assert!(compiled.html.contains("md-alert-important"));
        assert!(compiled.html.contains("Proposition 1 (Non-retroactivity)"));
        assert!(compiled.html.contains("Clifford(1877)"));
        assert!(compiled.html.contains("\\operatorname{Poss}(F)"));
        assert!(compiled.toc.iter().any(|t| t.text.contains("Introduction")));
        assert!(compiled.toc.iter().any(|t| t.text.contains("References")));
    }

    #[test]
    fn pdf_reflow_promotes_sections_and_rejoins_hyphenation() {
        let page1 = "When Correction Becomes Reproduction\nRecursive Blame and Repair\nFlyxion\nOctober 2026\nAbstract\nThis essay asks when correc-\ntion lowers prevalence.\n\n1\n\nIntroduction: Perpetrator-Centered Explanation\n\nAccounts of social dysfunction settle on a party.\n1\n";
        let extract = PdfExtract {
            title: String::new(),
            author: String::new(),
            date: String::new(),
            page_count: 1,
            pages: vec![page1.to_string()],
        };
        let md = format_pdf_to_markdown(
            "correction-reproduction.pdf",
            Some("/asset?path=/tmp/a.pdf"),
            &extract,
        );
        assert!(md.contains("# When Correction Becomes Reproduction: Recursive Blame and Repair"));
        assert!(md.contains("correction lowers prevalence."));
        assert!(md.contains("## 1. Introduction: Perpetrator-Centered Explanation"));
        assert!(md.contains("```qwave-pdf"));
    }

    #[test]
    fn spoken_narration_cleans_latex_and_markdown() {
        let tex = r#"\section{Intro} We have $\operatorname{Auth}(a) \iff \theta \ge 0$."#;
        let spoken = extract_spoken_narration(tex, true);
        assert!(spoken.contains("Intro"));
        assert!(spoken.contains("if and only if"));
        assert!(spoken.contains("is at least"));
        assert!(!spoken.contains("\\iff"));
    }

    #[test]
    fn summarizer_and_mem8_lens_distill_claims_and_drop_duplicates() {
        let doc = "## 1. Introduction\nThis essay argues that corrective institutions reproduce failure when feedback loops ignore structural repair.\nThis essay argues that corrective institutions reproduce failure when feedback loops ignore structural repair.\n## 2. Mechanism\nTherefore a necessary condition for repair is changing the boundary topology rather than repeating blame.";
        let anchors = vec!["BLU G75 AyeOS Slot-B Android removal".to_string()];
        let sum = summarize_markdown_with_mem8(
            "When Correction Becomes Reproduction",
            "Flyxion",
            doc,
            &anchors,
        );
        assert_eq!(sum.total_sections, 2);
        assert!(sum.custodian_dropped_duplicates >= 1);
        assert!(sum.executive_thesis.contains("corrective institutions"));
        assert!(
            sum.mem8_bridges
                .iter()
                .any(|b| b.contains("Anicca") || b.contains("BLU G75"))
        );
        let md = format_summary_and_phoenix_markdown(&sum);
        assert!(md.contains("## 🧠 Executive Summary & MEM|8 Personalized Lens"));
        assert!(md.contains("## 🔥 PhoeniX'd High-Resolution Distillation"));
    }
}
