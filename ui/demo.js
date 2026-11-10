"use strict";
/* =====================================================================
   Demo: de interface met verzonnen playlists, zonder server of Soulseek.
   Open index.html?demo (ook los vanaf schijf). Zoeken en downloaden lopen
   na een paar seconden "klaar"; er wordt niets gedownload of opgeslagen.

     ?demo            een playlist halverwege: kiezen, zoeken, niet gevonden, binnen
     ?demo=nieuw      net toegevoegd: alles moet nog gezocht worden
     ?demo=instellen  eerste keer: de introductie
   Handig om de rondleiding te testen; die begint elke keer opnieuw.
   ===================================================================== */

(() => {
  const scenario = new URLSearchParams(location.search).get("demo") || "";
  const cover = (a, b) => "data:image/svg+xml," + encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient></defs><rect width="10" height="10" fill="url(#g)"/></svg>`);

  // verzonnen nummers: [artiest, titel, lengte op Spotify, hoe het zoeken afloopt]
  const SONGS = [
    ["Mara Velden", "Tunnelvisie", 201, "versies"],
    ["Okko Brandt", "Night Shift", 188, "versies"],
    ["Lune & Ferro", "Glass Floor", 224, "versies"],
    ["Hendrik Saal", "Midnight Ferry", 196, "versies"],
    ["DVNA", "Lowlands Acid", 179, "versies"],
    ["Kees Polder", "Ruis", 210, "niets"],
    ["Sanne Ostra", "Brick by Brick", 232, "versies"],
    ["Tomasz Vey", "Arcade 303", 185, "versies"],
    ["Ylva Moor", "Second Sun", 205, "niets"],
    ["Baptiste Rey", "Signal Lost", 199, "versies"],
  ];
  const uri = (i) => `spotify:track:demo${i}`;
  function groupsFor(i, len) {
    const ext = len + 120 + (i * 17) % 90;
    const g = [
      { label: "extended mix", display: "Extended Mix", length: ext, sources: 3 + (i % 4), free: 1 + (i % 3), quality: "FLAC 16/44.1", score: 3, example: `${SONGS[i][0]} - ${SONGS[i][1]} (Extended Mix).flac` },
      { label: "", display: "(zonder aanduiding)", length: len, sources: 5, free: i % 2 ? 0 : 2, quality: "FLAC 16/44.1", score: 1, example: `${SONGS[i][1]}.flac` },
    ];
    if (i % 3 === 0) g.push({ label: "dub mix", display: "Dub Mix", length: ext + 40, sources: 1, free: 0, quality: "FLAC 24/48", score: 0, example: `${SONGS[i][1]} (Dub Mix).flac` });
    return g;
  }
  function track(i, status) {
    const [artist, title, length] = SONGS[i];
    const t = { uri: uri(i), artist, artists: artist, title, base: title, version: "", length, preview: "", status, versie: "", bestand: "", groups: [] };
    if (status === "kiezen") t.groups = groupsFor(i, length);
    if (status === "binnen") { t.versie = "Extended Mix"; t.bestand = `${artist} - ${title} (Extended Mix).flac`; }
    return t;
  }

  const lists = [];
  const addList = (name, c1, c2, statuses) => lists.push({
    name, cover: cover(c1, c2), src: `https://open.spotify.com/playlist/demo${lists.length}`,
    tracks: statuses.map((st, i) => track(i, st)),
  });
  if (scenario === "nieuw") {
    addList("Warehouse Nights", "#ff3d8b", "#3ee6ff", Array(8).fill("zoeken"));
  } else if (scenario !== "instellen") {
    addList("Warehouse Nights", "#ff3d8b", "#3ee6ff",
      ["kiezen", "kiezen", "kiezen", "zoeken", "zoeken", "nietgevonden", "binnen", "binnen", "binnen"]);
    addList("Zondagmiddag", "#ffd23f", "#ff8a3d", ["binnen", "binnen", "binnen", "binnen"]);
  }

  const st = {
    setup: {
      ready: scenario !== "instellen", problem: scenario === "instellen" ? "Nog niet ingesteld." : null,
      user: scenario === "instellen" ? "" : "flacsync-demo42", hasPassword: scenario !== "instellen",
      musicDir: "~\\Music", musicDirFull: "C:\\Users\\demo\\Music",
      alleenFlac: true, timSelector: false, netteNamen: true, voorkeur: "extended, original, club", traktor: true,
      spotify: { app: false, loggedIn: false, user: null, login: null, redirect: "http://127.0.0.1:48721/callback", hasId: false },
      analyse: { installed: false, python: "3.13.1", exportDir: "C:\\demo\\data\\export" },
    },
    version: "demo",
    task: null, running: false, queue: [],
    rondleiding: { seen: [], off: false },
  };

  const counts = (l) => {
    const c = { total: l.tracks.length, binnen: 0, overgeslagen: 0, kiezen: 0, zoeken: 0, nietgevonden: 0, wachtrij: 0 };
    for (const t of l.tracks) c[t.status]++;
    return c;
  };
  const view = (i) => {
    const l = lists[i];
    if (!l) throw new Error("Die playlist bestaat niet (meer).");
    return {
      index: i, key: `demo${i}`, name: l.name, cover: l.cover, src: l.src, outDir: `C:\\Users\\demo\\Music\\${l.name}`,
      limited: false, fromApi: false, note: null, counts: counts(l), tracks: l.tracks, outDirFiles: 0, analyse: null,
    };
  };
  const state = () => ({
    ...st,
    playlists: lists.map((l, i) => ({ index: i, src: l.src, name: l.name, cover: l.cover })),
    rondleiding: { seen: [...st.rondleiding.seen], off: st.rondleiding.off },
  });

  // een taak die vanzelf afloopt: elke 0,7 s een nummer verder
  let timer = null;
  function runTask(type, i, items, finish) {
    const l = lists[i];
    const before = new Map(items.map((u) => [u, l.tracks.find((t) => t.uri === u.uri || t.uri === u)]));
    for (const t of before.values()) { t._was = t.status; t.status = "wachtrij"; t.versie = type; }
    st.task = { type, state: "bezig", phase: type, index: i, name: l.name, total: items.length, done: 0, started: new Date().toISOString(), log: [] };
    st.running = true;
    clearInterval(timer);
    timer = setInterval(() => {
      const k = st.task.done;
      const t = [...before.values()][k];
      const line = finish(t, items[k]);
      st.task.log.push(line);
      st.task.current = `${t.artist} - ${t.title}`;
      st.task.done++;
      if (type === "downloaden") st.task.file = { title: `${t.artist} - ${t.title}`, status: "binnen", pct: 100 };
      if (st.task.done >= st.task.total) {
        clearInterval(timer);
        st.task.state = "klaar"; st.running = false; st.task.current = "";
        st.task.message = type === "zoeken" ? `${items.length} nummers gezocht.` : `${items.length} bestanden binnen.`;
      }
    }, 700);
  }

  const routes = {
    "GET /api/state": () => state(),
    "GET /api/update": () => ({ newer: false, latest: "demo" }),
    "GET /api/playlist": (q) => view(+q.get("i")),
    "POST /api/rondleiding": (b) => {
      const r = st.rondleiding;
      if (b.reset) { r.seen = []; r.off = false; }
      if (b.off) r.off = true;
      if (b.seen && !r.seen.includes(b.seen)) r.seen.push(b.seen);
      return { seen: [...r.seen], off: r.off };
    },
    "POST /api/settings": (b) => {
      const s = st.setup;
      if (b.user) s.user = b.user;
      if (b.pass) s.hasPassword = true;
      if (b.musicDir) s.musicDir = b.musicDir;
      for (const k of ["alleenFlac", "timSelector", "netteNamen"]) if (k in b) s[k] = !!b[k];
      if (b.voorkeur) s.voorkeur = b.voorkeur;
      s.ready = !!(s.user && s.hasPassword); s.problem = s.ready ? null : "Nog niet ingesteld.";
      return state();
    },
    "POST /api/playlists/add": () => {
      addList(`Nieuwe playlist ${lists.length + 1}`, "#5cf2a5", "#3ee6ff", Array(6).fill("zoeken"));
      return { index: lists.length - 1 };
    },
    "POST /api/playlists/remove": (b) => { lists.splice(+b.index, 1); return { ok: true }; },
    "POST /api/search": (b) => {
      runTask("zoeken", +b.index, b.uris, (t) => {
        const i = SONGS.findIndex((s) => s[1] === t.title);
        if (SONGS[i][3] === "niets") { t.status = "nietgevonden"; t.groups = []; return `Niet gevonden: ${t.artist} - ${t.title}`; }
        t.status = "kiezen"; t.groups = groupsFor(i, t.length);
        return `${t.artist} - ${t.title}: ${t.groups.length} versies`;
      });
      return { ok: true };
    },
    "POST /api/download": (b) => {
      const seenUri = new Set();
      const items = b.picks.filter((p) => !seenUri.has(p.uri) && seenUri.add(p.uri));
      runTask("downloaden", +b.index, items, (t, p) => {
        const g = t.groups.find((x) => x.label === p.label) || t.groups[0];
        t.status = "binnen"; t.versie = g.display; t.bestand = g.example; t.groups = [];
        return `Binnen: ${g.example}`;
      });
      return { ok: true };
    },
    "POST /api/choice": (b) => {
      const t = lists[+b.index].tracks.find((x) => x.uri === b.uri);
      if (b.action === "overslaan") t.status = "overgeslagen";
      else { const i = SONGS.findIndex((s) => s[1] === t.title); t.status = "kiezen"; t.groups = groupsFor(i, t.length); }
      return { ok: true };
    },
    "POST /api/cancel": () => {
      clearInterval(timer);
      if (st.task && st.task.state === "bezig") {
        for (const l of lists) for (const t of l.tracks) if (t.status === "wachtrij") t.status = t._was;
        st.task.state = "gestopt"; st.task.message = "Gestopt."; st.running = false;
      }
      return { ok: true };
    },
  };

  window.demoApi = async (path, body) => {
    await new Promise((r) => setTimeout(r, 80));
    const [p, qs] = path.split("?");
    const key = `${body === undefined ? "GET" : "POST"} ${p}`;
    const fn = routes[key];
    // alles wat in het echt iets op je computer doet (map openen, afsluiten, analyse) doet hier niets
    const out = fn ? fn(body === undefined ? new URLSearchParams(qs || "") : body) : { ok: true };
    return JSON.parse(JSON.stringify(out));
  };

  // een strookje bovenaan, zodat niemand denkt dat dit echt is
  const tag = document.createElement("div");
  tag.textContent = "Demo: verzonnen playlists, er wordt niets gedownload";
  tag.style.cssText = "position:fixed;top:0;left:50%;transform:translateX(-50%);z-index:70;background:var(--sun);color:#160f26;font:600 12px/1 var(--body);padding:5px 12px;border-radius:0 0 10px 10px;";
  document.body.appendChild(tag);
})();
