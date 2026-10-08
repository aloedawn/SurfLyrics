import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
const source = fs.readFileSync(new URL("../windows/SurfLyrics.Windows/SpotifyNowPlayingBridge.js",import.meta.url),"utf8");
const first = "0123456789abcdefghijkl", second = "abcdefghijkl0123456789";
const item = (id=first,name="Song",artist="Artist") => ({ type:"track",uri:"spotify:track:"+id,name,artists:[{name:artist}] });
function read({href="/album/0123456789abcdefghijkl",state=item(),alternate=null,host="xpui.app.spotify.com",artist="Artist",depth=0}={}) {
 const link={textContent:"Song",getAttribute:()=>href};
 const widget={querySelector:()=>link,querySelectorAll:()=>[{textContent:artist}]};
 let fiber={memoizedProps:{state:{item:state}},alternate:alternate?{memoizedProps:{state:{item:alternate}}}:null};
 for(let i=0;i<depth;i++)fiber={return:fiber};
 widget.__reactFiber$fixture=fiber;
 return JSON.parse(JSON.stringify(vm.runInNewContext(source,{location:{hostname:host},document:{querySelector:()=>widget}})));
}
test("album links resolve the validated now-playing track",()=>assert.deepEqual(read(),{id:first,title:"Song",artist:"Artist"}));
test("direct track links work without React state",()=>assert.equal(read({href:"/track/"+first,state:null}).id,first));
test("current React lane is checked when the other lane is stale",()=>assert.equal(read({state:item(second,"Old song"),alternate:item()}).id,first));
test("stale tracks cannot masquerade as current playback",()=>assert.deepEqual(read({state:item(first,"Old song")}),{}));
test("artist mismatch fails closed",()=>assert.deepEqual(read({state:item(first,"Song","Different artist")}),{}));
test("two IDs with identical display metadata fail closed",()=>assert.deepEqual(read({alternate:item(second)}),{}));
test("invalid IDs fail closed",()=>assert.deepEqual(read({state:item("bad")}),{}));
test("local tracks fail closed",()=>{const state=item();state.isLocal=true;assert.deepEqual(read({state}),{});});
test("episodes cannot be used as Spotify songs",()=>{const state=item();state.type="episode";assert.deepEqual(read({state}),{});});
test("inspection is bounded",()=>assert.deepEqual(read({depth:24}),{}));
test("other application origins are rejected",()=>assert.deepEqual(read({host:"example.com"}),{}));
