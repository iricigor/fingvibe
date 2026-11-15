const { test } = require("node:test");
const assert = require("node:assert/strict");
const { inspectRouterLogin, submitRouterLogin } = require("./RouterLogin.js");

function loginDocument(extra = {}) {
    let clicks = 0;
    const element = properties => ({
        getClientRects: () => [{}], dispatchEvent: () => {}, ...properties
    });
    const elements = {
        "pc-login": element({}),
        "pc-login-password": element({ type: "password", value: "", disabled: false }),
        "pc-login-btn": element({ disabled: false, click: () => clicks++ }),
        ...extra
    };
    return {
        elements,
        clicks: () => clicks,
        defaultView: {
            getComputedStyle: () => ({ display: "block", visibility: "visible" }),
            Event: class { constructor(type) { this.type = type; } }
        },
        getElementById: id => elements[id] || null
    };
}

test("local login detection returns no password and submits only the local login button", () => {
    const doc = loginDocument();
    assert.deepEqual(inspectRouterLogin(doc), { State: "Login", Error: false });
    assert.equal(submitRouterLogin(doc, "test-password"), true);
    assert.equal(doc.elements["pc-login-password"].value, "test-password");
    assert.equal(doc.clicks(), 1);
    assert.ok(!JSON.stringify(inspectRouterLogin(doc)).includes("test-password"));
});

test("cloud and password-setup fields are not login targets", () => {
    const doc = loginDocument({
        "pc-login": null, "pc-setPwd-new": { type: "password" },
        "cloud-bind-password": { type: "password" }
    });
    assert.equal(inspectRouterLogin(doc).State, "Other");
    assert.equal(submitRouterLogin(doc, "test-password"), false);
    assert.equal(doc.clicks(), 0);
});

test("hidden, locked and username-required login forms are not automatically submitted", () => {
    for (const extra of [
        { "pc-login": { getClientRects: () => [] } },
        { "pc-login-password": { type: "password", disabled: true } },
        { "pc-login-user-div": { getClientRects: () => [{}] } }
    ]) {
        const doc = loginDocument(extra);
        assert.equal(submitRouterLogin(doc, "test-password"), false);
        assert.equal(doc.clicks(), 0);
    }
});

test("authenticated content and router errors are identified without exporting messages", () => {
    const doc = loginDocument({ "pc-login": null, main: { getClientRects: () => [{}] } });
    assert.equal(inspectRouterLogin(doc).State, "Authenticated");
    const failed = loginDocument({
        errorContent: { innerText: "Router rejected login", getClientRects: () => [{}] }
    });
    assert.deepEqual(inspectRouterLogin(failed), { State: "Login", Error: true });
});
