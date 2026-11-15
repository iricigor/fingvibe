function extractClients(doc, source) {
    const visible = element => {
        const style = doc.defaultView.getComputedStyle(element);
        return style.display !== "none" && style.visibility !== "hidden" &&
            element.getClientRects().length > 0;
    };
    const text = element => (element.innerText || "").replace(/\s+/g, " ").trim();
    const macPattern = /\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b/i;
    const ipPattern = /\b(?:\d{1,3}\.){3}\d{1,3}\b/;
    const titleSelector = "h1,h2,h3,h4,h5,h6,legend,[role='heading'],.table-title,.section-title,.title";
    function tableTitle(table) {
        if (table.caption && visible(table.caption)) return text(table.caption);
        for (let node = table; node && node !== doc.body; node = node.parentElement) {
            for (let sibling = node.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
                if (sibling.matches("table") || sibling.querySelector("table")) break;
                const headings = [
                    ...(sibling.matches(titleSelector) ? [sibling] : []),
                    ...sibling.querySelectorAll(titleSelector)
                ].filter(visible);
                if (headings.length) return text(headings[headings.length - 1]);
            }
        }
        return "";
    }
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
        tables.push({ Title: tableTitle(table), Clients: clients, InvalidRows: invalidRows });
    }
    return {
        Tables: source ? selectClientTables(tables, source) : tables,
        AvailableTitles: tables.map(table => table.Title).filter(Boolean)
    };
}

function selectClientTables(tables, source) {
    const aliases = {
        Clients: ["client list", "clients", "dhcp client list"],
        Wired: ["wired clients", "wired client list", "wired devices", "wired client"],
        Arp: ["arp list", "arp client list", "arp table", "arp client table"]
    };
    const normalize = value => value.toLowerCase().replace(/\s+/g, " ")
        .replace(/\s*(?:\(\d+\)|:\s*\d*)\s*$/, "").trim();
    const names = aliases[source];
    if (!names) throw new Error("Unknown client source.");
    const matched = tables.filter(table => names.includes(normalize(table.Title)));
    if (matched.length) return matched;
    return tables.length === 1 && !tables[0].Title ? tables : [];
}

if (typeof module !== "undefined") module.exports = { extractClients, selectClientTables };
