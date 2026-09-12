// Personal-use adapter for the installed Spotify 1.2.99.317 desktop client.
// Module IDs were read from xpui-routes-track-v2.js. Fail closed after incompatible updates.
// Only the requested track's lyrics leave this context; authentication stays inside Spotify.
(async function surfLyricsClient(trackID) {
    if (location.hostname !== "xpui.app.spotify.com" || !/^[A-Za-z0-9]{22}$/.test(trackID)) {
        return { status: "unsupported" };
    }
    const chunks = globalThis.rspackChunkclient_web;
    if (!chunks || typeof chunks.push !== "function") return { status: "unsupported" };

    let require;
    const chunk = [[`surflyrics-${Date.now()}-${Math.random()}`], {}, (runtime) => { require = runtime; }];
    chunks.push(chunk);
    if (chunks.at(-1) === chunk) chunks.pop();
    if (typeof require !== "function") return { status: "unsupported" };

    let api, host;
    try {
        api = require(22358).n.getInstance();
        host = require(52388).Hj;
        if (!api || typeof api.build !== "function" || !host) return { status: "unsupported" };
    } catch {
        return { status: "unsupported" };
    }

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
