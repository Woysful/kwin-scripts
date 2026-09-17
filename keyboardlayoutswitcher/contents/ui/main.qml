import QtQuick
import org.kde.kwin

Item {
    id: root

    // Guides:
    // https://develop.kde.org/docs/plasma/kwin/
    // https://develop.kde.org/docs/plasma/kwin/api/

    property bool debugLogs: false
    property bool matchTitle: false
    property int fallbackLayout: -1
    property var rules: []           // [{ patterns: ["kitty","discord"], layout: 0 }, ...]
    property int lastKnownLayout: -1
    property int desiredLayout: -1
    property int layoutCount: 0
    property bool stepping: false

    function log(msg) {
        if (debugLogs) {
            console.log("KeyboardLayoutSwitcher: " + msg);
        }
    }

    function logE(msg) {
        console.error("KeyboardLayoutSwitcher: " + msg);
    }

    // Parses lines like:
    //   kitty,discord,zen:0
    //   telegram,steam:1
    //   # comment lines and blank lines are ignored
    //
    // The old "app1|app2 -> 0" / "app1|app2 = 0" syntax is still accepted
    // for backward compatibility with existing configs.
    function parseRules(text) {
        const parsed = [];
        if (!text) return parsed;

        const separators = ["->", "=>", ":", "="];

        const lines = text.split(/\r?\n/);
        for (let raw of lines) {
            const line = raw.trim();
            if (line.length === 0 || line.startsWith("#") || line.startsWith("//")) {
                continue;
            }

            let sepIndex = -1;
            let sepLen = 1;
            for (const sep of separators) {
                const idx = line.lastIndexOf(sep);
                if (idx !== -1) {
                    sepIndex = idx;
                    sepLen = sep.length;
                    break;
                }
            }
            if (sepIndex === -1) {
                logE("Skipping malformed rule (no ':' separator found): " + line);
                continue;
            }

            const patternsPart = line.substring(0, sepIndex).trim();
            const layoutPart = line.substring(sepIndex + sepLen).trim();

            const numberMatch = layoutPart.match(/-?\d+/);
            if (!numberMatch) {
                logE("Skipping malformed rule (no layout number found): " + line);
                continue;
            }
            const layoutIndex = parseInt(numberMatch[0], 10);

            const patterns = patternsPart
                .split(/[,|]/)
                .map(p => p.trim().toLowerCase())
                .filter(p => p.length > 0);

            if (patterns.length === 0) {
                logE("Skipping malformed rule (no app patterns found): " + line);
                continue;
            }

            parsed.push({ patterns: patterns, layout: layoutIndex });
        }
        return parsed;
    }

    function loadConfig() {
        debugLogs = KWin.readConfig("debugLogs", false);
        matchTitle = KWin.readConfig("matchTitle", false);
        fallbackLayout = KWin.readConfig("fallbackLayout", -1);
        rules = parseRules(KWin.readConfig("rules", ""));
        log("Configuration loaded, " + rules.length + " rule(s), fallbackLayout=" + fallbackLayout + ", matchTitle=" + matchTitle);
    }

    // Returns the layout index for a window, or null if no rule matches.
    function matchWindow(window) {
        if (!window) return null;

        const resourceClass = (window.resourceClass || "").toString().toLowerCase();
        const resourceName = (window.resourceName || "").toString().toLowerCase();
        const caption = matchTitle ? (window.caption || "").toString().toLowerCase() : "";

        for (const rule of rules) {
            for (const pattern of rule.patterns) {
                if ((resourceClass.length > 0 && resourceClass.indexOf(pattern) !== -1) ||
                    (resourceName.length > 0 && resourceName.indexOf(pattern) !== -1) ||
                    (caption.length > 0 && caption.indexOf(pattern) !== -1)) {
                    return rule.layout;
                }
            }
        }
        return null;
    }

    // org.kde.KeyboardLayouts' setLayout(uint) cannot be called reliably from
    // QML DBusCall: plain JS numbers marshal as D-Bus "i" (int32), but the
    // method's real signature requires "u" (uint32), so the call is rejected
    // before it ever runs. switchToNextLayout()/switchToPreviousLayout() take
    // no arguments at all, so we "walk" to the desired index using those
    // instead - slower, but immune to the type-signature problem.
    function applyLayout(index) {
        // NOTE: we deliberately do NOT short-circuit here based on
        // lastKnownLayout. lastKnownLayout only reflects what this script
        // itself last set - if the user changes the layout by any other
        // means (global shortcut, applet, etc.) while a window is focused,
        // our cached value goes stale and we'd wrongly think "nothing to
        // do" the next time that same target layout is requested. Instead
        // we always ask KWin for the real current layout (via
        // getLayoutCall/getLayoutsListCall below) and only skip once we've
        // confirmed - in reconcileLayout() - that it already matches.
        desiredLayout = index;
        if (!stepping) {
            stepping = true;
            if (layoutCount > 0) {
                getLayoutCall.call();
            } else {
                getLayoutsListCall.call();
            }
        } else {
            log("Already reconciling layout, updating target to " + index);
        }
    }

    // Called once we know the current layout index; decides whether we're
    // done, or which direction to step in next.
    function reconcileLayout(current) {
        lastKnownLayout = current;

        if (layoutCount <= 0 || current === desiredLayout) {
            stepping = false;
            log("Layout settled at index " + current);
            return;
        }

        const forwardSteps = ((desiredLayout - current) % layoutCount + layoutCount) % layoutCount;
        const backwardSteps = ((current - desiredLayout) % layoutCount + layoutCount) % layoutCount;

        if (forwardSteps <= backwardSteps) {
            log("Stepping forward from " + current + " toward " + desiredLayout);
            nextLayoutCall.call();
        } else {
            log("Stepping backward from " + current + " toward " + desiredLayout);
            previousLayoutCall.call();
        }
    }

    function handleWindowActivated(window) {
        if (!window) {
            return;
        }

        const layout = matchWindow(window);
        log("Window activated: class=" + window.resourceClass + " name=" + window.resourceName + " caption=" + window.caption + " -> " + (layout === null ? "no match" : ("layout " + layout)));

        if (layout !== null) {
            applyLayout(layout);
        } else if (fallbackLayout >= 0) {
            applyLayout(fallbackLayout);
        }
    }

    Connections {
        target: Workspace

        function onWindowActivated(window) {
            root.handleWindowActivated(window);
        }
    }

    // Note: KWin fully reloads a script (destroys and re-creates this Item,
    // re-running Component.onCompleted) whenever its settings are saved in
    // System Settings -> Window Management -> KWin Scripts, so no explicit
    // "config changed" handling is needed here.

    DBusCall {
        id: getLayoutsListCall
        service: "org.kde.keyboard"
        path: "/Layouts"
        dbusInterface: "org.kde.KeyboardLayouts"
        method: "getLayoutsList"

        onFinished: (returnValue) => {
            root.layoutCount = (returnValue && returnValue[0]) ? returnValue[0].length : 0;
            root.log("Detected " + root.layoutCount + " configured layout(s)");
            getLayoutCall.call();
        }

        onFailed: {
            root.logE("Failed to call getLayoutsList - is org.kde.keyboard running?");
            root.stepping = false;
        }
    }

    DBusCall {
        id: getLayoutCall
        service: "org.kde.keyboard"
        path: "/Layouts"
        dbusInterface: "org.kde.KeyboardLayouts"
        method: "getLayout"

        onFinished: (returnValue) => {
            root.reconcileLayout(returnValue ? returnValue[0] : -1);
        }

        onFailed: {
            root.logE("Failed to call getLayout.");
            root.stepping = false;
        }
    }

    DBusCall {
        id: nextLayoutCall
        service: "org.kde.keyboard"
        path: "/Layouts"
        dbusInterface: "org.kde.KeyboardLayouts"
        method: "switchToNextLayout"

        onFinished: getLayoutCall.call()

        onFailed: {
            root.logE("Failed to call switchToNextLayout.");
            root.stepping = false;
        }
    }

    DBusCall {
        id: previousLayoutCall
        service: "org.kde.keyboard"
        path: "/Layouts"
        dbusInterface: "org.kde.KeyboardLayouts"
        method: "switchToPreviousLayout"

        onFinished: getLayoutCall.call()

        onFailed: {
            root.logE("Failed to call switchToPreviousLayout.");
            root.stepping = false;
        }
    }

    Component.onCompleted: {
        log("Loading...");
        loadConfig();
        handleWindowActivated(Workspace.activeWindow);
        log("Loaded.");
    }
}
