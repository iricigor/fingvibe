function inspectDecoLogin(doc) {
    const visible = element => decoVisible(doc, element);
    const page = doc.querySelector(".local-login-page");
    if (!visible(page)) {
        return {
            State: visible(doc.getElementById("map-clients")) ? "Authenticated" :
                visible(doc.querySelector(".login-view")) ? "Unsupported" : "Other",
            Error: false
        };
    }
    const inputs = Array.from(page.querySelectorAll("#local-login-pwd input[type='password']"))
        .filter(visible);
    const button = page.querySelector("#local-login-button");
    const rejected = Array.from(page.querySelectorAll(
        ".widget-error-tips,.password-error-tips,#left-attempts-prompt,#max-attempts-prompt"))
        .some(element => visible(element) && decoText(element).length > 0);
    return {
        State: inputs.length !== 1 || !visible(button) ? "Unsupported" :
            inputs[0].disabled || button.classList.contains("disabled") ? "Locked" : "Login",
        Error: rejected
    };
}

function submitDecoLogin(doc, password) {
    const state = inspectDecoLogin(doc);
    if (state.State !== "Login" || state.Error) return false;
    const input = Array.from(doc.querySelectorAll("#local-login-pwd input[type='password']"))
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
