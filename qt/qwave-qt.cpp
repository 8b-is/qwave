// qwave-qt — Native Qt6 WebEngine Sovereign Browser & Markdown Shell for Qwave
//
// Paired with the zero-dependency Rust `qwave` binary (`core/src/bin/qwave.rs`).
// Includes a first-class Sovereign Address Bar (Ctrl+L), Back/Forward/Reload/Home
// navigation, and one-click Bookmarks (HUD, 8b.is, g8t.is, Hot Tub, A6000, GitHub Keys,
// plus one-click Copy SSH Public Key) so no external browser is ever required.

#include <QApplication>
#include <QClipboard>
#include <QDesktopServices>
#include <QFile>
#include <QHBoxLayout>
#include <QIcon>
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
#include <QWebEngineSettings>
#include <QWebEngineView>
#include <QWidget>

class SovereignPage : public QWebEnginePage {
public:
    explicit SovereignPage(QWebEngineProfile *profile, QWebEngineView *ownerView)
        : QWebEnginePage(profile, ownerView), m_view(ownerView) {
        connect(this, &QWebEnginePage::permissionRequested,
                this, [](QWebEnginePermission permission) {
            const QUrl origin = permission.origin();
            if (origin.host() == "127.0.0.1" || origin.host() == "localhost" ||
                origin.host().endsWith("8b.is") || origin.host().endsWith("g8t.is") ||
                origin.host().endsWith("cheet.is")) {
                permission.grant();
            } else {
                permission.deny();
            }
        });
    }

protected:
    QWebEnginePage *createWindow(WebWindowType /*type*/) override {
        // Keep target="_blank" and popup links inside the same sovereign window
        return this;
    }

    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override {
        if (url.scheme() == "mailto") {
            QDesktopServices::openUrl(url);
            return false;
        }
        // Keep all http/https/loopback/data navigation inside Qwave (never punt to Chromium)
        if (url.scheme() == "https" || url.scheme() == "http" || url.scheme() == "data" || url.scheme() == "file") {
            return true;
        }
        return QWebEnginePage::acceptNavigationRequest(url, type, isMainFrame);
    }

private:
    QWebEngineView *m_view;
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
        // Local file path: if homeUrl is a local Qwave loopback studio, ask it to render the path via /view?path=...
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
    // Otherwise search GitHub / 8b-is or DuckDuckGo Lite
    QUrl searchUrl(QStringLiteral("https://html.duckduckgo.com/html/"));
    QUrlQuery q;
    q.addQueryItem("q", s);
    searchUrl.setQuery(q);
    return searchUrl;
}

int main(int argc, char *argv[]) {
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", "--enable-gpu-rasterization --enable-webgl --ignore-gpu-blocklist");
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

    // Session profile (in-memory HTTP cache, session cookies allowed so GitHub login works during session)
    auto *profile = new QWebEngineProfile(&window);
    profile->setHttpCacheType(QWebEngineProfile::MemoryHttpCache);
    profile->setPersistentCookiesPolicy(QWebEngineProfile::AllowPersistentCookies);

    auto *view = new QWebEngineView(root);
    auto *page = new SovereignPage(profile, view);
    view->setPage(page);
    page->setBackgroundColor(QColor(2, 8, 13));

    auto *settings = view->settings();
    settings->setAttribute(QWebEngineSettings::WebGLEnabled, true);
    settings->setAttribute(QWebEngineSettings::Accelerated2dCanvasEnabled, true);
    settings->setAttribute(QWebEngineSettings::LocalContentCanAccessRemoteUrls, true);
    settings->setAttribute(QWebEngineSettings::JavascriptCanAccessClipboard, true);

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
    btnCopySsh->setToolTip(QStringLiteral("Copy ~/.ssh/id_ed25519.pub to clipboard for GitHub"));
    QObject::connect(btnCopySsh, &QPushButton::clicked, btnCopySsh, [btnCopySsh]() {
        QFile f(QStringLiteral("/home/hue/.ssh/id_ed25519.pub"));
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
            shieldBadge->setText(QStringLiteral("🔒 HTTPS"));
        } else {
            shieldBadge->setText(QStringLiteral("🌊 QWAVE"));
        }
    });

    QObject::connect(view, &QWebEngineView::titleChanged, &window, [&window](const QString &title) {
        if (!title.isEmpty()) {
            window.setWindowTitle(title + QStringLiteral(" — Qwave Sovereign Browser"));
        }
    });

    // Keyboard Shortcuts: Ctrl+L (focus URL bar), Alt+Left/Right, Ctrl+R/F5, Ctrl+H (Home HUD), Zoom, F11
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
