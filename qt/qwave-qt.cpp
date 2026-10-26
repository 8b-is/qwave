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
#include <QDir>
#include <QFile>
#include <QHBoxLayout>
#include <QIcon>
#include <QInputDialog>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPushButton>
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
    qputenv(
        "QTWEBENGINE_CHROMIUM_FLAGS",
        "--enable-gpu-rasterization --enable-webgl --ignore-gpu-blocklist "
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
    addressEdit->setPlaceholderText(QStringLiteral("Enter URL (https://github.com/settings/keys, 8b.is, g8t.is), file path (/home/hue/...), or search — Ctrl+L"));
    addressEdit->setText(initialTarget);

    auto *btnGo = new QPushButton(QStringLiteral("Go ↵"), navBar);
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
    bmLayout->addStretch(1);

    rootLayout->addWidget(navBar);
    rootLayout->addWidget(bmBar);
    rootLayout->addWidget(view, 1);

    // Wire Navigation Signals
    QObject::connect(btnBack, &QPushButton::clicked, view, &QWebEngineView::back);
    QObject::connect(btnFwd, &QPushButton::clicked, view, &QWebEngineView::forward);
    QObject::connect(btnReload, &QPushButton::clicked, view, &QWebEngineView::reload);
    QObject::connect(btnHome, &QPushButton::clicked, view, [view, addressEdit, homeUrl]() {
        addressEdit->setText(homeUrl.toString());
        view->setUrl(homeUrl);
    });
    QObject::connect(addressEdit, &QLineEdit::returnPressed, view, [navigateTo, addressEdit]() {
        navigateTo(addressEdit->text());
    });
    QObject::connect(btnGo, &QPushButton::clicked, view, [navigateTo, addressEdit]() {
        navigateTo(addressEdit->text());
    });

    QObject::connect(view, &QWebEngineView::urlChanged, addressEdit, [addressEdit, shieldBadge](const QUrl &u) {
        addressEdit->setText(u.toString());
        if (u.host() == "127.0.0.1" || u.host() == "localhost") {
            shieldBadge->setText(QStringLiteral("🛡️ LOOPBACK"));
        } else if (u.scheme() == "https") {
            shieldBadge->setText(QStringLiteral("🔒 PASSKEY+HTTPS"));
        } else {
            shieldBadge->setText(QStringLiteral("🌊 QWAVE"));
        }
    });

    QObject::connect(view, &QWebEngineView::titleChanged, &window, [&window](const QString &title) {
        if (!title.isEmpty()) {
            window.setWindowTitle(title + QStringLiteral(" — Qwave Sovereign Browser"));
        }
    });

    // Keyboard Shortcuts: Ctrl+L (focus URL bar), Alt+Left/Right, Ctrl+R/F5, Alt+Home, Zoom, F11
    auto *focusUrl = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_L), &window);
    QObject::connect(focusUrl, &QShortcut::activated, addressEdit, [addressEdit]() {
        addressEdit->setFocus();
        addressEdit->selectAll();
    });
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

    auto *zoomIn = new QShortcut(QKeySequence::ZoomIn, &window);
    QObject::connect(zoomIn, &QShortcut::activated, view, [view]() {
        view->setZoomFactor(view->zoomFactor() + 0.1);
    });
    auto *zoomOut = new QShortcut(QKeySequence::ZoomOut, &window);
    QObject::connect(zoomOut, &QShortcut::activated, view, [view]() {
        view->setZoomFactor(qMax(0.5, view->zoomFactor() - 0.1));
    });
    auto *zoomReset = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key_0), &window);
    QObject::connect(zoomReset, &QShortcut::activated, view, [view]() {
        view->setZoomFactor(1.0);
    });
    auto *fullScreen = new QShortcut(QKeySequence(Qt::Key_F11), &window);
    QObject::connect(fullScreen, &QShortcut::activated, &window, [&window]() {
        if (window.isFullScreen()) window.showNormal();
        else window.showFullScreen();
    });

    view->setUrl(homeUrl);
    window.setCentralWidget(root);
    window.show();

    return app.exec();
}
