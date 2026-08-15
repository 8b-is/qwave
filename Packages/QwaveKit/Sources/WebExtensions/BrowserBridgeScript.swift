import Foundation

/// The JavaScript injected at document start that implements the
/// `browser.*` (and `chrome.*`) API surface on top of a promise-based
/// message bridge to native code.
///
/// Pages call `browser.storage.local.get(...)` etc.; the bridge forwards
/// `{id, method, args}` to the `qwaveExtension` message handler and resolves
/// the promise when native code replies via `window.__qwaveNative.respond`.
///
/// Supports multi-listener `browser.runtime.onMessage` fan-out and native message dispatch.
public enum BrowserBridgeScript {
    public static let messageHandlerName = "qwaveExtension"

    public static let source = """
        (() => {
          'use strict';
          if (window.__qwaveBridgeInstalled) return;
          window.__qwaveBridgeInstalled = true;

          const pending = new Map();
          let nextId = 1;
          const messageListeners = new Set();

          function call(method, args) {
            return new Promise((resolve, reject) => {
              const id = nextId++;
              pending.set(id, { resolve, reject });
              window.webkit.messageHandlers.qwaveExtension.postMessage({ id, method, args });
              // Safety: drop stale calls after 30s.
              setTimeout(() => {
                if (pending.has(id)) {
                  pending.delete(id);
                  reject(new Error(method + ' timed out'));
                }
              }, 30000);
            });
          }

          window.__qwaveNative = {
            respond(id, ok, value) {
              const entry = pending.get(id);
              if (!entry) return;
              pending.delete(id);
              if (ok) entry.resolve(value);
              else entry.reject(value instanceof Error ? value : new Error(String(value)));
            },
            dispatchMessage(message, sender, messageId) {
              let responded = false;
              const sendResponse = (reply) => {
                if (responded) return;
                responded = true;
                if (messageId != null && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.qwaveExtension) {
                  window.webkit.messageHandlers.qwaveExtension.postMessage({
                    id: messageId,
                    method: 'runtime.onMessageReply',
                    args: [reply]
                  });
                }
              };

              for (const listener of messageListeners) {
                try {
                  const result = listener(message, sender || {}, sendResponse);
                  if (result === true) {
                    // Async sendResponse will be invoked by listener
                  } else if (result && typeof result.then === 'function') {
                    result.then(sendResponse).catch(err => {
                      sendResponse({ error: String(err) });
                    });
                  }
                } catch (err) {
                  console.error('[QwaveExtension] listener error:', err);
                }
              }
            }
          };

          const api = {};
          api.runtime = {
            sendMessage(message) {
              return call('runtime.sendMessage', [message]);
            },
            onMessage: {
              addListener(fn) {
                if (typeof fn === 'function') messageListeners.add(fn);
              },
              removeListener(fn) {
                messageListeners.delete(fn);
              },
              hasListener(fn) {
                return messageListeners.has(fn);
              }
            }
          };
          api.tabs = {
            query(queryInfo) {
              return call('tabs.query', [queryInfo || {}]);
            },
            create(createProperties) {
              return call('tabs.create', [createProperties || {}]);
            }
          };
          api.storage = {
            local: {
              get(keys) { return call('storage.local.get', [keys == null ? null : keys]); },
              set(items) { return call('storage.local.set', [items || {}]); },
              remove(keys) { return call('storage.local.remove', [keys == null ? null : keys]); }
            }
          };
          window.browser = window.browser || api;
          window.chrome = window.chrome || api;
        })();
        """

    /// A WKUserScript source; injected at document start, before page code.
    public static var userScriptSource: String { source }
}
