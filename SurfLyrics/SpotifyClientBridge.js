// Personal-use adapters for Spotify 1.2.99.317 and 1.3.0.277 desktop clients.
// Module IDs were read from xpui-routes-track-v2.js. Fail closed after incompatible updates.
// Only the requested track's lyrics leave this context; authentication stays inside Spotify.
(async function surfLyricsClient(trackID) {
    if (location.hostname !== "xpui.app.spotify.com" || !/^[A-Za-z0-9]{22}$/.test(trackID)) {
        return { status: "unsupported" };
    }
    let api, host;
    const adapters = [
        { chunks: globalThis.rspackChunk, apiModule: 48331, hostModule: 62192 },
        { chunks: globalThis.rspackChunkclient_web, apiModule: 22358, hostModule: 52388 },
    ];
    for (const { chunks, apiModule, hostModule } of adapters) {
        if (!chunks || typeof chunks.push !== "function") continue;
        let require;
        const chunk = [[`surflyrics-${Date.now()}-${Math.random()}`], {}, (runtime) => { require = runtime; }];
        try {
            chunks.push(chunk);
            if (typeof require !== "function") continue;
            const candidate = require(apiModule).n.getInstance();
            const candidateHost = require(hostModule).Hj;
            if (typeof candidate?.build !== "function"
                || candidateHost !== "https://spclient.wg.spotify.com/color-lyrics/v2") continue;
            api = candidate;
            host = candidateHost;
            break;
        } catch {
            // Try only known adapters; do not probe arbitrary modules after an update.
        } finally {
            if (chunks.at(-1) === chunk) chunks.pop();
        }
    }
    if (!api) return { status: "unsupported" };

    try {
        const response = await api.build()
            .withHost(host)
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
        const lines = lyrics.lines.map(({ startTimeMs, words }) => ({ startTimeMs: String(startTimeMs), words }));
        return { status: "found", trackID, syncType: lyrics.syncType, lines };
    } catch (error) {
        return { status: error?.status === 404 ? "notFound" : "transientFailure", trackID };
    }
})
