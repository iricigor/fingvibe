const { test } = require("node:test");
const assert = require("node:assert/strict");
const { extractClients } = require("./ExtractClients.js");

function documentWithTables(definitions) {
    const tables = definitions.map(({ headings, rows, hidden = false, headerInBody = false }) => {
        const table = {
            hidden,
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
        Clients: [{ Name: "Desktop", Mac: "aa-bb-cc-dd-ee-ff", Ip: "192.168.0.2" }],
        InvalidRows: 0
    }]);
    assert.ok(!JSON.stringify(result).includes("secret"));
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
