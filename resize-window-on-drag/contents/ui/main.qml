import QtQuick
import org.kde.kwin

Item {
    id: root

    // Guides:
    // https://develop.kde.org/docs/plasma/kwin/
    // https://develop.kde.org/docs/plasma/kwin/api/

    property bool debugLogs: false
    property bool onlyOnce: true
    property var defaultSize: null   // { width, height } or null
    property var defaultExceptions: [] // app patterns that Default must NOT apply to
    property var rules: []           // [{ patterns: ["firefox","discord"], width, height }, ...]
    property var allConnections: []  // cleanup callbacks, one per tracked window

    function log(msg) {
        if (debugLogs) {
            console.log("Resize window on drag: " + msg);
        }
    }

    function logE(msg) {
        console.error("Resize window on drag: " + msg);
    }

    // Parses lines like:
    //   Default:800x600
    //   Default-Exception:vlc,mpv      (apps that Default does not apply to)
    //   firefox,discord,telegram:1200x960
    //   # comment lines and blank lines are ignored
    function parseRules(text) {
        const parsedRules = [];
        const parsedExceptions = [];
        let parsedDefault = null;

        if (!text) {
            return { defaultSize: parsedDefault, rules: parsedRules, exceptions: parsedExceptions };
        }

        const lines = text.split(/\r?\n/);
        for (const raw of lines) {
            const line = raw.trim();
            if (line.length === 0 || line.startsWith("#") || line.startsWith("//")) {
                continue;
            }

            const sepIndex = line.indexOf(":");
            if (sepIndex === -1) {
                logE("Skipping malformed rule (no ':' found): " + line);
                continue;
            }

            const namesPart = line.substring(0, sepIndex).trim();
            const sizePart = line.substring(sepIndex + 1).trim();

            // "Default-Exception:app1,app2" (also accepts "Default-Exceptions",
            // "Default Exception", "Default_Exception"). No size here.
            if (/^default[\s_-]*exceptions?$/i.test(namesPart)) {
                const exc = sizePart
                    .split(",")
                    .map(p => p.trim().toLowerCase())
                    .filter(p => p.length > 0);
                if (exc.length === 0) {
                    logE("Skipping malformed exception rule (no app names found): " + line);
                } else {
                    for (const e of exc) parsedExceptions.push(e);
                }
                continue;
            }

            const sizeMatch = sizePart.match(/^(\d+)\s*[xX×]\s*(\d+)$/);
            if (!sizeMatch) {
                logE("Skipping malformed rule (expected WIDTHxHEIGHT): " + line);
                continue;
            }

            const width = parseInt(sizeMatch[1], 10);
            const height = parseInt(sizeMatch[2], 10);
            if (width <= 0 || height <= 0) {
                logE("Skipping malformed rule (non-positive size): " + line);
                continue;
            }

            if (namesPart.toLowerCase() === "default") {
                parsedDefault = { width: width, height: height };
                continue;
            }

            const patterns = namesPart
                .split(",")
                .map(p => p.trim().toLowerCase())
                .filter(p => p.length > 0);

            if (patterns.length === 0) {
                logE("Skipping malformed rule (no app names found): " + line);
                continue;
            }

            parsedRules.push({ patterns: patterns, width: width, height: height });
        }

        return { defaultSize: parsedDefault, rules: parsedRules, exceptions: parsedExceptions };
    }

    function loadConfig() {
        debugLogs = KWin.readConfig("debugLogs", false);
        onlyOnce = KWin.readConfig("onlyOnce", true);

        const parsed = parseRules(KWin.readConfig("rules", ""));
        defaultSize = parsed.defaultSize;
        rules = parsed.rules;
        defaultExceptions = parsed.exceptions;

        log("Configuration loaded: " + rules.length + " rule(s), default=" +
            (defaultSize ? (defaultSize.width + "x" + defaultSize.height) : "none") +
            ", default exceptions=[" + defaultExceptions.join(", ") + "]" +
            ", onlyOnce=" + onlyOnce);
    }

    // Returns { width, height } for a window, or null if nothing applies to it.
    function matchWindow(client) {
        if (!client) return null;

        const resourceClass = (client.resourceClass || "").toString().toLowerCase();
        const resourceName = (client.resourceName || "").toString().toLowerCase();

        for (const rule of rules) {
            for (const pattern of rule.patterns) {
                if ((resourceClass.length > 0 && resourceClass.indexOf(pattern) !== -1) ||
                    (resourceName.length > 0 && resourceName.indexOf(pattern) !== -1)) {
                    return { width: rule.width, height: rule.height };
                }
            }
        }

        // Nothing matched explicitly: fall back to Default, unless excluded.
        if (defaultSize) {
            for (const pattern of defaultExceptions) {
                if ((resourceClass.length > 0 && resourceClass.indexOf(pattern) !== -1) ||
                    (resourceName.length > 0 && resourceName.indexOf(pattern) !== -1)) {
                    log("Default skipped for " + client.resourceClass + " (exception: " + pattern + ")");
                    return null;
                }
            }
        }

        return defaultSize;
    }

    function isValidWindow(client) {
        if (!client) return false;
        if (!client.normalWindow) return false;
        if (client.skipTaskbar) return false;
        if (client.popupWindow) return false;
        if (client.deleted) return false;
        if (!client.resourceClass) return false;
        if (client.resourceClass.trim().length === 0) return false;
        return true;
    }

    // Dialogs, message boxes, "are you sure?" windows etc. must keep their own size.
    // Checked at move time (not only when the window appears), because the
    // transient-for relation may be set after the window is added.
    function isDialogLike(client) {
        if (client.dialog) return true;
        if (client.transient) return true;
        if (client.modal) return true;
        if (client.utility) return true;
        if (client.transientFor) return true;
        return false;
    }

    // Clamps a requested size to the window's own min/max size constraints, if any.
    function clampSize(client, width, height) {
        let w = width;
        let h = height;

        if (client.minSize) {
            w = Math.max(w, client.minSize.width);
            h = Math.max(h, client.minSize.height);
        }
        if (client.maxSize) {
            if (client.maxSize.width > 0) w = Math.min(w, client.maxSize.width);
            if (client.maxSize.height > 0) h = Math.min(h, client.maxSize.height);
        }

        return { width: w, height: h };
    }

    function applySize(client) {
        if (isDialogLike(client)) {
            log("Skipping dialog-like window: " + client.resourceClass + " (" + client.caption + ")");
            return;
        }

        const size = matchWindow(client);
        if (!size) {
            log("No matching rule and no Default set for " + client.resourceClass + ", leaving as is");
            return;
        }

        const current = client.frameGeometry;
        const target = clampSize(client, size.width, size.height);

        if (onlyOnce && current.width === target.width && current.height === target.height) {
            log("Window " + client.resourceClass + " is already " + target.width + "x" + target.height + ", skipping");
            return;
        }

        log("Resizing " + client.resourceClass + " to " + target.width + "x" + target.height);
        client.frameGeometry = Qt.rect(current.x, current.y, target.width, target.height);
    }

    function addWindow(client) {
        if (!isValidWindow(client)) return;

        function onInteractiveMoveResizeStarted() {
            // Only react to plain moves, not interactive resizes done by the user.
            if (client.move) {
                applySize(client);
            }
        }

        function onClosed() {
            disconnectAll();
        }

        function disconnectAll() {
            client.interactiveMoveResizeStarted.disconnect(onInteractiveMoveResizeStarted);
            client.closed.disconnect(onClosed);
            const idx = allConnections.indexOf(disconnectAll);
            if (idx !== -1) {
                allConnections.splice(idx, 1);
            }
        }

        client.interactiveMoveResizeStarted.connect(onInteractiveMoveResizeStarted);
        client.closed.connect(onClosed);
        allConnections.push(disconnectAll);

        log("Tracking window: " + client.resourceClass);
    }

    Connections {
        target: Workspace

        function onWindowAdded(client) {
            root.addWindow(client);
        }
    }

    // Note: KWin fully reloads a script (destroys and re-creates this Item,
    // re-running Component.onCompleted) whenever its settings are saved in
    // System Settings -> Window Management -> KWin Scripts, so no explicit
    // "config changed" handling is needed here.

    Component.onCompleted: {
        log("Loading...");
        loadConfig();

        const clients = Workspace.stackingOrder;
        for (let i = 0; i < clients.length; i++) {
            addWindow(clients[i]);
        }

        log("Loaded.");
    }

    Component.onDestruction: {
        for (let i = allConnections.length - 1; i >= 0; i--) {
            allConnections[i]();
        }
    }
}
