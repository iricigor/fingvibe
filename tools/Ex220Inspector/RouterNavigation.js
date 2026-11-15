function normalizedRouterLabel(value) {
    return value.toLowerCase().replace(/&/g, "and").replace(/\s+/g, " ")
        .replace(/\s*\(\d+\)\s*$/, "").trim();
}

function routerLabelTargets(doc, label) {
    const expected = normalizedRouterLabel(label);
    const targets = new Map();
    const visible = element => {
        const style = doc.defaultView.getComputedStyle(element);
        return style.display !== "none" && style.visibility !== "hidden" &&
            element.getClientRects().length > 0;
    };
    for (const element of doc.querySelectorAll("a,button,[role='tab'],[role='button'],span,div")) {
        if (!visible(element) || normalizedRouterLabel(element.innerText || "") !== expected ||
            Array.from(element.children).some(child =>
                normalizedRouterLabel(child.innerText || "") === expected)) continue;
        const target = element.closest("a,button,[role='tab'],[role='button'],[onclick]") || element;
        if (target.disabled || target.getAttribute("aria-disabled") === "true") continue;
        const score = (target.matches("a,button") ? 100 : 0) +
            (target.closest("#menu,nav,[role='navigation'],.menu") ? 20 : 0) +
            (doc.defaultView.getComputedStyle(target).cursor === "pointer" ? 30 : 0);
        targets.set(target, score);
    }
    const best = Math.max(-1, ...targets.values());
    return Array.from(targets).filter(([, score]) => score === best).map(([element]) => element);
}

function clickRouterMenu(doc, label, nextLabel) {
    const permitted = ["basic", "advanced", "network", "lan settings", "network map",
        "wired clients", "security", "ip and mac binding"];
    if (!permitted.includes(normalizedRouterLabel(label)))
        throw new Error("This is not an approved inspector navigation control.");
    if (!["basic", "advanced"].includes(normalizedRouterLabel(label)) &&
        nextLabel && routerLabelTargets(doc, nextLabel).length === 1) return true;
    const targets = routerLabelTargets(doc, label);
    if (targets.length !== 1)
        throw new Error(`Router menu '${label}' is ${targets.length ? "ambiguous" : "not visible"}.`);
    targets[0].click();
    return true;
}

function routerCaptureState(doc, source, nextLabel) {
    const loading = doc.getElementById("g-loading-container");
    const busy = loading && loading.getClientRects().length > 0 &&
        doc.defaultView.getComputedStyle(loading).display !== "none" &&
        doc.defaultView.getComputedStyle(loading).visibility !== "hidden";
    const extraction = extractClients(doc, source);
    const table = extraction.Tables.length === 1 ? extraction.Tables[0] : null;
    return {
        Ready: !busy && table !== null && !!table.Title && table.InvalidRows === 0,
        Table: table,
        NextLabelVisible: !busy && !!nextLabel && routerLabelTargets(doc, nextLabel).length === 1
    };
}

function clickClientPage(doc, source, requestedPage) {
    const extraction = extractClients(doc, source);
    if (extraction.Tables.length !== 1 || !extraction.Tables[0].Title)
        throw new Error("A uniquely titled client table is required for automatic pagination.");
    const table = extraction.Tables[0];
    if (table.PageNumber === requestedPage) return true;
    const pager = clientPager(table.element);
    if (!pager) throw new Error("The client table has no pagination control.");
    const target = requestedPage === 1
        ? Array.from(pager.querySelectorAll("span")).find(element => (element.textContent || "").trim() === "1")
        : requestedPage === table.PageNumber + 1 ? pager.querySelector(".page.right") : null;
    if (!target || target.classList.contains("gray") || target.getClientRects().length === 0)
        throw new Error("The next required client page cannot be reached.");
    target.click();
    return true;
}

if (typeof module !== "undefined") module.exports = {
    normalizedRouterLabel, routerLabelTargets, clickRouterMenu, clickClientPage
};
