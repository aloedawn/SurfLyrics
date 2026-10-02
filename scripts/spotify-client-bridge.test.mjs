import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const source = await readFile(new URL("../SurfLyrics/SpotifyClientBridge.js", import.meta.url), "utf8");
const trackID = "6vgarqZvEEzWUgCK45gCfz";
const lyricsHost = "https://spclient.wg.spotify.com/color-lyrics/v2";

function fixture({ hostname = "xpui.app.spotify.com", status, syncType = "LINE_SYNCED", supported = true,
    runtime = "rspackChunk", ids = [95096, 62037], exportNames = ["n", "Hj"],
    modulesAvailable = true, host = lyricsHost, missingBuilderMethod,
    lines = [{ startTimeMs: 1025, words: "Synthetic line", extra: "private" }] } = {}) {
    const calls = [], loaded = [];
    const builder = {};
    for (const name of ["withHost", "withPath", "withHeaders", "withQueryParameters", "withEndpointIdentifier"]) {
        builder[name] = value => { calls.push([name, value]); return builder; };
    }
    builder.send = async () => {
        calls.push(["send"]);
        if (status) throw { status, accessToken: "must-not-leave-client" };
        return { body: { accessToken: "must-not-leave-client", lyrics: { syncType, lines } } };
    };
    if (missingBuilderMethod) delete builder[missingBuilderMethod];
    // These factories have real source signatures, including when IDs and export names change.
    const apiFactory = function (exports) {
        class Client {
            static getInstance() { return { build: () => builder }; }
            static createNew() {}
            static setAccessToken() {}
            static setGlobalRequestHeaders() {}
        }
        exports[exportNames[0]] = Client;
    };
    const hostFactory = function (exports) {
        const base = "https://spclient.wg.spotify.com";
        const path = "/color-lyrics/v2";
        exports[exportNames[1]] = host ?? `${base}${path}`;
    };
    const modules = modulesAvailable ? { [ids[0]]: apiFactory, [ids[1]]: hostFactory } : {};
    modules.unrelated = () => { throw new Error("Unrelated module must never execute"); };
    const cache = {};
    const require = id => {
        loaded.push(String(id));
        if (!cache[id]) { cache[id] = {}; modules[id](cache[id]); }
        return cache[id];
    };
    require.m = modules;
    const chunks = [];
    chunks.push = chunk => {
        if (supported) chunk[2](require);
        Array.prototype.push.call(chunks, chunk);
    };
    const context = { location: { hostname }, [runtime]: chunks };
    const extract = vm.runInNewContext(source, context);
    return { calls, loaded, extract, chunks, context, modules, cache, apiFactory, hostFactory };
}

for (const [runtime, ids] of [
    ["rspackChunkclient_web", [22358, 52388]],
    ["rspackChunk", [48331, 62192]],
    ["rspackChunk", [95096, 62037]],
    ["webpackChunkfuture_client", ["renumbered-api", "renumbered-host"]],
]) test(`discovers ${runtime} modules ${ids.join("/")} and exports only timed lyric fields`, async () => {
    const { calls, loaded, extract, chunks } = fixture({ runtime, ids, exportNames: ["renamedClient", "renamedHost"] });
    const result = JSON.parse(JSON.stringify(await extract(trackID)));
    assert.deepEqual(result, { status: "found", trackID, syncType: "LINE_SYNCED", lines: [{ startTimeMs: "1025", words: "Synthetic line" }] });
    assert.deepEqual(calls.find(([key]) => key === "withHost"), ["withHost", lyricsHost]);
    assert.deepEqual(calls.find(([key]) => key === "withPath"), ["withPath", `/track/${trackID}`]);
    assert.equal(JSON.stringify(result).includes("must-not-leave-client"), false);
    assert.deepEqual(loaded, [String(ids[1]), String(ids[0])]);
    assert.equal(chunks.length, 0);
});

test("an uninitialized modern runtime does not hide a supported legacy runtime", async () => {
    const { extract, chunks, context } = fixture({ runtime: "rspackChunkclient_web" });
    context.rspackChunk = [];
    assert.equal((await extract(trackID)).status, "found");
    assert.equal(chunks.length, 0);
    assert.equal(context.rspackChunk.length, 0);
});

test("missing modules and changed lyrics hosts fail before making requests", async () => {
    for (const options of [{ modulesAvailable: false }, { host: "https://example.com/color-lyrics/v2" }]) {
        const { calls, loaded, extract, chunks } = fixture(options);
        assert.equal((await extract(trackID)).status, "unsupported");
        assert.equal(calls.length, 0);
        assert.equal(loaded.includes("95096"), false);
        assert.equal(chunks.length, 0);
    }
});

test("ambiguous source signatures reject candidates without executing them", async () => {
    for (const duplicate of ["apiFactory", "hostFactory"]) {
        const f = fixture();
        f.modules.duplicate = f[duplicate];
        assert.equal((await f.extract(trackID)).status, "unsupported");
        assert.deepEqual(f.loaded, []);
        assert.deepEqual(f.calls, []);
        assert.equal(f.chunks.length, 0);
    }
});

test("renumbering works without reinitializing unrelated modules on repeat requests", async () => {
    const f = fixture({ ids: [700001, 700002] });
    for (let i = 0; i < 2; i++) assert.equal((await f.extract(trackID)).status, "found");
    assert.equal(f.loaded.includes("unrelated"), false);
    assert.equal(f.calls.filter(([name]) => name === "send").length, 2);
    assert.equal(f.chunks.length, 0);
});

test("a source match must still export a compatible singleton and complete builder", async () => {
    for (const missingBuilderMethod of ["withHost", "withEndpointIdentifier", "send"]) {
        const f = fixture({ missingBuilderMethod });
        assert.equal((await f.extract(trackID)).status, "unsupported");
        assert.deepEqual(f.calls, []);
    }
    const f = fixture();
    f.cache[95096] = { n: { getInstance() { throw new Error("Must not invoke incomplete client"); } } };
    assert.equal((await f.extract(trackID)).status, "unsupported");
    assert.deepEqual(f.calls, []);
});

test("ambiguous exported clients are rejected before invoking either singleton", async () => {
    const f = fixture();
    const client = () => ({ getInstance() { throw new Error("Must not invoke ambiguous client"); },
        createNew() {}, setAccessToken() {}, setGlobalRequestHeaders() {} });
    f.cache[95096] = { first: client(), second: client() };
    assert.equal((await f.extract(trackID)).status, "unsupported");
    assert.deepEqual(f.calls, []);
});

test("throwing export getters are isolated and global runtime getters are not invoked", async () => {
    const f = fixture();
    Object.defineProperty(f.context, "rspackChunkdecoy", { enumerable: true, get() { throw new Error("Do not invoke global getter"); } });
    f.cache[62037] = { changedName: lyricsHost };
    Object.defineProperty(f.cache[62037], "private", { get() { throw new Error("Private export"); } });
    assert.equal((await f.extract(trackID)).status, "found");
    assert.equal(f.chunks.length, 0);
});

test("oversized module registries, exports and runtime inventories fail closed", async () => {
    const registry = fixture();
    for (let i = 0; i < 5000; i++) registry.modules[`extra-${i}`] = () => {};
    const exports = fixture();
    exports.cache[62037] = Object.fromEntries(Array.from({ length: 65 }, (_, i) => [i, lyricsHost]));
    const runtimes = fixture();
    for (let i = 0; i < 8; i++) runtimes.context[`rspackChunkextra${i}`] = [];
    for (const f of [registry, exports, runtimes]) {
        assert.equal((await f.extract(trackID)).status, "unsupported");
        assert.deepEqual(f.calls, []);
        assert.equal(f.chunks.length, 0);
    }
});

test("oversized source text stops inspection before loading any candidates", async () => {
    const f = fixture();
    f.modules.large = vm.runInNewContext(`(function(){ /*${"x".repeat(24_000_000)}*/ })`);
    assert.equal((await f.extract(trackID)).status, "unsupported");
    assert.deepEqual(f.loaded, []);
    assert.deepEqual(f.calls, []);
    assert.equal(f.chunks.length, 0);
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

test("malformed lines never export objects, invalid timestamps or unordered data", async () => {
    for (const lines of [
        [null], [{ startTimeMs: 1, words: { accessToken: "private" } }],
        [{ startTimeMs: "bad", words: "Synthetic line" }], [{ startTimeMs: -1, words: "Synthetic line" }],
        [{ startTimeMs: 86_400_001, words: "Synthetic line" }],
        [{ startTimeMs: 2, words: "Synthetic line" }, { startTimeMs: 1, words: "Synthetic line" }],
        [{ startTimeMs: 1, words: "x".repeat(16_385) }],
    ]) {
        const result = await fixture({ lines }).extract(trackID);
        assert.equal(result.status, "transientFailure");
        assert.equal(result.lines, undefined);
    }
});

test("unknown sync types and oversized lyrics fail closed", async () => {
    assert.equal((await fixture({ syncType: "FUTURE_SYNC" }).extract(trackID)).status, "unsupported");
    assert.equal((await fixture({ lines: Array(10001).fill({ startTimeMs: 1, words: "Synthetic" }) }).extract(trackID)).status, "unsupported");
});

test("wrong pages, invalid IDs and unsupported runtimes fail before requesting lyrics", async () => {
    for (const options of [{ hostname: "example.com" }, { supported: false }, { runtime: "unknownRuntime" }]) {
        const { calls, extract } = fixture(options);
        assert.equal((await extract(trackID)).status, "unsupported");
        assert.equal(calls.length, 0);
    }
    const { calls, extract } = fixture();
    assert.equal((await extract(`${trackID}\"`)).status, "unsupported");
    assert.equal(calls.length, 0);
});
