const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readDecoClients, openDecoClients, clickDecoMap } = require("./ExtractDecoClients.js");
const { readFileSync } = require("node:fs");
const vm = require("node:vm");

const node = (innerText = "", hidden = false) => ({
    innerText, hidden, getClientRects: () => hidden ? [] : [{}],
    classList: { contains: () => false }
});

function fixture(definitions, options = {}) {
    const rows = definitions.map(client => {
        const fields = {
            ".name": [node(client.name ?? "Desktop")],
            ".mac": [node(client.mac ?? "00-28-F8-9E-88-51")],
            ".ip": [node(client.ip ?? "192.168.0.110")],
            td: [node("Information"), node("secret-rate-or-token"), node(client.connection ?? "Wireless(5G)")]
        };
        if (client.hiddenResponsive) {
            for (const key of [".name", ".mac", ".ip"]) fields[key].push(node("hidden", true));
        }
        return {
            ...node(), classList: { contains: name => client.empty && name === "empty" },
            querySelectorAll: selector => fields[selector] || []
        };
    });
    const panel = {
        querySelector: () => ({ value: options.selection ?? "All Deco's" }),
        querySelectorAll: () => [{ getAttribute: () => options.index ?? "0" }]
    };
    const grid = {
        ...node(), closest: () => panel,
        querySelectorAll: selector => selector.startsWith("tbody") ? rows :
            options.pagination ? [node()] : []
    };
    const count = node(String(options.count ?? definitions.length));
    let clicked = false;
    const control = { ...node(), scrollIntoView: () => { }, click: () => { clicked = true; } };
    const doc = {
        defaultView: {
            getComputedStyle: element => ({ display: element.hidden ? "none" : "block", visibility: "visible" })
        },
        getElementById: () => null,
        querySelector: selector => selector.endsWith(".map-clients-icon-num") ? count :
            selector === ".map-item.map-clients" ? control : null,
        querySelectorAll: selector => selector === ".connected-clients-grid" ? [grid] :
            selector === ".map-item.map-clients" ? [control] : []
    };
    return { doc, clicked: () => clicked };
}

test("reads screenshot-shaped rows including offscreen clients, ignoring hidden responsive fields and rates", () => {
    const { doc } = fixture([
        { name: "T470s", hiddenResponsive: true },
        { name: "WDMyCloud", mac: "00:90:A9:EE:92:65", ip: "192.168.0.123", connection: "Wired" },
        { name: "Cosori", mac: "5C:01:3B:F1:E9:28", ip: "192.168.0.112", connection: "Wireless (2.4G)" }
    ]);
    const result = readDecoClients(doc);
    assert.equal(result.State, "Ready");
    assert.equal(result.ClientCount, 3);
    assert.deepEqual(result.Clients[0], {
        Name: "T470s", Mac: "00:28:F8:9E:88:51", Ip: "192.168.0.110", Connection: "Wireless (5G)"
    });
    assert.equal(result.Clients[1].Connection, "Wired");
    assert.equal(result.Clients[2].Connection, "Wireless (2.4G)");
    assert.ok(!JSON.stringify(result).includes("secret"));
});

test("does not publish partial lists or unverified empty states", () => {
    assert.equal(readDecoClients(fixture([{}], { count: 2 }).doc).State, "Incomplete");
    assert.equal(readDecoClients(fixture([], { count: 0 }).doc).State, "Loading");
    assert.equal(readDecoClients(fixture([{ empty: true }], { count: 0 }).doc).State, "Ready");
});

test("accepts the actual parenthesized All Decos label with namescoped widget IDs", () => {
    const { doc } = fixture([{}], { selection: "(All Deco's)" });
    assert.equal(doc.getElementById("map-clients"), null);
    assert.equal(readDecoClients(doc).State, "Ready");
    assert.equal(openDecoClients(doc), true);
});

test("rejects duplicates, malformed identities, unsupported labels, per-Deco filtering and pagination", () => {
    for (const [definitions, options, message] of [
        [[{}, {}], {}, /duplicate MAC/],
        [[{ mac: "invalid" }], {}, /malformed MAC/],
        [[{ ip: "192.168.0.999" }], {}, /malformed IPv4/],
        [[{ connection: "Maybe wireless" }], {}, /Unsupported/],
        [[{}], { selection: "Living room", index: "1" }, /All Decos/],
        [[{}], { pagination: true }, /pagination/]
    ]) assert.throws(() => readDecoClients(fixture(definitions, options).doc), message);
});

test("opens only the known map-clients control", () => {
    const example = fixture([]);
    assert.equal(openDecoClients(example.doc), true);
    assert.equal(example.clicked(), true);
    example.doc.querySelectorAll = () => [node(), node()];
    assert.throws(() => openDecoClients(example.doc), /ambiguous/);
});

test("clicks Clients even if already active and permits only the Internet fallback", () => {
    const example = fixture([]);
    const control = example.doc.querySelectorAll(".map-item.map-clients")[0];
    control.classList.contains = () => true;
    assert.equal(openDecoClients(example.doc), true);
    assert.equal(example.clicked(), true);
    example.doc.querySelectorAll = selector => selector === ".map-item.map-internet" ? [control] : [];
    assert.equal(clickDecoMap(example.doc, "internet"), true);
    assert.throws(() => clickDecoMap(example.doc, "reboot"), /Only Clients and Internet/);
});

function loginFixture({ locked = false, error = false, incomplete = false, authenticated = false } = {}) {
    const events = [];
    const password = {
        ...node(), value: "", disabled: locked, dispatchEvent: event => events.push(event)
    };
    const button = node();
    const page = {
        ...node(),
        querySelectorAll: selector => selector === ".login-card .password-container input[type='password']" ?
            incomplete ? [] : [password] : selector === ".login-card .button-container.full-line" ?
                incomplete ? [] : [button] : selector.includes("error-tips") && error ? [node("Rejected")] : [],
        querySelector: () => null
    };
    const doc = {
        defaultView: {
            getComputedStyle: () => ({ display: "block", visibility: "visible" }),
            Event: class { constructor(type, options) { this.type = type; Object.assign(this, options); } },
            KeyboardEvent: class { constructor(type, options) { this.type = type; Object.assign(this, options); } }
        },
        querySelector: selector => selector === ".local-login-page" ? page :
            selector === ".map-item.map-clients" && authenticated ? node() : null,
        querySelectorAll: selector =>
            selector === ".local-login-page .login-card .password-container input[type='password']" ? [password] : [],
        getElementById: () => null
    };
    return { doc, password, events };
}

test("uses the verified Deco keyup Enter handler and stops on rejected or locked login", () => {
    const context = { module: { exports: {} } };
    vm.createContext(context);
    vm.runInContext(readFileSync(require.resolve("./ExtractDecoClients.js"), "utf8") +
        readFileSync(require.resolve("./RouterLogin.js"), "utf8"), context);
    const login = loginFixture();
    assert.equal(context.module.exports.submitDecoLogin(login.doc, "fixture-password"), true);
    assert.equal(login.password.value, "fixture-password");
    assert.equal(login.events.at(-1).type, "keyup");
    assert.equal(login.events.at(-1).keyCode, 13);
    for (const options of [{ locked: true }, { error: true }]) {
        const other = loginFixture(options);
        assert.equal(context.module.exports.submitDecoLogin(other.doc, "fixture-password"), false);
        assert.equal(other.events.length, 0);
    }
    assert.equal(context.module.exports.inspectDecoLogin(loginFixture({ incomplete: true }).doc).State, "Other");
    assert.equal(context.module.exports.inspectDecoLogin(
        loginFixture({ incomplete: true, authenticated: true }).doc).State, "Authenticated");
});
