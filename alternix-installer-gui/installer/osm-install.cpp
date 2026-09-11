// ═══════════════════════════════════════════════════════════════
// osm-install.cpp — Alternix graphical installer
//
// A FRONTEND ONLY. This program contains no install logic: it
// collects answers, writes /tmp/alternix-install.conf, then runs
// the existing /installer/install.sh and streams its output.
// Every partitioning, chroot and bootloader decision stays in the
// shell scripts, so there is exactly one source of truth.
//
// Build:
//   g++ -std=c++17 -Wall -Wextra -fPIC osm-install.cpp -o osm-install
//       $(pkg-config --cflags --libs Qt5Widgets)
//
// No Q_OBJECT / moc anywhere — new-style connects only.
// ═══════════════════════════════════════════════════════════════

#include <QApplication>
#include <QButtonGroup>
#include <QCheckBox>
#include <QComboBox>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFont>
#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QMessageBox>
#include <QMouseEvent>
#include <QPlainTextEdit>
#include <QProcess>
#include <QProgressBar>
#include <QPushButton>
#include <QRegularExpression>
#include <QScrollArea>
#include <QScrollBar>
#include <QSpinBox>
#include <QStackedWidget>
#include <QStandardPaths>
#include <QTextStream>
#include <QTime>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <QScreen>
#include <QCloseEvent>

#include <functional>
#include <sys/utsname.h>

// Xlib is needed for one thing only: setting keyboard focus onto the
// embedded terminal. With no window manager running, nothing assigns
// input focus, so an xterm launched as its own window receives no key
// presses at all. See TerminalPage.
#include <X11/Xlib.h>

// X11 HEADER POLLUTION — DO NOT REMOVE THESE UNDEFS
// X.h defines KeyPress, KeyRelease, FocusIn, FocusOut, Expose, None,
// Bool and Status as bare preprocessor macros. They collide with
// QEvent::KeyPress and friends, producing errors like
// "expected unqualified-id before numeric constant" in any Qt header
// included afterwards. Undefining them is the standard remedy; the
// Xlib functions used below do not need them.
#undef KeyPress
#undef KeyRelease
#undef FocusIn
#undef FocusOut
#undef Expose
#undef Bool
#undef Status
#undef None
#undef CursorShape
#undef Unsorted

#include "osm-keyboard.h"

// ── Theme ─────────────────────────────────────────────────────────
static const char *BG      = "#282828";
static const char *BG_CARD = "#323232";
static const char *FG      = "#e8e8e8";
static const char *FG_DIM  = "#9a9a9a";
static const char *ACCENT  = "#4a90d9";
static const char *DANGER  = "#d9534f";
static const char *OKGREEN = "#5cb85c";

static const char *INSTALLER_DIR = "/installer";
static const char *CONF_PATH     = "/tmp/alternix-install.conf";
static const char *LOG_PATH      = "/tmp/alternix-install.log";

// ── Collected answers ─────────────────────────────────────────────
struct Answers {
    QString username, password, hostname = "alternix";
    QString timezone = "Europe/London", locale = "en_GB.UTF-8";
    QString desktop  = "alternix";
    QString targetDisk, targetDiskSize, targetDiskModel;
    bool    useSwap  = true;
    int     swapMb   = 2048;
    bool    useHome  = false;
    QString netIface, netSsid;
    bool    netConnected = false;
};

static Answers g_ans;

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

// Strip ANSI escape sequences. install.sh draws a TUI banner with
// colours and scroll-region codes; under QProcess there is no tty,
// so those arrive as literal noise in the log pane.
static QString stripAnsi(const QString &in) {
    static const QRegularExpression re(
        QStringLiteral("\x1B\\[[0-9;?]*[A-Za-z]|\x1B[=>()][0-9A-Za-z]?|\\r"));
    QString out = in;
    out.remove(re);
    return out;
}

// Colourise a line of installer output for the log pane.
//
// ui.sh marks every line with a glyph: err() uses U+2717, warn() "!",
// ok() U+2713, info() U+00B7. Plain text made a fatal error look
// identical to a progress tick, so failures were easy to scroll past.
static QString logLineToHtml(const QString &line) {
    QString esc = line.toHtmlEscaped();
    // Preserve the leading indent, which HTML would otherwise collapse.
    int lead = 0;
    while (lead < esc.size() && esc.at(lead) == ' ') ++lead;
    if (lead > 0) esc = QString("&nbsp;").repeated(lead) + esc.mid(lead);

    const QString t = line.trimmed();
    QString colour = FG_DIM;
    bool bold = false;

    if (t.startsWith(QString::fromUtf8("\u2717"))) {          // err
        colour = DANGER;  bold = true;
    } else if (t.startsWith(QStringLiteral("!"))) {            // warn
        colour = QStringLiteral("#d9a34f");
    } else if (t.startsWith(QString::fromUtf8("\u2713"))) {    // ok
        colour = OKGREEN;
    } else if (t.startsWith(QString::fromUtf8("\u2550")) ||
               t.startsWith(QString::fromUtf8("\u2500")) ||
               t.startsWith(QStringLiteral("=="))) {           // section
        colour = ACCENT;  bold = true;
    } else if (t.contains(QStringLiteral("E: "), Qt::CaseSensitive) ||
               t.contains(QStringLiteral("error"), Qt::CaseInsensitive) ||
               t.contains(QStringLiteral("failed"), Qt::CaseInsensitive)) {
        // Output from apt, dpkg, git and make does not carry ui.sh
        // glyphs, so catch the common failure wording too.
        colour = DANGER;
    }

    return QString("<span style=\"color:%1;%2\">%3</span>")
        .arg(colour, bold ? QStringLiteral("font-weight:600;") : QString(), esc);
}

struct CmdResult {
    int     code = -1;
    QString out;
    QString err;
};

// Synchronous run — only for fast local queries (lsblk, cat, scan).
static CmdResult runCmd(const QString &prog, const QStringList &args,
                        const QByteArray &stdinData = QByteArray(),
                        int timeoutMs = 30000) {
    CmdResult r;
    QProcess p;
    p.start(prog, args);
    if (!p.waitForStarted(5000)) {
        r.err = QStringLiteral("failed to start: ") + prog;
        return r;
    }
    if (!stdinData.isEmpty()) p.write(stdinData);
    p.closeWriteChannel();
    if (!p.waitForFinished(timeoutMs)) {
        p.kill();
        p.waitForFinished(2000);
        r.err = QStringLiteral("timed out: ") + prog;
        return r;
    }
    r.out  = QString::fromUtf8(p.readAllStandardOutput());
    r.err  = QString::fromUtf8(p.readAllStandardError());
    r.code = p.exitCode();
    return r;
}

static QString netHelper() {
    return QString(INSTALLER_DIR) + "/alternix-net";
}

// PROCFS READER — DO NOT REPLACE WITH QTextStream::atEnd()
// Files under /proc report a size of 0, so QFile::size() is 0 and
// QTextStream::atEnd() returns true before a single line is read.
// That is why CPU and Memory both showed "Unknown". readAll() ignores
// the reported size and reads until EOF, which works correctly.
static QStringList readProcLines(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return QStringList();
    return QString::fromUtf8(f.readAll()).split('\n', Qt::SkipEmptyParts);
}

// Run a command without blocking the event loop. The synchronous
// runCmd() froze the entire UI for up to 90 seconds during a WiFi
// connect, which is indistinguishable from a hang.
static void runCmdAsync(QObject *ctx, const QString &prog, const QStringList &args,
                        const QByteArray &stdinData, int timeoutMs,
                        std::function<void(CmdResult)> done) {
    QProcess *p = new QProcess(ctx);
    QTimer *t = new QTimer(p);
    t->setSingleShot(true);
    t->setInterval(timeoutMs);

    auto finish = [p, t, done](int code, bool timedOut) {
        t->stop();
        CmdResult r;
        r.out  = QString::fromUtf8(p->readAllStandardOutput());
        r.err  = timedOut ? QStringLiteral("The operation timed out.")
                          : QString::fromUtf8(p->readAllStandardError());
        r.code = timedOut ? -2 : code;
        done(r);
        p->deleteLater();
    };

    QObject::connect(t, &QTimer::timeout, p, [p, finish]() {
        p->kill();
        finish(-2, true);
    });
    QObject::connect(p, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                     p, [finish](int code, QProcess::ExitStatus) { finish(code, false); });

    p->start(prog, args);
    if (!p->waitForStarted(5000)) {
        t->stop();
        CmdResult r;
        r.code = -1;
        r.err  = QStringLiteral("Could not start %1").arg(prog);
        done(r);
        p->deleteLater();
        return;
    }
    if (!stdinData.isEmpty()) p->write(stdinData);
    p->closeWriteChannel();
    t->start();
}

// Dark-themed modal, sized for a touchscreen.
static void touchMessage(QWidget *parent, const QString &title,
                         const QString &text, bool error) {
    QMessageBox box(parent);
    box.setWindowTitle(title);
    box.setText(text);
    box.setIcon(error ? QMessageBox::Warning : QMessageBox::Information);
    box.setStyleSheet(QString(
        "QMessageBox { background: %1; }"
        "QLabel { color: %2; font-size: 17px; }"
        "QPushButton { background: %3; color: #ffffff; border: none;"
        "  border-radius: 6px; font-size: 17px; padding: 12px 28px;"
        "  min-width: 110px; min-height: 44px; }")
        .arg(BG_CARD, FG, error ? DANGER : ACCENT));
    box.exec();
}

static QString readFileTrimmed(const QString &path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    return QString::fromUtf8(f.readAll()).trimmed();
}

// Single-quote a value for a shell config file.
static QString shQuote(const QString &v) {
    QString s = v;
    s.replace('\'', "'\\''");
    return "'" + s + "'";
}

// ═══════════════════════════════════════════════════════════════
// Widgets
// ═══════════════════════════════════════════════════════════════

// Drag-to-scroll area — scrollbars are unusable on a small touchscreen.
class TouchScrollArea : public QScrollArea {
public:
    explicit TouchScrollArea(QWidget *parent = nullptr) : QScrollArea(parent) {
        setWidgetResizable(true);
        setFrameShape(QFrame::NoFrame);
        setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
        setAttribute(Qt::WA_AcceptTouchEvents, true);
    }

protected:
    void mousePressEvent(QMouseEvent *e) override {
        m_pressY  = e->globalY();
        m_startV  = verticalScrollBar()->value();
        m_dragging = false;
        QScrollArea::mousePressEvent(e);
    }
    void mouseMoveEvent(QMouseEvent *e) override {
        const int dy = e->globalY() - m_pressY;
        if (!m_dragging && qAbs(dy) < 8) { QScrollArea::mouseMoveEvent(e); return; }
        m_dragging = true;
        verticalScrollBar()->setValue(m_startV - dy);
    }
    void mouseReleaseEvent(QMouseEvent *e) override {
        if (m_dragging) { m_dragging = false; e->accept(); return; }
        QScrollArea::mouseReleaseEvent(e);
    }

private:
    int  m_pressY  = 0;
    int  m_startV  = 0;
    bool m_dragging = false;
};

// A tappable panel.
//
// STYLESHEET NOTE — ClickableCard has no Q_OBJECT macro, so
// metaObject()->className() reports "QFrame". A `ClickableCard {}`
// selector therefore matches nothing at all, silently. Always style
// via setObjectName("card") + `QFrame#card {}`.
class ClickableCard : public QFrame {
public:
    explicit ClickableCard(QWidget *parent = nullptr) : QFrame(parent) {
        setObjectName("card");
        setCursor(Qt::PointingHandCursor);
        applyStyle(false);
    }

    void setOnClick(std::function<void()> fn) { m_fn = std::move(fn); }

    void setSelected(bool sel) {
        if (m_selected == sel) return;
        m_selected = sel;
        applyStyle(sel);
    }
    bool isSelected() const { return m_selected; }

protected:
    void mouseReleaseEvent(QMouseEvent *e) override {
        if (rect().contains(e->pos()) && m_fn) m_fn();
        QFrame::mouseReleaseEvent(e);
    }

private:
    void applyStyle(bool sel) {
        const QString border = sel ? ACCENT : "#3c3c3c";
        const QString bg     = sel ? "#2f3d4d" : BG_CARD;
        setStyleSheet(QString(
            "QFrame#card { background: %1; border: 2px solid %2;"
            "              border-radius: 8px; }"
            // Children must be transparent or each one paints its own
            // slab of card-coloured background over the rounded corners.
            "QFrame#card QWidget { background: transparent; border: none; }")
            .arg(bg, border));
    }

    std::function<void()> m_fn;
    bool m_selected = false;
};

static QLabel *mkLabel(const QString &text, int px, const char *colour,
                       bool bold = false, QWidget *parent = nullptr) {
    QLabel *l = new QLabel(text, parent);
    l->setWordWrap(true);
    l->setStyleSheet(QString("color: %1; font-size: %2px; %3")
                         .arg(colour).arg(px)
                         .arg(bold ? "font-weight: 600;" : ""));
    return l;
}

static QPushButton *mkButton(const QString &text, bool primary = false) {
    QPushButton *b = new QPushButton(text);
    b->setMinimumHeight(52);
    b->setMinimumWidth(130);
    b->setCursor(Qt::PointingHandCursor);
    const QString bg = primary ? ACCENT : "#3a3a3a";
    b->setStyleSheet(QString(
        "QPushButton { background: %1; color: #ffffff; border: none;"
        "  border-radius: 6px; font-size: 17px; padding: 0 22px; }"
        "QPushButton:disabled { background: #333333; color: #6a6a6a; }"
        "QPushButton:pressed { background: %2; }")
        .arg(bg, primary ? "#3a7ab8" : "#4a4a4a"));
    return b;
}

static QLineEdit *mkEdit(const QString &placeholder, bool password = false) {
    QLineEdit *e = new QLineEdit;
    e->setPlaceholderText(placeholder);
    e->setMinimumHeight(50);
    if (password) e->setEchoMode(QLineEdit::Password);
    e->setStyleSheet(QString(
        "QLineEdit { background: #1e1e1e; color: %1; border: 1px solid #4a4a4a;"
        "  border-radius: 6px; padding: 0 12px; font-size: 18px; }"
        "QLineEdit:focus { border: 1px solid %2; }")
        .arg(FG, ACCENT));
    return e;
}

// A password field with a reveal toggle. Typing blind on a touch
// keyboard is error-prone, and the installer asks for it twice.
static QWidget *mkPasswordRow(QLineEdit *edit, QWidget *parent = nullptr) {
    QWidget *row = new QWidget(parent);
    QHBoxLayout *h = new QHBoxLayout(row);
    h->setContentsMargins(0, 0, 0, 0);
    h->setSpacing(8);
    h->addWidget(edit, 1);

    QPushButton *eye = new QPushButton(QStringLiteral("Show"), row);
    eye->setMinimumHeight(50);
    eye->setMinimumWidth(88);
    eye->setCheckable(true);
    eye->setFocusPolicy(Qt::NoFocus);   // must not steal focus from the field
    eye->setCursor(Qt::PointingHandCursor);
    eye->setStyleSheet(QString(
        "QPushButton { background: #3a3a3a; color: %1; border: none;"
        "  border-radius: 6px; font-size: 15px; }"
        "QPushButton:checked { background: %2; color: #ffffff; }")
        .arg(FG, ACCENT));
    QObject::connect(eye, &QPushButton::toggled, edit, [edit, eye](bool on) {
        edit->setEchoMode(on ? QLineEdit::Normal : QLineEdit::Password);
        eye->setText(on ? QStringLiteral("Hide") : QStringLiteral("Show"));
    });
    h->addWidget(eye);
    return row;
}

// ═══════════════════════════════════════════════════════════════
// Taskbar — clock, battery, keyboard toggle
//
// There is no window manager or panel in the live session, so this is
// the only place the user can see the time or check whether the
// battery will last the install. It also owns the only way back to a
// keyboard that has been hidden.
// ═══════════════════════════════════════════════════════════════
class Taskbar : public QWidget {
public:
    explicit Taskbar(QWidget *parent = nullptr) : QWidget(parent) {
        setObjectName("osmTaskbar");
        setFixedHeight(46);
        setStyleSheet(
            "QWidget#osmTaskbar { background: #1a1a1a;"
            "                     border-top: 1px solid #3c3c3c; }");

        QHBoxLayout *h = new QHBoxLayout(this);
        h->setContentsMargins(14, 4, 14, 4);
        h->setSpacing(14);

        m_kbBtn = new QPushButton(QStringLiteral("\u2328  Keyboard"), this);
        m_kbBtn->setCheckable(true);
        m_kbBtn->setMinimumHeight(36);
        m_kbBtn->setFocusPolicy(Qt::NoFocus);
        m_kbBtn->setCursor(Qt::PointingHandCursor);
        m_kbBtn->setStyleSheet(QString(
            "QPushButton { background: #303030; color: %1; border: none;"
            "  border-radius: 5px; font-size: 15px; padding: 0 16px; }"
            "QPushButton:checked { background: %2; color: #ffffff; }")
            .arg(FG, ACCENT));
        h->addWidget(m_kbBtn);

        h->addStretch(1);

        m_network = makePill();
        h->addWidget(m_network);

        m_battery = makePill();
        h->addWidget(m_battery);

        m_clock = makePill();
        h->addWidget(m_clock);

        // 10s rather than 1s: the clock shows no seconds, and a Bay
        // Trail tablet does not need a timer waking the CPU every
        // second through a 40-minute install.
        QTimer *t = new QTimer(this);
        QObject::connect(t, &QTimer::timeout, this, [this]() { refresh(); });
        t->start(10000);
        refresh();
    }

    void setOnKeyboardToggled(std::function<void(bool)> fn) {
        QObject::connect(m_kbBtn, &QPushButton::toggled, this, std::move(fn));
    }

    // Keeps the button in step when the keyboard hides itself.
    void setKeyboardVisible(bool visible) {
        if (m_kbBtn->isChecked() == visible) return;
        const bool wasBlocked = m_kbBtn->blockSignals(true);
        m_kbBtn->setChecked(visible);
        m_kbBtn->blockSignals(wasBlocked);
    }

    // Called by the network page once a connection succeeds, and again
    // from the periodic refresh so a dropped link is visible.
    void refreshNetwork() {
        QString text;
        const char *colour = FG_DIM;

        if (!g_ans.netConnected) {
            text = QString::fromUtf8("\u2715  Offline");
            colour = DANGER;
        } else if (!g_ans.netSsid.isEmpty()) {
            QString ssid = g_ans.netSsid;
            if (ssid.size() > 18) ssid = ssid.left(17) + QString::fromUtf8("\u2026");
            text = QString::fromUtf8("\u21f5  ") + ssid;
            colour = OKGREEN;
        } else {
            text = QString::fromUtf8("\u21f5  Wired");
            colour = OKGREEN;
        }
        m_network->setText(text);
        stylePill(m_network, colour);
    }

private:
    // Rounded pill, matching the keyboard button.
    QLabel *makePill() {
        QLabel *l = new QLabel(this);
        l->setAlignment(Qt::AlignCenter);
        l->setMinimumHeight(36);
        l->setFont(QFont(QStringLiteral("DejaVu Sans")));
        stylePill(l, FG);
        return l;
    }

    static void stylePill(QLabel *l, const QString &colour) {
        l->setStyleSheet(QString(
            "QLabel { background: #303030; color: %1; border: none;"
            "  border-radius: 5px; font-size: 15px;"
            "  padding: 0 14px; }").arg(colour));
    }
    void refresh() {
        m_clock->setText(QTime::currentTime().toString(QStringLiteral("HH:mm")));
        refreshNetwork();

        QDir d("/sys/class/power_supply");
        const QStringList bats =
            d.entryList(QStringList() << "BAT*", QDir::Dirs | QDir::NoDotAndDotDot);
        if (bats.isEmpty()) {
            m_battery->setText(QString::fromUtf8("\u26a1  AC"));
            stylePill(m_battery, FG_DIM);
            return;
        }
        const QString base = d.absoluteFilePath(bats.first());
        const QString cap  = readFileTrimmed(base + "/capacity");
        const QString st   = readFileTrimmed(base + "/status");
        if (cap.isEmpty()) {
            m_battery->setText(QStringLiteral("Battery"));
            return;
        }
        const int pct = cap.toInt();
        const bool charging = st.contains(QStringLiteral("Charging"),
                                          Qt::CaseInsensitive);
        m_battery->setText(QString("%1%2%")
                               .arg(charging ? QStringLiteral("\u26a1 ") : QString())
                               .arg(pct));
        // A flat battery mid-install leaves an unbootable disk, so this
        // warns rather than just reporting.
        const char *col = (pct <= 15 && !charging) ? DANGER
                        : (pct <= 30 && !charging) ? "#d9a34f" : FG;
        stylePill(m_battery, col);
    }

    QPushButton *m_kbBtn   = nullptr;
    QLabel      *m_network = nullptr;
    QLabel      *m_battery = nullptr;
    QLabel      *m_clock   = nullptr;
};

// ═══════════════════════════════════════════════════════════════
// Page scaffold
// ═══════════════════════════════════════════════════════════════
class Page : public QWidget {
public:
    explicit Page(const QString &title, const QString &subtitle,
                  QWidget *parent = nullptr)
        : QWidget(parent) {
        QVBoxLayout *root = new QVBoxLayout(this);
        root->setContentsMargins(28, 22, 28, 16);
        root->setSpacing(10);

        root->addWidget(mkLabel(title, 27, FG, true));
        if (!subtitle.isEmpty()) {
            QLabel *s = mkLabel(subtitle, 15, FG_DIM);
            root->addWidget(s);
        }
        root->addSpacing(6);

        m_scroll = new TouchScrollArea(this);
        QWidget *inner = new QWidget;
        m_body = new QVBoxLayout(inner);
        m_body->setContentsMargins(0, 0, 0, 0);
        m_body->setSpacing(12);
        m_scroll->setWidget(inner);
        root->addWidget(m_scroll, 1);

        m_footer = new QHBoxLayout;
        m_footer->setSpacing(12);
        root->addLayout(m_footer);
    }

    QVBoxLayout *body()   { return m_body; }
    QHBoxLayout *footer() { return m_footer; }

    // Called each time the page becomes visible.
    virtual void onEnter() {}

private:
    TouchScrollArea *m_scroll  = nullptr;
    QVBoxLayout     *m_body    = nullptr;
    QHBoxLayout     *m_footer  = nullptr;
};

// ═══════════════════════════════════════════════════════════════
// 1. Welcome
// ═══════════════════════════════════════════════════════════════
class WelcomePage : public Page {
public:
    WelcomePage(std::function<void()> next, std::function<void()> quit)
        : Page(QStringLiteral("Welcome to Alternix"),
               QStringLiteral("One OS. Any machine.")) {

        body()->addWidget(mkLabel(
            QStringLiteral("This installer will set up Alternix on this device."),
            17, FG));

        const QStringList steps = {
            QStringLiteral("Detect your hardware"),
            QStringLiteral("Connect to the internet"),
            QStringLiteral("Collect your preferences"),
            QStringLiteral("Partition and format your disk"),
            QStringLiteral("Install Devuan base (no systemd)"),
            QStringLiteral("Build the seL4 microkernel"),
            QStringLiteral("Install your desktop"),
            QStringLiteral("Configure and boot")
        };
        int n = 1;
        for (const QString &s : steps) {
            body()->addWidget(mkLabel(QString("%1.  %2").arg(n++).arg(s), 16, FG_DIM));
        }

        body()->addSpacing(10);
        body()->addWidget(mkLabel(
            QStringLiteral("Estimated time: 30-50 minutes.\n"
                           "Requires an internet connection and 8 GB of free disk space."),
            15, FG_DIM));
        body()->addStretch(1);

        QPushButton *quitBtn = mkButton(QStringLiteral("Quit"));
        QPushButton *nextBtn = mkButton(QStringLiteral("Begin"), true);
        QObject::connect(quitBtn, &QPushButton::clicked, this, quit);
        QObject::connect(nextBtn, &QPushButton::clicked, this, next);
        footer()->addWidget(quitBtn);
        footer()->addStretch(1);
        footer()->addWidget(nextBtn);
    }
};

// ═══════════════════════════════════════════════════════════════
// 2. Hardware
// ═══════════════════════════════════════════════════════════════
class HardwarePage : public Page {
public:
    HardwarePage(std::function<void()> back, std::function<void()> next)
        : Page(QStringLiteral("Hardware"),
               QStringLiteral("What this installer found on your machine.")) {

        m_card = new ClickableCard;
        m_card->setCursor(Qt::ArrowCursor);
        m_grid = new QGridLayout(m_card);
        m_grid->setContentsMargins(18, 16, 18, 16);
        m_grid->setVerticalSpacing(10);
        m_grid->setColumnStretch(1, 1);
        body()->addWidget(m_card);
        body()->addStretch(1);

        QPushButton *b = mkButton(QStringLiteral("Back"));
        QPushButton *n = mkButton(QStringLiteral("Next"), true);
        QObject::connect(b, &QPushButton::clicked, this, back);
        QObject::connect(n, &QPushButton::clicked, this, next);
        footer()->addWidget(b);
        footer()->addStretch(1);
        footer()->addWidget(n);
    }

    void onEnter() override {
        if (m_loaded) return;
        m_loaded = true;

        addRow(QStringLiteral("Model"),        machineModel());
        addRow(QStringLiteral("CPU"),          cpuModel());
        addRow(QStringLiteral("Cores"),        cpuCores());
        addRow(QStringLiteral("Memory"),       memTotal());
        addRow(QStringLiteral("Architecture"), machineArch());
        addRow(QStringLiteral("Boot Method"),
               QDir("/sys/firmware/efi").exists()
                   ? QStringLiteral("UEFI") : QStringLiteral("BIOS / Legacy"));
        addRow(QStringLiteral("Battery"),      battery());
    }

private:
    void addRow(const QString &k, const QString &v) {
        QLabel *kl = mkLabel(k, 15, FG_DIM);
        QLabel *vl = mkLabel(v.isEmpty() ? QStringLiteral("Unknown") : v, 16, FG, true);
        // DejaVu Sans explicitly: some Noto faces on the target hardware
        // have no digit glyphs, so fontconfig substitutes a face that
        // ignores the stylesheet colour and renders the numbers wrong.
        vl->setFont(QFont(QStringLiteral("DejaVu Sans")));
        m_grid->addWidget(kl, m_row, 0);
        m_grid->addWidget(vl, m_row, 1);
        ++m_row;
    }

    static QString cpuModel() {
        const QStringList lines = readProcLines(QStringLiteral("/proc/cpuinfo"));
        for (const QString &line : lines) {
            if (line.startsWith(QStringLiteral("model name"))) {
                const int i = line.indexOf(':');
                if (i > 0) return line.mid(i + 1).simplified();
            }
        }
        // ARM and some virtualised x86 kernels omit "model name".
        for (const QString &line : lines) {
            if (line.startsWith(QStringLiteral("Hardware")) ||
                line.startsWith(QStringLiteral("Processor"))) {
                const int i = line.indexOf(':');
                if (i > 0) return line.mid(i + 1).simplified();
            }
        }
        return QString();
    }

    static QString cpuCores() {
        int n = 0;
        const QStringList lines = readProcLines(QStringLiteral("/proc/cpuinfo"));
        for (const QString &line : lines)
            if (line.startsWith(QStringLiteral("processor"))) ++n;
        return n > 0 ? QString::number(n) : QString();
    }

    static QString memTotal() {
        const QStringList lines = readProcLines(QStringLiteral("/proc/meminfo"));
        for (const QString &line : lines) {
            if (!line.startsWith(QStringLiteral("MemTotal"))) continue;
            const QStringList parts =
                line.split(QRegularExpression(QStringLiteral("\\s+")),
                           Qt::SkipEmptyParts);
            if (parts.size() >= 2) {
                const double mb = parts[1].toDouble() / 1024.0;
                if (mb >= 1024.0)
                    return QString::number(mb / 1024.0, 'f', 1) + " GB";
                return QString::number(mb, 'f', 0) + " MB";
            }
        }
        return QString();
    }

    // uname(2) directly rather than spawning /bin/uname — no PATH
    // dependency and no process to fail silently.
    static QString machineArch() {
        struct utsname u;
        if (uname(&u) != 0) return QString();
        return QString::fromLatin1(u.machine);
    }

    // DMI gives the actual make and model, which matters when the same
    // image is installed across wildly different machines.
    static QString machineModel() {
        const QString vendor =
            readFileTrimmed(QStringLiteral("/sys/class/dmi/id/sys_vendor"));
        const QString product =
            readFileTrimmed(QStringLiteral("/sys/class/dmi/id/product_name"));
        QString out = (vendor + " " + product).simplified();
        if (out.isEmpty() || out.contains(QStringLiteral("To Be Filled")))
            return QString();
        return out;
    }

    static QString battery() {
        QDir d("/sys/class/power_supply");
        const QStringList entries = d.entryList(QStringList() << "BAT*", QDir::Dirs);
        if (entries.isEmpty()) return QStringLiteral("None (mains powered)");
        const QString base = d.absoluteFilePath(entries.first());
        const QString cap  = readFileTrimmed(base + "/capacity");
        const QString st   = readFileTrimmed(base + "/status");
        if (cap.isEmpty()) return QStringLiteral("Present");
        return cap + "%  " + (st.isEmpty() ? QString() : st);
    }

    ClickableCard *m_card = nullptr;
    QGridLayout   *m_grid = nullptr;
    int  m_row    = 0;
    bool m_loaded = false;
};

// ═══════════════════════════════════════════════════════════════
// 3. Network
// ═══════════════════════════════════════════════════════════════
class NetworkPage : public Page {
public:
    NetworkPage(std::function<void()> back, std::function<void()> next)
        : Page(QStringLiteral("Network"),
               QStringLiteral("Alternix downloads its packages during install, "
                              "so a connection is required.")) {
        m_next = next;

        m_status = mkLabel(QStringLiteral("Checking..."), 16, FG_DIM);
        body()->addWidget(m_status);

        m_ifaceBox = new QComboBox;
        m_ifaceBox->setMinimumHeight(50);
        m_ifaceBox->setStyleSheet(comboStyle());
        body()->addWidget(m_ifaceBox);

        m_scanBtn = mkButton(QStringLiteral("Scan for networks"));
        body()->addWidget(m_scanBtn);

        m_ssidList = new QListWidget;
        m_ssidList->setMinimumHeight(190);
        m_ssidList->setStyleSheet(QString(
            "QListWidget { background: #1e1e1e; color: %1; border: 1px solid #4a4a4a;"
            "  border-radius: 6px; font-size: 17px; }"
            "QListWidget::item { padding: 13px 10px; }"
            "QListWidget::item:selected { background: %2; color: #ffffff; }")
            .arg(FG, ACCENT));
        body()->addWidget(m_ssidList);

        m_psk = mkEdit(QStringLiteral("WiFi password (blank if open)"), true);
        m_pskRow = mkPasswordRow(m_psk);
        body()->addWidget(m_pskRow);

        m_connectBtn = mkButton(QStringLiteral("Connect"), true);
        body()->addWidget(m_connectBtn);
        body()->addStretch(1);

        m_backBtn = mkButton(QStringLiteral("Back"));
        m_nextBtn = mkButton(QStringLiteral("Next"), true);
        m_nextBtn->setEnabled(false);
        QObject::connect(m_backBtn, &QPushButton::clicked, this, back);
        QObject::connect(m_nextBtn, &QPushButton::clicked, this, next);
        footer()->addWidget(m_backBtn);
        footer()->addStretch(1);
        footer()->addWidget(m_nextBtn);

        QObject::connect(m_scanBtn, &QPushButton::clicked, this,
                         [this]() { doScan(); });
        QObject::connect(m_connectBtn, &QPushButton::clicked, this,
                         [this]() { doConnect(); });
        QObject::connect(m_ifaceBox,
                         QOverload<int>::of(&QComboBox::currentIndexChanged), this,
                         [this](int) { updateWifiControls(); });
    }

    // DRIVER PRELOAD — started from main(), not from onEnter().
    // net_load_drivers walks 21 modprobe calls and then sleeps two
    // seconds, with another four seconds on the iwlwifi retry path.
    // Doing that when the page opens meant staring at "Loading network
    // drivers..." for half a minute. Kicking it off as the app starts
    // means it has almost always finished by the time anyone has read
    // the welcome screen and tapped through hardware.
    static void startDriverPreload(QObject *ctx) {
        if (s_driverProc) return;
        s_driverProc = new QProcess(ctx);
        s_driverProc->start("bash", {netHelper(), "drivers"});
    }

    void onEnter() override {
        if (m_populated) return;
        m_populated = true;

        if (s_driverProc && s_driverProc->state() != QProcess::NotRunning) {
            setBusy(true, QStringLiteral("Finishing network driver setup..."));
            QObject::connect(s_driverProc,
                QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                this, [this](int, QProcess::ExitStatus) { afterDrivers(); });
            // Do not wait forever on a wedged modprobe.
            QTimer::singleShot(45000, this, [this]() {
                if (!m_driversDone) afterDrivers();
            });
            return;
        }
        afterDrivers();
    }

private:
    void afterDrivers() {
        if (m_driversDone) return;
        m_driversDone = true;
        populateInterfaces();
        setBusy(false, QString());
        checkStatus();
    }

public:

private:
    static QString comboStyle() {
        return QString(
            "QComboBox { background: #1e1e1e; color: %1; border: 1px solid #4a4a4a;"
            "  border-radius: 6px; padding: 0 12px; font-size: 17px; }"
            "QComboBox QAbstractItemView { background: #1e1e1e; color: %1;"
            "  selection-background-color: %2; font-size: 17px; }")
            .arg(FG, ACCENT);
    }

    void populateInterfaces() {
        m_ifaceBox->clear();
        const CmdResult r = runCmd("bash", {netHelper(), "list"});
        const QStringList lines = r.out.split('\n', Qt::SkipEmptyParts);
        for (const QString &line : lines) {
            const QStringList f = line.split('\t');
            if (f.size() < 2) continue;
            const QString label = f[0] + "   " +
                (f[1] == "wifi" ? QStringLiteral("WiFi") : QStringLiteral("Ethernet"));
            m_ifaceBox->addItem(label, QVariant(QStringList() << f[0] << f[1]));
        }
        if (m_ifaceBox->count() == 0)
            m_status->setText(QStringLiteral("No network interfaces found."));
        updateWifiControls();
    }

    bool currentIsWifi() const {
        if (m_ifaceBox->currentIndex() < 0) return false;
        return m_ifaceBox->currentData().toStringList().value(1) == "wifi";
    }
    QString currentIface() const {
        if (m_ifaceBox->currentIndex() < 0) return QString();
        return m_ifaceBox->currentData().toStringList().value(0);
    }

    void updateWifiControls() {
        const bool wifi = currentIsWifi();
        m_scanBtn->setVisible(wifi);
        m_ssidList->setVisible(wifi);
        m_pskRow->setVisible(wifi);
    }

    void setBusy(bool busy, const QString &msg) {
        if (!msg.isEmpty()) m_status->setText(msg);
        m_scanBtn->setEnabled(!busy);
        m_connectBtn->setEnabled(!busy);
        m_ifaceBox->setEnabled(!busy);
        m_backBtn->setEnabled(!busy);
        QApplication::processEvents();
    }

    void checkStatus() {
        const CmdResult r = runCmd("bash", {netHelper(), "status"}, QByteArray(), 15000);
        setConnected(r.code == 0);
    }

    void setConnected(bool ok) {
        g_ans.netConnected = ok;
        m_nextBtn->setEnabled(ok);
        if (ok) {
            m_status->setText(QStringLiteral("Connected."));
            m_status->setStyleSheet(QString("color: %1; font-size: 16px;").arg(OKGREEN));
        } else {
            m_status->setText(QStringLiteral("Not connected."));
            m_status->setStyleSheet(QString("color: %1; font-size: 16px;").arg(FG_DIM));
        }
    }

    void doScan() {
        const QString iface = currentIface();
        if (iface.isEmpty()) return;
        setBusy(true, QStringLiteral("Scanning for networks..."));
        runCmdAsync(this, "bash", {netHelper(), "scan", iface},
                    QByteArray(), 45000, [this](CmdResult r) {
            m_ssidList->clear();
            const QStringList ssids = r.out.split('\n', Qt::SkipEmptyParts);
            for (const QString &s : ssids) m_ssidList->addItem(s.trimmed());
            setBusy(false, ssids.isEmpty()
                               ? QStringLiteral("No networks found.")
                               : QStringLiteral("Select a network."));
            if (ssids.isEmpty()) {
                touchMessage(this, QStringLiteral("No networks"),
                             QStringLiteral(
                                 "No wireless networks were found.\n\n"
                                 "Check the adapter is enabled and not blocked "
                                 "by a hardware switch, then scan again."),
                             true);
            }
        });
    }

    void doConnect() {
        const QString iface = currentIface();
        if (iface.isEmpty()) return;
        const bool wifi = currentIsWifi();

        QString ssid;
        if (wifi) {
            if (!m_ssidList->currentItem()) {
                m_status->setText(QStringLiteral("Select a network first."));
                return;
            }
            ssid = m_ssidList->currentItem()->text();
        }

        setBusy(true, wifi ? QStringLiteral("Connecting to ") + ssid + "..."
                           : QStringLiteral("Requesting a DHCP lease..."));

        const QByteArray psk = wifi ? (m_psk->text().toUtf8() + "\n") : QByteArray();
        const QStringList args = wifi
            ? QStringList{netHelper(), "connect-wifi", iface, ssid}
            : QStringList{netHelper(), "connect-eth", iface};

        runCmdAsync(this, "bash", args, wifi ? psk : QByteArray(), 90000,
                    [this, iface, wifi, ssid](CmdResult r) {
            setBusy(false, QString());
            if (r.code == 0) {
                g_ans.netIface = iface;
                g_ans.netSsid  = ssid;
                setConnected(true);
                // A wrong RTC breaks every TLS handshake and makes apt
                // reject the Release file as "not valid yet". Sync now,
                // while we know the network is up.
                runCmdAsync(this, "bash", {netHelper(), "synctime"},
                            QByteArray(), 30000, [](CmdResult) {});
                return;
            }

            setConnected(false);
            const QString detail = r.err.trimmed().isEmpty()
                                       ? QStringLiteral("Connection failed.")
                                       : r.err.trimmed().section('\n', -1);
            m_status->setText(detail);
            m_status->setStyleSheet(
                QString("color: %1; font-size: 16px;").arg(DANGER));

            // A failure used to update only this small label, which is
            // easy to miss — the page looked like it was still working.
            QString advice;
            if (r.code == -2) {
                advice = QStringLiteral(
                    "The connection attempt timed out.\n\n"
                    "The network may be out of range, or the access point "
                    "may not have responded.");
            } else if (wifi) {
                advice = QStringLiteral(
                    "Could not connect to \"%1\".\n\n"
                    "The most likely cause is an incorrect password. "
                    "Use Show to check what you typed, then try again.\n\n"
                    "%2").arg(ssid, detail);
            } else {
                advice = QStringLiteral(
                    "Could not get an address on %1.\n\n"
                    "Check the cable is connected and that the network has "
                    "a DHCP server.\n\n%2").arg(iface, detail);
            }
            touchMessage(this, QStringLiteral("Connection failed"), advice, true);
        });
    }

    QLabel      *m_status     = nullptr;
    QComboBox   *m_ifaceBox   = nullptr;
    QPushButton *m_scanBtn    = nullptr;
    QListWidget *m_ssidList   = nullptr;
    QLineEdit   *m_psk        = nullptr;
    QWidget     *m_pskRow     = nullptr;
    QPushButton *m_connectBtn = nullptr;
    QPushButton *m_backBtn    = nullptr;
    QPushButton *m_nextBtn    = nullptr;
    std::function<void()> m_next;
    bool m_populated = false;
    bool m_driversDone = false;
    static QProcess *s_driverProc;
};

QProcess *NetworkPage::s_driverProc = nullptr;

// ═══════════════════════════════════════════════════════════════
// 4. User account and system
// ═══════════════════════════════════════════════════════════════
class UserPage : public Page {
public:
    UserPage(std::function<void()> back, std::function<void()> next)
        : Page(QStringLiteral("Your account"),
               QStringLiteral("This is the account you will log in with.")) {

        body()->addWidget(mkLabel(QStringLiteral("Username"), 15, FG_DIM));
        m_user = mkEdit(QStringLiteral("lowercase letters, digits, - or _"));
        body()->addWidget(m_user);

        body()->addWidget(mkLabel(QStringLiteral("Password"), 15, FG_DIM));
        m_pass1 = mkEdit(QStringLiteral("Password"), true);
        body()->addWidget(mkPasswordRow(m_pass1));

        body()->addWidget(mkLabel(QStringLiteral("Confirm password"), 15, FG_DIM));
        m_pass2 = mkEdit(QStringLiteral("Repeat password"), true);
        body()->addWidget(mkPasswordRow(m_pass2));

        body()->addWidget(mkLabel(QStringLiteral("Computer name"), 15, FG_DIM));
        m_host = mkEdit(QStringLiteral("alternix"));
        m_host->setText(QStringLiteral("alternix"));
        body()->addWidget(m_host);

        body()->addWidget(mkLabel(QStringLiteral("Timezone"), 15, FG_DIM));
        m_tz = new QComboBox;
        m_tz->setMinimumHeight(50);
        m_tz->setStyleSheet(comboStyle());
        m_tz->setEditable(false);
        populateTimezones();
        body()->addWidget(m_tz);

        body()->addWidget(mkLabel(QStringLiteral("Language"), 15, FG_DIM));
        m_locale = new QComboBox;
        m_locale->setMinimumHeight(50);
        m_locale->setStyleSheet(comboStyle());
        populateLocales();
        body()->addWidget(m_locale);

        m_error = mkLabel(QString(), 15, DANGER);
        body()->addWidget(m_error);
        body()->addStretch(1);

        QPushButton *b = mkButton(QStringLiteral("Back"));
        QPushButton *n = mkButton(QStringLiteral("Next"), true);
        QObject::connect(b, &QPushButton::clicked, this, back);
        QObject::connect(n, &QPushButton::clicked, this, [this, next]() {
            if (validate()) next();
        });
        footer()->addWidget(b);
        footer()->addStretch(1);
        footer()->addWidget(n);
    }

private:
    static QString comboStyle() {
        return QString(
            "QComboBox { background: #1e1e1e; color: %1; border: 1px solid #4a4a4a;"
            "  border-radius: 6px; padding: 0 12px; font-size: 17px; }"
            "QComboBox QAbstractItemView { background: #1e1e1e; color: %1;"
            "  selection-background-color: %2; font-size: 17px; }")
            .arg(FG, ACCENT);
    }

    void populateTimezones() {
        // Prefer the real tzdata list; fall back to the same short list
        // the text installer offers if tzdata is not present.
        QStringList zones;
        QDir base("/usr/share/zoneinfo");
        if (base.exists()) {
            const QStringList regions = {"Africa", "America", "Antarctica", "Asia",
                                         "Atlantic", "Australia", "Europe",
                                         "Indian", "Pacific"};
            for (const QString &region : regions) {
                QDir d(base.absoluteFilePath(region));
                if (!d.exists()) continue;
                const QStringList cities =
                    d.entryList(QDir::Files | QDir::NoDotAndDotDot, QDir::Name);
                for (const QString &c : cities) zones << (region + "/" + c);
            }
        }
        if (zones.isEmpty()) {
            zones = QStringList{"Europe/London", "Europe/Paris", "Europe/Berlin",
                                "America/New_York", "America/Los_Angeles",
                                "Asia/Tokyo", "Australia/Sydney", "UTC"};
        }
        zones.sort();
        m_tz->addItems(zones);
        const int i = m_tz->findText(QStringLiteral("Europe/London"));
        m_tz->setCurrentIndex(i >= 0 ? i : 0);
    }

    void populateLocales() {
        QStringList locales;
        QFile f("/usr/share/i18n/SUPPORTED");
        if (f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            QTextStream ts(&f);
            while (!ts.atEnd()) {
                const QString line = ts.readLine().trimmed();
                if (!line.endsWith(QStringLiteral(" UTF-8"))) continue;
                const QString name = line.section(' ', 0, 0);
                if (name.endsWith(QStringLiteral(".UTF-8"))) locales << name;
            }
        }
        if (locales.isEmpty())
            locales = QStringList{"en_GB.UTF-8", "en_US.UTF-8",
                                  "de_DE.UTF-8", "fr_FR.UTF-8"};
        locales.removeDuplicates();
        locales.sort();
        m_locale->addItems(locales);
        const int i = m_locale->findText(QStringLiteral("en_GB.UTF-8"));
        m_locale->setCurrentIndex(i >= 0 ? i : 0);
    }

    bool validate() {
        // Mirrors configure_system.sh gather_user_config exactly.
        static const QRegularExpression userRe("^[a-z_][a-z0-9_-]{0,30}$");
        static const QRegularExpression hostRe(
            "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$");

        if (!userRe.match(m_user->text()).hasMatch()) {
            fail(QStringLiteral("Username must start with a lowercase letter or "
                                "underscore, and contain only lowercase letters, "
                                "digits, - or _."));
            return false;
        }
        if (m_pass1->text().isEmpty()) {
            fail(QStringLiteral("Password cannot be empty."));
            return false;
        }
        if (m_pass1->text() != m_pass2->text()) {
            fail(QStringLiteral("Passwords do not match."));
            return false;
        }
        if (!hostRe.match(m_host->text()).hasMatch()) {
            fail(QStringLiteral("Computer name may contain only letters, digits "
                                "and hyphens, and cannot start or end with a hyphen."));
            return false;
        }

        g_ans.username = m_user->text();
        g_ans.password = m_pass1->text();
        g_ans.hostname = m_host->text();
        g_ans.timezone = m_tz->currentText();
        g_ans.locale   = m_locale->currentText();
        m_error->setText(QString());
        return true;
    }

    void fail(const QString &msg) { m_error->setText(msg); }

    QLineEdit *m_user = nullptr, *m_pass1 = nullptr, *m_pass2 = nullptr,
              *m_host = nullptr;
    QComboBox *m_tz = nullptr, *m_locale = nullptr;
    QLabel    *m_error = nullptr;
};

// ═══════════════════════════════════════════════════════════════
// 5. Disk
// ═══════════════════════════════════════════════════════════════
class DiskPage : public Page {
public:
    DiskPage(std::function<void()> back, std::function<void()> next)
        : Page(QStringLiteral("Disk"),
               QStringLiteral("Choose where Alternix will be installed.")) {

        m_diskBox = new QVBoxLayout;
        m_diskBox->setSpacing(10);
        body()->addLayout(m_diskBox);

        m_warn = mkLabel(QString(), 16, DANGER, true);
        body()->addWidget(m_warn);

        body()->addSpacing(8);
        m_swap = new QCheckBox(QStringLiteral("Create a swap partition"));
        m_swap->setChecked(true);
        m_swap->setStyleSheet(checkStyle());
        body()->addWidget(m_swap);

        QHBoxLayout *swapRow = new QHBoxLayout;
        swapRow->addWidget(mkLabel(QStringLiteral("Swap size (MB)"), 15, FG_DIM));
        m_swapMb = new QSpinBox;
        m_swapMb->setRange(256, 65536);
        m_swapMb->setSingleStep(256);
        m_swapMb->setValue(2048);
        m_swapMb->setMinimumHeight(46);
        m_swapMb->setFont(QFont(QStringLiteral("DejaVu Sans")));
        m_swapMb->setStyleSheet(QString(
            "QSpinBox { background: #1e1e1e; color: %1; border: 1px solid #4a4a4a;"
            "  border-radius: 6px; padding: 0 10px; font-size: 17px; }"
            "QSpinBox::up-button, QSpinBox::down-button { width: 30px; }")
            .arg(FG));
        swapRow->addWidget(m_swapMb, 1);
        body()->addLayout(swapRow);

        m_home = new QCheckBox(QStringLiteral("Separate /home partition"));
        m_home->setStyleSheet(checkStyle());
        body()->addWidget(m_home);

        body()->addWidget(mkLabel(
            QStringLiteral("Everything on the selected disk will be erased."),
            15, FG_DIM));
        body()->addStretch(1);

        QObject::connect(m_swap, &QCheckBox::toggled, this,
                         [this](bool on) { m_swapMb->setEnabled(on); });

        QPushButton *b = mkButton(QStringLiteral("Back"));
        m_nextBtn = mkButton(QStringLiteral("Next"), true);
        m_nextBtn->setEnabled(false);
        QObject::connect(b, &QPushButton::clicked, this, back);
        QObject::connect(m_nextBtn, &QPushButton::clicked, this, [this, next]() {
            g_ans.useSwap = m_swap->isChecked();
            g_ans.swapMb  = m_swapMb->value();
            g_ans.useHome = m_home->isChecked();
            next();
        });
        footer()->addWidget(b);
        footer()->addStretch(1);
        footer()->addWidget(m_nextBtn);
    }

    void onEnter() override {
        if (m_loaded) return;
        m_loaded = true;
        loadDisks();
    }

private:
    static QString checkStyle() {
        return QString("QCheckBox { color: %1; font-size: 17px; spacing: 12px; }"
                       "QCheckBox::indicator { width: 26px; height: 26px; }")
            .arg(FG);
    }

    // Which disk did the live ISO boot from? Installing onto it would
    // pull the filesystem out from under the running installer.
    static QString liveDisk() {
        const QString src = runCmd("findmnt", {"-n", "-o", "SOURCE", "/"}).out.trimmed();
        if (src.isEmpty()) return QString();
        const QString pk = runCmd("lsblk", {"-no", "PKNAME", src}).out
                               .split('\n', Qt::SkipEmptyParts).value(0).trimmed();
        return pk.isEmpty() ? QString() : "/dev/" + pk;
    }

    void loadDisks() {
        // Reuse list_disks from partition.sh rather than duplicating its
        // filtering rules (loop/ram/sr/dm-/zram/md are all excluded there).
        const QString script = QString("source %1/partition.sh; list_disks")
                                   .arg(INSTALLER_DIR);
        const CmdResult r = runCmd("bash", {"-c", script});
        const QString live = liveDisk();

        const QStringList lines = r.out.split('\n', Qt::SkipEmptyParts);
        if (lines.isEmpty()) {
            m_diskBox->addWidget(mkLabel(QStringLiteral("No disks found."), 17, DANGER));
            return;
        }

        for (const QString &line : lines) {
            const QStringList f = line.split('\t');
            if (f.size() < 3) continue;
            const QString dev = f[0], size = f[1], model = f[2];
            const bool isLive = (!live.isEmpty() && dev == live);

            ClickableCard *card = new ClickableCard;
            QVBoxLayout *cv = new QVBoxLayout(card);
            cv->setContentsMargins(18, 14, 18, 14);
            cv->setSpacing(4);

            QLabel *title = mkLabel(dev + "    " + size, 19, FG, true);
            title->setFont(QFont(QStringLiteral("DejaVu Sans")));
            cv->addWidget(title);
            cv->addWidget(mkLabel(model, 15, FG_DIM));
            if (isLive) {
                cv->addWidget(mkLabel(
                    QStringLiteral("This is the installation medium you booted from."),
                    14, DANGER, true));
            }

            card->setOnClick([this, card, dev, size, model, isLive]() {
                if (isLive) {
                    m_warn->setText(QStringLiteral(
                        "That is the drive you booted from. Choose another disk."));
                    return;
                }
                for (ClickableCard *c : m_cards) c->setSelected(c == card);
                g_ans.targetDisk      = dev;
                g_ans.targetDiskSize  = size;
                g_ans.targetDiskModel = model;
                m_warn->setText(QStringLiteral("Everything on %1 will be erased.")
                                    .arg(dev));
                m_nextBtn->setEnabled(true);
            });

            m_cards.append(card);
            m_diskBox->addWidget(card);
        }
    }

    QVBoxLayout           *m_diskBox = nullptr;
    QLabel                *m_warn    = nullptr;
    QCheckBox             *m_swap    = nullptr;
    QCheckBox             *m_home    = nullptr;
    QSpinBox              *m_swapMb  = nullptr;
    QPushButton           *m_nextBtn = nullptr;
    QList<ClickableCard *> m_cards;
    bool m_loaded = false;
};

// ═══════════════════════════════════════════════════════════════
// 6. Desktop
// ═══════════════════════════════════════════════════════════════
class DesktopPage : public Page {
public:
    DesktopPage(std::function<void()> back, std::function<void()> next)
        : Page(QStringLiteral("Desktop"),
               QStringLiteral("Which desktop would you like?")) {

        struct Item { const char *id; const char *name; const char *desc; };
        static const Item items[] = {
            {"alternix", "Alternix",  "The native Alternix desktop. Built from source."},
            {"xfce",     "XFCE",      "Lightweight and traditional."},
            {"lxqt",     "LXQt",      "Lightweight, Qt based."},
            {"lxde",     "LXDE",      "Very lightweight, GTK2."},
            {"mate",     "MATE",      "Classic GNOME 2 fork."},
            {"openbox",  "Openbox",   "Minimal window manager only."},
            {"cli",      "No desktop", "Terminal only. No display server."}
        };

        for (const Item &it : items) {
            ClickableCard *card = new ClickableCard;
            QVBoxLayout *cv = new QVBoxLayout(card);
            cv->setContentsMargins(18, 14, 18, 14);
            cv->setSpacing(4);
            cv->addWidget(mkLabel(QString::fromUtf8(it.name), 19, FG, true));
            cv->addWidget(mkLabel(QString::fromUtf8(it.desc), 15, FG_DIM));

            const QString id = QString::fromUtf8(it.id);
            card->setOnClick([this, card, id]() {
                for (ClickableCard *c : m_cards) c->setSelected(c == card);
                g_ans.desktop = id;
            });
            if (id == QStringLiteral("alternix")) card->setSelected(true);
            m_cards.append(card);
            body()->addWidget(card);
        }
        body()->addStretch(1);

        QPushButton *b = mkButton(QStringLiteral("Back"));
        QPushButton *n = mkButton(QStringLiteral("Next"), true);
        QObject::connect(b, &QPushButton::clicked, this, back);
        QObject::connect(n, &QPushButton::clicked, this, next);
        footer()->addWidget(b);
        footer()->addStretch(1);
        footer()->addWidget(n);
    }

private:
    QList<ClickableCard *> m_cards;
};

// ═══════════════════════════════════════════════════════════════
// 7. Summary
// ═══════════════════════════════════════════════════════════════
class SummaryPage : public Page {
public:
    SummaryPage(std::function<void()> back, std::function<void()> install)
        : Page(QStringLiteral("Ready to install"),
               QStringLiteral("Check these details. Nothing has been written yet.")) {

        m_card = new ClickableCard;
        m_card->setCursor(Qt::ArrowCursor);
        m_grid = new QGridLayout(m_card);
        m_grid->setContentsMargins(18, 16, 18, 16);
        m_grid->setVerticalSpacing(10);
        m_grid->setColumnStretch(1, 1);
        body()->addWidget(m_card);

        body()->addSpacing(8);
        body()->addWidget(mkLabel(
            QStringLiteral("Once you continue, the selected disk is erased and "
                           "cannot be recovered."),
            16, DANGER, true));
        body()->addStretch(1);

        QPushButton *b = mkButton(QStringLiteral("Back"));
        QPushButton *n = mkButton(QStringLiteral("Erase disk and install"), true);
        n->setStyleSheet(QString(
            "QPushButton { background: %1; color: #ffffff; border: none;"
            "  border-radius: 6px; font-size: 17px; padding: 0 22px; }"
            "QPushButton:pressed { background: #b03a37; }").arg(DANGER));
        QObject::connect(b, &QPushButton::clicked, this, back);
        QObject::connect(n, &QPushButton::clicked, this, install);
        footer()->addWidget(b);
        footer()->addStretch(1);
        footer()->addWidget(n);
    }

    void onEnter() override {
        // Rebuild every time — the user may have gone back and changed things.
        QLayoutItem *item;
        while ((item = m_grid->takeAt(0)) != nullptr) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
        m_row = 0;

        addRow(QStringLiteral("Install to"),
               g_ans.targetDisk + "   " + g_ans.targetDiskSize);
        addRow(QStringLiteral("Disk model"), g_ans.targetDiskModel);
        addRow(QStringLiteral("Swap"),
               g_ans.useSwap ? QString::number(g_ans.swapMb) + " MB"
                             : QStringLiteral("None"));
        addRow(QStringLiteral("Separate /home"),
               g_ans.useHome ? QStringLiteral("Yes") : QStringLiteral("No"));
        addRow(QStringLiteral("Username"),  g_ans.username);
        addRow(QStringLiteral("Computer"),  g_ans.hostname);
        addRow(QStringLiteral("Timezone"),  g_ans.timezone);
        addRow(QStringLiteral("Language"),  g_ans.locale);
        addRow(QStringLiteral("Desktop"),   g_ans.desktop);
        addRow(QStringLiteral("Network"),
               g_ans.netSsid.isEmpty()
                   ? (g_ans.netIface.isEmpty() ? QStringLiteral("Already connected")
                                               : g_ans.netIface)
                   : g_ans.netSsid);
    }

private:
    void addRow(const QString &k, const QString &v) {
        QLabel *vl = mkLabel(v, 16, FG, true);
        vl->setFont(QFont(QStringLiteral("DejaVu Sans")));
        m_grid->addWidget(mkLabel(k, 15, FG_DIM), m_row, 0);
        m_grid->addWidget(vl, m_row, 1);
        ++m_row;
    }

    ClickableCard *m_card = nullptr;
    QGridLayout   *m_grid = nullptr;
    int m_row = 0;
};

// ═══════════════════════════════════════════════════════════════
// 8. Progress
// ═══════════════════════════════════════════════════════════════
class ProgressPage : public Page {
public:
    // finished(ok) fires when install.sh exits.
    explicit ProgressPage(std::function<void(bool)> finished)
        : Page(QStringLiteral("Installing"), QString()), m_finished(finished) {

        m_step = mkLabel(QStringLiteral("Starting..."), 18, FG, true);
        body()->addWidget(m_step);

        m_bar = new QProgressBar;
        m_bar->setRange(0, 8);
        m_bar->setValue(0);
        m_bar->setTextVisible(false);
        m_bar->setMinimumHeight(16);
        m_bar->setStyleSheet(QString(
            "QProgressBar { background: #1e1e1e; border: none; border-radius: 8px; }"
            "QProgressBar::chunk { background: %1; border-radius: 8px; }")
            .arg(ACCENT));
        body()->addWidget(m_bar);

        // Second bar, shown only while the rootfs is being unpacked.
        // That single step is most of the install, so without it the
        // main bar would sit still for minutes and look hung.
        m_sub = new QProgressBar;
        m_sub->setRange(0, 100);
        m_sub->setValue(0);
        m_sub->setTextVisible(false);
        m_sub->setMinimumHeight(8);
        m_sub->setStyleSheet(QString(
            "QProgressBar { background: #1e1e1e; border: none; border-radius: 4px; }"
            "QProgressBar::chunk { background: %1; border-radius: 4px; }")
            .arg(OKGREEN));
        m_sub->hide();
        body()->addWidget(m_sub);

        m_errors = mkLabel(QStringLiteral("Errors: 0"), 15, FG_DIM);
        m_errors->setFont(QFont(QStringLiteral("DejaVu Sans")));
        body()->addWidget(m_errors);

        m_log = new QPlainTextEdit;
        m_log->setReadOnly(true);
        m_log->setMinimumHeight(260);
        m_log->setMaximumBlockCount(6000);
        m_log->setStyleSheet(QString(
            "QPlainTextEdit { background: #1a1a1a; color: %1;"
            "  border: 1px solid #3c3c3c; border-radius: 6px;"
            "  font-family: 'DejaVu Sans Mono', monospace; font-size: 13px; }")
            .arg(FG_DIM));
        body()->addWidget(m_log, 1);

        // No footer buttons: there is nothing safe to do mid-install.
    }

    void start() {
        m_log->clear();
        m_errorCount = 0;
        m_errors->setText(QStringLiteral("Errors: 0"));

        m_proc = new QProcess(this);
        m_proc->setProcessChannelMode(QProcess::MergedChannels);

        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        env.insert(QStringLiteral("ALTERNIX_UNATTENDED"), QStringLiteral("1"));

        // TERM MUST NOT BE "dumb" — DO NOT CHANGE BACK
        // "dumb" has no clear capability in terminfo, so `clear` exits
        // with status 1. install-alternix_devuan.sh runs `clear` on
        // line 3 with `set -e` on line 2, so the whole desktop build
        // died instantly with exit 1 and no output at all. Any script
        // in the chain that calls clear, tput or reset has the same
        // problem. xterm is a safe, universally present terminfo entry.
        //
        // The cursor codes this was meant to avoid are handled anyway:
        // banner() and spin_start() are both suppressed when
        // ALTERNIX_UNATTENDED is set, and stripAnsi() removes whatever
        // is left.
        env.insert(QStringLiteral("TERM"), QStringLiteral("xterm"));
        m_proc->setProcessEnvironment(env);

        QObject::connect(m_proc, &QProcess::readyReadStandardOutput, this,
                         [this]() { drain(); });
        QObject::connect(m_proc,
                         QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
                         this, [this](int code, QProcess::ExitStatus st) {
                             drain();
                             const bool ok =
                                 (st == QProcess::NormalExit && code == 0);
                             m_finished(ok);
                         });

        m_proc->start("bash", {QString(INSTALLER_DIR) + "/install.sh"});
    }

    int errorCount() const { return m_errorCount; }

private:
    void drain() {
        m_pending += QString::fromUtf8(m_proc->readAllStandardOutput());
        int nl;
        while ((nl = m_pending.indexOf('\n')) >= 0) {
            const QString raw = m_pending.left(nl);
            m_pending.remove(0, nl + 1);
            handleLine(stripAnsi(raw));
        }
    }

    void handleLine(const QString &line) {
        // Progress token emitted by progress_set() when unattended.
        if (line.startsWith(QStringLiteral("##STEP:"))) {
            const QStringList f = line.split(':');
            if (f.size() >= 3) {
                m_bar->setValue(f[1].toInt());
                m_step->setText(f.mid(2).join(':').trimmed());
            }
            m_sub->hide();
            m_sub->setValue(0);
            return;
        }
        // Per-percent token from install_copy.sh during unsquashfs.
        if (line.startsWith(QStringLiteral("##COPY:"))) {
            bool okNum = false;
            const int pct = line.mid(7).trimmed().toInt(&okNum);
            if (okNum) {
                m_sub->show();
                m_sub->setValue(pct);
                m_step->setText(
                    QStringLiteral("Copying system to disk   %1%").arg(pct));
            }
            return;
        }
        // err() prints "  ✗ message". Errors must stay visible.
        if (line.contains(QStringLiteral("\u2717"))) {
            ++m_errorCount;
            m_errors->setText(QStringLiteral("Errors: %1").arg(m_errorCount));
            m_errors->setStyleSheet(
                QString("color: %1; font-size: 15px; font-weight: 600;").arg(DANGER));
        }
        if (line.trimmed().isEmpty()) return;
        m_log->appendHtml(logLineToHtml(line));
        m_log->verticalScrollBar()->setValue(m_log->verticalScrollBar()->maximum());
    }

    QProcess    *m_proc   = nullptr;
    QLabel      *m_step   = nullptr;
    QProgressBar*m_bar    = nullptr;
    QProgressBar*m_sub    = nullptr;
    QLabel      *m_errors = nullptr;
    QPlainTextEdit *m_log = nullptr;
    QString      m_pending;
    int          m_errorCount = 0;
    std::function<void(bool)> m_finished;
};

// ═══════════════════════════════════════════════════════════════
// Embedded terminal
//
// The old "Terminal" button ran `xterm` detached. Two things were
// wrong with that. Without a window manager nothing positions the
// window, so it appeared small in the top-left corner; and nothing
// assigns input focus, so it ignored the keyboard entirely. Qt had
// already claimed focus via activateWindow() at startup, which made
// it worse.
//
// xterm's -into option reparents it into a window we own, so it fills
// the page like any other widget. Focus is then set explicitly with
// XSetInputFocus on xterm's own window, found by walking the children
// of our container.
// ═══════════════════════════════════════════════════════════════
class TerminalPage : public Page {
public:
    explicit TerminalPage(std::function<void()> back)
        : Page(QStringLiteral("Terminal"),
               QStringLiteral("Tap inside the terminal before typing.")) {

        m_host = new QWidget;
        m_host->setMinimumHeight(320);
        m_host->setAttribute(Qt::WA_NativeWindow);   // must have a real X window
        m_host->setStyleSheet("background: #000000;");
        body()->addWidget(m_host, 1);

        m_status = mkLabel(QString(), 15, FG_DIM);
        body()->addWidget(m_status);

        QPushButton *focusBtn = mkButton(QStringLiteral("Give keyboard to terminal"));
        QPushButton *backBtn  = mkButton(QStringLiteral("Close"), true);
        QObject::connect(focusBtn, &QPushButton::clicked, this,
                         [this]() { grabKeyboardFocus(); });
        QObject::connect(backBtn, &QPushButton::clicked, this, [this, back]() {
            stopTerminal();
            back();
        });
        footer()->addWidget(focusBtn);
        footer()->addStretch(1);
        footer()->addWidget(backBtn);
    }

    void onEnter() override {
        if (m_proc) return;

        if (QStandardPaths::findExecutable(QStringLiteral("xterm")).isEmpty()) {
            m_status->setText(QStringLiteral("xterm is not installed."));
            return;
        }

        m_proc = new QProcess(this);
        const QString wid = QString::number(static_cast<qulonglong>(m_host->winId()));
        m_proc->start("xterm", {"-into", wid,
                                "-fa", "DejaVu Sans Mono", "-fs", "11",
                                "-bg", "black", "-fg", "white",
                                "-sb", "-rightbar",
                                "-e", "/bin/bash"});

        // xterm needs a moment to create and map its window before the
        // child can be found.
        QTimer::singleShot(700, this, [this]() { grabKeyboardFocus(); });
    }

private:
    void stopTerminal() {
        if (!m_proc) return;
        m_proc->terminate();
        if (!m_proc->waitForFinished(1500)) m_proc->kill();
        m_proc->deleteLater();
        m_proc = nullptr;
    }

    void grabKeyboardFocus() {
        Display *dpy = XOpenDisplay(nullptr);
        if (!dpy) {
            m_status->setText(QStringLiteral("Could not open the X display."));
            return;
        }

        Window root = 0, parent = 0, *children = nullptr;
        unsigned int n = 0;
        const Window host = static_cast<Window>(m_host->winId());

        if (XQueryTree(dpy, host, &root, &parent, &children, &n) && n > 0) {
            // xterm is the only child we ever reparent in here.
            XSetInputFocus(dpy, children[0], RevertToParent, CurrentTime);
            XFlush(dpy);
            m_status->setText(QStringLiteral("Keyboard is on the terminal. "
                                             "Use Close to return."));
        } else {
            m_status->setText(QStringLiteral("Terminal window not ready — "
                                             "tap the button again."));
        }
        if (children) XFree(children);
        XCloseDisplay(dpy);
    }

    QWidget  *m_host   = nullptr;
    QLabel   *m_status = nullptr;
    QProcess *m_proc   = nullptr;
};

// ═══════════════════════════════════════════════════════════════
// 9. Finished / failed
// ═══════════════════════════════════════════════════════════════
class FinishedPage : public Page {
public:
    FinishedPage() : Page(QString(), QString()) {
        m_title  = mkLabel(QString(), 26, FG, true);
        m_detail = mkLabel(QString(), 17, FG_DIM);
        body()->addWidget(m_title);
        body()->addWidget(m_detail);
        body()->addSpacing(10);

        m_log = new QPlainTextEdit;
        m_log->setReadOnly(true);
        m_log->setStyleSheet(QString(
            "QPlainTextEdit { background: #1a1a1a; color: %1;"
            "  border: 1px solid #3c3c3c; border-radius: 6px;"
            "  font-family: 'DejaVu Sans Mono', monospace; font-size: 13px; }")
            .arg(FG_DIM));
        m_log->setMinimumHeight(240);
        m_log->hide();
        body()->addWidget(m_log, 1);
        body()->addStretch(1);

        m_logBtn   = mkButton(QStringLiteral("Show log"));
        m_saveBtn  = mkButton(QStringLiteral("Save log to USB"));
        m_shellBtn = mkButton(QStringLiteral("Terminal"));
        m_offBtn   = mkButton(QStringLiteral("Shut down"));
        m_mainBtn  = mkButton(QStringLiteral("Restart now"), true);

        QObject::connect(m_logBtn, &QPushButton::clicked, this, [this]() {
            if (m_log->isVisible()) { m_log->hide(); m_logBtn->setText(QStringLiteral("Show log")); }
            else { loadLog(); m_log->show(); m_logBtn->setText(QStringLiteral("Hide log")); }
        });
        QObject::connect(m_saveBtn, &QPushButton::clicked, this, [this]() {
            m_saveBtn->setEnabled(false);
            m_saveBtn->setText(QStringLiteral("Saving..."));
            QApplication::processEvents();
            const CmdResult r = runCmd(
                "bash", {QString(INSTALLER_DIR) + "/alternix-media", "savelog"},
                QByteArray(), 60000);
            m_saveBtn->setEnabled(true);
            m_saveBtn->setText(QStringLiteral("Save log to USB"));
            if (r.code == 0) {
                touchMessage(this, QStringLiteral("Log saved"),
                             QStringLiteral(
                                 "The install log was written to the "
                                 "installation medium:\n\n%1\n\n"
                                 "You can remove the USB stick and read it "
                                 "on another computer.")
                                 .arg(r.out.trimmed()),
                             false);
            } else {
                touchMessage(this, QStringLiteral("Could not save log"),
                             QStringLiteral(
                                 "There is no writable partition on the "
                                 "installation medium.\n\n"
                                 "The ISO itself is read-only. To save logs, "
                                 "add a second partition to the USB stick and "
                                 "label it ALTERNIX.\n\n%1")
                                 .arg(r.err.trimmed()),
                             true);
            }
        });

        QObject::connect(m_shellBtn, &QPushButton::clicked, this, [this]() {
            if (m_onTerminal) m_onTerminal();
        });
        QObject::connect(m_offBtn, &QPushButton::clicked, this, []() {
            QProcess::execute("sync", {});
            QProcess::startDetached("/sbin/poweroff", {"-f"});
        });
        QObject::connect(m_mainBtn, &QPushButton::clicked, this, []() {
            QProcess::execute("sync", {});
            QProcess::startDetached("/sbin/reboot", {"-f"});
        });

        footer()->addWidget(m_logBtn);
        footer()->addWidget(m_saveBtn);
        footer()->addWidget(m_shellBtn);
        footer()->addStretch(1);
        footer()->addWidget(m_offBtn);
        footer()->addWidget(m_mainBtn);
    }

    void setOnTerminal(std::function<void()> fn) { m_onTerminal = std::move(fn); }

    void setResult(bool ok, int errors) {
        if (ok) {
            m_title->setText(QStringLiteral("Installation complete"));
            m_title->setStyleSheet(
                QString("color: %1; font-size: 26px; font-weight: 600;").arg(OKGREEN));
            QString d = QStringLiteral(
                "Alternix has been installed to %1.\n"
                "Remove the installation media, then restart.")
                .arg(g_ans.targetDisk);
            if (errors > 0) {
                // Never let a "success" screen bury warnings the install
                // recorded on the way through.
                d += QStringLiteral("\n\n%1 error(s) were reported during the "
                                    "install. Check the log before restarting.")
                         .arg(errors);
            }
            m_detail->setText(d);
        } else {
            m_title->setText(QStringLiteral("Installation failed"));
            m_title->setStyleSheet(
                QString("color: %1; font-size: 26px; font-weight: 600;").arg(DANGER));
            m_detail->setText(QStringLiteral(
                "The installer did not finish. The full log is at %1 and is "
                "shown below. The disk may be in a partial state.").arg(LOG_PATH));
            loadLog();
            m_log->show();
            m_logBtn->setText(QStringLiteral("Hide log"));
            m_mainBtn->setText(QStringLiteral("Restart"));
        }
    }

private:
    void loadLog() {
        QFile f(LOG_PATH);
        if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
            m_log->setPlainText(QStringLiteral("Could not read %1").arg(LOG_PATH));
            return;
        }
        m_log->clear();
        const QStringList lines =
            stripAnsi(QString::fromUtf8(f.readAll())).split('\n');
        // Tail only: the full log runs to thousands of lines and the
        // failure is always at the end.
        const int from = qMax(0, lines.size() - 400);
        for (int i = from; i < lines.size(); ++i) {
            if (lines[i].trimmed().isEmpty()) continue;
            m_log->appendHtml(logLineToHtml(lines[i]));
        }
        m_log->verticalScrollBar()->setValue(m_log->verticalScrollBar()->maximum());
    }

    QLabel *m_title = nullptr, *m_detail = nullptr;
    QPlainTextEdit *m_log = nullptr;
    QPushButton *m_logBtn = nullptr, *m_saveBtn = nullptr,
                *m_shellBtn = nullptr, *m_offBtn = nullptr,
                *m_mainBtn = nullptr;
    std::function<void()> m_onTerminal;
};

// ═══════════════════════════════════════════════════════════════
// Config file
// ═══════════════════════════════════════════════════════════════
static bool writeConf(QString *errOut) {
    QFile f(CONF_PATH);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        if (errOut) *errOut = QStringLiteral("Cannot write ") + CONF_PATH;
        return false;
    }
    // The password lives in here in clear text, so restrict it before
    // anything is written. It is on the live tmpfs only and never
    // reaches the installed system.
    f.setPermissions(QFile::ReadOwner | QFile::WriteOwner);

    QTextStream ts(&f);
    ts << "# Written by osm-install. Sourced by install.sh.\n";
    ts << "ALTERNIX_UNATTENDED=1\n";
    ts << "ALTERNIX_USERNAME=" << shQuote(g_ans.username) << "\n";
    ts << "ALTERNIX_PASSWORD=" << shQuote(g_ans.password) << "\n";
    ts << "ALTERNIX_HOSTNAME=" << shQuote(g_ans.hostname) << "\n";
    ts << "ALTERNIX_TIMEZONE=" << shQuote(g_ans.timezone) << "\n";
    ts << "ALTERNIX_LOCALE="   << shQuote(g_ans.locale)   << "\n";
    ts << "ALTERNIX_DESKTOP="  << shQuote(g_ans.desktop)  << "\n";
    ts << "TARGET_DISK="       << shQuote(g_ans.targetDisk) << "\n";
    ts << "PART_MODE='guided'\n";
    ts << "USE_SWAP=" << (g_ans.useSwap ? 1 : 0) << "\n";
    ts << "SWAP_MB="  << (g_ans.useSwap ? g_ans.swapMb : 0) << "\n";
    ts << "USE_HOME=" << (g_ans.useHome ? 1 : 0) << "\n";
    ts.flush();
    f.close();
    return true;
}

// ═══════════════════════════════════════════════════════════════
// Main window
// ═══════════════════════════════════════════════════════════════
class Installer : public QWidget {
public:
    Installer() {
        setWindowTitle(QStringLiteral("Install Alternix"));
        setWindowFlags(Qt::Window | Qt::FramelessWindowHint);
        setStyleSheet(QString("QWidget { background: %1; color: %2; }").arg(BG, FG));

        QVBoxLayout *root = new QVBoxLayout(this);
        root->setContentsMargins(0, 0, 0, 0);
        root->setSpacing(0);

        m_stack = new QStackedWidget(this);
        root->addWidget(m_stack, 1);

        m_kb = new OsmKeyboard(this);
        m_kb->attachAutoShow();
        m_kb->setMaximumHeight(300);
        root->addWidget(m_kb);

        m_taskbar = new Taskbar(this);
        root->addWidget(m_taskbar);

        // Taskbar button -> keyboard, and keyboard -> button, without
        // the two bouncing each other. setKeyboardVisible suppresses
        // the signal when it only needs to reflect state.
        m_taskbar->setOnKeyboardToggled([this](bool on) {
            if (on) m_kb->showFromTaskbar();
            else    m_kb->hideByUser();
        });
        m_kb->setOnVisibilityChanged([this](bool visible) {
            m_taskbar->setKeyboardVisible(visible);
        });

        // The network page updates g_ans; the taskbar reads it. Poll on
        // page changes so the indicator updates the moment a connection
        // succeeds rather than waiting for the next 10s tick.
        QObject::connect(m_stack, &QStackedWidget::currentChanged, this,
                         [this](int) { m_taskbar->refreshNetwork(); });

        auto go = [this](int i) { navigate(i); };

        m_welcome  = new WelcomePage([go]() { go(1); },
                                     []() { QApplication::quit(); });
        m_hardware = new HardwarePage([go]() { go(0); }, [go]() { go(2); });
        m_network  = new NetworkPage ([go]() { go(1); }, [go]() { go(3); });
        m_user     = new UserPage    ([go]() { go(2); }, [go]() { go(4); });
        m_disk     = new DiskPage    ([go]() { go(3); }, [go]() { go(5); });
        m_desktop  = new DesktopPage ([go]() { go(4); }, [go]() { go(6); });
        m_summary  = new SummaryPage ([go]() { go(5); }, [this]() { beginInstall(); });
        m_progress = new ProgressPage([this](bool ok) { onFinished(ok); });
        m_done     = new FinishedPage();

        m_terminal = new TerminalPage([go]() { go(8); });
        m_done->setOnTerminal([go]() { go(9); });

        m_pages = {m_welcome, m_hardware, m_network, m_user, m_disk,
                   m_desktop, m_summary, m_progress, m_done, m_terminal};
        for (Page *p : m_pages) m_stack->addWidget(p);
        navigate(0);
    }

protected:
    // Once the install is running there is no safe way to stop it, so
    // the window manager close button must not be able to.
    void closeEvent(QCloseEvent *e) override {
        if (m_installing) e->ignore();
        else QWidget::closeEvent(e);
    }

private:
    void navigate(int index) {
        m_stack->setCurrentIndex(index);
        // NOT qobject_cast: Page has no Q_OBJECT macro (no moc in this
        // build), so qobject_cast would fail its static_assert. Keep an
        // explicit list instead.
        if (index >= 0 && index < m_pages.size()) m_pages[index]->onEnter();
    }

    void beginInstall() {
        QString err;
        if (!writeConf(&err)) {
            QMessageBox::critical(this, QStringLiteral("Error"), err);
            return;
        }
        m_installing = true;
        m_kb->setAutoShow(false);
        m_kb->hide();
        navigate(7);
        m_progress->start();
    }

    void onFinished(bool ok) {
        m_installing = false;
        // The clear-text password must not outlive the install.
        QFile::remove(CONF_PATH);
        m_done->setResult(ok, m_progress->errorCount());
        navigate(8);
    }

    QStackedWidget *m_stack   = nullptr;
    OsmKeyboard    *m_kb      = nullptr;
    Taskbar        *m_taskbar = nullptr;
    WelcomePage    *m_welcome = nullptr;
    HardwarePage   *m_hardware= nullptr;
    NetworkPage    *m_network = nullptr;
    UserPage       *m_user    = nullptr;
    DiskPage       *m_disk    = nullptr;
    DesktopPage    *m_desktop = nullptr;
    SummaryPage    *m_summary = nullptr;
    ProgressPage   *m_progress= nullptr;
    FinishedPage   *m_done    = nullptr;
    TerminalPage   *m_terminal= nullptr;
    QList<Page *>   m_pages;
    bool m_installing = false;
};

// ═══════════════════════════════════════════════════════════════
int main(int argc, char **argv) {
    QApplication app(argc, argv);

    // Application-wide font, not a palette change: setting a palette
    // from inside a page mutates state every other widget shares.
    app.setFont(QFont(QStringLiteral("DejaVu Sans"), 11));

    Installer w;

    // Start the network driver sweep now so it overlaps with the user
    // reading the welcome and hardware screens.
    NetworkPage::startDriverPreload(&w);

    // FULLSCREEN — showMaximized() IS NOT ENOUGH
    // The installer is launched by `startx osm-install` with no window
    // manager running. Maximise is a request to a WM; with none there
    // it is silently ignored and the window keeps its default size in
    // the top-left corner. Setting the geometry explicitly and going
    // fullscreen does not depend on a WM being present.
    if (QScreen *scr = QApplication::primaryScreen()) {
        w.setGeometry(scr->geometry());
    } else {
        w.resize(1024, 768);
    }
    w.showFullScreen();
    w.raise();
    w.activateWindow();
    return app.exec();
}
