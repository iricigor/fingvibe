const { test } = require("node:test");
const assert = require("node:assert/strict");
const { clickRouterMenu, clickClientPage } = require("./RouterNavigation.js");

function menuDocument(labels) {
    const elements = labels.map(label => ({
        innerText: label, children: [], disabled: false,
        getClientRects: () => [{}], getAttribute: () => null,
        closest: () => null, matches: () => true, clicks: 0,
        click() { this.clicks++; }
    }));
    return {
        elements,
        querySelectorAll: () => elements,
        defaultView: { getComputedStyle: () => ({ display: "block", visibility: "visible", cursor: "pointer" }) }
    };
}

test("known menu controls click once and already-expanded menus do not collapse", () => {
    const doc = menuDocument(["Network", "LAN Settings"]);
    assert.equal(clickRouterMenu(doc, "Network", "LAN Settings"), true);
    assert.equal(doc.elements[0].clicks, 0);
    assert.equal(clickRouterMenu(doc, "LAN Settings", null), true);
    assert.equal(doc.elements[1].clicks, 1);
});

test("binding label aliases work but unknown or ambiguous controls never click", () => {
    const doc = menuDocument(["IP & MAC Binding"]);
    clickRouterMenu(doc, "IP and MAC Binding", null);
    assert.equal(doc.elements[0].clicks, 1);
    assert.throws(() => clickRouterMenu(doc, "Save", null), /approved/);
    assert.throws(() => clickRouterMenu(menuDocument(["Network", "Network"]), "Network", null), /ambiguous/);
});

test("page 1 and sequential next controls are targeted, never arbitrary hidden pages", () => {
    let firstClicks = 0;
    let nextClicks = 0;
    const first = { textContent: "1", classList: { contains: () => false }, getClientRects: () => [{}], click: () => firstClicks++ };
    const next = { classList: { contains: () => false }, getClientRects: () => [{}], click: () => nextClicks++ };
    const pager = {
        matches: selector => selector === ".table-bottom-pages",
        querySelectorAll: () => [first], querySelector: () => next
    };
    global.clientPager = table => table.nextElementSibling;
    global.extractClients = () => ({ Tables: [{ Title: "Wired Clients", PageNumber: 3, element: { nextElementSibling: pager } }] });
    try {
        clickClientPage({}, "Wired", 1);
        clickClientPage({}, "Wired", 4);
        assert.equal(firstClicks, 1);
        assert.equal(nextClicks, 1);
        assert.throws(() => clickClientPage({}, "Wired", 6), /cannot be reached/);
        next.classList.contains = () => true;
        assert.throws(() => clickClientPage({}, "Wired", 4), /cannot be reached/);
    } finally {
        delete global.clientPager;
        delete global.extractClients;
    }
});
