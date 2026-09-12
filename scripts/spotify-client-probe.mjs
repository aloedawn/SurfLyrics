import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, relative } from "node:path";

export const port = 43827;
export const bridgeURL = new URL("../SurfLyrics/SpotifyClientBridge.js", import.meta.url);

export function targetSocket(target) {
    try {
        const page = new URL(target.url);
        const socket = new URL(target.webSocketDebuggerUrl);
        return target.type === "page" && ["http:", "https:"].includes(page.protocol)
            && page.hostname === "xpui.app.spotify.com"
            && socket.protocol === "ws:" && socket.hostname === "127.0.0.1"
            && socket.port === String(port) && !socket.username && !socket.password
            && socket.pathname.startsWith("/devtools/page/") && !socket.search && !socket.hash
            ? socket.href : null;
    } catch { return null; }
}

export async function extract(trackID) {
    if (!/^[A-Za-z0-9]{22}$/.test(trackID)) throw new Error("Invalid Spotify track ID");
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, {
        signal: AbortSignal.timeout(2000), redirect: "error",
    });
    if (!response.ok) throw new Error("Spotify client connection unavailable");
    const target = (await response.json()).map(targetSocket).find(Boolean);
    if (!target) throw new Error("No eligible Spotify desktop target");
    const source = await readFile(bridgeURL, "utf8");

    return await new Promise((resolveResult, reject) => {
        const socket = new WebSocket(target);
        const timer = setTimeout(() => finish(new Error("Client extraction timed out")), 10000);
        let finished = false;
        function finish(error, value) {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            socket.close();
            error ? reject(error) : resolveResult(value);
        }
        socket.addEventListener("error", () => finish(new Error("Client connection failed")));
        socket.addEventListener("close", () => {
            if (!finished) finish(new Error("Client connection closed"));
        });
        socket.addEventListener("open", () => socket.send(JSON.stringify({
            id: 1, method: "Runtime.evaluate", params: {
                expression: `${source}(${JSON.stringify(trackID)})`,
                awaitPromise: true, returnByValue: true, timeout: 9000,
            },
        })));
        socket.addEventListener("message", (event) => {
            try {
                if (typeof event.data !== "string" || event.data.length > 1000000) {
                    return finish(new Error("Unexpected client response"));
                }
                const message = JSON.parse(event.data);
                if (message.id !== 1) return;
                if (message.error || message.result?.exceptionDetails || !message.result?.result?.value) {
                    return finish(new Error("Client adapter unavailable"));
                }
                finish(null, message.result.result.value);
            } catch { finish(new Error("Invalid client response")); }
        });
    });
}

async function main() {
    const [trackID, output] = process.argv.slice(2);
    if (!trackID) throw new Error("Usage: node scripts/spotify-client-probe.mjs TRACK_ID [OUTPUT_OUTSIDE_REPOSITORY]");
    const result = await extract(trackID);
    // Print only diagnostic metadata, never the lyric text or client authentication data.
    process.stdout.write(`${JSON.stringify({
        status: result.status, trackID: result.trackID, syncType: result.syncType,
        lineCount: result.lines?.length ?? 0,
        firstTimeMs: result.lines?.[0]?.startTimeMs,
        lastTimeMs: result.lines?.at(-1)?.startTimeMs,
    }, null, 2)}\n`);
    if (result.status !== "found" || result.trackID !== trackID) process.exitCode = 2;
    if (output && result.status === "found" && result.trackID === trackID) {
        const root = fileURLToPath(new URL("../", import.meta.url));
        const outputPath = resolve(output);
        const relativePath = relative(root, outputPath);
        if (!relativePath.startsWith("../")) throw new Error("Keep extracted lyrics outside the repository");
        await writeFile(outputPath, JSON.stringify(result), { mode: 0o600, flag: "wx" });
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    main().catch(() => {
        // Transport errors can contain URLs or response bodies. Keep the CLI output generic.
        process.stderr.write("Spotify client extraction unavailable. Check the local connection and supported client version.\n");
        process.exitCode = 1;
    });
}
