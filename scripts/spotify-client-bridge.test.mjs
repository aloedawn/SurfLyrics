import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../SurfLyrics/SpotifyClientBridge.js", import.meta.url), "utf8");
const trackID = "6vgarqZvEEzWUgCK45gCfz";

function fixture({ hostname = "xpui.app.spotify.com", status, syncType = "LINE_SYNCED", supported = true,
    version = "1.3.3", modulesAvailable = true, host = "https://spclient.wg.spotify.com/color-lyrics/v2",
    brokenModernRuntime = false } = {}) {
    const calls = [];
    const builder = {};
    for (const name of ["withHost", "withPath", "withHeaders", "withQueryParameters", "withEndpointIdentifier"]) {
        builder[name] = (value) => { calls.push([name, value]); return builder; };
    }
    builder.send = async () => {
        if (status) throw { status, accessToken: "must-not-leave-client" };
        return { body: { accessToken: "must-not-leave-client", lyrics: {
            syncType, lines: [{ startTimeMs: 1025, words: "Synthetic line", extra: "private" }],
        } } };
    };
    const chunks = [];
    const [apiModule, hostModule] = {
        "1.2": [22358, 52388], "1.3": [48331, 62192], "1.3.3": [95096, 62037],
    }[version];
    chunks.push = (chunk) => {
        if (supported) chunk[2]((id) => {
            if (!modulesAvailable) throw new Error("Module changed");
            if (id === apiModule) return { n: { getInstance: () => ({ build: () => builder }) } };
            if (id === hostModule) return { Hj: host };
            throw new Error("Unexpected module");
        });
        Array.prototype.push.call(chunks, chunk);
    };
    const context = { location: { hostname }, [version === "1.2" ? "rspackChunkclient_web" : "rspackChunk"]: chunks };
    if (brokenModernRuntime) context.rspackChunk = [];
    const extract = vm.runInNewContext(source, context);
    return { calls, extract, chunks, context };
}

for (const version of ["1.2", "1.3", "1.3.3"]) test(`Spotify ${version} uses the client request builder and exports only timed lyric fields`, async () => {
    const { calls, extract, chunks } = fixture({ version });
    const result = JSON.parse(JSON.stringify(await extract(trackID)));
    assert.deepEqual(result, { status: "found", trackID, syncType: "LINE_SYNCED", lines: [{ startTimeMs: "1025", words: "Synthetic line" }] });
    assert.equal(calls.find(([key]) => key === "withPath")[1], `/track/${trackID}`);
    assert.equal(JSON.stringify(result).includes("must-not-leave-client"), false);
    assert.equal(chunks.length, 0);
});

test("an uninitialized modern runtime does not hide a supported legacy runtime", async () => {
    const { extract, chunks, context } = fixture({ version: "1.2", brokenModernRuntime: true });
    assert.equal((await extract(trackID)).status, "found");
    assert.equal(chunks.length, 0);
    assert.equal(context.rspackChunk.length, 0);
});

test("changed modules or lyrics hosts fail closed without making requests", async () => {
    for (const version of ["1.2", "1.3", "1.3.3"]) {
        for (const options of [{ modulesAvailable: false }, { host: "https://example.com" }]) {
            const { calls, extract, chunks } = fixture({ version, ...options });
            assert.equal((await extract(trackID)).status, "unsupported");
            assert.equal(calls.length, 0);
            assert.equal(chunks.length, 0);
        }
    }
});

test("plain lyrics are not assigned invented timestamps", async () => {
    const { extract } = fixture({ syncType: "UNSYNCED" });
    const result = await extract(trackID);
    assert.equal(result.status, "unsynced");
    assert.equal(result.lines, undefined);
});

test("API failure distinguishes a missing track from temporary failure", async () => {
    assert.equal((await fixture({ status: 404 }).extract(trackID)).status, "notFound");
    assert.equal((await fixture({ status: 401 }).extract(trackID)).status, "transientFailure");
});

test("wrong pages, invalid IDs and unsupported runtimes fail before requesting lyrics", async () => {
    for (const options of [{ hostname: "example.com" }, { supported: false }]) {
        const { calls, extract } = fixture(options);
        assert.equal((await extract(trackID)).status, "unsupported");
        assert.equal(calls.length, 0);
    }
    const { calls, extract } = fixture();
    assert.equal((await extract(`${trackID}\"`)).status, "unsupported");
    assert.equal(calls.length, 0);
});
