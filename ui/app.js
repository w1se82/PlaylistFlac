"use strict";
const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const fmt = (sec) => sec ? `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}` : "?";
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;
const EQ = '<span class="eq live" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></span>';
const PORTS = Array.from({ length: 10 }, (_, i) => 47821 + i);
// Mac of Windows: alleen voor de teksten (mappen, starten, Python)
const MAC = /Mac/i.test(navigator.platform || navigator.userAgent);
const LINUX = !MAC && /Linux/i.test(navigator.platform || navigator.userAgent) && !/Android/i.test(navigator.userAgent);
const SEP = MAC || LINUX ? "/" : "\\";

/* =====================================================================
   Los geopend (file://): de tool zoeken of starten, dan doorsturen.
   ===================================================================== */

function pingPort(port) {
  // een plaatje laden mag ook vanaf een los bestand; lukt het, dan draait de tool
  return new Promise((resolve) => {
    const img = new Image();
    const t = setTimeout(() => { img.src = ""; resolve(false); }, 700);
    img.onload = () => { clearTimeout(t); resolve(true); };
    img.onerror = () => { clearTimeout(t); resolve(false); };
    img.src = `http://localhost:${port}/ping.gif?${Date.now()}`;
  });
}
async function findServer() {
  const hits = await Promise.all(PORTS.map(pingPort));
  const i = hits.indexOf(true);
  return i < 0 ? null : PORTS[i];
}

async function launcher() {
  const box = $("#launch");
  box.hidden = false;
  const show = (title, text, extra = "") => {
    box.innerHTML = `<div class="empty">${EQ}<h1>${title}</h1><p>${text}</p>${extra}</div>`;
  };
  show("PlaylistFlac zoeken...", "Even kijken of hij al draait.");
  let port = await findServer();
  if (port) { location.replace(`http://localhost:${port}/`); return; }

  const startBtn = `<div class="actions"><button class="btn primary" id="go">PlaylistFlac starten</button></div>`;
  show("PlaylistFlac starten...", "Je browser vraagt misschien of hij PlaylistFlac mag openen. Kies Openen; met Altijd toestaan hoeft dat voortaan niet meer.", startBtn);
  const go = () => { location.href = "playlistflac://start"; };
  $("#go").onclick = go;
  go();

  const t0 = Date.now();
  let helped = false;
  while (Date.now() - t0 < 120000) {
    await new Promise((r) => setTimeout(r, 1000));
    port = await findServer();
    if (port) { location.replace(`http://localhost:${port}/`); return; }
    if (!helped && Date.now() - t0 > 7000) {
      helped = true;
      show("Gebeurt er niets?", "De allereerste keer kan deze pagina PlaylistFlac nog niet zelf starten. Dubbelklik dan eenmalig op <code>" + (MAC ? "app/Start.command" : LINUX ? "app/Start.sh" : "app\\Start.cmd") + "</code> in de map van PlaylistFlac. Daarna start deze pagina hem voortaan vanzelf.", startBtn);
      $("#go").onclick = go;
    }
  }
}

/* =====================================================================
   De app zelf (geserveerd door PlaylistFlac op localhost).
   ===================================================================== */

const S = {
  app: null,        // /api/state
  current: null,    // index van de open playlist
  view: null,       // /api/playlist
  counts: {},       // index -> aantal te doen (voor de zijbalk)
  sel: {},          // uri -> Set(labels) voor de open playlist
  selByKey: {},
  wasRunning: false,
  dismissed: null,  // starttijd van een weggeklikte taakmelding
  polling: false,
};

async function api(path, body) {
  // index.html?demo: verzonnen playlists, geen server nodig (ui/demo.js)
  if (window.demoApi) return window.demoApi(path, body);
  const opt = body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  let data = null;
  try { data = await r.json(); } catch { /* leeg */ }
  if (!r.ok) throw new Error((data && data.error) || `Fout ${r.status}`);
  return data;
}

// updateknop: kijkt bij het starten op GitHub; een klik werkt bij en herstart de tool
const UPD = { latest: null };
async function checkUpdate(byClick) {
  const b = $("#upd");
  b.disabled = true;
  if (byClick) b.textContent = "Controleren...";
  try {
    const u = await api("/api/update");
    UPD.latest = u.newer ? u.latest : null;
    b.classList.toggle("new", !!u.newer);
    b.textContent = u.newer ? `Bijwerken naar ${u.latest}` : byClick ? "Je hebt de nieuwste versie" : "Controleren op updates";
  } catch {
    b.textContent = byClick ? "Controleren mislukt, opnieuw?" : "Controleren op updates";
  }
  b.disabled = false;
}
async function installUpdate() {
  const b = $("#upd");
  const from = S.app.version;
  b.disabled = true;
  b.textContent = "Bijwerken...";
  try {
    await api("/api/update", {});
  } catch (e) {
    b.textContent = e.message;
    b.disabled = false;
    return;
  }
  b.textContent = "Opnieuw starten...";
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 1000));
    try {
      const st = await api("/api/state");
      if (st.version !== from) { location.reload(); return; }
    } catch { /* de nieuwe versie start nog */ }
  }
  b.textContent = "Start PlaylistFlac opnieuw";
}
$("#upd").onclick = () => (UPD.latest ? installUpdate() : checkUpdate(true));

async function boot() {
  $("#app").hidden = false;
  try {
    S.app = await api("/api/state");
  } catch {
    rescueAnalyse(), $("#main").innerHTML = `<div class="empty"><h1>PlaylistFlac draait niet</h1><p>Open index.html opnieuw om hem te starten.</p></div>`;
    return;
  }
  renderRail();
  checkUpdate(false);
  if (!S.app.setup.ready) { renderEmpty(); openOnboarding(); return; }
  if (!S.app.playlists.length) { renderEmpty(); poll(); return; }
  const start = S.app.task && S.app.running ? S.app.task.index : 0;
  await openPlaylist(start ?? 0);
  poll();
  // tellers in de zijbalk vullen voor de andere playlists
  for (const p of S.app.playlists) {
    if (p.index === S.current) continue;
    try {
      const v = await api(`/api/playlist?i=${p.index}`);
      S.counts[p.index] = v.counts.kiezen + v.counts.zoeken;
      p.name = v.name; p.cover = v.cover;
      renderRail();
    } catch { /* dan geen teller */ }
  }
}

/* ---------- zijbalk ---------- */

function renderRail() {
  $("#lists").innerHTML = S.app.playlists.map((p) => {
    const n = S.counts[p.index];
    const img = p.cover ? `<img src="${esc(p.cover)}" alt="">` : `<span class="ph" aria-hidden="true">${esc((p.name || "?")[0])}</span>`;
    const badge = n === undefined ? "" : `<span class="badge ${n ? "" : "zero"}" title="${n} te doen">${n}</span>`;
    return `<li><button class="pl" data-i="${p.index}" aria-current="${p.index === S.current}">${img}<span class="nm">${esc(p.name || "Laden...")}</span>${badge}</button></li>`;
  }).join("");
  const u = S.app.setup.user;
  $("#who").textContent = u ? `Soulseek: ${u}` : "";
  if (S.app.version) $("#ver").textContent = `PlaylistFlac ${S.app.version}`;
  $("#logo-eq").classList.toggle("live", !!S.app.running);
}
$("#lists").addEventListener("click", (e) => {
  const b = e.target.closest(".pl");
  if (b) openPlaylist(+b.dataset.i);
});

/* ---------- playlist laden ---------- */

async function openPlaylist(i, refresh = false) {
  if (S.view) S.selByKey[S.view.key] = S.sel;
  S.current = i;
  renderRail();
  if (!S.view || S.view.index !== i) rescueAnalyse(), $("#main").innerHTML = `<div class="empty">${EQ}<h1>Ophalen bij Spotify...</h1></div>`;
  try {
    S.view = await api(`/api/playlist?i=${i}${refresh ? "&ververs=1" : ""}`);
  } catch (e) {
    S.view = null;
    rescueAnalyse(), $("#main").innerHTML = `<div class="empty"><h1>Deze playlist lukt niet</h1><p class="error">${esc(e.message)}</p>
      <div class="actions"><button class="btn" data-act="retry">Opnieuw proberen</button><button class="btn quiet" data-act="remove">Uit de lijst halen</button></div></div>`;
    $("#bar").hidden = true;
    return;
  }
  const p = S.app.playlists.find((x) => x.index === i);
  if (p) { p.name = S.view.name; p.cover = S.view.cover; }
  S.counts[i] = S.view.counts.kiezen + S.view.counts.zoeken;
  S.sel = S.selByKey[S.view.key] || {};
  // standaard staat de aanrader aangevinkt
  for (const t of S.view.tracks) {
    if (t.status === "kiezen" && !S.sel[t.uri]) S.sel[t.uri] = new Set([t.groups[0].label]);
    if (t.status !== "kiezen") delete S.sel[t.uri];
  }
  renderRail();
  render();
}

/* ---------- hoofdscherm ---------- */

function render() {
  const v = S.view;
  if (!v) return;
  const c = v.counts;
  const busy = S.app.running;
  const by = (st) => v.tracks.filter((t) => t.status === st);
  const cover = v.cover ? `<img class="cover" src="${esc(v.cover)}" alt="">` : `<div class="cover"></div>`;
  const glow = v.cover ? `<img src="${esc(v.cover)}" alt="">` : "";
  const stat = (n, label, cls = "") => n ? `<span class="stat ${cls}"><b>${n}</b>${label}</span>` : "";

  let html = `<div class="stage"><div class="glow" aria-hidden="true">${glow}</div>
    <header class="head">${cover}<div>
      <h1>${esc(v.name)}</h1>
      <div class="stats">
        <span class="stat"><b>${c.total}</b>op Spotify</span>
        ${stat(c.binnen, "binnen", "ok")}${stat(c.kiezen, "klaar om te kiezen", "hot")}${stat(c.zoeken, "nog niet gezocht", "hot")}${stat(c.wachtrij, "in de wachtrij", "hot")}
        ${stat(c.nietgevonden, "niet gevonden")}${stat(c.overgeslagen, "overgeslagen")}
      </div>
      ${limitNotice(v)}
      <div class="actions">
        ${c.zoeken ? `<button class="btn primary" data-act="search-new">${busy ? "In de wachtrij: zoek" : "Zoek"} ${plural(c.zoeken, "nieuw nummer", "nieuwe nummers")}${busy ? "" : " op Soulseek"}</button>` : ""}
        <button class="btn" data-act="open">Map openen</button>
        <button class="btn quiet" data-act="refresh">Opnieuw ophalen</button>
        <button class="btn quiet" data-act="remove">Uit de lijst halen</button>
      </div>
    </div></header></div>
    <div id="task"></div>`;

  const wacht = by("wachtrij");
  if (wacht.length) {
    html += `<section><h2>In de wachtrij <span class="num">${wacht.length}</span></h2>
      <p class="hint">Deze nummers komen aan de beurt zodra wat ervoor staat klaar is.</p>
      <div class="rows">${wacht.map((t) => row(t, `<span class="v" style="color:var(--cyan)">${t.versie === "downloaden" ? "wordt gedownload" : "wordt gezocht"}</span>`)).join("")}</div></section>`;
  }
  const kiezen = by("kiezen");
  if (kiezen.length) {
    html += `<section><h2>Kies je versies <span class="num">${kiezen.length}</span></h2>
      <p class="hint">De aanrader staat al aangevinkt. Klik versies aan of uit; meerdere per nummer mag.</p>
      <div class="legend"><span><i class="k-sel"></i>gekozen</span><span><i class="k-spot"></i>lengte op Spotify</span><span><b class="k-star">&#9733;</b>aanrader</span></div>
      ${kiezen.map(trackBlock).join("")}</section>`;
  }
  const zoeken = by("zoeken");
  if (zoeken.length) {
    html += `<section><h2>Nog niet gezocht <span class="num">${zoeken.length}</span></h2>
      <p class="hint">Nieuw op de playlist. Zoeken laat per nummer zien welke versies er op Soulseek zijn.</p>
      <div class="rows">${zoeken.map((t) => row(t)).join("")}</div></section>`;
  }
  const niet = by("nietgevonden");
  if (niet.length) {
    html += `<section><h2>Niet gevonden <span class="num">${niet.length}</span></h2>
      <p class="hint">Op Soulseek komt en gaat het aanbod met wie er online is. Later opnieuw zoeken levert vaak nog wat op.</p>
      <div class="actions" style="margin-bottom:14px"><button class="btn" data-act="search-missing">Deze ${niet.length} opnieuw zoeken</button></div>
      <div class="rows">${niet.map((t) => row(t, "", `<button class="btn quiet" data-act="skip" data-uri="${esc(t.uri)}">Overslaan</button>`)).join("")}</div></section>`;
  }
  html += `<div id="ana-slot"></div>`;
  html += analyseBlock(v.analyse);
  const binnen = by("binnen");
  if (binnen.length) {
    html += `<section><details class="fold"><summary>Binnen <span class="num">${binnen.length}</span></summary>
      <div class="rows">${binnen.map((t) => row(t, `<span class="v" title="${esc(t.bestand)}">${esc(t.versie)}</span>`,
        `<button class="btn quiet" data-act="reset" data-uri="${esc(t.uri)}">Opnieuw kiezen</button>`)).join("")}</div></details></section>`;
  }
  const over = by("overgeslagen");
  if (over.length) {
    html += `<section><details class="fold skipped"><summary>Overgeslagen <span class="num">${over.length}</span></summary>
      <div class="rows">${over.map((t) => row(t, "", `<button class="btn quiet" data-act="reset" data-uri="${esc(t.uri)}">Toch kiezen</button>`)).join("")}</div></details></section>`;
  }
  if (!kiezen.length && !zoeken.length && !niet.length && v.tracks.length) {
    html += `<section><h2>Alles is binnen</h2><p class="hint">Zet je nieuwe nummers op de playlist in Spotify, dan staan ze hier de volgende keer klaar.</p></section>`;
  }
  rescueAnalyse(), $("#main").innerHTML = html;
  placeAnalyse();
  renderTask();
  renderBar();
}

// Melding als Spotify maar 100 nummers gaf, met de weg naar de hele lijst.
function limitNotice(v) {
  if (!v.limited) return "";
  const sp = S.app.setup.spotify || {};
  if (sp.loggedIn) {
    return `<div class="limit"><p>Je ziet de eerste 100 nummers. ${esc(v.note || "De hele lijst ophalen via je Spotify-account lukte niet.")} Voor de rest: een CSV-export, zie README.md.</p></div>`;
  }
  return `<div class="limit"><p>Spotify laat zonder koppeling maar de eerste 100 nummers zien. Met een Spotify-koppeling (vereist Premium) haal je de hele playlist op.</p>
    <button class="btn" data-act="spotify">${sp.app ? "Inloggen met Spotify" : "Spotify koppelen"}</button></div>`;
}

const PLAY = '<svg viewBox="0 0 14 14"><path d="M3 1.5v11l9-5.5z"/></svg>';
const PAUSE = '<svg viewBox="0 0 14 14"><path d="M3 1.5h3v11H3zM8 1.5h3v11H8z"/></svg>';
function playBtn(t) {
  return `<button class="play" data-act="play" data-src="${esc(t.preview || "")}" ${t.preview ? "" : "disabled"}
    aria-pressed="false" aria-label="${t.preview ? "Fragment beluisteren" : "Geen fragment beschikbaar"}">${PLAY}</button>`;
}

function trackBlock(t) {
  const max = Math.max(t.length || 0, ...t.groups.map((g) => g.length || 0)) * 1.08 || 1;
  const minPct = Math.min(100, (60 / max) * 100);   // afstand tussen de minuutstreepjes
  const chosen = S.sel[t.uri] || new Set();
  const vers = t.groups.map((g, i) => {
    const on = chosen.has(g.label);
    const w = g.length ? (g.length / max) * 100 : 0;
    const tick = t.length ? `<span class="tick" style="left:${(t.length / max) * 100}%"></span>` : "";
    const src = `${plural(g.sources, "bron", "bronnen")}${g.free ? `, <b>${g.free} vrij</b>` : ""}`;
    return `<button class="ver ${g.label ? "" : "plain"}" data-act="toggle" data-uri="${esc(t.uri)}" data-label="${esc(g.label)}"
        aria-pressed="${on}" title="${esc(g.example)}">
      <span class="box" aria-hidden="true"></span>
      <span class="vname">${esc(g.display)}${i === 0 ? `<span class="star" title="aanrader">&#9733;</span>` : ""}</span>
      <span class="lenbar" aria-hidden="true" style="--min:${minPct}%"><span class="slot"><span class="fill" style="width:${w}%"></span></span>${tick}${g.length ? `<span class="cap${t.length && Math.abs(g.length - t.length) <= 3 ? " same" : ""}" style="left:${w}%"></span>` : ""}</span>
      <span class="len">${fmt(g.length)}</span>
      <span class="src">${src}</span>
      <span class="q">${esc(g.quality)}</span>
    </button>`;
  }).join("");
  return `<article class="track">
    <div class="track-head">${playBtn(t)}
      <div><h3>${esc(t.base)}</h3><div class="by">${esc(t.artists || t.artist)}${t.version ? ` <span class="tag">${esc(t.version)}</span>` : ""}</div></div>
      <span class="spot" title="Lengte op Spotify">Spotify ${fmt(t.length)}</span>
    </div>
    <div class="versions">${vers}</div>
    <div class="track-foot">
      <button class="btn quiet" data-act="none" data-uri="${esc(t.uri)}">Niets aanvinken</button>
      <button class="btn quiet" data-act="skip" data-uri="${esc(t.uri)}">Overslaan</button>
      <button class="btn quiet" data-act="research" data-uri="${esc(t.uri)}">Opnieuw zoeken</button>
    </div>
  </article>`;
}

// Sectie met de uitkomst van de laatste analyse: wat je moet nalopen bovenaan.
const ANA_KLEUR = { rood: "#ff5050", oranje: "#ff9a3d", geel: "#ffd23f", groen: "#3ddc84", blauw: "#4a8cff", violet: "#a070ff", magenta: "#ff4fd8" };
function analyseBlock(a) {
  if (!a || !a.tracks || !a.tracks.length) return "";
  const tracks = [].concat(a.tracks);
  const nalopen = (t) => [].concat(t.let_op || []).some((n) => n.niveau === 2);
  const one = (t) => {
    const notes = [].concat(t.let_op || []).sort((x, y) => y.niveau - x.niveau);
    const cues = [].concat(t.cues || []);
    const f = [];
    if (t.bpm) f.push(`<b>${Number(t.bpm).toFixed(Math.abs(t.bpm - Math.round(t.bpm)) > 0.001 ? 3 : 0)}</b> BPM`);
    if (t.key) f.push(`key <b>${esc(t.key)}</b>`);
    if (t.energy) f.push(`<span class="ana-dot" style="background:${ANA_KLEUR[t.kleur] || "var(--muted)"}"></span>energy <b>${t.energy}</b>`);
    if (cues.length) f.push(`<span title="${esc(cues.join(", "))}"><b>${cues.length}</b> cues</span>`);
    return `<div class="ana-row${nalopen(t) ? " warn" : ""}">
      <div class="ana-top"><span class="n" title="${esc(t.bestand)}">${esc(t.bestand.replace(/\.[^.]+$/, ""))}</span>${f.map((x) => `<span class="f">${x}</span>`).join("")}</div>
      ${notes.length ? `<ul class="ana-notes">${notes.map((n) => `<li class="n${n.niveau}">${esc(n.tekst)}</li>`).join("")}</ul>` : ""}
    </div>`;
  };
  const warn = tracks.filter(nalopen), rest = tracks.filter((t) => !nalopen(t));
  return `<section><h2>Analyse <span class="opt">beta</span></h2>
    <p class="ana-meta">Zet in de voorkeuren van Traktor eerst het schrijven van tags naar bestanden uit, anders herschrijft hij je muziekbestanden. Dan in deze volgorde: eerst de map met bestanden in Traktor slepen, Traktor afsluiten zodat hij de collectie opslaat, en pas daarna de .nml importeren; anders raakt hij de covers kwijt. Kies bij het importeren <b>Playlist</b>, niet File, anders komen de cues niet binnen.</p>
    <p class="ana-meta">Laatste analyse ${esc(a.datum || "")}: ${tracks.length} tracks${warn.length ? `, <b style="color:var(--sun)">${warn.length} om na te lopen</b>` : ", niets bijzonders"}. Geel = even controleren in Traktor of rekordbox, grijs = ter info.</p>
    ${warn.map(one).join("")}
    ${rest.length ? `<details class="fold" ${warn.length ? "" : "open"} style="margin-top:12px"><summary style="font-size:16px">Zonder bijzonderheden <span class="num">${rest.length}</span></summary>${rest.map(one).join("")}</details>` : ""}
  </section>`;
}

function row(t, extra = "", action = "") {
  return `<div class="row">${playBtn(t)}
    <div class="t"><div>${esc(t.base)}${t.version ? ` <span class="tag">${esc(t.version)}</span>` : ""}</div><div class="by">${esc(t.artists || t.artist)}</div></div>
    ${extra || "<span></span>"}${action || "<span></span>"}</div>`;
}

function selectedPicks() {
  const picks = [];
  for (const [uri, set] of Object.entries(S.sel)) for (const label of set) picks.push({ uri, label });
  return picks;
}

function renderBar() {
  const v = S.view;
  const bar = $("#bar");
  if (!v || !v.counts.kiezen) { bar.hidden = true; return; }
  const picks = selectedPicks();
  const tracks = Object.values(S.sel).filter((s) => s.size).length;
  bar.hidden = false;
  $("#bar-text").innerHTML = picks.length
    ? `<b>${picks.length}</b> ${picks.length === 1 ? "bestand" : "bestanden"} van ${plural(tracks, "nummer", "nummers")} aangevinkt`
    : "Nog niets aangevinkt";
  const b = $("#bar-btn");
  // loopt er al iets, dan gaat het achteraan in de wachtrij
  b.textContent = S.app.running || (S.app.queue || []).length
    ? `In de wachtrij: ${plural(picks.length, "bestand", "bestanden")}`
    : `Download ${plural(picks.length, "bestand", "bestanden")}`;
  b.disabled = !picks.length;
}

/* ---------- taak (zoeken / downloaden) ---------- */

function renderTask() {
  const el = $("#task");
  if (!el) return;
  const t = S.app.task;
  const queue = S.app.queue || [];
  if ((!t || (t.state !== "bezig" && S.dismissed === t.started)) && !queue.length) { el.innerHTML = ""; return; }
  if (!t) { el.innerHTML = `<div class="task live">${queueBlock(queue, false)}</div>`; return; }
  const running = t.state === "bezig";
  const total = t.total || 0, done = t.done || 0;
  let title, now = "";
  if (t.type === "zoeken") {
    if (t.phase === "inloggen") title = "Inloggen op Soulseek";
    else if (t.phase === "zoeken") title = `Zoeken: ${done} van ${total} klaar`;
    else title = "Verbinden met Soulseek";
    if (t.current) now = `Nu: ${t.current}`;
  } else if (t.type === "installeren") {
    title = `Analyse installeren: stap ${Math.min(total, done + 1)} van ${total}`;
  } else if (t.type === "analyseren") {
    title = total ? `Analyseren: ${done} van ${total} klaar` : "Analyse voorbereiden";
    if (t.current) now = `Nu: ${t.current}`;
  } else {
    title = t.phase === "downloaden" ? `Downloaden: ${done} van ${total} binnen` : "Verbinden met Soulseek";
    if (t.round > 1) title += `, poging ${t.round}`;
  }
  const doneTitle = { zoeken: "Zoeken klaar", downloaden: "Downloaden klaar", installeren: "Analyse geïnstalleerd", analyseren: "Analyse klaar" };
  if (!running) title = t.state === "klaar" ? (doneTitle[t.type] || "Klaar")
                     : t.state === "gestopt" ? "Gestopt" : "Er ging iets mis";
  if (S.view && t.index !== S.view.index && t.name && t.type !== "installeren") title += ` (${t.name})`;
  const pct = total ? Math.round((done / total) * 100) : 0;
  const busyBar = running && !(t.phase === "zoeken" || t.phase === "downloaden" || (t.phase === "analyseren" && total) || t.type === "installeren");
  const file = running && t.type === "downloaden" && t.file && t.file.title
    ? `<div class="file"><span>${esc(t.file.title)}</span><span class="num">${esc(t.file.status || "")}</span>
        <div class="meter"><i style="width:${Math.min(100, t.file.pct || 0)}%"></i></div></div>` : "";
  // het log blijft meescrollen, tenzij je zelf omhoog hebt gescrold om iets terug te lezen
  const old = el.querySelector(".log");
  const follow = !old || old.scrollTop + old.clientHeight >= old.scrollHeight - 12;
  const keep = old ? old.scrollTop : 0;
  const lines = (t.log || []).map((l) => {
    const cls = /\b(Binnen|Geanalyseerd|Ingelogd|bereikbaar|klaar)\b/.test(l) ? "ok" : /\b(Mislukt|Niet gelukt|niet bereikbaar|gestopt|afgebroken|reageerde)\b/i.test(l) ? "bad" : "";
    return cls ? `<span class="${cls}">${esc(l)}</span>` : esc(l);
  }).join("\n");
  const foot = running
    ? `<span></span><span class="actions">${queue.length ? `<button class="btn quiet" data-act="cancel-all">Alles stoppen</button>` : ""}<button class="btn" data-act="cancel">Stoppen</button></span>`
    : `<span></span><span class="actions">${t.type === "analyseren" && t.state === "klaar" ? `<button class="btn" data-act="export-dir">Exportmap openen</button>` : ""}<button class="btn quiet" data-act="dismiss">Sluiten</button></span>`;
  el.innerHTML = `<div class="task ${running ? "live" : t.state === "klaar" ? "done" : "err"}" role="status">
    <div class="task-top">${running ? EQ : ""}<h2>${esc(title)}</h2><span class="clock" id="clock"></span></div>
    ${running ? `<p class="now">${esc(now)}</p><div class="meter ${busyBar ? "busy" : ""}"><i style="${busyBar ? "" : `width:${pct}%`}"></i></div>${file}`
              : `<p class="msg ${t.state === "fout" ? "error" : ""}">${esc(t.message || "")}</p>`}
    <p class="log-title">Wat er gebeurt</p>
    <div class="log" aria-live="off">${lines || "Nog niets."}</div>
    ${queueBlock(queue, running)}
    <div class="task-foot">${foot}</div>
  </div>`;
  const log = el.querySelector(".log");
  log.scrollTop = follow ? log.scrollHeight : keep;
  tickClock();
}

function queueBlock(queue, running) {
  if (!queue.length) return "";
  const what = (q) => q.type === "downloaden" ? plural(q.count, "bestand downloaden", "bestanden downloaden")
    : q.type === "analyseren" ? "analyseren en exporteren" : q.type === "installeren" ? "installeren"
    : plural(q.count, "nummer zoeken", "nummers zoeken");
  return `<div class="queue"><p class="log-title">${running ? "Hierna in de wachtrij" : "In de wachtrij"}</p><ol>
    ${queue.map((q, i) => `<li><span><span class="n">${i + 1}</span><b>${esc(q.name)}</b>: ${what(q)}</span>
      <button class="btn quiet" data-act="unqueue" data-id="${q.id}">Uit wachtrij</button></li>`).join("")}</ol></div>`;
}

function tickClock() {
  const c = document.getElementById("clock");
  const t = S.app && S.app.task;
  if (!c || !t || !t.started) return;
  if (t.state !== "bezig") { c.textContent = ""; return; }
  const s = Math.max(0, Math.round((Date.now() - new Date(t.started)) / 1000));
  c.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
setInterval(tickClock, 1000);

async function poll() {
  // altijd maar een lus: een nieuwe aanroep vervangt de geplande
  clearTimeout(S.pollTimer);
  if (S.polling) return;
  S.polling = true;
  try {
    S.app = await api("/api/state");
  } catch {
    S.polling = false;
    const el = $("#task");
    if (el) el.innerHTML = `<div class="task err"><div class="task-top"><h2>Geen verbinding met PlaylistFlac</h2></div><p class="msg">Is het venster van PlaylistFlac gesloten? Open index.html opnieuw.</p></div>`;
    S.pollTimer = setTimeout(poll, 3000);
    return;
  }
  if (S.spWaiting) {
    const sp = S.app.setup.spotify || {};
    renderSpStatus();
    if (sp.loggedIn || (sp.login && sp.login.state === "fout")) {
      S.spWaiting = false;
      // net gekoppeld: de open playlist opnieuw ophalen, nu met de hele lijst
      if (sp.loggedIn && S.view) await openPlaylist(S.current, true);
    }
  }
  const running = S.app.running;
  // met een wachtrij kan taak 1 klaar zijn en taak 2 al lopen: let op de starttijd
  const started = S.app.task && S.app.task.started;
  const switched = S.lastStarted && started && started !== S.lastStarted;
  S.lastStarted = started || S.lastStarted;
  if (switched) {
    if (S.view) await openPlaylist(S.current);
    for (const p of S.app.playlists) {
      if (p.index === S.current) continue;
      try { const v = await api(`/api/playlist?i=${p.index}`); S.counts[p.index] = v.counts.kiezen + v.counts.zoeken; } catch {}
    }
    renderRail(); render();
  } else if (S.wasRunning && !running) {
    // taak net klaar: lijst en tellers opnieuw laden
    const i = S.app.task ? S.app.task.index : S.current;
    if (i === S.current) await openPlaylist(S.current);
    else {
      try { const v = await api(`/api/playlist?i=${i}`); S.counts[i] = v.counts.kiezen + v.counts.zoeken; } catch {}
      renderRail(); render();
    }
  } else if (S.wasRunning !== running) {
    renderRail(); render();
  } else {
    renderTask(); renderBar();
  }
  // venster open terwijl Python of de analyse geinstalleerd wordt: bijwerken
  if ($("#ana-fold").open && !(S.app.setup.analyse || {}).installed && !$("#ana-setup").hidden) renderAnalyse();
  S.wasRunning = running;
  S.polling = false;
  S.pollTimer = setTimeout(poll, running ? 700 : S.spWaiting ? 1000 : 4000);
}

/* ---------- acties ---------- */

$("#main").addEventListener("click", async (e) => {
  const b = e.target.closest("[data-act]");
  if (!b) return;
  const act = b.dataset.act, uri = b.dataset.uri, v = S.view;
  try {
    if (act === "toggle") {
      const set = S.sel[uri] || (S.sel[uri] = new Set());
      set.has(b.dataset.label) ? set.delete(b.dataset.label) : set.add(b.dataset.label);
      b.setAttribute("aria-pressed", set.has(b.dataset.label));
      renderBar();
    } else if (act === "none") {
      S.sel[uri] = new Set();
      b.closest(".track").querySelectorAll(".ver").forEach((x) => x.setAttribute("aria-pressed", "false"));
      renderBar();
    } else if (act === "play") {
      togglePlay(b);
    } else if (act === "search-new") {
      await startSearch(v.tracks.filter((t) => t.status === "zoeken").map((t) => t.uri));
    } else if (act === "search-missing") {
      await startSearch(v.tracks.filter((t) => t.status === "nietgevonden").map((t) => t.uri));
    } else if (act === "research") {
      await startSearch([uri]);
    } else if (act === "skip" || act === "reset") {
      await api("/api/choice", { index: v.index, uri, action: act === "skip" ? "overslaan" : "terug" });
      await openPlaylist(v.index);
    } else if (act === "open") {
      await api("/api/open", { index: v.index });
    } else if (act === "refresh" || act === "retry") {
      await openPlaylist(S.current, true);
    } else if (act === "remove") {
      const name = v ? v.name : "deze playlist";
      if (!confirm(`${name} uit PlaylistFlac halen? De muziek die al binnen is blijft gewoon staan.`)) return;
      await api("/api/playlists/remove", { index: S.current });
      S.view = null; S.app = await api("/api/state"); S.counts = {};
      if (S.app.playlists.length) await openPlaylist(0); else { renderRail(); renderEmpty(); }
    } else if (act === "cancel") {
      await api("/api/cancel", {});
      poll();
    } else if (act === "cancel-all") {
      if (!confirm("De huidige taak stoppen en de hele wachtrij leegmaken?")) return;
      await api("/api/cancel", { all: true });
      await openPlaylist(S.current);
      poll();
    } else if (act === "unqueue") {
      await api("/api/queue/remove", { id: +b.dataset.id });
      S.app = await api("/api/state");
      await openPlaylist(S.current);
    } else if (act === "export-dir") {
      await api("/api/reveal", { what: "export" });
    } else if (act === "dismiss") {
      S.dismissed = S.app.task && S.app.task.started;
      renderTask();
    } else if (act === "spotify") {
      if (S.app.setup.spotify.app) await spotifyLogin();
      else { openSettings(); $("#sp-how").open = true; $("#sp").scrollIntoView({ block: "start" }); }
    } else if (act === "add") {
      openAdd();
    } else if (act === "onboard") {
      openOnboarding();
    }
  } catch (err) {
    alert(err.message);
  }
});

// Zoeken en downloaden gaan via de wachtrij: draait er al iets, dan komt het
// erachter. Daarna de playlist opnieuw laden, zodat die nummers onder
// "In de wachtrij" staan.
async function enqueue(path, body) {
  S.dismissed = null;
  await api(path, body);
  S.app = await api("/api/state");
  await openPlaylist(S.current);
  poll();
}

async function startSearch(uris) {
  if (!uris.length) return;
  await enqueue("/api/search", { index: S.view.index, uris });
}

$("#bar-btn").addEventListener("click", async () => {
  const picks = selectedPicks();
  if (!picks.length) return;
  try {
    await enqueue("/api/download", { index: S.view.index, picks });
  } catch (err) { alert(err.message); }
});

/* ---------- fragment afspelen ---------- */

const audio = $("#audio");
let playing = null;
function togglePlay(b) {
  if (playing === b && !audio.paused) { audio.pause(); return; }
  if (playing) { playing.innerHTML = PLAY; playing.setAttribute("aria-pressed", "false"); }
  playing = b;
  audio.src = b.dataset.src;
  audio.play().catch(() => {});
  b.innerHTML = PAUSE; b.setAttribute("aria-pressed", "true");
}
audio.addEventListener("pause", () => { if (playing) { playing.innerHTML = PLAY; playing.setAttribute("aria-pressed", "false"); } });

/* ---------- leeg / eerste keer ---------- */

function renderEmpty() {
  $("#bar").hidden = true;
  const ready = S.app.setup.ready;
  rescueAnalyse(), $("#main").innerHTML = `<div class="empty">${EQ}
    <h1>${ready ? "Welke playlist gaan we vullen?" : "Eerst even instellen"}</h1>
    <p>${ready ? "Plak de link van een openbare Spotify-playlist. PlaylistFlac zoekt de nummers op Soulseek en laat per nummer zien welke versies er zijn."
               : "Een Soulseek-account en een muziekmap, dan kun je los. Duurt een minuut."}</p>
    <div class="actions"><button class="btn primary" data-act="${ready ? "add" : "onboard"}">${ready ? "Playlist toevoegen" : "Instellen"}</button></div></div>`;
}

/* ---------- account bedenken / controleren ---------- */

const randomFrom = (chars, n) => Array.from(crypto.getRandomValues(new Uint32Array(n)), (x) => chars[x % chars.length]).join("");
const newAccount = () => ({
  user: "flacsync-" + randomFrom("abcdefghijkmnpqrstuvwxyz23456789", 6),
  pass: randomFrom("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789", 18),
});
function checkAccount(user, pass, hasPassword) {
  if (!user) return "Vul een Soulseek-naam in, of laat er een bedenken.";
  if (!pass && !hasPassword) return "Vul een wachtwoord in.";
  if (/[#\s]/.test(pass)) return "Gebruik in het wachtwoord geen spaties of #.";
  return "";
}
async function afterSettingsSaved() {
  renderRail();
  if (S.view) await openPlaylist(S.current);
  else if (S.app.playlists.length) await openPlaylist(0);
  else renderEmpty();
  poll();
}

/* ---------- tandwiel: instellingen wijzigen ---------- */

function openSettings() {
  const s = S.app.setup;
  $("#f-user").value = s.user || "";
  $("#f-pass").value = "";
  $("#f-pass").placeholder = s.hasPassword ? "Laat leeg om niet te veranderen" : "";
  $("#f-dir").value = s.musicDir || (MAC || LINUX ? "~/Music" : "~\\Music");
  $("#f-flac").checked = s.alleenFlac;
  $("#f-tim").checked = !!s.timSelector; timSync("f");
  $("#f-names").checked = s.netteNamen;
  $("#f-pref").value = s.voorkeur || "";
  $("#f-spid").value = ""; $("#f-spsec").value = "";
  $("#f-spid").placeholder = s.spotify && s.spotify.hasId ? "Ingevuld; laat leeg om niet te veranderen" : "";
  $("#f-spsec").placeholder = s.spotify && s.spotify.app ? "Ingevuld; laat leeg om niet te veranderen" : "";
  $("#sp-how").open = !(s.spotify && s.spotify.app);
  renderSpStatus();
  $("#set-err").textContent = "";
  $("#dlg-settings").showModal();
}

/* ---------- Spotify koppelen (optioneel) ---------- */

function renderSpStatus() {
  const sp = (S.app && S.app.setup.spotify) || {};
  const el = $("#sp-status");
  if (!el) return;
  const login = sp.login || {};
  const waiting = login.state === "wachten" && Date.now() - new Date(login.at) < 6 * 60 * 1000;
  let cls = "", text, btn = "";
  if (sp.loggedIn) {
    cls = "on"; text = `Gekoppeld als <b>${esc(sp.user || "jij")}</b>. Hele playlists worden opgehaald.`;
    btn = `<button type="button" class="btn quiet" id="sp-logout">Uitloggen</button>`;
  } else if (waiting) {
    cls = "wait"; text = "Wachten op Spotify. Geef in het tabblad dat net openging toestemming.";
  } else if (sp.app) {
    text = login.state === "fout" ? `<span class="error">${esc(login.message)}</span>` : "Klaar om in te loggen.";
    btn = `<button type="button" class="btn primary" id="sp-login">Inloggen met Spotify</button>`;
  } else {
    text = "Niet gekoppeld. Vul de gegevens van je Spotify-app in en klik Opslaan.";
  }
  el.className = `sp-status ${cls}`;
  el.innerHTML = `<span><span class="dot"></span>${text}</span>${btn}`;
  const li = $("#sp-login"); if (li) li.onclick = spotifyLogin;
  const lo = $("#sp-logout"); if (lo) lo.onclick = async () => {
    await api("/api/spotify/logout", {}); S.app = await api("/api/state"); renderSpStatus();
    if (S.view) await openPlaylist(S.current, true);
  };
}

async function spotifyLogin() {
  try {
    await api("/api/spotify/login", {});
    S.app = await api("/api/state");
    S.spWaiting = true;
    renderSpStatus();
    poll();
  } catch (err) { alert(err.message); }
}
$("#settings").onclick = () => S.app.setup.ready ? openSettings() : openOnboarding();
$("#set-cancel").onclick = () => $("#dlg-settings").close();
$("#set-intro-again").onclick = () => { $("#dlg-settings").close(); openOnboarding(); };
$("#f-gen").onclick = () => { const a = newAccount(); $("#f-user").value = a.user; $("#f-pass").value = a.pass; };
$("#form-settings").addEventListener("submit", async (e) => {
  e.preventDefault();
  const user = $("#f-user").value.trim(), pass = $("#f-pass").value.trim();
  const problem = checkAccount(user, pass, S.app.setup.hasPassword);
  if (problem) { $("#set-err").textContent = problem; return; }
  $("#set-save").disabled = true;
  try {
    const hadApp = S.app.setup.spotify && S.app.setup.spotify.app;
    S.app = await api("/api/settings", {
      user, pass, musicDir: $("#f-dir").value.trim(), alleenFlac: $("#f-flac").checked, timSelector: $("#f-tim").checked,
      netteNamen: $("#f-names").checked, voorkeur: $("#f-pref").value.trim(),
      spotifyId: $("#f-spid").value.trim(), spotifySecret: $("#f-spsec").value.trim(),
    });
    // net een Spotify-app ingevuld? Dan open laten, zodat je meteen kunt inloggen
    if (!hadApp && S.app.setup.spotify.app && !S.app.setup.spotify.loggedIn) {
      $("#f-spid").value = ""; $("#f-spsec").value = "";
      $("#f-spid").placeholder = $("#f-spsec").placeholder = "Ingevuld; laat leeg om niet te veranderen";
      renderSpStatus();
      $("#sp").scrollIntoView({ block: "start" });
      return;
    }
    $("#dlg-settings").close();
    await afterSettingsSaved();
  } catch (err) {
    $("#set-err").textContent = err.message;
  } finally {
    $("#set-save").disabled = false;
  }
});

/* ---------- onboarding: eerste keer instellen, in vier stappen ---------- */

const OB_STEPS = 4;
let obStep = 1;
function openOnboarding() {
  const s = S.app.setup;
  const a = newAccount();
  // bestaand account houden; anders staat er een bedacht account klaar
  $("#o-user").value = s.user || a.user;
  $("#o-pass").value = s.user ? "" : a.pass;
  $("#o-pass").placeholder = s.hasPassword ? "Laat leeg om niet te veranderen" : "";
  $("#o-dir").value = s.musicDir || (MAC || LINUX ? "~/Music" : "~\\Music");
  $("#o-flac").checked = s.alleenFlac;
  $("#o-tim").checked = !!s.timSelector; timSync("o");
  $("#o-names").checked = s.netteNamen;
  $("#o-pref").value = s.voorkeur || "extended, original, club";
  $("#o-src").value = "";
  showStep(1);
  $("#dlg-onboard").showModal();
}
function nextLabel() {
  if (obStep === 1) return "Beginnen";
  if (obStep < OB_STEPS) return "Volgende";
  return $("#o-src").value.trim() ? "Klaar, playlist ophalen" : "Klaar";
}
function showStep(n) {
  obStep = n;
  document.querySelectorAll("#dlg-onboard .step").forEach((el) => { el.hidden = +el.dataset.step !== n; });
  document.querySelectorAll("#dlg-onboard .steps i").forEach((el, i) => el.classList.toggle("on", i < n));
  $("#ob-count").textContent = `Stap ${n} van ${OB_STEPS}`;
  $("#ob-back").hidden = n === 1;
  $("#ob-next").textContent = nextLabel();
  $("#ob-err").textContent = ""; $("#ob-err").className = "dlg-err";
  const first = document.querySelector(`#dlg-onboard .step[data-step="${n}"] input`);
  if (first) first.focus(); else $("#ob-next").focus();
}
$("#o-src").addEventListener("input", () => { $("#ob-next").textContent = nextLabel(); });
$("#o-gen").onclick = () => { const a = newAccount(); $("#o-user").value = a.user; $("#o-pass").value = a.pass; };
$("#ob-back").onclick = () => showStep(Math.max(1, obStep - 1));
// Escape sluit de onboarding alleen als er al een werkende setup is
$("#dlg-onboard").addEventListener("cancel", (e) => { if (!S.app.setup.ready) e.preventDefault(); });
$("#form-onboard").addEventListener("submit", async (e) => {
  e.preventDefault();
  if (obStep === 2) {
    const problem = checkAccount($("#o-user").value.trim(), $("#o-pass").value.trim(), S.app.setup.hasPassword);
    if (problem) { $("#ob-err").textContent = problem; return; }
  }
  if (obStep === 3 && !$("#o-dir").value.trim()) { $("#ob-err").textContent = "Vul een muziekmap in."; return; }
  if (obStep < OB_STEPS) { showStep(obStep + 1); return; }

  $("#ob-next").disabled = true;
  try {
    S.app = await api("/api/settings", {
      user: $("#o-user").value.trim(), pass: $("#o-pass").value.trim(), musicDir: $("#o-dir").value.trim(),
      alleenFlac: $("#o-flac").checked, timSelector: $("#o-tim").checked, netteNamen: $("#o-names").checked, voorkeur: $("#o-pref").value.trim(),
    });
    const src = $("#o-src").value.trim();
    if (src) {
      $("#ob-err").className = "dlg-err info";
      $("#ob-err").textContent = "Playlist ophalen bij Spotify...";
      const r = await api("/api/playlists/add", { src, name: "" });
      S.app = await api("/api/state");
      $("#dlg-onboard").close();
      renderRail();
      await openPlaylist(r.index);
      poll();
    } else {
      $("#dlg-onboard").close();
      await afterSettingsSaved();
    }
  } catch (err) {
    $("#ob-err").className = "dlg-err";
    $("#ob-err").textContent = err.message;
  } finally {
    $("#ob-next").disabled = false;
  }
});

/* ---------- playlist toevoegen ---------- */

function openAdd() {
  $("#a-src").value = ""; $("#a-name").value = ""; $("#add-err").textContent = "";
  $("#dlg-add").showModal();
}
$("#add").onclick = openAdd;
$("#add-cancel").onclick = () => $("#dlg-add").close();
$("#form-add").addEventListener("submit", async (e) => {
  e.preventDefault();
  $("#add-save").disabled = true;
  $("#add-err").className = "dlg-err info";
  $("#add-err").textContent = "Playlist ophalen bij Spotify...";
  try {
    const r = await api("/api/playlists/add", { src: $("#a-src").value.trim(), name: $("#a-name").value.trim() });
    S.app = await api("/api/state");
    $("#dlg-add").close();
    await openPlaylist(r.index);
  } catch (err) {
    $("#add-err").className = "dlg-err";
    $("#add-err").textContent = err.message;
  } finally {
    $("#add-save").disabled = false;
  }
});

/* ---------- export voor rekordbox ---------- */

const RB_STEPS = `<ol class="how-to">
  <li>Open rekordbox, ga naar <b>Voorkeuren → Geavanceerd → Database</b> (Preferences → Advanced → Database).</li>
  <li>Kies bij <b>rekordbox xml</b> het bestand <code>data${SEP}rekordbox.xml</code> in de map van PlaylistFlac.</li>
  <li>Zet in de voorkeuren bij <b>Weergave → Lay-out</b> (View → Layout) het vinkje bij <b>rekordbox xml</b> aan. Links in de boom verschijnt dan "rekordbox xml".</li>
  <li>Klik daar met rechts op een playlist of map en kies <b>Importeren</b> (Import Playlist).</li>
</ol>
<p class="keep">Opnieuw exporteren na nieuwe analyses in Traktor mag altijd: rekordbox leest het bestand opnieuw in. Controleer bij een paar mp3's even of het grid klopt.</p>`;

/* ---------- Tim Selector ---------- */

// met de Tim Selector aan doet "Alleen FLAC" niet mee
function timSync(p) {
  const on = $(`#${p}-tim`).checked;
  $(`#${p}-flac`).disabled = on;
  $(`#${p}-flac`).closest("label").style.opacity = on ? 0.45 : "";
}
["f", "o"].forEach((p) => { $(`#${p}-tim`).addEventListener("change", () => timSync(p)); });

/* ---------- analyseren & exporteren ---------- */

// gekozen vinkjes onthouden (alleen in deze browser; mag ontbreken)
const ANA_KEYS = ["grid", "cues", "key", "keyest", "energy", "traktor", "rb"];
function anaLoad() {
  try {
    const v = JSON.parse(localStorage.getItem("pf-analyse") || "null");
    if (v) ANA_KEYS.forEach((k) => { if (k in v) $(`#ana-${k}`).checked = !!v[k]; });
  } catch {}
}
function anaSave() {
  try { localStorage.setItem("pf-analyse", JSON.stringify(Object.fromEntries(ANA_KEYS.map((k) => [k, $(`#ana-${k}`).checked])))); } catch {}
}

function renderAnalyse() {
  const a = S.app.setup.analyse || {};
  $("#ana-setup").hidden = !!a.installed;
  $("#ana-form").hidden = !a.installed;
  $("#rb-body").innerHTML = "";
  $("#ana-err").textContent = "";
  $("#rb-traktor").hidden = !S.app.setup.traktor;
  if (!a.installed) {
    const installing = (S.app.task && S.app.task.type === "installeren" && S.app.task.state === "bezig") ||
                       (S.app.queue || []).some((q) => q.type === "installeren");
    $("#ana-steps").innerHTML = a.python
      ? `<li>Python ${esc(a.python)} is gevonden. Mooi.</li>
         <li>Klik <b>Analyse installeren</b>. Dat downloadt ruim 1 GB (vooral PyTorch) en duurt een paar minuten; je ziet het in "Wat er gebeurt".</li>`
      : (LINUX ? `<li>Installeer Python 3 met je pakketbeheer, bijvoorbeeld <code>sudo apt install python3 python3-venv</code>.</li>`
              : `<li>Download Python 3.13 van <b>python.org/downloads</b> en installeer het. ${MAC ? "Kies de macOS-installer." : "Vink in het eerste scherm <b>Add python.exe to PATH</b> aan."}</li>`) + `
         <li>Kom hier terug: PlaylistFlac ziet vanzelf dat Python er is.</li>
         <li>Klik dan op <b>Analyse installeren</b>.</li>`;
    $("#rb-go").textContent = installing ? "Wordt geïnstalleerd..." : "Analyse installeren";
    $("#rb-go").disabled = !a.python || installing;
    return;
  }
  $("#rb-go").textContent = "Deze playlist analyseren";
  $("#rb-go").disabled = false;
}

// Voor #main opnieuw gevuld wordt: het analyseblok eerst in veiligheid brengen.
function rescueAnalyse() { $("#ana-home").appendChild($("#dlg-rb")); }

// Het analyseblok is een vast stuk pagina (zodat de vinkjes blijven staan) dat
// bij elke render onder de playlist komt; zonder playlist terug naar zijn schuilplek.
function placeAnalyse() {
  const slot = $("#ana-slot");
  if (!slot) return;
  slot.replaceWith($("#dlg-rb"));
  // de uitkomst van "Traktor-collectie -> rekordbox" laten staan; de rest bijwerken
  if (!$("#rb-body").innerHTML) renderAnalyse();
}
$("#ana-fold").ontoggle = () => { if ($("#ana-fold").open) { $("#rb-body").innerHTML = ""; renderAnalyse(); } };
anaLoad();
// cues kunnen alleen met een beatgrid
$("#ana-cues").onchange = () => { if ($("#ana-cues").checked) $("#ana-grid").checked = true; anaSave(); };
$("#ana-grid").onchange = () => { if (!$("#ana-grid").checked) $("#ana-cues").checked = false; anaSave(); };
["key", "keyest", "energy", "traktor", "rb"].forEach((k) => { $(`#ana-${k}`).onchange = anaSave; });

$("#rb-go").onclick = async () => {
  const a = S.app.setup.analyse || {};
  $("#ana-err").textContent = "";
  try {
    if (!a.installed) {
      $("#rb-go").disabled = true;
      S.dismissed = null;
      await api("/api/analyse/install", {});
      S.app = await api("/api/state");
      poll();
      return;
    }
    const indexes = [S.current];
    const doen = [["grid", "grid"], ["cues", "cues"], ["key", "key"], ["keyest", "keyschatting"], ["energy", "energie"]].filter(([id]) => $(`#ana-${id}`).checked).map(([, v]) => v);
    const formaten = [["traktor", "traktor"], ["rb", "rekordbox"]].filter(([id]) => $(`#ana-${id}`).checked).map(([, v]) => v);
    if (!doen.length) throw new Error("Kies wat je wilt analyseren.");
    if (!formaten.length) throw new Error("Kies voor welke software.");
    anaSave();
    $("#rb-go").disabled = true;
    await enqueue("/api/analyse", { indexes, doen, formaten, opnieuw: $("#ana-opnieuw").checked, hele: $("#ana-hele").checked });
    $("#ana-opnieuw").checked = false; $("#ana-hele").checked = false;   // per keer, standaard weer uit
  } catch (err) {
    $("#ana-err").textContent = err.message;
  } finally {
    $("#rb-go").disabled = false;
  }
};

// zonder eigen analyse: wat Traktor al weet meenemen naar rekordbox (zoals in 1.0)
$("#rb-traktor").onclick = async () => {
  $("#ana-setup").hidden = true; $("#ana-form").hidden = true;
  $("#rb-traktor").disabled = true;
  $("#rb-body").innerHTML = `<div class="task live"><div class="task-top">${EQ}<h2>Traktor-collectie omzetten...</h2></div><p class="now">Duurt meestal zo'n tien seconden.</p></div>`;
  try {
    const r = await api("/api/export/rekordbox", {});
    if (!r.tracks) { $("#rb-body").innerHTML = `<p class="dlg-err">Er is nog niets om te exporteren.</p>`; return; }
    const parts = [`${r.grids} met beatgrid`, `${r.keys} met key`, `${r.hotcues} hotcues`,
      r.loops ? `${r.loops} loops` : "", `${plural(r.playlists, "playlist", "playlists")}`].filter(Boolean).join(", ");
    $("#rb-body").innerHTML = `<div class="stats"><span class="stat ok"><b>${r.tracks}</b>tracks uit Traktor klaar voor rekordbox</span></div>
      <p class="hint">${esc(parts)}. Het bestand is <code>data${SEP}rekordbox.xml</code>.${r.ontbreekt ? ` <span class="warn">${r.ontbreekt} tracks uit Traktor staan niet meer op hun plek en zijn overgeslagen.</span>` : ""}</p>
      <h3 class="sub">Zo haal je het binnen in rekordbox</h3>${RB_STEPS}`;
  } catch (err) {
    $("#rb-body").innerHTML = `<p class="dlg-err">${esc(err.message)}</p>`;
  } finally {
    $("#rb-traktor").disabled = false;
  }
};
$("#rb-reveal").onclick = () => api("/api/reveal", { what: "export" }).catch(() => {});

/* ---------- afsluiten ---------- */

$("#quit").onclick = async () => {
  if (S.app && S.app.running && !confirm("Er loopt nog een taak. Toch afsluiten? Die wordt dan gestopt.")) return;
  try { await api("/api/quit", {}); } catch {}
  audio.pause();
  $("#bar").hidden = true;
  rescueAnalyse(), $("#main").innerHTML = `<div class="empty"><h1>PlaylistFlac is gestopt</h1><p>Je kunt dit tabblad sluiten. Opnieuw beginnen: open index.html, of de snelkoppeling op je bureaublad.</p></div>`;
};

// ?demo laadt eerst ui/demo.js; dat speelt de server na
if (new URLSearchParams(location.search).has("demo")) {
  const d = document.createElement("script");
  d.src = "ui/demo.js";
  d.onload = boot;
  document.body.appendChild(d);
} else if (location.protocol === "file:") launcher(); else boot();
