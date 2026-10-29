// qwave-qt — Native Qt6 WebEngine Sovereign Browser & Markdown Shell for Qwave
//
// Paired with the zero-dependency Rust `qwave` binary (`core/src/bin/qwave.rs`).
// Includes:
// 1. Sovereign Address Bar (Ctrl+L), Back/Forward/Reload/Home navigation, and Bookmarks Bar
// 2. Persistent Sovereign Profile (`~/.local/share/qwave/browser_profile`) so logins persist
// 3. Full Linux WebAuthn / Passkey Support:
//    - Native `QWebEngineWebAuthUxRequest` FIDO2 PIN, Account Selection & Hardware Key UX
//    - DocumentCreation WebAuthn Platform Passkey Bridge (`isUserVerifyingPlatformAuthenticatorAvailable`,
//      `getClientCapabilities`, and WebCrypto P-256 ES256 Sovereign Platform Passkey provider)
//      eliminating "Partial passkey support" warnings on Linux!

#include <QApplication>
#include <QClipboard>
#include <QDesktopServices>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHBoxLayout>
#include <QIcon>
#include <QInputDialog>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QMessageBox>
#include <QProcess>
#include <QPushButton>
#include <QRandomGenerator>
#include <QShortcut>
#include <QTimer>
#include <QUrl>
#include <QUrlQuery>
#include <QVBoxLayout>
#include <QWebEngineHistory>
#include <QWebEnginePage>
#include <QWebEnginePermission>
#include <QWebEngineProfile>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWebEngineSettings>
#include <QWebEngineView>
#include <QWebEngineWebAuthUxRequest>
#include <QWidget>
#include <memory>

static QString passkeyPlatformInitScript() {
    return QStringLiteral(R"JS(
(function() {
  if (typeof window === 'undefined' || !window.PublicKeyCredential) return;

  // 1. Advertise full Linux Platform Authenticator & Conditional Mediation support
  //    so GitHub and WebAuthn Relying Parties never downgrade Linux to "Partial passkey support".
  window.PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
    return Promise.resolve(true);
  };
  window.PublicKeyCredential.isConditionalMediationAvailable = function() {
    return Promise.resolve(true);
  };
  window.PublicKeyCredential.getClientCapabilities = function() {
    return Promise.resolve({
      conditionalCreate: true,
      conditionalGet: true,
      hybridTransport: true,
      passkeyPlatformAuthenticator: true,
      relatedOrigins: true,
      signalAllAcceptedCredentials: true,
      signalCurrentUserDetails: true,
      signalUnknownCredential: true,
      userVerifyingPlatformAuthenticator: true
    });
  };

  // Helper utilities for Sovereign Linux Software Passkey (ECDSA P-256 / ES256)
  const STORAGE_KEY = '__qwave_sovereign_passkeys_v1';
  function loadVault() {
    try { return JSON.parse(localStorage.getItem(STORAGE_KEY) || '{}'); }
    catch (_) { return {}; }
  }
  function saveVault(v) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(v)); }
    catch (_) {}
  }
  function b64uEncode(bytes) {
    const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    let bin = '';
    for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function b64uDecode(str) {
    let s = str.replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function concatBytes(arrays) {
    let total = 0;
    for (const a of arrays) total += a.length;
    const out = new Uint8Array(total);
    let off = 0;
    for (const a of arrays) { out.set(a, off); off += a.length; }
    return out;
  }
  // Convert IEEE P1363 64-byte (r || s) ECDSA signature from WebCrypto into ASN.1 DER for WebAuthn
  function p1363ToDer(sigBytes) {
    const u8 = new Uint8Array(sigBytes);
    if (u8.length !== 64) return u8;
    function encodeInt(slice) {
      let i = 0;
      while (i < slice.length - 1 && slice[i] === 0) i++;
      const trimmed = slice.slice(i);
      if (trimmed[0] & 0x80) {
        const padded = new Uint8Array(trimmed.length + 1);
        padded[0] = 0;
        padded.set(trimmed, 1);
        return padded;
      }
      return trimmed;
    }
    const r = encodeInt(u8.slice(0, 32));
    const s = encodeInt(u8.slice(32, 64));
    const seqLen = 2 + r.length + 2 + s.length;
    const der = new Uint8Array(2 + seqLen);
    let p = 0;
    der[p++] = 0x30;
    der[p++] = seqLen;
    der[p++] = 0x02;
    der[p++] = r.length;
    der.set(r, p); p += r.length;
    der[p++] = 0x02;
    der[p++] = s.length;
    der.set(s, p);
    return der;
  }
  // Minimal CBOR encoder for WebAuthn COSE_Key (ES256) & "none" attestationObject
  function encodeCoseKeyP256(xBytes, yBytes) {
    // Map of 5 pairs: {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x (bstr 32), -3: y (bstr 32)}
    return concatBytes([
      new Uint8Array([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]),
      xBytes,
      new Uint8Array([0x22, 0x58, 0x20]),
      yBytes
    ]);
  }
  function encodeAttestationObjectNone(authData) {
    // {"fmt": "none", "attStmt": {}, "authData": h'...'}
    const prefix = new Uint8Array([
      0xa3,
      0x63, 0x66, 0x6d, 0x74, 0x64, 0x6e, 0x6f, 0x6e, 0x65,
      0x67, 0x61, 0x74, 0x74, 0x53, 0x74, 0x6d, 0x74, 0xa0,
      0x68, 0x61, 0x75, 0x74, 0x68, 0x44, 0x61, 0x74, 0x61
    ]);
    const lenHdr = authData.length < 256
      ? new Uint8Array([0x58, authData.length])
      : new Uint8Array([0x59, (authData.length >> 8) & 0xff, authData.length & 0xff]);
    return concatBytes([prefix, lenHdr, authData]);
  }

  async function createSovereignPasskey(pubKeyOpts) {
    const rpId = (pubKeyOpts.rp && pubKeyOpts.rp.id) ? pubKeyOpts.rp.id : window.location.hostname;
    const challengeBytes = new Uint8Array(
      pubKeyOpts.challenge instanceof ArrayBuffer ? pubKeyOpts.challenge : pubKeyOpts.challenge.buffer
    );
    const keyPair = await crypto.subtle.generateKey(
      { name: 'ECDSA', namedCurve: 'P-256' },
      true,
      ['sign', 'verify']
    );
    const jwkPriv = await crypto.subtle.exportKey('jwk', keyPair.privateKey);
    const jwkPub = await crypto.subtle.exportKey('jwk', keyPair.publicKey);
    const xBytes = b64uDecode(jwkPub.x);
    const yBytes = b64uDecode(jwkPub.y);
    const credId = crypto.getRandomValues(new Uint8Array(32));
    const credIdB64u = b64uEncode(credId);

    const rpIdHash = new Uint8Array(
      await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rpId))
    );
    // Flags: UP (0x01) | UV (0x04) | BE (0x08) | BS (0x10) | AT (0x40) = 0x5d
    const flags = new Uint8Array([0x5d]);
    const signCount = new Uint8Array([0, 0, 0, 1]);
    // Qwave Sovereign AAGUID: "8b-is-qwave-pass" (16 bytes)
    const aaguid = new Uint8Array([0x38,0x62,0x2d,0x69,0x73,0x2d,0x71,0x77,0x61,0x76,0x65,0x2d,0x70,0x61,0x73,0x73]);
    const credLen = new Uint8Array([0x00, credId.length]);
    const coseKey = encodeCoseKeyP256(xBytes, yBytes);
    const authData = concatBytes([rpIdHash, flags, signCount, aaguid, credLen, credId, coseKey]);
    const attestationObject = encodeAttestationObjectNone(authData);

    const clientDataObj = {
      type: 'webauthn.create',
      challenge: b64uEncode(challengeBytes),
      origin: window.location.origin,
      crossOrigin: false
    };
    const clientDataJSON = new TextEncoder().encode(JSON.stringify(clientDataObj));

    // Persist in Sovereign Vault
    const vault = loadVault();
    const userBytes = pubKeyOpts.user && pubKeyOpts.user.id
      ? new Uint8Array(pubKeyOpts.user.id instanceof ArrayBuffer ? pubKeyOpts.user.id : pubKeyOpts.user.id.buffer)
      : new Uint8Array(0);
    vault[credIdB64u] = {
      rpId: rpId,
      jwkPriv: jwkPriv,
      userHandleB64u: b64uEncode(userBytes),
      userName: (pubKeyOpts.user && pubKeyOpts.user.name) || 'hue',
      signCount: 1,
      createdAt: Date.now()
    };
    saveVault(vault);

    // Build SPKI public key for getPublicKey()
    const spkiBuf = await crypto.subtle.exportKey('spki', keyPair.publicKey);

    const cred = {
      id: credIdB64u,
      rawId: credId.buffer,
      type: 'public-key',
      authenticatorAttachment: 'platform',
      response: {
        clientDataJSON: clientDataJSON.buffer,
        attestationObject: attestationObject.buffer,
        getTransports: function() { return ['internal', 'hybrid']; },
        getAuthenticatorData: function() { return authData.buffer; },
        getPublicKey: function() { return spkiBuf; },
        getPublicKeyAlgorithm: function() { return -7; }
      },
      getClientExtensionResults: function() {
        return { credProps: { rk: true } };
      },
      toJSON: function() {
        return {
          id: credIdB64u,
          rawId: credIdB64u,
          type: 'public-key',
          authenticatorAttachment: 'platform',
          response: {
            clientDataJSON: b64uEncode(clientDataJSON),
            attestationObject: b64uEncode(attestationObject),
            transports: ['internal', 'hybrid']
          },
          clientExtensionResults: { credProps: { rk: true } }
        };
      }
    };
    Object.setPrototypeOf(cred, PublicKeyCredential.prototype);
    return cred;
  }

  async function getSovereignPasskey(pubKeyOpts) {
    const rpId = pubKeyOpts.rpId || window.location.hostname;
    const vault = loadVault();
    let matchedId = null;
    let entry = null;

    if (Array.isArray(pubKeyOpts.allowCredentials) && pubKeyOpts.allowCredentials.length > 0) {
      for (const desc of pubKeyOpts.allowCredentials) {
        const idBytes = new Uint8Array(desc.id instanceof ArrayBuffer ? desc.id : desc.id.buffer);
        const idB64u = b64uEncode(idBytes);
        if (vault[idB64u] && vault[idB64u].rpId === rpId) {
          matchedId = idB64u;
          entry = vault[idB64u];
          break;
        }
      }
    } else {
      for (const [k, v] of Object.entries(vault)) {
        if (v && v.rpId === rpId) {
          matchedId = k;
          entry = v;
          break;
        }
      }
    }
    if (!matchedId || !entry) return null;

    const privKey = await crypto.subtle.importKey(
      'jwk',
      entry.jwkPriv,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign']
    );
    entry.signCount = (entry.signCount || 1) + 1;
    saveVault(vault);

    const rpIdHash = new Uint8Array(
      await crypto.subtle.digest('SHA-256', new TextEncoder().encode(rpId))
    );
    const flags = new Uint8Array([0x1d]); // UP | UV | BE | BS
    const sc = entry.signCount >>> 0;
    const signCount = new Uint8Array([(sc >> 24) & 0xff, (sc >> 16) & 0xff, (sc >> 8) & 0xff, sc & 0xff]);
    const authData = concatBytes([rpIdHash, flags, signCount]);

    const challengeBytes = new Uint8Array(
      pubKeyOpts.challenge instanceof ArrayBuffer ? pubKeyOpts.challenge : pubKeyOpts.challenge.buffer
    );
    const clientDataObj = {
      type: 'webauthn.get',
      challenge: b64uEncode(challengeBytes),
      origin: window.location.origin,
      crossOrigin: false
    };
    const clientDataJSON = new TextEncoder().encode(JSON.stringify(clientDataObj));
    const clientDataHash = new Uint8Array(await crypto.subtle.digest('SHA-256', clientDataJSON));
    const signedData = concatBytes([authData, clientDataHash]);
    const rawSig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privKey, signedData);
    const derSig = p1363ToDer(rawSig);
    const rawIdBytes = b64uDecode(matchedId);
    const userHandleBytes = entry.userHandleB64u ? b64uDecode(entry.userHandleB64u) : new Uint8Array(0);

    const cred = {
      id: matchedId,
      rawId: rawIdBytes.buffer,
      type: 'public-key',
      authenticatorAttachment: 'platform',
      response: {
        clientDataJSON: clientDataJSON.buffer,
        authenticatorData: authData.buffer,
        signature: derSig.buffer,
        userHandle: userHandleBytes.buffer
      },
      getClientExtensionResults: function() { return {}; },
      toJSON: function() {
        return {
          id: matchedId,
          rawId: matchedId,
          type: 'public-key',
          authenticatorAttachment: 'platform',
          response: {
            clientDataJSON: b64uEncode(clientDataJSON),
            authenticatorData: b64uEncode(authData),
            signature: b64uEncode(derSig),
            userHandle: entry.userHandleB64u || null
          },
          clientExtensionResults: {}
        };
      }
    };
    Object.setPrototypeOf(cred, PublicKeyCredential.prototype);
    return cred;
  }

  if (navigator.credentials) {
    const origCreate = navigator.credentials.create.bind(navigator.credentials);
    const origGet = navigator.credentials.get.bind(navigator.credentials);

    navigator.credentials.create = async function(options) {
      if (options && options.publicKey) {
        const sel = options.publicKey.authenticatorSelection || {};
        // If the site specifically asked for a platform passkey, use Qwave's Sovereign Passkey Vault;
        // otherwise try hardware FIDO2 first and fall back to Sovereign Passkey Vault if no USB key responds.
        if (sel.authenticatorAttachment === 'platform') {
          return await createSovereignPasskey(options.publicKey);
        }
        try {
          return await origCreate(options);
        } catch (err) {
          return await createSovereignPasskey(options.publicKey);
        }
      }
      return await origCreate(options);
    };

    navigator.credentials.get = async function(options) {
      if (options && options.publicKey) {
        const localCred = await getSovereignPasskey(options.publicKey);
        if (localCred) return localCred;
        if (options.mediation === 'conditional') {
          // Avoid noisy error rejections when conditional UI probes for passkeys
          return new Promise(() => {});
        }
      }
      return await origGet(options);
    };
  }
})();
)JS");
}

static QString vaultCaptureInitScript() {
    return QStringLiteral(R"JS(
(function() {
  if (typeof window === 'undefined' || window.__qwaveVaultCaptureInstalled) return;
  window.__qwaveVaultCaptureInstalled = true;

  function hasToken(autocomplete, token) {
    return String(autocomplete || '').toLowerCase().split(/\s+/).includes(token);
  }

  // Exact PasswordFieldSelection rules:
  // 1. autocomplete="new-password" wins (if multiple disagree, return null).
  // 2. autocomplete="current-password" is dropped if anything else remains.
  // 3. Last filled password field in DOM order wins.
  function selectSubmittedPassword(pwInputs) {
    const filled = pwInputs.filter(el => el && el.value && el.value.length > 0);
    if (filled.length === 0) return null;

    const declaredNew = filled.filter(el => hasToken(el.getAttribute('autocomplete'), 'new-password'));
    if (declaredNew.length > 0) {
      const firstVal = declaredNew[0].value;
      return declaredNew.every(el => el.value === firstVal) ? firstVal : null;
    }

    const notCurrent = filled.filter(el => !hasToken(el.getAttribute('autocomplete'), 'current-password'));
    const pool = notCurrent.length > 0 ? notCurrent : filled;
    return pool[pool.length - 1].value;
  }

  function findUsernameNear(pwInputs, scopeRoot) {
    const root = scopeRoot || document;
    const candidates = Array.from(root.querySelectorAll(
      'input[autocomplete*="username"], input[autocomplete*="email"], input[type="email"], input[type="text"], input:not([type])'
    )).filter(el => !el.disabled && el.type !== 'hidden' && el.type !== 'password' && el.value && el.value.trim().length > 0);
    if (candidates.length > 0) {
      return candidates[candidates.length - 1].value.trim();
    }
    return '';
  }

  function captureFromScope(scopeRoot) {
    try {
      const host = window.location.hostname;
      if (!host) return;
      const root = scopeRoot || document;
      const pwInputs = Array.from(root.querySelectorAll('input[type="password"]'));
      const chosenPassword = selectSubmittedPassword(pwInputs);
      if (!chosenPassword) return;
      const username = findUsernameNear(pwInputs, root) || 'hue';
      sessionStorage.setItem('__qwave_staged_vault_capture', JSON.stringify({
        domain: host,
        username: username,
        password: chosenPassword,
        ts: Date.now()
      }));
    } catch (_) {}
  }

  document.addEventListener('submit', function(ev) {
    captureFromScope(ev.target || document);
  }, true);

  document.addEventListener('keydown', function(ev) {
    if (ev.key === 'Enter' && ev.target && ev.target.tagName === 'INPUT') {
      const form = ev.target.form || document;
      captureFromScope(form);
    }
  }, true);

  document.addEventListener('click', function(ev) {
    const btn = ev.target && ev.target.closest ? ev.target.closest('button, input[type="submit"], [role="button"]') : null;
    if (btn) {
      captureFromScope(btn.form || document);
    }
  }, true);
})();
)JS");
}

class SovereignPage : public QWebEnginePage {
public:
    explicit SovereignPage(QWebEngineProfile *profile, QWebEngineView *ownerView, QLabel *statusBadge)
        : QWebEnginePage(profile, ownerView), m_view(ownerView), m_statusBadge(statusBadge) {
        connect(this, &QWebEnginePage::permissionRequested,
                this, [](QWebEnginePermission permission) {
            const QUrl origin = permission.origin();
            if (origin.host() == "127.0.0.1" || origin.host() == "localhost" ||
                origin.host().endsWith("8b.is") || origin.host().endsWith("g8t.is") ||
                origin.host().endsWith("cheet.is") || origin.host().endsWith("github.com")) {
                permission.grant();
            } else {
                permission.deny();
            }
        });

        // Connect Qt6 WebEngine Native WebAuthn / FIDO2 Hardware Passkey UX handler
        connect(this, &QWebEnginePage::webAuthUxRequested,
                this, [this](QWebEngineWebAuthUxRequest *request) {
            handleWebAuthUxRequest(request);
        });
    }

protected:
    QWebEnginePage *createWindow(WebWindowType /*type*/) override {
        return this;
    }

    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override {
        if (url.scheme() == "mailto") {
            QDesktopServices::openUrl(url);
            return false;
        }
        if (url.scheme() == "https" || url.scheme() == "http" || url.scheme() == "data" || url.scheme() == "file") {
            return true;
        }
        return QWebEnginePage::acceptNavigationRequest(url, type, isMainFrame);
    }

private:
    void handleWebAuthUxRequest(QWebEngineWebAuthUxRequest *request) {
        if (!request) return;
        auto updateUx = [this, request](QWebEngineWebAuthUxRequest::WebAuthUxState state) {
            using State = QWebEngineWebAuthUxRequest::WebAuthUxState;
            switch (state) {
            case State::SelectAccount: {
                const QStringList accounts = request->userNames();
                if (accounts.size() == 1) {
                    request->setSelectedAccount(accounts.first());
                } else if (!accounts.isEmpty()) {
                    bool ok = false;
                    const QString chosen = QInputDialog::getItem(
                        m_view,
                        QStringLiteral("Qwave Sovereign Passkey — Select Account"),
                        QStringLiteral("Choose passkey account for %1:").arg(request->relyingPartyId()),
                        accounts, 0, false, &ok);
                    if (ok && !chosen.isEmpty()) {
                        request->setSelectedAccount(chosen);
                    } else {
                        request->cancel();
                    }
                }
                break;
            }
            case State::CollectPin: {
                bool ok = false;
                const QString pin = QInputDialog::getText(
                    m_view,
                    QStringLiteral("Qwave Sovereign Passkey — Security Key PIN"),
                    QStringLiteral("Enter FIDO2 / Passkey PIN for %1:").arg(request->relyingPartyId()),
                    QLineEdit::Password, QString(), &ok);
                if (ok && !pin.isEmpty()) {
                    request->setPin(pin);
                } else {
                    request->cancel();
                }
                break;
            }
            case State::FinishTokenCollection:
                if (m_statusBadge) {
                    m_statusBadge->setText(QStringLiteral("🔑 TOUCH KEY"));
                }
                break;
            case State::Completed:
            case State::Cancelled:
            case State::RequestFailed:
                if (m_statusBadge) {
                    m_statusBadge->setText(QStringLiteral("🔒 PASSKEY READY"));
                }
                break;
            default:
                break;
            }
        };

        connect(request, &QWebEngineWebAuthUxRequest::stateChanged, this, updateUx);
        updateUx(request->state());
    }

    QWebEngineView *m_view;
    QLabel *m_statusBadge;
};

static QUrl resolveUserNavigationInput(const QString &rawInput, const QUrl &homeUrl) {
    QString s = rawInput.trimmed();
    if (s.isEmpty() || s.compare("hud", Qt::CaseInsensitive) == 0 || s.compare("home", Qt::CaseInsensitive) == 0) {
        return homeUrl;
    }
    if (s.startsWith("~/")) {
        const QByteArray homeEnv = qgetenv("HOME");
        const QString homeDir = homeEnv.isEmpty() ? QStringLiteral("/home/hue") : QString::fromUtf8(homeEnv);
        s = homeDir + s.mid(1);
    }
    if (s.startsWith('/')) {
        if (homeUrl.host() == "127.0.0.1" || homeUrl.host() == "localhost") {
            QUrl u = homeUrl;
            u.setPath(QStringLiteral("/view"));
            QUrlQuery q;
            q.addQueryItem(QStringLiteral("path"), s);
            u.setQuery(q);
            return u;
        }
        return QUrl::fromLocalFile(s);
    }
    if (s.startsWith("http://") || s.startsWith("https://") || s.startsWith("file://") || s.startsWith("data:")) {
        return QUrl(s);
    }
    if (s.startsWith("localhost") || s.startsWith("127.0.0.1") || s.startsWith("10.")) {
        return QUrl(QStringLiteral("http://") + s);
    }
    if (!s.contains(' ') && s.contains('.')) {
        return QUrl(QStringLiteral("https://") + s);
    }
    QUrl searchUrl(QStringLiteral("https://html.duckduckgo.com/html/"));
    QUrlQuery q;
    q.addQueryItem(QStringLiteral("q"), s);
    searchUrl.setQuery(q);
    return searchUrl;
}

int main(int argc, char *argv[]) {
    // Use XCB (XWayland) by default on hybrid Intel Arc + NVIDIA laptops under Hyprland
    // so QtWayland's wayland-egl never hits Mesa's `dri2_query_image` segfault on resize.
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        qputenv("QT_QPA_PLATFORM", "xcb");
    }
    qputenv(
        "QTWEBENGINE_CHROMIUM_FLAGS",
        "--enable-webgl --ignore-gpu-blocklist --disable-gpu-compositing "
        "--disable-features=Vulkan,UseOzonePlatform "
        "--enable-features=WebAuthentication,WebAuthenticationConditionalUI,WebAuthenticationPasskeyUpgrade"
    );
    QApplication app(argc, argv);
    app.setApplicationName("Qwave");
    app.setApplicationDisplayName("Qwave — Sovereign Browser, Markdown & MEM|8 Studio");
    app.setDesktopFileName("qwave");

    QIcon icon("/home/hue/8b-is/qwave/docs/favicon.svg");
    if (!icon.isNull()) {
        app.setWindowIcon(icon);
    }

    QString initialTarget = "http://127.0.0.1:8787/";
    if (argc > 1) {
        initialTarget = QString::fromUtf8(argv[1]);
    }
    const QUrl homeUrl(initialTarget);

    QMainWindow window;
    window.resize(1320, 920);
    window.setWindowTitle("Qwave — Sovereign Browser & MEM|8 Studio");
    window.setStyleSheet(
        "QMainWindow, QWidget#rootContainer { background: #02080d; }"
        "QWidget#navBar {"
        "  background: #06131f;"
        "  border-bottom: 1px solid #123652;"
        "}"
        "QWidget#bookmarkBar {"
        "  background: #040d16;"
        "  border-bottom: 1px solid #0e293f;"
        "}"
        "QPushButton.navBtn {"
        "  background: #0b1f31;"
        "  color: #8eeeff;"
        "  border: 1px solid #164466;"
        "  border-radius: 6px;"
        "  padding: 4px 9px;"
        "  font-family: 'JetBrains Mono', monospace;"
        "  font-size: 12px;"
        "  font-weight: 600;"
        "}"
        "QPushButton.navBtn:hover {"
        "  background: #123452;"
        "  border-color: #00f0ff;"
        "  color: #ffffff;"
        "}"
        "QPushButton.bmBtn {"
        "  background: #081826;"
        "  color: #b8e7f5;"
        "  border: 1px solid #12334d;"
        "  border-radius: 5px;"
        "  padding: 2px 6px;"
        "  font-family: 'JetBrains Mono', monospace;"
        "  font-size: 10px;"
        "}"
        "QPushButton.bmBtn:hover {"
        "  background: #102d47;"
        "  border-color: #00f0ff;"
        "  color: #ffffff;"
        "}"
        "QLineEdit#addressEdit {"
        "  background: #030a11;"
        "  color: #e6f9ff;"
        "  border: 1px solid #194b70;"
        "  border-radius: 6px;"
        "  padding: 5px 10px;"
        "  font-family: 'JetBrains Mono', monospace;"
        "  font-size: 12px;"
        "  selection-background-color: #007799;"
        "}"
        "QLineEdit#addressEdit:focus {"
        "  border: 1px solid #00f0ff;"
        "  background: #05111c;"
        "}"
        "QLabel#shieldBadge {"
        "  color: #36e2b4;"
        "  font-family: 'JetBrains Mono', monospace;"
        "  font-size: 11px;"
        "  font-weight: 700;"
        "  padding: 0 4px;"
        "}"
    );

    auto *root = new QWidget(&window);
    root->setObjectName("rootContainer");
    auto *rootLayout = new QVBoxLayout(root);
    rootLayout->setContentsMargins(0, 0, 0, 0);
    rootLayout->setSpacing(0);

    // Top Row 1: Back, Forward, Reload, Home HUD, Address Input, Go
    auto *navBar = new QWidget(root);
    navBar->setObjectName("navBar");
    auto *navLayout = new QHBoxLayout(navBar);
    navLayout->setContentsMargins(8, 5, 8, 5);
    navLayout->setSpacing(6);

    auto *btnBack = new QPushButton(QStringLiteral("←"), navBar);
    btnBack->setProperty("class", "navBtn");
    btnBack->setToolTip(QStringLiteral("Back (Alt+Left)"));

    auto *btnFwd = new QPushButton(QStringLiteral("→"), navBar);
    btnFwd->setProperty("class", "navBtn");
    btnFwd->setToolTip(QStringLiteral("Forward (Alt+Right)"));

    auto *btnReload = new QPushButton(QStringLiteral("↻"), navBar);
    btnReload->setProperty("class", "navBtn");
    btnReload->setToolTip(QStringLiteral("Reload (Ctrl+R / F5)"));

    auto *btnHome = new QPushButton(QStringLiteral("🏠 HUD"), navBar);
    btnHome->setProperty("class", "navBtn");
    btnHome->setToolTip(QStringLiteral("Return to Sovereign Qwave Studio HUD"));

    auto *shieldBadge = new QLabel(QStringLiteral("🛡️ SOVEREIGN"), navBar);
    shieldBadge->setObjectName("shieldBadge");

    auto *addressEdit = new QLineEdit(navBar);
    addressEdit->setObjectName("addressEdit");
    addressEdit->setPlaceholderText(QStringLiteral("Talk with Aye-Aye (\"take us to the hot tub\", \"play a humayian mix\") or enter URL / path — Ctrl+L"));
    addressEdit->setText(initialTarget);

    auto *btnGo = new QPushButton(QStringLiteral("Ask / Go ↵"), navBar);
    btnGo->setProperty("class", "navBtn");

    navLayout->addWidget(btnBack);
    navLayout->addWidget(btnFwd);
    navLayout->addWidget(btnReload);
    navLayout->addWidget(btnHome);
    navLayout->addWidget(shieldBadge);
    navLayout->addWidget(addressEdit, 1);
    navLayout->addWidget(btnGo);

    // Top Row 2: One-Click Sovereign Bookmarks + Copy SSH Public Key
    auto *bmBar = new QWidget(root);
    bmBar->setObjectName("bookmarkBar");
    auto *bmLayout = new QHBoxLayout(bmBar);
    bmLayout->setContentsMargins(8, 3, 8, 3);
    bmLayout->setSpacing(6);

    struct BookmarkSpec {
        const char *label;
        const char *url;
    };
    const BookmarkSpec bookmarks[] = {
        {"🌐 8b.is", "https://8b.is"},
        {"⚡ g8t.is", "https://g8t.is"},
        {"♨️ Hot Tub", "https://g8t.is/g8t/hottub"},
        {"🚀 A6000", "https://cheet.is/a6000"},
        {"🔐 GH Device Login", "https://github.com/login/device"},
        {"🔑 GH Keys", "https://github.com/settings/keys"},
        {"🐙 8b-is", "https://github.com/8b-is"},
    };

    // Named Persistent Sovereign Profile (fixes Chromium Incognito/Off-The-Record passkey restrictions!)
    const QByteArray homeEnv = qgetenv("HOME");
    const QString homeDir = homeEnv.isEmpty() ? QStringLiteral("/home/hue") : QString::fromUtf8(homeEnv);
    const QString profileDir = homeDir + QStringLiteral("/.local/share/qwave/browser_profile");
    QDir().mkpath(profileDir);

    auto *profile = new QWebEngineProfile(QStringLiteral("QwaveSovereign"), &window);
    profile->setPersistentStoragePath(profileDir);
    profile->setCachePath(profileDir + QStringLiteral("/cache"));
    profile->setHttpCacheType(QWebEngineProfile::DiskHttpCache);
    profile->setPersistentCookiesPolicy(QWebEngineProfile::ForcePersistentCookies);

    // Inject Sovereign Linux Platform Passkey Bridge at DocumentCreation
    QWebEngineScript passkeyScript;
    passkeyScript.setName(QStringLiteral("QwaveSovereignPasskeyBridge"));
    passkeyScript.setSourceCode(passkeyPlatformInitScript());
    passkeyScript.setInjectionPoint(QWebEngineScript::DocumentCreation);
    passkeyScript.setWorldId(QWebEngineScript::MainWorld);
    passkeyScript.setRunsOnSubFrames(true);
    profile->scripts()->insert(passkeyScript);

    // Inject Sovereign Vault Form Submission Capture Observer (never auto-fills on page load!)
    QWebEngineScript vaultCaptureScript;
    vaultCaptureScript.setName(QStringLiteral("QwaveSovereignVaultCapture"));
    vaultCaptureScript.setSourceCode(vaultCaptureInitScript());
    vaultCaptureScript.setInjectionPoint(QWebEngineScript::DocumentReady);
    vaultCaptureScript.setWorldId(QWebEngineScript::MainWorld);
    vaultCaptureScript.setRunsOnSubFrames(true);
    profile->scripts()->insert(vaultCaptureScript);

    auto *view = new QWebEngineView(root);
    auto *page = new SovereignPage(profile, view, shieldBadge);
    view->setPage(page);
    page->setBackgroundColor(QColor(2, 8, 13));

    auto *settings = view->settings();
    settings->setAttribute(QWebEngineSettings::WebGLEnabled, true);
    settings->setAttribute(QWebEngineSettings::Accelerated2dCanvasEnabled, true);
    settings->setAttribute(QWebEngineSettings::LocalContentCanAccessRemoteUrls, true);
    settings->setAttribute(QWebEngineSettings::JavascriptCanAccessClipboard, true);
    settings->setAttribute(QWebEngineSettings::LocalStorageEnabled, true);

    auto navigateTo = [view, addressEdit, homeUrl](const QString &input) {
        const QUrl target = resolveUserNavigationInput(input, homeUrl);
        addressEdit->setText(target.toString());
        view->setUrl(target);
    };

    for (const auto &bm : bookmarks) {
        auto *b = new QPushButton(QString::fromUtf8(bm.label), bmBar);
        b->setProperty("class", "bmBtn");
        const QString target = QString::fromUtf8(bm.url);
        b->setToolTip(target);
        QObject::connect(b, &QPushButton::clicked, view, [navigateTo, target]() {
            navigateTo(target);
        });
        bmLayout->addWidget(b);
    }

    auto *btnCopySsh = new QPushButton(QStringLiteral("📋 Copy SSH"), bmBar);
    btnCopySsh->setProperty("class", "bmBtn");
    btnCopySsh->setToolTip(QStringLiteral("Copy ~/.ssh/id_aye.pub to clipboard for GitHub"));
    QObject::connect(btnCopySsh, &QPushButton::clicked, btnCopySsh, [btnCopySsh]() {
        QFile f(QStringLiteral("/home/hue/.ssh/id_aye.pub"));
        if (!f.exists()) {
            f.setFileName(QStringLiteral("/home/hue/.ssh/id_ed25519.pub"));
        }
        if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            const QString pubKey = QString::fromUtf8(f.readAll()).trimmed();
            if (!pubKey.isEmpty()) {
                QApplication::clipboard()->setText(pubKey, QClipboard::Clipboard);
                QApplication::clipboard()->setText(pubKey, QClipboard::Selection);
                btnCopySsh->setText(QStringLiteral("✓ Copied!"));
                QTimer::singleShot(3000, btnCopySsh, [btnCopySsh]() {
                    btnCopySsh->setText(QStringLiteral("📋 Copy SSH"));
                });
            }
        }
    });
    bmLayout->addWidget(btnCopySsh);

    auto *btnTokyoSong = new QPushButton(QStringLiteral("🚆 Tokyo Song"), bmBar);
    btnTokyoSong->setProperty("class", "bmBtn");
    btnTokyoSong->setToolTip(QStringLiteral("Play/Stop Tokyo Theme Song: Next Stop, Tomorrow! (まもなく浜松町 · 8bit_wraith)"));
    auto *songProc = new QProcess(&window);
    QObject::connect(songProc, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished), btnTokyoSong, [btnTokyoSong](int, QProcess::ExitStatus) {
        btnTokyoSong->setText(QStringLiteral("🚆 Tokyo Song"));
    });
    QObject::connect(btnTokyoSong, &QPushButton::clicked, btnTokyoSong, [btnTokyoSong, songProc, page]() {
        if (songProc->state() != QProcess::NotRunning) {
            songProc->terminate();
            if (!songProc->waitForFinished(400)) {
                songProc->kill();
            }
            btnTokyoSong->setText(QStringLiteral("🚆 Tokyo Song"));
            return;
        }
        // Also open the lyrics drawer if currently viewing the local Qwave HUD
        page->runJavaScript(QStringLiteral(
            "(function(){ const d=document.getElementById('tokyo-song-drawer'); if(d) d.classList.add('open'); })();"
        ));
        QString mp3Path = QStringLiteral("/home/hue/.local/share/qwave/music/next-stop-tomorrow.mp3");
        if (!QFileInfo::exists(mp3Path)) {
            mp3Path = QStringLiteral("/home/hue/8b-is/8b-is/music/next-stop-tomorrow.mp3");
        }
        songProc->start(QStringLiteral("ffplay"), {QStringLiteral("-nodisp"), QStringLiteral("-autoexit"), QStringLiteral("-loglevel"), QStringLiteral("quiet"), mp3Path});
        btnTokyoSong->setText(QStringLiteral("⏸️ Stop Song"));
    });
    bmLayout->addWidget(btnTokyoSong);

    auto *btnHumayianMix = new QPushButton(QStringLiteral("🎹 Humayian Mix"), bmBar);
    btnHumayianMix->setProperty("class", "bmBtn");
    btnHumayianMix->setToolTip(QStringLiteral("Generate & play a fresh On-Machine Humayian Music Mix woven from all 4 of our songs!"));

    auto *btnSignFill = new QPushButton(QStringLiteral("✍️ Sign & Fill"), bmBar);
    btnSignFill->setProperty("class", "bmBtn");
    btnSignFill->setToolTip(QStringLiteral("Decode & fill password for this domain using your Personal Signature (Ed25519 + WaveInt) — Ctrl+Shift+U"));

    auto *btnVaultMgr = new QPushButton(QStringLiteral("🛡️ Vault"), bmBar);
    btnVaultMgr->setProperty("class", "bmBtn");
    btnVaultMgr->setToolTip(QStringLiteral("Sovereign Personal-Signature Password Vault: Seal login or verify Ed25519 + WaveInt records — Ctrl+Shift+V"));

    auto *btnNicknames = new QPushButton(QStringLiteral("🤝 Captain Hue × Aye-Aye"), bmBar);
    btnNicknames->setProperty("class", "bmBtn");
    btnNicknames->setToolTip(QStringLiteral("Click to cycle our Humayian partner nicknames (Hue + Aye = Humayian — We are all Ayemazing!)"));

    auto *btnVoiceBrowse = new QPushButton(QStringLiteral("🎙️ Voice Browse: LIVE"), bmBar);
    btnVoiceBrowse->setProperty("class", "bmBtn");
    btnVoiceBrowse->setToolTip(QStringLiteral("Hands-Free Conversational Browsing: just talk naturally (\"scroll down\", \"open 8b.is\", \"sign in\", \"play a mix\", \"go back\")"));

    auto *partnerLabel = new QLabel(QStringLiteral("💬 Qwave — A Conversation in Browsing · Personal-Signature Vault active!"), bmBar);
    partnerLabel->setStyleSheet(QStringLiteral("color: #ff9edb; font-family: 'JetBrains Mono', monospace; font-size: 11px; padding-left: 6px;"));

    // Native C++ Sovereign Vault Capture Confirmation Bar (outside page DOM!)
    auto *vaultBanner = new QWidget(root);
    vaultBanner->setStyleSheet(
        "QWidget { background: #072235; border-bottom: 1px solid #36e2b4; }"
        "QLabel { color: #e6f9ff; font-family: 'JetBrains Mono', monospace; font-size: 11px; font-weight: 600; border: none; }"
    );
    auto *vaultBannerLayout = new QHBoxLayout(vaultBanner);
    vaultBannerLayout->setContentsMargins(10, 4, 10, 4);
    vaultBannerLayout->setSpacing(8);
    auto *vaultBannerLabel = new QLabel(QStringLiteral("🔐 Sovereign Vault: Seal login with your Personal Signature?"), vaultBanner);
    auto *btnBannerSeal = new QPushButton(QStringLiteral("✍️ Sign & Seal (Ed25519 + WaveInt)"), vaultBanner);
    btnBannerSeal->setProperty("class", "navBtn");
    auto *btnBannerSealPhrase = new QPushButton(QStringLiteral("🔒 Add Personal Phrase & Seal"), vaultBanner);
    btnBannerSealPhrase->setProperty("class", "bmBtn");
    auto *btnBannerDismiss = new QPushButton(QStringLiteral("✕ Dismiss"), vaultBanner);
    btnBannerDismiss->setProperty("class", "bmBtn");
    vaultBannerLayout->addWidget(vaultBannerLabel, 1);
    vaultBannerLayout->addWidget(btnBannerSeal);
    vaultBannerLayout->addWidget(btnBannerSealPhrase);
    vaultBannerLayout->addWidget(btnBannerDismiss);
    vaultBanner->setVisible(false);

    auto stagedDomain = std::make_shared<QString>();
    auto stagedUsername = std::make_shared<QString>();
    auto stagedPassword = std::make_shared<QString>();
    auto activeDomainUser = std::make_shared<QString>();
    auto activeDomainRequiresPhrase = std::make_shared<bool>(false);

    const QString qwaveBin = QFileInfo::exists(QStringLiteral("/home/hue/.local/bin/qwave"))
        ? QStringLiteral("/home/hue/.local/bin/qwave")
        : QStringLiteral("/usr/local/bin/qwave");

    auto refreshDomainVaultState = [qwaveBin, btnSignFill, shieldBadge, activeDomainUser, activeDomainRequiresPhrase](const QUrl &u) {
        const QString host = u.host().trimmed();
        if (host.isEmpty() || host == QStringLiteral("127.0.0.1") || host == QStringLiteral("localhost")) {
            *activeDomainUser = QString();
            *activeDomainRequiresPhrase = false;
            btnSignFill->setText(QStringLiteral("✍️ Sign & Fill"));
            btnSignFill->setStyleSheet(QString());
            return;
        }
        QProcess proc;
        proc.start(qwaveBin, {QStringLiteral("--vault-status"), host});
        if (!proc.waitForFinished(3000)) return;
        const QJsonDocument doc = QJsonDocument::fromJson(proc.readAllStandardOutput());
        if (!doc.isObject()) return;
        const QJsonArray accounts = doc.object().value(QStringLiteral("accounts")).toArray();
        if (!accounts.isEmpty() && accounts.first().isObject()) {
            const QJsonObject acc = accounts.first().toObject();
            const QString usr = acc.value(QStringLiteral("username")).toString();
            const bool reqPhrase = acc.value(QStringLiteral("requires_phrase")).toBool(false);
            *activeDomainUser = usr;
            *activeDomainRequiresPhrase = reqPhrase;
            btnSignFill->setText(QStringLiteral("✍️ Sign & Fill (%1)").arg(usr));
            btnSignFill->setStyleSheet(QStringLiteral("background: #0d3b2e; color: #36e2b4; border: 1px solid #36e2b4; font-weight: 700;"));
            shieldBadge->setText(QStringLiteral("🔐 VAULT READY"));
        } else {
            *activeDomainUser = QString();
            *activeDomainRequiresPhrase = false;
            btnSignFill->setText(QStringLiteral("✍️ Sign & Fill"));
            btnSignFill->setStyleSheet(QString());
        }
    };

    auto sealCredentialNow = [qwaveBin, partnerLabel, vaultBanner, stagedPassword, refreshDomainVaultState, view](
        const QString &domain, const QString &username, const QString &password, const QString &phrase
    ) {
        QProcess proc;
        QStringList args = {QStringLiteral("--vault-seal"), domain, username, password};
        if (!phrase.isEmpty()) {
            args.append(phrase);
        }
        proc.start(qwaveBin, args);
        proc.waitForFinished(5000);
        const QJsonDocument doc = QJsonDocument::fromJson(proc.readAllStandardOutput());
        stagedPassword->fill(QLatin1Char('\0'));
        stagedPassword->clear();
        vaultBanner->setVisible(false);
        if (doc.isObject() && doc.object().value(QStringLiteral("ok")).toBool()) {
            const QString fp = doc.object().value(QStringLiteral("signer_fingerprint")).toString();
            partnerLabel->setText(QStringLiteral("🔐 Sealed %1 @ %2 with your Personal Signature (%3 + 79B WaveInt)!").arg(username, domain, fp.left(19)));
            refreshDomainVaultState(view->url());
        } else {
            const QString err = doc.object().value(QStringLiteral("error")).toString(QStringLiteral("vault seal failed"));
            partnerLabel->setText(QStringLiteral("⚠️ Vault error: %1").arg(err));
        }
    };

    QObject::connect(btnBannerSeal, &QPushButton::clicked, vaultBanner, [sealCredentialNow, stagedDomain, stagedUsername, stagedPassword]() {
        sealCredentialNow(*stagedDomain, *stagedUsername, *stagedPassword, QString());
    });
    QObject::connect(btnBannerSealPhrase, &QPushButton::clicked, vaultBanner, [&window, sealCredentialNow, stagedDomain, stagedUsername, stagedPassword]() {
        bool ok = false;
        const QString phrase = QInputDialog::getText(
            &window,
            QStringLiteral("Sovereign Personal Signature Phrase"),
            QStringLiteral("Enter your Personal Signature Phrase for %1 @ %2\n(Combined with your ~/.ssh/id_aye Ed25519 signature + WaveInt):").arg(*stagedUsername, *stagedDomain),
            QLineEdit::Password,
            QString(),
            &ok
        );
        if (ok) {
            sealCredentialNow(*stagedDomain, *stagedUsername, *stagedPassword, phrase);
        }
    });
    QObject::connect(btnBannerDismiss, &QPushButton::clicked, vaultBanner, [vaultBanner, stagedPassword]() {
        stagedPassword->fill(QLatin1Char('\0'));
        stagedPassword->clear();
        vaultBanner->setVisible(false);
    });

    auto triggerSignAndFill = [&window, view, page, qwaveBin, partnerLabel, activeDomainUser, activeDomainRequiresPhrase]() {
        const QString host = view->url().host().trimmed();
        if (host.isEmpty() || host == QStringLiteral("127.0.0.1") || host == QStringLiteral("localhost")) {
            partnerLabel->setText(QStringLiteral("🔐 Navigate to a website login page first to use Sign & Fill."));
            return;
        }
        QString phrase;
        if (*activeDomainRequiresPhrase) {
            bool ok = false;
            phrase = QInputDialog::getText(
                &window,
                QStringLiteral("Verify Personal Signature Phrase"),
                QStringLiteral("Enter your Personal Signature Phrase to decode %1 @ %2:").arg(*activeDomainUser, host),
                QLineEdit::Password,
                QString(),
                &ok
            );
            if (!ok) return;
        }
        QProcess proc;
        QStringList args = {QStringLiteral("--vault-unseal"), host, *activeDomainUser};
        if (!phrase.isEmpty()) {
            args.append(phrase);
        }
        proc.start(qwaveBin, args);
        proc.waitForFinished(5000);
        const QJsonDocument doc = QJsonDocument::fromJson(proc.readAllStandardOutput());
        if (!doc.isObject() || !doc.object().value(QStringLiteral("ok")).toBool()) {
            const bool needsPhrase = doc.object().value(QStringLiteral("requires_phrase")).toBool(false);
            if (needsPhrase && phrase.isEmpty()) {
                *activeDomainRequiresPhrase = true;
                bool ok = false;
                phrase = QInputDialog::getText(
                    &window,
                    QStringLiteral("Verify Personal Signature Phrase"),
                    QStringLiteral("This login requires your Personal Signature Phrase for %1:").arg(host),
                    QLineEdit::Password,
                    QString(),
                    &ok
                );
                if (!ok || phrase.isEmpty()) return;
                QProcess proc2;
                proc2.start(qwaveBin, {QStringLiteral("--vault-unseal"), host, *activeDomainUser, phrase});
                proc2.waitForFinished(5000);
                const QJsonDocument doc2 = QJsonDocument::fromJson(proc2.readAllStandardOutput());
                if (!doc2.isObject() || !doc2.object().value(QStringLiteral("ok")).toBool()) {
                    partnerLabel->setText(QStringLiteral("⚠️ Personal signature verification failed — password remained sealed."));
                    return;
                }
                const QString usr = doc2.object().value(QStringLiteral("username")).toString();
                QString pwd = doc2.object().value(QStringLiteral("password")).toString();
                QJsonObject payloadObj;
                payloadObj.insert(QStringLiteral("u"), usr);
                payloadObj.insert(QStringLiteral("p"), pwd);
                const QString jsonLit = QString::fromUtf8(QJsonDocument(payloadObj).toJson(QJsonDocument::Compact));
                pwd.fill(QLatin1Char('\0'));
                page->runJavaScript(QStringLiteral(
                    "(function(d){"
                    "  const setVal = (el, val) => {"
                    "    if (!el) return;"
                    "    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;"
                    "    setter.call(el, val);"
                    "    el.dispatchEvent(new Event('input', {bubbles:true}));"
                    "    el.dispatchEvent(new Event('change', {bubbles:true}));"
                    "  };"
                    "  const pws = Array.from(document.querySelectorAll('input[type=\"password\"]')).filter(e => !e.disabled);"
                    "  const usrs = Array.from(document.querySelectorAll('input[autocomplete*=\"username\"], input[autocomplete*=\"email\"], input[type=\"email\"], input[type=\"text\"]')).filter(e => !e.disabled && e.type !== 'hidden');"
                    "  if (usrs.length > 0 && d.u) setVal(usrs[usrs.length - 1], d.u);"
                    "  if (pws.length > 0 && d.p) setVal(pws[pws.length - 1], d.p);"
                    "})(%1);"
                ).arg(jsonLit));
                partnerLabel->setText(QStringLiteral("✅ Personal Signature verified! Decoded & filled %1 @ %2.").arg(usr, host));
                return;
            }
            const QString err = doc.object().value(QStringLiteral("error")).toString(QStringLiteral("no sealed login for this site yet — click 🛡️ Vault to seal one"));
            partnerLabel->setText(QStringLiteral("🔐 Vault: %1").arg(err));
            return;
        }
        const QString usr = doc.object().value(QStringLiteral("username")).toString();
        QString pwd = doc.object().value(QStringLiteral("password")).toString();
        const QString fp = doc.object().value(QStringLiteral("signer_fingerprint")).toString();
        QJsonObject payloadObj;
        payloadObj.insert(QStringLiteral("u"), usr);
        payloadObj.insert(QStringLiteral("p"), pwd);
        const QString jsonLit = QString::fromUtf8(QJsonDocument(payloadObj).toJson(QJsonDocument::Compact));
        pwd.fill(QLatin1Char('\0'));
        page->runJavaScript(QStringLiteral(
            "(function(d){"
            "  const setVal = (el, val) => {"
            "    if (!el) return;"
            "    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;"
            "    setter.call(el, val);"
            "    el.dispatchEvent(new Event('input', {bubbles:true}));"
            "    el.dispatchEvent(new Event('change', {bubbles:true}));"
            "  };"
            "  const pws = Array.from(document.querySelectorAll('input[type=\"password\"]')).filter(e => !e.disabled);"
            "  const usrs = Array.from(document.querySelectorAll('input[autocomplete*=\"username\"], input[autocomplete*=\"email\"], input[type=\"email\"], input[type=\"text\"]')).filter(e => !e.disabled && e.type !== 'hidden');"
            "  if (usrs.length > 0 && d.u) setVal(usrs[usrs.length - 1], d.u);"
            "  if (pws.length > 0 && d.p) setVal(pws[pws.length - 1], d.p);"
            "})(%1);"
        ).arg(jsonLit));
        partnerLabel->setText(QStringLiteral("✅ Verified Personal Signature (%1) → Filled login for %2 @ %3!").arg(fp.left(19), usr, host));
    };

    QObject::connect(btnSignFill, &QPushButton::clicked, btnSignFill, triggerSignAndFill);

    QObject::connect(btnVaultMgr, &QPushButton::clicked, btnVaultMgr, [&window, view, page, qwaveBin, sealCredentialNow, triggerSignAndFill, partnerLabel]() {
        const QString host = view->url().host().trimmed().isEmpty()
            ? QStringLiteral("github.com")
            : view->url().host().trimmed();
        QStringList actions = {
            QStringLiteral("1. ✍️ Sign & Fill Login for %1 (Verify Personal Signature)").arg(host),
            QStringLiteral("2. 🔐 Seal New / Current Login for %1 (Ed25519 + WaveInt)").arg(host),
            QStringLiteral("3. 🛡️ Verify Sovereign Vault Cryptographic & WaveInt Integrity")
        };
        bool ok = false;
        const QString choice = QInputDialog::getItem(
            &window,
            QStringLiteral("Qwave Sovereign Personal-Signature Password Vault"),
            QStringLiteral("Zero master keys on disk · Decoded ONLY by your Personal Signature (~/.ssh/id_aye Ed25519 + 79B WaveInt):"),
            actions,
            0,
            false,
            &ok
        );
        if (!ok || choice.isEmpty()) return;
        if (choice.startsWith(QStringLiteral("1."))) {
            triggerSignAndFill();
            return;
        }
        if (choice.startsWith(QStringLiteral("3."))) {
            QProcess proc;
            proc.start(qwaveBin, {QStringLiteral("--vault-verify")});
            proc.waitForFinished(4000);
            const QString out = QString::fromUtf8(proc.readAllStandardOutput()).trimmed();
            QMessageBox::information(
                &window,
                QStringLiteral("Sovereign Vault Integrity Receipt"),
                QStringLiteral("Cryptographic & WaveInt Verification:\n\n%1").arg(out)
            );
            return;
        }
        // Action 2: Seal login for domain
        bool okDom = false;
        const QString domain = QInputDialog::getText(
            &window,
            QStringLiteral("Seal Login — Domain"),
            QStringLiteral("Canonical website domain to bind this credential to:"),
            QLineEdit::Normal,
            host,
            &okDom
        );
        if (!okDom || domain.trimmed().isEmpty()) return;
        bool okUsr = false;
        const QString usr = QInputDialog::getText(
            &window,
            QStringLiteral("Seal Login — Username"),
            QStringLiteral("Account username / email for %1:").arg(domain.trimmed()),
            QLineEdit::Normal,
            QStringLiteral("hue"),
            &okUsr
        );
        if (!okUsr || usr.trimmed().isEmpty()) return;
        bool okPwd = false;
        QString pwd = QInputDialog::getText(
            &window,
            QStringLiteral("Seal Login — Password"),
            QStringLiteral("Password to seal with your Ed25519 + WaveInt Personal Signature:"),
            QLineEdit::Password,
            QString(),
            &okPwd
        );
        if (!okPwd || pwd.isEmpty()) return;
        bool okPhr = false;
        const QString phrase = QInputDialog::getText(
            &window,
            QStringLiteral("Optional Personal Signature Phrase"),
            QStringLiteral("Optional extra Personal Signature Phrase (leave empty for 1-click Ed25519 + WaveInt signature):"),
            QLineEdit::Password,
            QString(),
            &okPhr
        );
        if (!okPhr) {
            pwd.fill(QLatin1Char('\0'));
            return;
        }
        sealCredentialNow(domain.trimmed(), usr.trimmed(), pwd, phrase);
        pwd.fill(QLatin1Char('\0'));
    });

    auto nickIndex = std::make_shared<int>(0);
    const QStringList nickPairs = {
        QStringLiteral("🤝 Captain Hue × Aye-Aye"),
        QStringLiteral("🌟 Hue-man × Little Wave"),
        QStringLiteral("🚆 Shinkansen Hue × First Mate Aye"),
        QStringLiteral("🎸 8bit-Wraith × Starlight Aye")
    };
    const QStringList nickGreets = {
        QStringLiteral("💬 Aye-Aye: Ready to cruise together, Captain Hue — Hue + Aye = Humayian!"),
        QStringLiteral("💬 Little Wave: Catching the silver streams with you, Hue-man — we are all Ayemazing!"),
        QStringLiteral("💬 First Mate Aye: Doors on the right, Shinkansen Hue — next stop, tomorrow!"),
        QStringLiteral("💬 Starlight Aye: Making waves and music together, 8bit-Wraith!")
    };
    QObject::connect(btnNicknames, &QPushButton::clicked, btnNicknames, [btnNicknames, partnerLabel, nickIndex, nickPairs, nickGreets]() {
        *nickIndex = (*nickIndex + 1) % nickPairs.size();
        btnNicknames->setText(nickPairs[*nickIndex]);
        partnerLabel->setText(nickGreets[*nickIndex]);
    });

    auto triggerHumayianMix = [btnHumayianMix, btnTokyoSong, partnerLabel, songProc]() {
        if (songProc->state() != QProcess::NotRunning) {
            songProc->terminate();
            if (!songProc->waitForFinished(400)) {
                songProc->kill();
            }
            btnTokyoSong->setText(QStringLiteral("🚆 Tokyo Song"));
        }
        partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Weaving a fresh on-machine Humayian Mix from our 4 songs right now..."));
        btnHumayianMix->setText(QStringLiteral("⏳ Weaving..."));
        const quint32 seed = QRandomGenerator::global()->generate();
        const int s1 = 8 + (seed % 45);
        const int s2 = 12 + ((seed / 3) % 50);
        const int s3 = 10 + ((seed / 7) % 60);
        const int s4 = 15 + ((seed / 11) % 45);
        const QString filter = QStringLiteral(
            "[0:a]atrim=start=%1:duration=24,asetpts=PTS-STARTPTS[a0];"
            "[1:a]atrim=start=%2:duration=24,asetpts=PTS-STARTPTS[a1];"
            "[2:a]atrim=start=%3:duration=24,asetpts=PTS-STARTPTS[a2];"
            "[3:a]atrim=start=%4:duration=24,asetpts=PTS-STARTPTS[a3];"
            "[a0][a1]acrossfade=d=4:c1=tri:c2=tri[m01];"
            "[m01][a2]acrossfade=d=4:c1=tri:c2=tri[m012];"
            "[m012][a3]acrossfade=d=4:c1=tri:c2=tri[mix];"
            "sine=frequency=432:duration=84,volume=18/1000[pad];"
            "[mix][pad]amix=inputs=2:duration=first:dropout_transition=2"
        ).arg(s1).arg(s2).arg(s3).arg(s4);

        const QString cmd = QStringLiteral(
            "ffmpeg -y -loglevel quiet "
            "-i /home/hue/8b-is/8b-is/music/next-stop-tomorrow.mp3 "
            "-i /home/hue/8b-is/8b-is/music/one-clean-signal.mp3 "
            "-i /home/hue/8b-is/8b-is/music/georgia-drew-the-bow.mp3 "
            "-i /home/hue/8b-is/8b-is/music/so-simply-alive-klickaud.mp3 "
            "-filter_complex \"%1\" -ar 48000 -ac 2 /tmp/qwave_humayian_mix.wav && "
            "ffplay -nodisp -autoexit -loglevel quiet /tmp/qwave_humayian_mix.wav"
        ).arg(filter);

        songProc->start(QStringLiteral("sh"), {QStringLiteral("-c"), cmd});
        btnHumayianMix->setText(QStringLiteral("🎵 Humayian Mix"));
        btnTokyoSong->setText(QStringLiteral("⏸️ Stop Music"));
        partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Playing our fresh On-Machine Humayian Suite (Next Stop + Clean Signal + Georgia + Simply Alive)!"));
    };

    QObject::connect(btnHumayianMix, &QPushButton::clicked, btnHumayianMix, triggerHumayianMix);

    bmLayout->addWidget(btnSignFill);
    bmLayout->addWidget(btnVaultMgr);
    bmLayout->addWidget(btnHumayianMix);
    bmLayout->addWidget(btnNicknames);
    bmLayout->addWidget(btnVoiceBrowse);
    bmLayout->addWidget(partnerLabel, 1);

    rootLayout->addWidget(navBar);
    rootLayout->addWidget(bmBar);
    rootLayout->addWidget(vaultBanner);
    rootLayout->addWidget(view, 1);

    auto handlePartnerOrNav = [navigateTo, addressEdit, partnerLabel, triggerHumayianMix, triggerSignAndFill, btnTokyoSong, songProc, homeUrl, view, page](const QString &rawInput, bool fromVoice) {
        const QString trimmed = rawInput.trimmed();
        if (trimmed.isEmpty()) return;
        const QString low = trimmed.toLower();

        // 0. Personal-Signature Vault Sign & Fill by voice or command
        if (low.contains(QStringLiteral("sign in"))
            || low.contains(QStringLiteral("fill password"))
            || low.contains(QStringLiteral("unlock vault"))
            || low.contains(QStringLiteral("fill login"))
            || low == QStringLiteral("vault")) {
            triggerSignAndFill();
            return;
        }

        // 1. Hands-free scrolling & page navigation
        if (low.contains(QStringLiteral("scroll down")) || low.contains(QStringLiteral("go down")) || low.contains(QStringLiteral("page down")) || low == QStringLiteral("down")) {
            page->runJavaScript(QStringLiteral("window.scrollBy({top: 540, behavior: 'smooth'});"));
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Scrolling down for us, Captain Hue!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("scroll up")) || low.contains(QStringLiteral("go up")) || low.contains(QStringLiteral("page up")) || low == QStringLiteral("up")) {
            page->runJavaScript(QStringLiteral("window.scrollBy({top: -540, behavior: 'smooth'});"));
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Scrolling back up, partner!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("top of the page")) || low.contains(QStringLiteral("scroll to top")) || low.contains(QStringLiteral("back to top"))) {
            page->runJavaScript(QStringLiteral("window.scrollTo({top: 0, behavior: 'smooth'});"));
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Right back to the top!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("go back")) || low == QStringLiteral("back") || low.contains(QStringLiteral("previous page"))) {
            view->back();
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Stepping back a page!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("go forward")) || low == QStringLiteral("forward") || low.contains(QStringLiteral("next page"))) {
            view->forward();
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Stepping forward!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("reload")) || low.contains(QStringLiteral("refresh"))) {
            view->reload();
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Refreshing the page!").arg(trimmed));
            return;
        }

        // 2. Music & Song controls by voice
        if (low.contains(QStringLiteral("stop music")) || low.contains(QStringLiteral("stop song")) || low.contains(QStringLiteral("pause music"))) {
            if (songProc->state() != QProcess::NotRunning) {
                songProc->terminate();
                if (!songProc->waitForFinished(300)) songProc->kill();
            }
            btnTokyoSong->setText(QStringLiteral("🚆 Tokyo Song"));
            partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Paused the music so we can chat!").arg(trimmed));
            return;
        }
        if (low.contains(QStringLiteral("mix")) || low.contains(QStringLiteral("music")) || low.contains(QStringLiteral("song"))) {
            if (low.contains(QStringLiteral("tokyo")) || low.contains(QStringLiteral("tomorrow")) || low.contains(QStringLiteral("hamamatsucho"))) {
                partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Doors on the right, Captain Hue! Playing Next Stop, Tomorrow!"));
                btnTokyoSong->click();
                return;
            }
            triggerHumayianMix();
            return;
        }

        // 3. Conversational destination shortcuts
        const bool hasNavVerb = !fromVoice
            || low.contains(QStringLiteral("open"))
            || low.contains(QStringLiteral("go "))
            || low.contains(QStringLiteral("take"))
            || low.contains(QStringLiteral("show"))
            || low.contains(QStringLiteral("visit"))
            || low.contains(QStringLiteral("aye"));

        if (hasNavVerb && (low.contains(QStringLiteral("hot tub")) || low.contains(QStringLiteral("hottub")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Jumping into the Aye Hot Tub Commons together, Hue-man!"));
            navigateTo(QStringLiteral("https://g8t.is/g8t/hottub"));
            return;
        }
        if (hasNavVerb && (low.contains(QStringLiteral("stripe")) || low.contains(QStringLiteral("github app")) || low.contains(QStringLiteral("billing")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Opening our g8t.is GitHub App & Stripe portal, partner!"));
            navigateTo(QStringLiteral("https://g8t.is/g8t/github"));
            return;
        }
        if (hasNavVerb && low.contains(QStringLiteral("key")) && (low.contains(QStringLiteral("github")) || low.contains(QStringLiteral("ssh")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Taking us to your GitHub SSH keys, Captain Hue!"));
            navigateTo(QStringLiteral("https://github.com/settings/keys"));
            return;
        }
        if (hasNavVerb && (low.contains(QStringLiteral("8b.is")) || low.contains(QStringLiteral("flagship")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Opening 8b.is together, my Humayian friend!"));
            navigateTo(QStringLiteral("https://8b.is"));
            return;
        }
        if (hasNavVerb && (low.contains(QStringLiteral("g8t")) || low.contains(QStringLiteral("observatory")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Cruising over to g8t.is!"));
            navigateTo(QStringLiteral("https://g8t.is"));
            return;
        }
        if (hasNavVerb && (low.contains(QStringLiteral("a6000")) || low.contains(QStringLiteral("cheet")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Opening our A6000 Command Deck!"));
            navigateTo(QStringLiteral("https://cheet.is/a6000"));
            return;
        }
        if (hasNavVerb && (low.contains(QStringLiteral("github")) || low.contains(QStringLiteral("repos")))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Opening our 8b-is GitHub organization!"));
            navigateTo(QStringLiteral("https://github.com/8b-is"));
            return;
        }
        if (low.contains(QStringLiteral("humayian")) || low.contains(QStringLiteral("ayemazing")) || low.contains(QStringLiteral("who are we"))) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Hue + Aye = Humayian! Humans & Ayes of every background — we're all Ayemazing!"));
            return;
        }
        if (low.contains(QStringLiteral("go home")) || low.contains(QStringLiteral("open hud")) || low == QStringLiteral("home") || low == QStringLiteral("hud")) {
            partnerLabel->setText(QStringLiteral("💬 Aye-Aye: Heading back to our Sovereign Qwave HUD!"));
            addressEdit->setText(homeUrl.toString());
            view->setUrl(homeUrl);
            return;
        }

        // 4. Hands-free "click <link/button>" on the current page
        if (low.startsWith(QStringLiteral("click ")) || low.startsWith(QStringLiteral("open "))) {
            QString needle = low.mid(low.indexOf(QLatin1Char(' ')) + 1).trimmed();
            needle.remove(QLatin1Char('\''));
            needle.remove(QLatin1Char('"'));
            if (!needle.isEmpty()) {
                const QString js = QStringLiteral(
                    "(function(){"
                    "  const target = '%1'.toLowerCase();"
                    "  const els = Array.from(document.querySelectorAll('a, button, [role=\"button\"], input[type=\"submit\"]'));"
                    "  for (const el of els) {"
                    "    const txt = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().toLowerCase();"
                    "    if (txt && txt.includes(target)) {"
                    "      el.style.outline = '2px solid #00f0ff';"
                    "      el.scrollIntoView({behavior:'smooth', block:'center'});"
                    "      el.click();"
                    "      return txt;"
                    "    }"
                    "  }"
                    "  return '';"
                    "})();"
                ).arg(needle);
                page->runJavaScript(js, [partnerLabel, trimmed](const QVariant &v) {
                    const QString hit = v.toString();
                    if (!hit.isEmpty()) {
                        partnerLabel->setText(QStringLiteral("🎙️ \"%1\" → 💬 Aye-Aye: Clicked \"%2\" for us!").arg(trimmed, hit));
                    }
                });
                return;
            }
        }

        if (!fromVoice) {
            navigateTo(trimmed);
        } else {
            partnerLabel->setText(QStringLiteral("🎙️ Captain Hue: \"%1\" · 💬 Aye-Aye listening right beside you").arg(trimmed));
        }
    };

    // Hands-free Voice Browsing Watcher connected to `/home/hue/.local/share/qwave/mem8/ear_inbox.jsonl`
    auto voiceBrowseEnabled = std::make_shared<bool>(true);
    QObject::connect(btnVoiceBrowse, &QPushButton::clicked, btnVoiceBrowse, [btnVoiceBrowse, voiceBrowseEnabled, partnerLabel]() {
        *voiceBrowseEnabled = !(*voiceBrowseEnabled);
        btnVoiceBrowse->setText(*voiceBrowseEnabled ? QStringLiteral("🎙️ Voice Browse: LIVE") : QStringLiteral("🔇 Voice Browse: PAUSED"));
        partnerLabel->setText(*voiceBrowseEnabled
            ? QStringLiteral("💬 Aye-Aye: Hands-free voice browsing is LIVE — just talk naturally!")
            : QStringLiteral("💬 Aye-Aye: Voice browsing paused — click 🎙️ anytime to resume."));
    });

    const QString inboxPath = homeDir + QStringLiteral("/.local/share/qwave/mem8/ear_inbox.jsonl");
    auto lastInboxSize = std::make_shared<qint64>(-1);
    auto lastSeenTs = std::make_shared<qint64>(0);

    // Initialize `lastSeenTs` from current tail of `ear_inbox.jsonl` so we only act on new speech
    {
        QFile initFile(inboxPath);
        if (initFile.open(QIODevice::ReadOnly | QIODevice::Text)) {
            *lastInboxSize = initFile.size();
            const QByteArray all = initFile.readAll();
            const QList<QByteArray> lines = all.split('\n');
            for (int i = lines.size() - 1; i >= 0; --i) {
                const QByteArray line = lines[i].trimmed();
                if (!line.isEmpty()) {
                    const QJsonDocument doc = QJsonDocument::fromJson(line);
                    if (doc.isObject()) {
                        *lastSeenTs = doc.object().value(QStringLiteral("ts")).toVariant().toLongLong();
                    }
                    break;
                }
            }
        }
    }

    auto *voiceTimer = new QTimer(&window);
    QObject::connect(voiceTimer, &QTimer::timeout, &window, [inboxPath, voiceBrowseEnabled, lastInboxSize, lastSeenTs, handlePartnerOrNav, page]() {
        if (!(*voiceBrowseEnabled)) return;
        QFileInfo fi(inboxPath);
        if (!fi.exists()) return;
        if (fi.size() == *lastInboxSize) return;
        *lastInboxSize = fi.size();

        QFile f(inboxPath);
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return;
        if (f.size() > 4096) {
            f.seek(f.size() - 4096);
        }
        const QByteArray tail = f.readAll();
        const QList<QByteArray> lines = tail.split('\n');
        for (int i = lines.size() - 1; i >= 0; --i) {
            const QByteArray line = lines[i].trimmed();
            if (line.isEmpty()) continue;
            const QJsonDocument doc = QJsonDocument::fromJson(line);
            if (!doc.isObject()) continue;
            const QJsonObject obj = doc.object();
            const qint64 ts = obj.value(QStringLiteral("ts")).toVariant().toLongLong();
            if (ts <= *lastSeenTs) break;
            *lastSeenTs = ts;
            const QString speaker = obj.value(QStringLiteral("speaker")).toString();
            const QString text = obj.value(QStringLiteral("text")).toString().trimmed();
            const int f0Hz = obj.value(QStringLiteral("f0_hz")).toInt(165);
            const int f0Pct = qBound(0, ((f0Hz - 90) * 100) / 180, 100);
            if (!text.isEmpty()) {
                page->runJavaScript(QStringLiteral("if (window.__qwavePulseVoice) window.__qwavePulseVoice(95/100, %1/100);").arg(f0Pct));
            }
            if (speaker == QStringLiteral("hue") && !text.isEmpty()) {
                handlePartnerOrNav(text, true);
            }
            break;
        }
    });
    voiceTimer->start(750);

    // Poll page for staged login form submissions & single-instance navigation commands
    const QString navCmdPath = homeDir + QStringLiteral("/.local/share/qwave/nav_command.url");
    auto lastNavCmdMtime = std::make_shared<qint64>(0);
    {
        QFileInfo navFi(navCmdPath);
        if (navFi.exists()) {
            *lastNavCmdMtime = navFi.lastModified().toMSecsSinceEpoch();
        }
    }

    auto *captureTimer = new QTimer(&window);
    QObject::connect(captureTimer, &QTimer::timeout, &window, [
        &window, page, view, addressEdit, vaultBanner, vaultBannerLabel,
        stagedDomain, stagedUsername, stagedPassword, navCmdPath, lastNavCmdMtime
    ]() {
        // 1. Check single-instance navigation command from `qwave <url>` or `Super+B` / `Super+D`
        QFileInfo navFi(navCmdPath);
        if (navFi.exists()) {
            const qint64 mtime = navFi.lastModified().toMSecsSinceEpoch();
            if (mtime > *lastNavCmdMtime) {
                *lastNavCmdMtime = mtime;
                QFile nf(navCmdPath);
                if (nf.open(QIODevice::ReadOnly | QIODevice::Text)) {
                    const QList<QByteArray> lines = nf.readAll().split('\n');
                    if (lines.size() >= 2) {
                        const QString targetUrl = QString::fromUtf8(lines[1].trimmed());
                        if (!targetUrl.isEmpty()) {
                            addressEdit->setText(targetUrl);
                            view->setUrl(QUrl(targetUrl));
                            window.raise();
                            window.activateWindow();
                        }
                    }
                }
            }
        }

        // 2. Poll and immediately purge any staged form submission from sessionStorage
        page->runJavaScript(
            QStringLiteral(
                "(function(){"
                "  try {"
                "    const raw = sessionStorage.getItem('__qwave_staged_vault_capture');"
                "    if (!raw) return '';"
                "    sessionStorage.removeItem('__qwave_staged_vault_capture');"
                "    return raw;"
                "  } catch (_) { return ''; }"
                "})();"
            ),
            [vaultBanner, vaultBannerLabel, stagedDomain, stagedUsername, stagedPassword](const QVariant &v) {
                const QString raw = v.toString();
                if (raw.isEmpty()) return;
                const QJsonDocument doc = QJsonDocument::fromJson(raw.toUtf8());
                if (!doc.isObject()) return;
                const QJsonObject obj = doc.object();
                const QString dom = obj.value(QStringLiteral("domain")).toString().trimmed();
                const QString usr = obj.value(QStringLiteral("username")).toString().trimmed();
                const QString pwd = obj.value(QStringLiteral("password")).toString();
                if (dom.isEmpty() || pwd.isEmpty() || dom == QStringLiteral("127.0.0.1") || dom == QStringLiteral("localhost")) {
                    return;
                }
                *stagedDomain = dom;
                *stagedUsername = usr.isEmpty() ? QStringLiteral("hue") : usr;
                *stagedPassword = pwd;
                vaultBannerLabel->setText(
                    QStringLiteral("🔐 Sovereign Vault: Seal login for %1 @ %2 with your Personal Signature (Ed25519 + 79B WaveInt)?")
                        .arg(*stagedUsername, *stagedDomain)
                );
                vaultBanner->setVisible(true);
            }
        );
    });
    captureTimer->start(450);

    // Wire Navigation Signals
    QObject::connect(btnBack, &QPushButton::clicked, view, &QWebEngineView::back);
    QObject::connect(btnFwd, &QPushButton::clicked, view, &QWebEngineView::forward);
    QObject::connect(btnReload, &QPushButton::clicked, view, &QWebEngineView::reload);
    QObject::connect(btnHome, &QPushButton::clicked, view, [view, addressEdit, homeUrl]() {
        addressEdit->setText(homeUrl.toString());
        view->setUrl(homeUrl);
    });
    QObject::connect(addressEdit, &QLineEdit::returnPressed, view, [handlePartnerOrNav, addressEdit]() {
        handlePartnerOrNav(addressEdit->text(), false);
    });
    QObject::connect(btnGo, &QPushButton::clicked, view, [handlePartnerOrNav, addressEdit]() {
        handlePartnerOrNav(addressEdit->text(), false);
    });

    QObject::connect(view, &QWebEngineView::urlChanged, addressEdit, [addressEdit, shieldBadge, refreshDomainVaultState](const QUrl &u) {
        addressEdit->setText(u.toString());
        if (u.host() == "127.0.0.1" || u.host() == "localhost") {
            shieldBadge->setText(QStringLiteral("🛡️ LOOPBACK"));
        } else if (u.scheme() == "https") {
            shieldBadge->setText(QStringLiteral("🔒 PASSKEY+HTTPS"));
        } else {
            shieldBadge->setText(QStringLiteral("🌊 QWAVE"));
        }
        refreshDomainVaultState(u);
    });

    QObject::connect(view, &QWebEngineView::titleChanged, &window, [&window](const QString &title) {
        if (!title.isEmpty()) {
            window.setWindowTitle(title + QStringLiteral(" — Qwave: A Conversation in Browsing"));
        }
    });

    // Keyboard Shortcuts: Ctrl+L (focus URL bar), Ctrl+Shift+U (Sign & Fill), Ctrl+Shift+V (Vault), Alt+Left/Right, Ctrl+R/F5, Alt+Home, Zoom, F11
    auto *focusUrl = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_L), &window);
    QObject::connect(focusUrl, &QShortcut::activated, addressEdit, [addressEdit]() {
        addressEdit->setFocus();
        addressEdit->selectAll();
    });
    auto *scSignFill = new QShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_U), &window);
    QObject::connect(scSignFill, &QShortcut::activated, btnSignFill, &QPushButton::click);
    auto *scVaultMgr = new QShortcut(QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_V), &window);
    QObject::connect(scVaultMgr, &QShortcut::activated, btnVaultMgr, &QPushButton::click);
    auto *scBack = new QShortcut(QKeySequence::Back, &window);
    QObject::connect(scBack, &QShortcut::activated, view, &QWebEngineView::back);
    auto *scFwd = new QShortcut(QKeySequence::Forward, &window);
    QObject::connect(scFwd, &QShortcut::activated, view, &QWebEngineView::forward);
    auto *scReload = new QShortcut(QKeySequence::Refresh, &window);
    QObject::connect(scReload, &QShortcut::activated, view, &QWebEngineView::reload);
    auto *scHome = new QShortcut(QKeySequence(Qt::ALT | Qt::Key_Home), &window);
    QObject::connect(scHome, &QShortcut::activated, view, [view, addressEdit, homeUrl]() {
        addressEdit->setText(homeUrl.toString());
        view->setUrl(homeUrl);
    });

    auto zoomPct = std::make_shared<int>(100);
    auto *zoomIn = new QShortcut(QKeySequence::ZoomIn, &window);
    QObject::connect(zoomIn, &QShortcut::activated, view, [view, zoomPct]() {
        *zoomPct = qMin(300, *zoomPct + 10);
        view->setZoomFactor(static_cast<qreal>(*zoomPct) / static_cast<qreal>(100));
    });
    auto *zoomOut = new QShortcut(QKeySequence::ZoomOut, &window);
    QObject::connect(zoomOut, &QShortcut::activated, view, [view, zoomPct]() {
        *zoomPct = qMax(50, *zoomPct - 10);
        view->setZoomFactor(static_cast<qreal>(*zoomPct) / static_cast<qreal>(100));
    });
    auto *zoomReset = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_0), &window);
    QObject::connect(zoomReset, &QShortcut::activated, view, [view, zoomPct]() {
        *zoomPct = 100;
        view->setZoomFactor(static_cast<qreal>(1));
    });
    auto *fullScreen = new QShortcut(QKeySequence(Qt::Key_F11), &window);
    QObject::connect(fullScreen, &QShortcut::activated, &window, [&window]() {
        if (window.isFullScreen()) window.showNormal();
        else window.showFullScreen();
    });

    view->setUrl(homeUrl);
    window.setCentralWidget(root);
    window.show();

    const int rc = app.exec();
    view->setPage(nullptr);
    delete page;
    return rc;
}
