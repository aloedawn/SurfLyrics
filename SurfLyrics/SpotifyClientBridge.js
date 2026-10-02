// Discover Spotify's private lyrics client by source signatures and exported capabilities.
// Inspect factories without executing unrelated modules; fail closed on ambiguous matches.
// Only the requested track's lyrics leave this context; authentication stays inside Spotify.
(async function surfLyricsClient(trackID) {
    if (location.hostname !== "xpui.app.spotify.com" || !/^[A-Za-z0-9]{22}$/.test(trackID)) {
        return { status: "unsupported" };
    }
    const lyricsHost = "https://spclient.wg.spotify.com/color-lyrics/v2";
    const apiMethods = ["getInstance", "createNew", "setAccessToken", "setGlobalRequestHeaders"];
    const apiSignatures = apiMethods.map(method => new RegExp(`\\b${method}\\s*\\(`));
    const builderMethods = ["withHost", "withPath", "withHeaders", "withQueryParameters", "withEndpointIdentifier", "send"];
    const exportValues = (module) => {
        if (!module || !["object", "function"].includes(typeof module)) return [];
        const keys = Object.getOwnPropertyNames(module);
        if (keys.length > 64) return [];
        return keys.flatMap(key => {
            try { return [module[key]]; } catch { return []; }
        });
    };
    let builder;
    const runtimeNames = Object.keys(globalThis).filter(name => /^(?:rspack|webpack)Chunk\w*$/.test(name));
    if (runtimeNames.length > 8) return { status: "unsupported" };
    for (const name of runtimeNames) {
        // Do not invoke global getters while discovering chunk arrays.
        const chunks = Object.getOwnPropertyDescriptor(globalThis, name)?.value;
        if (!Array.isArray(chunks) || typeof chunks.push !== "function") continue;
        let require;
        const chunk = [[`surflyrics-${Date.now()}-${Math.random()}`], {}, (runtime) => { require = runtime; }];
        try {
            chunks.push(chunk);
            if (typeof require !== "function" || !require.m) continue;
            const ids = Object.keys(require.m);
            if (ids.length > 5000) continue;
            const apiModules = [], hostModules = [];
            let sourceSize = 0;
            for (const id of ids) {
                const factory = require.m[id];
                if (typeof factory !== "function") continue;
                const source = Function.prototype.toString.call(factory);
                sourceSize += source.length;
                if (sourceSize > 24_000_000) throw new Error("Factory inspection limit");
                if (apiSignatures.every(signature => signature.test(source))) apiModules.push(id);
                if (source.includes("https://spclient.wg.spotify.com") && source.includes("/color-lyrics/v2")) hostModules.push(id);
            }
            // Do not execute candidate factories until their source matches are unique.
            if (apiModules.length !== 1 || hostModules.length !== 1) continue;
            if (!exportValues(require(hostModules[0])).includes(lyricsHost)) continue;
            const clients = [...new Set(exportValues(require(apiModules[0])).filter(value =>
                value && apiMethods.every(method => typeof value[method] === "function")
            ))];
            if (clients.length !== 1) continue;
            const candidate = clients[0].getInstance();
            if (typeof candidate?.build !== "function") continue;
            const candidateBuilder = candidate.build();
            if (!builderMethods.every(method => typeof candidateBuilder?.[method] === "function")) continue;
            builder = candidateBuilder;
            break;
        } catch {
            // A changed runtime or client interface falls through to the other lyrics providers.
        } finally {
            if (chunks.at(-1) === chunk) chunks.pop();
        }
    }
    if (!builder) return { status: "unsupported" };

    try {
        const response = await builder.withHost(lyricsHost)
            // The image suffix is optional, but an empty /image/ suffix returns 404.
            .withPath(`/track/${trackID}`)
            .withHeaders([{ key: "App-Platform", value: "WebPlayer" }])
            .withQueryParameters({ format: "json", vocalRemoval: false })
            .withEndpointIdentifier("/track/{trackId}")
            .send();
        const lyrics = response?.body?.lyrics;
        if (!lyrics || !Array.isArray(lyrics.lines)) return { status: "transientFailure" };
        if (lyrics.syncType === "UNSYNCED") return { status: "unsynced", trackID };
        if (lyrics.syncType !== "LINE_SYNCED" || lyrics.lines.length > 10000) {
            return { status: "unsupported" };
        }
        let previousTime = 0;
        const lines = [];
        for (const line of lyrics.lines) {
            if (!line || !["number", "string"].includes(typeof line.startTimeMs)
                || !/^\d+$/.test(String(line.startTimeMs)) || !Number.isSafeInteger(Number(line.startTimeMs))
                || Number(line.startTimeMs) < previousTime || Number(line.startTimeMs) > 86_400_000
                || typeof line.words !== "string" || line.words.length > 16_384) {
                return { status: "transientFailure", trackID };
            }
            previousTime = Number(line.startTimeMs);
            lines.push({ startTimeMs: String(line.startTimeMs), words: line.words });
        }
        return { status: "found", trackID, syncType: lyrics.syncType, lines };
    } catch (error) {
        return { status: error?.status === 404 ? "notFound" : "transientFailure", trackID };
    }
})
