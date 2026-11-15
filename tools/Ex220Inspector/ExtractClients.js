function extractClients(doc) {
    const visible = element => {
        const style = doc.defaultView.getComputedStyle(element);
        return style.display !== "none" && style.visibility !== "hidden" &&
            element.getClientRects().length > 0;
    };
    const text = element => (element.innerText || "").replace(/\s+/g, " ").trim();
    const macPattern = /\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/i;
    const ipPattern = /\b(?:\d{1,3}\.){3}\d{1,3}\b/;
    const tables = [];
    for (const table of doc.querySelectorAll("table")) {
        if (!visible(table)) continue;
        const header = Array.from(table.querySelectorAll("thead th, thead td"));
        const fallback = table.querySelector("tr");
        const headings = (header.length ? header : fallback ? Array.from(fallback.cells) : [])
            .map(text);
        if (!headings.some(value => /\bmac\b/i.test(value)) ||
            !headings.some(value => /\bip\b/i.test(value))) continue;
        const nameIndex = headings.findIndex(value => /(?:name|hostname)/i.test(value));
        const macIndex = headings.findIndex(value => /\bmac\b/i.test(value));
        const ipIndex = headings.findIndex(value => /\bip\b/i.test(value));
        const clients = [];
        let invalidRows = 0;
        for (const row of table.querySelectorAll("tr")) {
            if (!visible(row) || row.closest("table") !== table || row.querySelector("th") ||
                row.closest("thead") || (!header.length && row === fallback)) continue;
            const cells = Array.from(row.cells).map(text);
            if (cells.length <= Math.max(macIndex, ipIndex) ||
                cells.every(value => !value) || cells.some(value => /^(?:no (?:entries|clients|data)|empty)/i.test(value)))
                continue;
            const mac = cells[macIndex].match(macPattern)?.[0];
            const ipCell = cells[ipIndex];
            const ip = ipCell.match(ipPattern)?.[0] || "";
            if (!mac || (ipCell && !ip && !/^(?:-|--|n\/a|unknown)$/i.test(ipCell))) {
                invalidRows++;
                continue;
            }
            clients.push({ Name: nameIndex >= 0 ? cells[nameIndex] || "" : "", Mac: mac, Ip: ip });
        }
        tables.push({ Clients: clients, InvalidRows: invalidRows });
    }
    return { Tables: tables };
}

if (typeof module !== "undefined") module.exports = { extractClients };
