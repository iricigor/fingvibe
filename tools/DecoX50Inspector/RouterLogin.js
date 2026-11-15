function inspectDecoLogin(doc) {
    const visible = element => decoVisible(doc, element);
    const page = doc.querySelector(".local-login-page");
    const authenticated = visible(doc.querySelector(".map-item.map-clients")) ||
        decoClientPageVisible(doc);
    if (!visible(page)) {
        return {
            State: authenticated ? "Authenticated" :
                visible(doc.querySelector(".login-view")) ? "Unsupported" : "Other",
            Error: false
        };
    }
    const inputs = Array.from(page.querySelectorAll(
        ".login-card .password-container input[type='password']"))
        .filter(visible);
    const buttons = Array.from(page.querySelectorAll(".login-card .button-container.full-line"))
        .filter(visible);
    if (inputs.length !== 1 || buttons.length !== 1)
        return { State: authenticated ? "Authenticated" : "Other", Error: false };
    const button = buttons[0];
    const rejected = Array.from(page.querySelectorAll(
        ".widget-error-tips,.password-error-tips,.msg-container"))
        .some(element => visible(element) && decoText(element).length > 0);
    return {
        State: inputs[0].disabled || button.classList.contains("disabled") ? "Locked" : "Login",
        Error: rejected
    };
}

function submitDecoLogin(doc, password) {
    const state = inspectDecoLogin(doc);
    if (state.State !== "Login" || state.Error) return false;
    const input = Array.from(doc.querySelectorAll(
        ".local-login-page .login-card .password-container input[type='password']"))
        .filter(element => decoVisible(doc, element))[0];
    input.value = password;
    const view = doc.defaultView;
    input.dispatchEvent(new view.Event("input", { bubbles: true }));
    input.dispatchEvent(new view.Event("change", { bubbles: true }));
    // This firmware's local-login controller listens for keyup, not keydown.
    input.dispatchEvent(new view.KeyboardEvent("keyup", {
        key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true
    }));
    return true;
}

if (typeof module !== "undefined") module.exports = { inspectDecoLogin, submitDecoLogin };
