function routerLoginControls(doc) {
    const visible = element => {
        if (!element) return false;
        const style = doc.defaultView.getComputedStyle(element);
        return style.display !== "none" && style.visibility !== "hidden" &&
            element.getClientRects().length > 0;
    };
    for (const prefix of ["pc", "ph"]) {
        const password = doc.getElementById(`${prefix}-login-password`);
        const button = doc.getElementById(`${prefix}-login-btn`);
        const container = doc.getElementById(`${prefix}-login`);
        if (!visible(container) || !visible(button) || !password ||
            password.type !== "password") continue;
        const user = doc.getElementById(`${prefix}-login-user-div`);
        const error = doc.getElementById("errorContent");
        const buttonError = button.parentElement?.querySelector(".button-error-tips,.widget-error-tips");
        return {
            State: visible(user) ? "UsernameRequired" : password.disabled || button.disabled ? "Locked" : "Login",
            Error: visible(error) && (error.innerText || "").trim().length > 0 ||
                visible(buttonError) && (buttonError.innerText || "").trim().length > 0 ||
                password.parentElement?.classList.contains("err") === true,
            password, button
        };
    }
    return {
        State: visible(doc.getElementById("main")) ? "Authenticated" : "Other",
        Error: false
    };
}

function inspectRouterLogin(doc) {
    const { State, Error } = routerLoginControls(doc);
    return { State, Error };
}

function submitRouterLogin(doc, password) {
    const controls = routerLoginControls(doc);
    if (controls.State !== "Login") return false;
    controls.password.value = password;
    const view = doc.defaultView;
    controls.password.dispatchEvent(new view.Event("input", { bubbles: true }));
    controls.password.dispatchEvent(new view.Event("change", { bubbles: true }));
    controls.password.dispatchEvent(new view.Event("focus", { bubbles: false }));
    controls.password.dispatchEvent(new view.KeyboardEvent("keydown", {
        key: "Enter", code: "Enter", keyCode: 13, which: 13,
        bubbles: true, cancelable: true
    }));
    return true;
}

if (typeof module !== "undefined") module.exports = { inspectRouterLogin, submitRouterLogin };
