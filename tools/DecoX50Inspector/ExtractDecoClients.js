function decoVisible(doc, element) {
    if (!element) return false;
    const style = doc.defaultView.getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" &&
        element.getClientRects().length > 0;
}

function decoText(element) {
    return (element?.innerText || "").replace(/\s+/g, " ").trim();
}

function normalizeDecoConnection(value) {
    const compact = value.replace(/\s+/g, "").toLowerCase();
    const known = {
        wired: "Wired",
        "wireless(2.4g)": "Wireless (2.4G)",
        "wireless(5g)": "Wireless (5G)",
        "wireless(6g)": "Wireless (6G)",
        "wireless(mlo)": "Wireless (MLO)",
        zigbee: "Zigbee",
        bluetooth: "Bluetooth",
        "-": "Unknown"
    };
    if (!Object.hasOwn(known, compact)) throw new Error("Unsupported Deco connection label.");
    return known[compact];
}

function readDecoClients(doc) {
    const result = (State, ClientCount = 0, Clients = [], Error = "") =>
        ({ State, Error, ClientCount, Clients });
    const visible = element => decoVisible(doc, element);
    const authenticated = visible(doc.querySelector(".map-item.map-clients"));
    if (!authenticated && (visible(doc.querySelector(".local-login-page")) ||
        visible(doc.querySelector(".login-view")))) return result("Login");
    const grids = Array.from(doc.querySelectorAll(".connected-clients-grid")).filter(visible);
    if (grids.length === 0) return result("Loading");
    if (grids.length !== 1) throw new Error("The Deco connected-client grid is ambiguous.");
    const grid = grids[0];
    const panel = grid.closest(".networkmap-client-panel");
    if (!panel) throw new Error("The Deco client panel is missing.");
    const choice = panel.querySelector("input.combobox-text");
    const selected = panel.querySelectorAll("input.combobox-checkbox:checked");
    const choiceText = choice?.value.trim().replace(/^\((.*)\)$/, "$1") || "";
    if (!/^all deco'?s?$/i.test(choiceText) || selected.length !== 1 ||
        selected[0].getAttribute("data-index") !== "0")
        throw new Error("Select All Decos before capturing; a per-Deco list is not a complete snapshot.");
    if (Array.from(doc.querySelectorAll(".loading,.grid-loading,.mask")).some(visible))
        return result("Loading");
    const countText = decoText(doc.querySelector(".map-item.map-clients .map-clients-icon-num"));
    if (!/^\d+$/.test(countText)) return result("Loading");
    const count = Number(countText);
    if (!Number.isSafeInteger(count) || count > 10000)
        throw new Error("The Deco client count is invalid or exceeds the 10,000-client safety limit.");
    if (Array.from(grid.querySelectorAll(".paging-container,.table-bottom-pages")).some(visible))
        throw new Error("This Deco firmware has unsupported pagination; no partial capture was saved.");
    const rows = Array.from(grid.querySelectorAll("tbody.grid-content-data > tr.grid-content-tr"))
        .filter(visible);
    const clients = [];
    const seen = new Set();
    for (const row of rows) {
        if (row.classList.contains("empty")) continue;
        const single = selector => {
            const elements = Array.from(row.querySelectorAll(selector)).filter(visible);
            if (elements.length !== 1) throw new Error(`A Deco client has missing or ambiguous ${selector} fields.`);
            return decoText(elements[0]);
        };
        const mac = single(".mac");
        if (!/^(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}$/i.test(mac))
            throw new Error("A Deco client has a malformed MAC.");
        const normalized = mac.replace(/-/g, ":").toUpperCase();
        if (seen.has(normalized)) throw new Error("The Deco list contains a duplicate MAC.");
        seen.add(normalized);
        let ip = single(".ip");
        if (ip === "-") ip = "";
        else if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip) ||
            ip.split(".").some(part => Number(part) > 255) || ip === "0.0.0.0")
            throw new Error("A Deco client has a malformed IPv4 address.");
        const cells = Array.from(row.querySelectorAll("td")).filter(visible);
        if (!cells.length) throw new Error("A Deco client has no connection cell.");
        clients.push({
            Name: single(".name"), Mac: normalized, Ip: ip,
            Connection: normalizeDecoConnection(decoText(cells[cells.length - 1]))
        });
    }
    if (clients.length !== count) return result("Incomplete", count);
    if (count === 0 && !rows.some(row => row.classList.contains("empty")))
        return result("Loading");
    return result("Ready", count, clients);
}

function openDecoClients(doc) {
    return clickDecoMap(doc, "clients");
}

function clickDecoMap(doc, target) {
    if (!["clients", "internet"].includes(target))
        throw new Error("Only Clients and Internet map navigation are allowed.");
    // Deco's widget framework prefixes element IDs with the view's namescope.
    const controls = Array.from(doc.querySelectorAll(`.map-item.map-${target}`))
        .filter(element => decoVisible(doc, element));
    if (controls.length === 0) return false;
    if (controls.length !== 1) throw new Error(`The Deco ${target} navigation control is ambiguous.`);
    const control = controls[0];
    control.scrollIntoView({ block: "nearest", inline: "nearest" });
    control.click();
    return true;
}

function decoClientPageVisible(doc) {
    const grids = Array.from(doc.querySelectorAll(".connected-clients-grid"))
        .filter(element => decoVisible(doc, element));
    if (grids.length > 1) throw new Error("The Deco connected-client grid is ambiguous.");
    return grids.length === 1;
}

if (typeof module !== "undefined") module.exports = {
    readDecoClients, normalizeDecoConnection, openDecoClients, clickDecoMap, decoClientPageVisible
};
