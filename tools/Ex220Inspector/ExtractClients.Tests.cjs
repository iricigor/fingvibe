const { test } = require("node:test");
const assert = require("node:assert/strict");
const { extractClients, selectClientTables } = require("./ExtractClients.js");

function documentWithTables(definitions) {
    const tables = definitions.map(({ headings, rows, hidden = false, headerInBody = false, title = "" }) => {
        const titleElement = title ? {
            innerText: title,
            matches: selector => selector !== "table",
            querySelector: () => null,
            querySelectorAll: () => [],
            getClientRects: () => [{}]
        } : null;
        const table = {
            hidden,
            previousElementSibling: titleElement,
            getClientRects: () => hidden ? [] : [{}],
            querySelector: () => table.rows[0],
            querySelectorAll: selector => selector === "tr" ? table.rows : headerInBody ? [] : table.header.cells
        };
        function row(values, isHeader, hiddenRow = false) {
            return {
                cells: values.map(innerText => ({ innerText })),
                getClientRects: () => hiddenRow ? [] : [{}],
                querySelector: () => isHeader && !headerInBody ? {} : null,
                closest: selector => selector === "table" ? table : isHeader && !headerInBody ? {} : null
            };
        }
        table.header = row(headings, true);
        table.rows = [table.header, ...rows.map(values => row(values.cells || values, false, values.hidden))];
        return table;
    });
    return {
        defaultView: { getComputedStyle: () => ({ display: "table", visibility: "visible" }) },
        querySelectorAll: () => tables
    };
}

test("extracts only client fields despite reordered columns and sensitive adjacent columns", () => {
    const result = extractClients(documentWithTables([{
        headings: ["IP Address", "Token", "MAC Address", "Name"],
        rows: [["192.168.0.2", "secret-do-not-return", "aa-bb-cc-dd-ee-ff", "Desktop"]]
    }]));
    assert.deepEqual(result.Tables, [{
        Title: "", Clients: [{ Name: "Desktop", Mac: "aa-bb-cc-dd-ee-ff", Ip: "192.168.0.2" }],
        InvalidRows: 0, PageNumber: 1, PageCount: 1
    }]);
    assert.ok(!JSON.stringify(result).includes("secret"));
});

test("TP-Link numeric markers include hidden pages and require a unique selected page", () => {
    const { readClientPagination } = require("./ExtractClients.js");
    const spans = Array.from({ length: 12 }, (_, index) => ({ textContent: String(index + 1) }));
    const pager = {
        matches: selector => selector === ".table-bottom-pages",
        querySelectorAll: selector => selector === ".click-page" ? [{ textContent: "3" }] : spans,
        querySelector: () => ({ textContent: "3" })
    };
    assert.deepEqual(readClientPagination({}, { nextElementSibling: pager }), { PageNumber: 3, PageCount: 12 });
    spans.push({ textContent: "3" });
    assert.throws(() => readClientPagination({}, { nextElementSibling: pager }), /ambiguous/);
    spans.pop();
    pager.querySelectorAll = selector => selector === ".click-page"
        ? [{ textContent: "2" }, { textContent: "3" }] : spans;
    assert.throws(() => readClientPagination({}, { nextElementSibling: pager }), /ambiguous/);
});

test("nearby titles select wired clients without mixing the co-visible wireless table", () => {
    const result = extractClients(documentWithTables([
        { title: "Wireless Clients", headings: ["Name", "MAC", "IP"],
            rows: [["Phone", "00:11:22:33:44:55", "192.168.0.3"]] },
        { title: "Wired Clients (1)", headings: ["Name", "MAC", "IP"],
            rows: [["Desktop", "aa:bb:cc:dd:ee:ff", "192.168.0.2"]] }
    ]), "Wired");
    assert.equal(result.Tables.length, 1);
    assert.equal(result.Tables[0].Clients[0].Name, "Desktop");
});

test("ARP section title selects ARP rather than the binding list", () => {
    const result = extractClients(documentWithTables([
        { title: "ARP List", headings: ["MAC", "IP"], rows: [["aa:bb:cc:dd:ee:ff", "192.168.0.2"]] },
        { title: "Binding List", headings: ["MAC", "IP"], rows: [["00:11:22:33:44:55", "192.168.0.3"]] }
    ]), "Arp");
    assert.equal(result.Tables.length, 1);
    assert.equal(result.Tables[0].Title, "ARP List");
});

test("wrong source is not silently accepted and duplicate matching titles stay ambiguous", () => {
    assert.deepEqual(selectClientTables([{ Title: "Wireless Clients" }], "Wired"), []);
    assert.equal(selectClientTables([{ Title: "" }], "Clients").length, 1);
    assert.equal(selectClientTables([{ Title: "" }, { Title: "" }], "Clients").length, 0);
    assert.equal(selectClientTables([{ Title: "ARP List" }, { Title: "ARP List" }], "Arp").length, 2);
});

test("ARP without names and headers in the table body are supported", () => {
    const result = extractClients(documentWithTables([{
        headings: ["MAC Address", "IP Address"], headerInBody: true,
        rows: [["AA:BB:CC:DD:EE:FF", "192.168.0.2"]]
    }]));
    assert.equal(result.Tables[0].Clients[0].Name, "");
    assert.equal(result.Tables[0].Clients.length, 1);
});

test("empty recognized tables differ from missing tables", () => {
    assert.equal(extractClients(documentWithTables([{
        headings: ["MAC Address", "IP Address"], rows: [["No entries"]]
    }])).Tables[0].Clients.length, 0);
    assert.equal(extractClients(documentWithTables([{
        headings: ["Username", "Password"], rows: [["admin", "secret"]]
    }])).Tables.length, 0);
});

test("hidden tables and rows are excluded and malformed rows are reported", () => {
    const result = extractClients(documentWithTables([
        { headings: ["MAC", "IP"], rows: [], hidden: true },
        { headings: ["MAC", "IP"], rows: [
            { cells: ["aa:bb:cc:dd:ee:ff", "192.168.0.2"], hidden: true },
            ["broken", "192.168.0.3"],
            ["aa:bb:cc:dd:ee:ff", "unrecognized"]
        ] }
    ]));
    assert.equal(result.Tables.length, 1);
    assert.equal(result.Tables[0].Clients.length, 0);
    assert.equal(result.Tables[0].InvalidRows, 2);
});
