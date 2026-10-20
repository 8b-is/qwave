/// Runs only in an isolated WebKit content world; translated strings never become HTML.
public enum PageTranslationScript {
    public static let install = #"""
        if (!globalThis.qwaveReading) {
          const records = new Map(); const ids = new WeakMap(); let serial = 0; let paused = false; let targetLanguage = ''; let automatic = true;
          const documentID = Math.random().toString(36).slice(2);
          const blocked = 'script,style,noscript,textarea,input,select,code,pre,svg,math,[contenteditable]:not([contenteditable="false"]),[translate="no"],[hidden],[aria-hidden="true"]';
          function eligible(el) {
            return el && !el.closest(blocked) && el.getClientRects().length > 0;
          }
          function current(r) { return r.attr ? r.node.getAttribute(r.attr) : r.node.nodeValue; }
          function write(r, value) { if (r.attr) r.node.setAttribute(r.attr, value); else r.node.nodeValue = value; }
          function capture(node, attr, out, budget) {
            const value = attr ? node.getAttribute(attr) : node.nodeValue;
            if (!value || !value.trim() || value.length > 3000) return budget;
            let keys = ids.get(node); if (!keys) { keys = {}; ids.set(node, keys); }
            const key = attr || 'text'; let id = keys[key]; let r = records.get(id);
            if (r && (value === r.translated || (r.translated === null && value === r.original))) return budget;
            if (out.length >= 48 || budget + value.length > 10000 || records.size >= 5000) return budget;
            if (!id) { id = String(++serial); keys[key] = id; }
            r = {node, attr, original:value, translated:null}; records.set(id,r);
            out.push({id, text:value}); return budget + value.length;
          }
          globalThis.qwaveReading = {
            configure(target, enabled) {
              if (targetLanguage && targetLanguage !== target) this.restore(false);
              if (automatic !== enabled) this.restore(!enabled);
              targetLanguage = target; automatic = enabled;
            },
            scan() {
              for (const [id,r] of records) if (!r.node.isConnected) records.delete(id);
              const out=[]; let budget=0;
              const title=document.querySelector('title');
              if (title && !title.closest('[translate="no"]')) for (const node of title.childNodes) {
                if (node.nodeType === Node.TEXT_NODE) budget=capture(node,null,out,budget);
              }
              const walker=document.createTreeWalker(document.body || document.documentElement,NodeFilter.SHOW_TEXT);
              let node; let visited=0;
              while ((node=walker.nextNode()) && visited++ < 20000 && out.length < 48) {
                if (eligible(node.parentElement)) budget=capture(node,null,out,budget);
              }
              for (const el of document.querySelectorAll('[title],[alt],[aria-label],[placeholder]')) {
                if (out.length >= 48) break;
                // No form values; placeholders and accessible labels are page-authored UI.
                if (eligible(el) || (el.matches('input:not([type=password]),textarea') && !el.closest('[translate="no"],[contenteditable]'))) {
                  for (const attr of ['title','alt','aria-label','placeholder']) budget=capture(el,attr,out,budget);
                }
              }
              return {documentID, entries:out, paused, translated:Array.from(records.values()).some(r => r.translated !== null), language:document.documentElement.lang || ''};
            },
            apply(doc, rows) {
              if (doc !== documentID) return false;
              for (const row of rows) { const r=records.get(row.id);
                if (r && r.node.isConnected && current(r) === r.original) { write(r,row.text); r.translated=row.text; }
              } return true;
            },
            restore(pause = false) {
              paused = pause;
              for (const r of records.values()) if (r.node.isConnected && r.translated !== null && current(r) === r.translated) write(r,r.original);
              records.clear(); return true;
            },
            release(ids) { for (const id of ids) { const r=records.get(id); if (r && r.translated === null) records.delete(id); } return true; },
            retry() { paused = false; for (const [id,r] of records) if (r.translated === null) records.delete(id); }
          };
        }
        if (typeof targetLanguage !== 'undefined') qwaveReading.configure(targetLanguage, automatic);
        return qwaveReading.scan();
        """#
}
