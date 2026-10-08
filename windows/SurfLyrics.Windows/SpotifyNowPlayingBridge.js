// Only a validated current track's ID and display metadata leave Spotify.
// The title link may point to an album in the Store client, so also inspect
// the now-playing component's bounded state, including React's current lane.
(function surfLyricsNowPlaying() {
    if (location.hostname !== "xpui.app.spotify.com") return {};
    const widget = document.querySelector('[data-testid="now-playing-widget"]');
    if (!widget) return {};
    const link = widget.querySelector('a[data-testid="context-item-link"]');
    const title = link?.textContent?.trim().slice(0,512);
    const artist = Array.from(widget.querySelectorAll('[data-testid="context-item-info-subtitles"] a[href*="/artist/"]'),
        a => a.textContent?.trim()).join(", ").slice(0,512);
    if (!title || !artist) return {};
    const trackID = uri => /^(?:spotify:track:|\/track\/)([A-Za-z0-9]{22})$/.exec(uri || "")?.[1];
    const direct = trackID(link?.getAttribute("href"));
    if (direct) return { id: direct, title, artist };
    const key = Object.getOwnPropertyNames(widget).find(k => k.startsWith("__reactFiber$"));
    let fiber = key ? Object.getOwnPropertyDescriptor(widget,key)?.value : null;
    const ids = new Set();
    for (let depth=0; fiber && depth<24; depth++,fiber=fiber.return) {
        for (const node of [fiber, fiber.alternate]) {
            const item = node?.memoizedProps?.state?.item;
            const id = trackID(item?.uri);
            if (!id || item?.type !== "track" || item.isLocal || item.name?.trim() !== title || !Array.isArray(item.artists)) continue;
            const artists = item.artists.slice(0,16).map(a => a.name?.trim()).join(", ").slice(0,512);
            if (artists === artist) ids.add(id);
        }
    }
    return ids.size === 1 ? { id: [...ids][0], title, artist } : {};
})()
