// readability-probe extractor: heuristic article extraction, no external
// deps. Scores paragraph-ish nodes, picks the best container, extracts text.
(function () {
  function extract() {
    const scored = [];
    const nodes = document.querySelectorAll("p, pre, li, blockquote, td, h1, h2, h3, h4, h5, h6");
    for (const el of nodes) {
      const text = (el.textContent || "").replace(/\s+/g, " ").trim();
      if (text.length < 40) continue;
      let score = Math.min(text.length / 100, 5);
      if (/[.!?]["']?$/.test(text)) score += 1;
      if (/[;:—–]/.test(text)) score += 0.5;
      if (el.closest("nav, header, footer, aside, form, script, style, .ad, .ads, .advert, .menu, .sidebar, .comments, .subscribe, .paywall, .promo, .related")) score -= 8;
      if (el.closest("article, main, .content, .post, .entry, .article-body, .prose, [role=main]")) score += 2;
      if (el.tagName === "PRE") score += 1;
      if (el.tagName === "LI") score += 0.5;
      scored.push({ el, score });
    }
    scored.sort((a, b) => b.score - a.score);
    if (scored.length === 0) return { text: "", source: "none", candidates: 0 };
    let container = scored[0].el;
    for (let i = 0; i < 8; i++) {
      const parent = container.parentElement;
      if (!parent || parent === document.body || parent.tagName === "HTML") break;
      const t = (parent.textContent || "").length;
      const rich = parent.querySelectorAll("p, pre, li").length;
      if (t < 400 || (rich > 3 && t < 3000)) {
        container = parent;
        if (parent.tagName === "ARTICLE" || parent.tagName === "MAIN") break;
        continue;
      }
      if (parent.tagName === "ARTICLE" || parent.tagName === "MAIN") { container = parent; }
      break;
    }
    const parts = [];
    const BOILER = "nav, header, footer, aside, form, script, style, .ad, .ads, .advert, .menu, .sidebar, .comments, .subscribe, .paywall, .promo, .related";
    const sel = container.querySelectorAll("p, pre, li, blockquote, td, h1, h2, h3, h4, h5, h6");
    for (const n of sel) {
      if (n.closest(BOILER)) continue;
      const t = (n.textContent || "").replace(/\s+/g, " ").trim();
      if (t.length >= 20) parts.push(t);
    }
    return {
      text: parts.join("\n\n"),
      source: (container.tagName + "." + (container.className || "")).slice(0, 60),
      candidates: scored.length,
    };
  }
  const result = extract();
  window.webkit.messageHandlers.probe.postMessage(JSON.stringify(result));
})();
