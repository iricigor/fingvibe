const { test } = require("node:test");
const assert = require("node:assert/strict");
const { clickRouterMenu, clickClientPage } = require("./RouterNavigation.js");

function menuDocument(labels) {
    const elements = labels.map(label => ({
        innerText: label, children: [], disabled: false,
        getClientRects: () => [{}], getAttribute: () => null,
        closest: () => null, matches: () => true, clicks: 0,
        scrollIntoView() {},
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

test("Wired Clients paragraph targets and scrolls its tile icon, not just its label", () => {
    let scrolled = false;
    let clicks = 0;
    const icon = {
        getClientRects: () => [{}], getAttribute: () => null,
        matches: () => false, closest: () => null, contains: () => false,
        scrollIntoView(options) { assert.equal(options.block, "center"); scrolled = true; },
        click() { assert.equal(scrolled, true); clicks++; }
    };
    const tile = { querySelectorAll: () => [icon] };
    const label = {
        innerText: "Wired Clients", children: [], parentElement: tile,
        getClientRects: () => [{}], closest: () => null
    };
    const doc = {
        querySelectorAll: selector => selector.split(",").includes("p") ? [label] : [],
        defaultView: { getComputedStyle: () => ({ display: "block", visibility: "visible", cursor: "pointer" }) }
    };
    clickRouterMenu(doc, "Wired Clients", null);
    assert.equal(clicks, 1);
});

test("wired PC/count link is selected independently of the separate text link and changing count", () => {
    for (const count of [0, 12, 37]) {
        let scrolled = false;
        let clicks = 0;
        const pcLink = {
            innerText: String(count), disabled: false,
            getAttribute: () => null, closest: () => null, matches: () => true,
            scrollIntoView() { scrolled = true; },
            click() { assert.equal(scrolled, true); clicks++; }
        };
        const icon = {
            getClientRects: () => [{}], contains: () => false,
            closest: () => pcLink,
            click() { assert.fail("Click the PC link, not its decorative icon."); }
        };
        const tile = { querySelectorAll: () => [icon], parentElement: null };
        const textLink = {
            parentElement: tile, querySelectorAll: () => [],
            click() { assert.fail("The text-only Wired Clients link is not the PC link."); }
        };
        const label = {
            innerText: "Wired Clients", children: [], parentElement: textLink,
            getClientRects: () => [{}], closest: () => textLink
        };
        const doc = {
            querySelectorAll: () => [label],
            defaultView: { getComputedStyle: () => ({ display: "block", visibility: "visible", cursor: "pointer" }) }
        };
        clickRouterMenu(doc, "Wired Clients", null);
        assert.equal(clicks, 1);
    }
});

test("a wired text label without a resolvable PC icon is not clicked as a fallback", () => {
    const doc = menuDocument(["Wired Clients"]);
    assert.throws(() => clickRouterMenu(doc, "Wired Clients", null), /not visible/);
    assert.equal(doc.elements[0].clicks, 0);
});

test("wired count link works without relying on an icon CSS class", () => {
    for (const count of [0, 12, 37]) {
        const doc = menuDocument([String(count)]);
        const pcLink = doc.elements[0];
        pcLink.contains = () => false;
        const tile = {
            querySelectorAll: selector => selector === "[class*='icon']" ? [] : [pcLink]
        };
        const label = {
            innerText: "Wired Clients", children: [], parentElement: tile,
            getClientRects: () => [{}], closest: () => null
        };
        doc.querySelectorAll = () => [label];
        clickRouterMenu(doc, "Wired Clients", null);
        assert.equal(pcLink.clicks, 1);
    }
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
