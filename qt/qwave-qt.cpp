// qwave-qt — Native Qt6 WebEngine Sovereign Shell for Qwave on Linux / FreeBSD
//
// Paired with the zero-dependency Rust `qwave` binary (`core/src/bin/qwave.rs`).
// Uses an off-the-record (zero disk cache, zero cookie persistence) QWebEngineProfile
// restricted to the local loopback Qwave server.

#include <QApplication>
#include <QMainWindow>
#include <QWebEngineView>
#include <QWebEngineProfile>
#include <QWebEnginePage>
#include <QWebEnginePermission>
#include <QWebEngineSettings>
#include <QShortcut>
#include <QKeySequence>
#include <QIcon>
#include <QUrl>
#include <QDesktopServices>

class SovereignPage : public QWebEnginePage {
public:
    explicit SovereignPage(QWebEngineProfile *profile, QObject *parent = nullptr)
        : QWebEnginePage(profile, parent) {
        connect(this, &QWebEnginePage::permissionRequested,
                this, [](QWebEnginePermission permission) {
            const QUrl origin = permission.origin();
            if (origin.host() == "127.0.0.1" || origin.host() == "localhost") {
                permission.grant();
            } else {
                permission.deny();
            }
        });
    }

protected:
    bool acceptNavigationRequest(const QUrl &url, NavigationType type, bool isMainFrame) override {
        // Keep loopback Qwave traffic inside the window; open external https:// links in user's browser
        if (url.host() == "127.0.0.1" || url.host() == "localhost" || url.scheme() == "data") {
            return true;
        }
        if (type == QWebEnginePage::NavigationTypeLinkClicked &&
            (url.scheme() == "https" || url.scheme() == "http" || url.scheme() == "mailto")) {
            QDesktopServices::openUrl(url);
            return false;
        }
        return QWebEnginePage::acceptNavigationRequest(url, type, isMainFrame);
    }
};

int main(int argc, char *argv[]) {
    qputenv("QTWEBENGINE_CHROMIUM_FLAGS", "--enable-gpu-rasterization --enable-webgl --ignore-gpu-blocklist");
    QApplication app(argc, argv);
    app.setApplicationName("Qwave");
    app.setApplicationDisplayName("Qwave — Sovereign Markdown & MEM|8 Studio");
    app.setDesktopFileName("qwave");

    QIcon icon("/home/hue/8b-is/qwave/docs/favicon.svg");
    if (!icon.isNull()) {
        app.setWindowIcon(icon);
    }

    QString targetUrl = "http://127.0.0.1:8787/";
    if (argc > 1) {
        targetUrl = QString::fromUtf8(argv[1]);
    }

    QMainWindow window;
    window.resize(1320, 920);
    window.setWindowTitle("Qwave — Sovereign Markdown & MEM|8 Studio");
    window.setStyleSheet("QMainWindow { background: #02080d; }");

    // Off-the-record sovereign profile (no persistent cookies or disk cache)
    auto *profile = new QWebEngineProfile(&window);
    profile->setHttpCacheType(QWebEngineProfile::MemoryHttpCache);
    profile->setPersistentCookiesPolicy(QWebEngineProfile::NoPersistentCookies);

    auto *view = new QWebEngineView(&window);
    auto *page = new SovereignPage(profile, view);
    view->setPage(page);
    page->setBackgroundColor(QColor(2, 8, 13));

    auto *settings = view->settings();
    settings->setAttribute(QWebEngineSettings::WebGLEnabled, true);
    settings->setAttribute(QWebEngineSettings::Accelerated2dCanvasEnabled, true);
    settings->setAttribute(QWebEngineSettings::LocalContentCanAccessRemoteUrls, false);
    settings->setAttribute(QWebEngineSettings::JavascriptCanAccessClipboard, true);

    QObject::connect(view, &QWebEngineView::titleChanged, &window, [&window](const QString &title) {
        if (!title.isEmpty()) {
            window.setWindowTitle(title);
        }
    });

    // Zoom & Fullscreen shortcuts
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

    view->setUrl(QUrl(targetUrl));
    window.setCentralWidget(view);
    window.show();

    return app.exec();
}
