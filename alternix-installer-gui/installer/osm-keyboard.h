// ═══════════════════════════════════════════════════════════════
// osm-keyboard.h — Alternix on-screen touch keyboard
//
// Header-only. No Q_OBJECT / moc required.
//
//   #include "osm-keyboard.h"
//   OsmKeyboard *kb = new OsmKeyboard(parent);
//   layout->addWidget(kb);
//   kb->attachAutoShow();      // show only while a QLineEdit has focus
//
// Keys are delivered to QApplication::focusWidget() as real
// QKeyEvents, so any Qt input widget works without modification.
//
// Build: g++ -std=c++17 $(pkg-config --cflags --libs Qt5Widgets)
// ═══════════════════════════════════════════════════════════════
#ifndef OSM_KEYBOARD_H
#define OSM_KEYBOARD_H

#include <QApplication>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QHideEvent>
#include <QLineEdit>
#include <QShowEvent>
#include <QPushButton>
#include <QString>
#include <QStringList>
#include <QStyle>
#include <QVBoxLayout>
#include <QWidget>

#include <functional>
#include <vector>

// Sentinel for the Hide key. Deliberately outside the Qt::Key range
// so it can never collide with a real key code.
#define OSM_KEY_HIDE (-100)

// ── Key descriptor ────────────────────────────────────────────────
struct OsmKeyDef {
    QString lower;   // label + text in unshifted state
    QString upper;   // label + text when shift is active
    int     span;    // column span (1 = normal key)
    int     special; // 0 = character, otherwise Qt::Key_*
};

class OsmKeyboard : public QWidget {
public:
    explicit OsmKeyboard(QWidget *parent = nullptr) : QWidget(parent) {
        setObjectName("osmKeyboard");
        // NEVER take focus — the target QLineEdit must keep it, otherwise
        // focusWidget() returns a keyboard button and keys go nowhere.
        setFocusPolicy(Qt::NoFocus);
        setAttribute(Qt::WA_ShowWithoutActivating);

        m_grid = new QGridLayout(this);
        m_grid->setContentsMargins(6, 6, 6, 6);
        m_grid->setSpacing(4);

        setStyleSheet(
            "QWidget#osmKeyboard { background: #1e1e1e; border-top: 1px solid #3c3c3c; }"
            "QPushButton {"
            "  background: #383838; color: #e8e8e8; border: none;"
            "  border-radius: 4px; font-size: 17px; padding: 0px;"
            "}"
            "QPushButton:pressed { background: #4a90d9; color: #ffffff; }"
            "QPushButton#modKey { background: #2e2e2e; color: #b8b8b8; font-size: 14px; }"
            "QPushButton#modKeyOn { background: #4a90d9; color: #ffffff; font-size: 14px; }");

        buildLayout();
    }

    // Automatically show while a QLineEdit holds focus, hide otherwise.
    void attachAutoShow() {
        m_autoShow = true;
        hide();
        QObject::connect(qApp, &QApplication::focusChanged, this,
                         [this](QWidget *, QWidget *now) {
                             if (!m_autoShow) return;
                             // Ignore focus landing on our own buttons.
                             if (now && isAncestorOf(now)) return;
                             // A manual Hide must stick. Without this the
                             // next tap on a text field would immediately
                             // pop the keyboard back up, which makes the
                             // Hide key look broken.
                             if (m_userHidden) return;
                             setVisible(qobject_cast<QLineEdit *>(now) != nullptr);
                         });
    }

    void setAutoShow(bool on) { m_autoShow = on; }

    // Called by the taskbar keyboard button.
    void showFromTaskbar() {
        m_userHidden = false;
        show();
    }
    void hideByUser() {
        m_userHidden = true;
        hide();
        if (m_onVisibilityChanged) m_onVisibilityChanged(false);
    }
    bool userHidden() const { return m_userHidden; }

    // Lets the taskbar keep its button state in step.
    void setOnVisibilityChanged(std::function<void(bool)> fn) {
        m_onVisibilityChanged = std::move(fn);
    }

protected:
    void showEvent(QShowEvent *e) override {
        QWidget::showEvent(e);
        if (m_onVisibilityChanged) m_onVisibilityChanged(true);
    }
    void hideEvent(QHideEvent *e) override {
        QWidget::hideEvent(e);
        if (m_onVisibilityChanged) m_onVisibilityChanged(false);
    }

private:
    // ── Send a synthetic key event to whatever currently has focus ──
    void emitKey(int qtKey, const QString &text) {
        QWidget *target = QApplication::focusWidget();
        if (!target || isAncestorOf(target)) return;
        QKeyEvent press(QEvent::KeyPress, qtKey, Qt::NoModifier, text);
        QApplication::sendEvent(target, &press);
        QKeyEvent release(QEvent::KeyRelease, qtKey, Qt::NoModifier, text);
        QApplication::sendEvent(target, &release);
    }

    QPushButton *makeKey(const OsmKeyDef &def) {
        QPushButton *b = new QPushButton(this);
        b->setFocusPolicy(Qt::NoFocus);
        b->setMinimumHeight(46);
        b->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

        if (def.special != 0) {
            b->setObjectName("modKey");
            b->setText(def.lower);
            const int key = def.special;
            QObject::connect(b, &QPushButton::clicked, this, [this, key, b]() {
                handleSpecial(key, b);
            });
        } else {
            m_charKeys.push_back({b, def});
            b->setText(m_shift || m_caps ? def.upper : def.lower);
            QObject::connect(b, &QPushButton::clicked, this, [this, def]() {
                const QString t = (m_shift || m_caps) ? def.upper : def.lower;
                emitKey(Qt::Key_unknown, t);
                if (m_shift && !m_caps) { m_shift = false; refreshFaces(); }
            });
        }
        return b;
    }

    void handleSpecial(int key, QPushButton *b) {
        switch (key) {
        case Qt::Key_Shift:
            m_shift = !m_shift;
            b->setObjectName(m_shift ? "modKeyOn" : "modKey");
            restyle(b);
            refreshFaces();
            break;
        case Qt::Key_CapsLock:
            m_caps = !m_caps;
            b->setObjectName(m_caps ? "modKeyOn" : "modKey");
            restyle(b);
            refreshFaces();
            break;
        case Qt::Key_Mode_switch:
            m_symbols = !m_symbols;
            buildLayout();
            break;
        case Qt::Key_Backspace: emitKey(Qt::Key_Backspace, QString()); break;
        case Qt::Key_Return:    emitKey(Qt::Key_Return, QString());    break;
        case Qt::Key_Tab:       emitKey(Qt::Key_Tab, QString());       break;
        case Qt::Key_Space:     emitKey(Qt::Key_Space, QStringLiteral(" ")); break;
        case Qt::Key_Left:      emitKey(Qt::Key_Left, QString());      break;
        case Qt::Key_Right:     emitKey(Qt::Key_Right, QString());     break;
        case OSM_KEY_HIDE:      hideByUser();                          break;
        default: break;
        }
    }

    // Qt does not re-evaluate an objectName selector on its own.
    static void restyle(QWidget *w) {
        w->style()->unpolish(w);
        w->style()->polish(w);
    }

    void refreshFaces() {
        const bool up = m_shift || m_caps;
        for (const auto &pair : m_charKeys)
            pair.first->setText(up ? pair.second.upper : pair.second.lower);
    }

    void clearGrid() {
        m_charKeys.clear();
        QLayoutItem *item;
        while ((item = m_grid->takeAt(0)) != nullptr) {
            if (item->widget()) item->widget()->deleteLater();
            delete item;
        }
    }

    void buildLayout() {
        clearGrid();
        const std::vector<std::vector<OsmKeyDef>> rows =
            m_symbols ? symbolRows() : letterRows();

        for (int r = 0; r < static_cast<int>(rows.size()); ++r) {
            int col = 0;
            for (const OsmKeyDef &def : rows[r]) {
                QPushButton *b = makeKey(def);
                m_grid->addWidget(b, r, col, 1, def.span);
                col += def.span;
            }
        }
        for (int c = 0; c < 20; ++c) m_grid->setColumnStretch(c, 1);
        refreshFaces();
    }

    // Grid is 20 columns wide; normal keys span 2.
    static std::vector<std::vector<OsmKeyDef>> letterRows() {
        auto k = [](const char *lo, const char *up) {
            return OsmKeyDef{QString::fromUtf8(lo), QString::fromUtf8(up), 2, 0};
        };
        return {
            {k("1","!"), k("2","\""), k("3","#"), k("4","$"), k("5","%"),
             k("6","^"), k("7","&"),  k("8","*"), k("9","("), k("0",")")},
            {k("q","Q"), k("w","W"), k("e","E"), k("r","R"), k("t","T"),
             k("y","Y"), k("u","U"), k("i","I"), k("o","O"), k("p","P")},
            {k("a","A"), k("s","S"), k("d","D"), k("f","F"), k("g","G"),
             k("h","H"), k("j","J"), k("k","K"), k("l","L"),
             {QStringLiteral("\u232b"), QString(), 2, Qt::Key_Backspace}},
            {{QStringLiteral("\u21e7"), QString(), 3, Qt::Key_Shift},
             k("z","Z"), k("x","X"), k("c","C"), k("v","V"), k("b","B"),
             k("n","N"), k("m","M"),
             {QStringLiteral("\u21b5"), QString(), 3, Qt::Key_Return}},
            {{QStringLiteral("?123"), QString(), 3, Qt::Key_Mode_switch},
             k("-","_"), k("@","~"),
             {QStringLiteral("space"), QString(), 5, Qt::Key_Space},
             k(".",","),
             {QStringLiteral("\u2190"), QString(), 1, Qt::Key_Left},
             {QStringLiteral("\u2192"), QString(), 1, Qt::Key_Right},
             {QStringLiteral("\u2b07 Hide"), QString(), 4, OSM_KEY_HIDE}}};
    }

    static std::vector<std::vector<OsmKeyDef>> symbolRows() {
        auto k = [](const char *lo, const char *up) {
            return OsmKeyDef{QString::fromUtf8(lo), QString::fromUtf8(up), 2, 0};
        };
        return {
            {k("1","1"), k("2","2"), k("3","3"), k("4","4"), k("5","5"),
             k("6","6"), k("7","7"), k("8","8"), k("9","9"), k("0","0")},
            {k("!","!"), k("@","@"), k("#","#"), k("$","$"), k("%","%"),
             k("^","^"), k("&","&"), k("*","*"), k("(","("), k(")",")")},
            {k("-","-"), k("_","_"), k("=","="), k("+","+"), k("[","["),
             k("]","]"), k("{","{"), k("}","}"), k("\\","\\"),
             {QStringLiteral("\u232b"), QString(), 2, Qt::Key_Backspace}},
            {k(";",";"), k(":",":"), k("'","'"), k("\"","\""), k(",",","),
             k(".","."), k("/","/"), k("?","?"),
             {QStringLiteral("\u21b5"), QString(), 4, Qt::Key_Return}},
            {{QStringLiteral("abc"), QString(), 3, Qt::Key_Mode_switch},
             k("<","<"), k(">",">"),
             {QStringLiteral("space"), QString(), 5, Qt::Key_Space},
             k("|","|"), k("`","`"),
             {QStringLiteral("\u2b07 Hide"), QString(), 4, OSM_KEY_HIDE}}};
    }

    QGridLayout *m_grid = nullptr;
    std::vector<std::pair<QPushButton *, OsmKeyDef>> m_charKeys;
    bool m_shift   = false;
    bool m_caps    = false;
    bool m_symbols = false;
    bool m_autoShow = false;
    bool m_userHidden = false;
    std::function<void(bool)> m_onVisibilityChanged;
};

#endif // OSM_KEYBOARD_H
