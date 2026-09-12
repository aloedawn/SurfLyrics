import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../SurfLyrics/SpotifyClientBridge.js", import.meta.url), "utf8");
const trackID = "6vgarqZvEEzWUgCK45gCfz";

function fixture({ hostname = "xpui.app.spotify.com", status, syncType = "LINE_SYNCED", supported = true } = {}) {
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
    chunks.push = (chunk) => {
        if (supported) chunk[2]((id) => {
            if (id === 22358) return { n: { getInstance: () => ({ build: () => builder }) } };
            if (id === 52388) return { Hj: "client-lyrics-host" };
            throw new Error("Unexpected module");
        });
        Array.prototype.push.call(chunks, chunk);
    };
    const extract = vm.runInNewContext(source, { location: { hostname }, rspackChunkclient_web: chunks });
    return { calls, extract };
}

test("uses the client request builder and exports only timed lyric fields", async () => {
    const { calls, extract } = fixture();
    const result = JSON.parse(JSON.stringify(await extract(trackID)));
    assert.deepEqual(result, { status: "found", trackID, syncType: "LINE_SYNCED", lines: [{ startTimeMs: "1025", words: "Synthetic line" }] });
    assert.equal(calls.find(([key]) => key === "withPath")[1], `/track/${trackID}`);
    assert.equal(JSON.stringify(result).includes("must-not-leave-client"), false);
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
