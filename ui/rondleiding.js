"use strict";
/* =====================================================================
   Rondleiding: elk onderdeel wordt een keer uitgelegd, op het moment dat
   je het voor het eerst ziet. Geen vaste reeks stappen vooraf.

   Werkt los van de rest: kijkt elke ~0,7 s of er een onderdeel in beeld is
   dat nog niet is uitgelegd. Wat je gezien hebt onthoudt de server
   (data/status/rondleiding.json, via /api/rondleiding), niet de browser.

   Een uitleg verdwijnt met "Snap ik", Escape, of door het uitgelichte
   onderdeel zelf te gebruiken; alle drie tellen als gezien.
   ===================================================================== */

const TOUR = (() => {
  // Volgorde = voorrang als er meer tegelijk in beeld zijn.
  // el: het onderdeel; when: extra voorwaarde; c: kleur (betekenis zoals in de app)
  const HINTS = [
    {
      id: "zoeken", c: "--hot",
      el: () => document.querySelector('#main [data-act="search-new"]'),
      title: "Eerst zoeken op Soulseek",
      text: "Dan zie je per nummer welke versies er te vinden zijn. Het zoeken loopt op de achtergrond; je kunt intussen gewoon verder.",
    },
    {
      id: "taak", c: "--cyan",
      el: () => document.querySelector("#task .task.live"),
      title: "Hier zie je wat er gebeurt",
      text: "Zoeken en downloaden lopen een voor een. Start je intussen iets anders, dan komt het in de wachtrij en is het daarna aan de beurt.",
    },
    {
      id: "kies-versie", c: "--sun",
      el: () => document.querySelector("#main .track .ver"),
      title: "Vink aan wat je wilt hebben",
      text: "De versie met de <b>ster</b> past het best bij je voorkeur en staat al aangevinkt. Meer versies van een nummer aanvinken mag ook.",
    },
    {
      id: "lengte", c: "--cyan",
      el: () => document.querySelector("#main .track .ver .lenbar"),
      title: "De cyaan streep is de lengte op Spotify",
      text: "De balk is de lengte van de versie op Soulseek. Loopt hij ver door voorbij de streep, dan is het bijna altijd een extended mix.",
    },
    {
      id: "bronnen", c: "--ok",
      el: () => document.querySelector("#main .track .ver .src"),
      title: "Bronnen zijn mensen die het bestand delen",
      text: "Meer bronnen geeft meer kans dat de download lukt. <b>Vrij</b> betekent dat die bron nu meteen kan sturen, zonder wachtrij.",
    },
    {
      id: "downloaden", c: "--hot",
      el: () => { const b = document.querySelector("#bar:not([hidden]) #bar-btn"); return b && !b.disabled ? b : null; },
      title: "Alles in een keer downloaden",
      text: "Wat je hebt aangevinkt gaat samen naar de wachtrij. De bestanden komen in de map van de playlist.",
    },
    {
      id: "niet-gevonden", c: "--sun",
      el: () => document.querySelector('#main [data-act="search-missing"]'),
      title: "Niet gevonden is niet voorgoed",
      text: "Wat er op Soulseek staat hangt af van wie er online is. Probeer het later nog eens, of sla het nummer over.",
    },
    {
      id: "analyse", c: "--ok",
      el: () => document.querySelector("#main #ana-fold > summary"),
      when: () => S.view && S.view.counts.binnen > 0,
      title: "Klaar voor Traktor of rekordbox",
      text: "Hier bepaalt PlaylistFlac BPM, beatgrid en cues van wat binnen is. Optioneel en nog in beta. Je muziekbestanden worden alleen gelezen.",
    },
    {
      id: "tandwiel", c: "--cyan",
      el: () => document.querySelector("#settings"),
      when: () => S.view && S.view.counts.binnen > 0 && seen.has("analyse"),
      title: "Instellingen",
      text: "Hier pas je je account en muziekmap aan, koppel je Spotify voor playlists van meer dan 100 nummers en zet je deze uitleg weer aan.",
    },
  ];

  const seen = new Set();
  let off = false;
  let loaded = false;
  let active = null;     // { hint, since }
  let lastFocus = null;
  let raf = 0;
  let pauseUntil = 0;

  const root = document.createElement("div");
  root.className = "tour";
  root.hidden = true;
  root.innerHTML = `<div class="tour-hole"></div><div class="tour-cue"></div>
    <div class="tour-card" role="dialog" aria-modal="false" aria-labelledby="tour-title" aria-describedby="tour-text">
      <h2 id="tour-title"></h2><p id="tour-text"></p>
      <div class="tour-foot"><button type="button" class="tour-off">Uitleg uitzetten</button><button type="button" class="btn tour-ok">Snap ik</button></div>
    </div>`;
  document.body.appendChild(root);
  const hole = root.querySelector(".tour-hole"), cue = root.querySelector(".tour-cue"), card = root.querySelector(".tour-card");

  // wat de server weet erbij nemen (komt mee met elke /api/state)
  function sync() {
    const r = S.app && S.app.rondleiding;
    if (!r) return false;
    for (const id of r.seen || []) seen.add(id);
    if (r.off) off = true;
    loaded = true;
    return true;
  }

  function save(body) {
    api("/api/rondleiding", body).catch(() => { /* dan zie je hem volgende keer nog eens */ });
  }

  // In beeld: niet weggevouwen, bovenkant zichtbaar en niet onder de onderbalk.
  // Een hoog onderdeel (de taak met zijn log) hoeft niet helemaal in beeld.
  function visible(el) {
    if (!el || !el.isConnected) return null;
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height) return null;
    const bar = $("#bar");
    const floor = !bar.hidden && !bar.contains(el) ? bar.getBoundingClientRect().top : innerHeight;
    if (r.top < 8 || Math.min(r.bottom, r.top + 120) > floor - 8 || r.right < 0 || r.left > innerWidth) return null;
    return r;
  }

  function blocked() {
    return off || !loaded || !S.app || !S.app.setup.ready || document.querySelector("dialog[open]") || Date.now() < pauseUntil;
  }

  function check() {
    sync();
    if (active) return;
    if (blocked()) return;
    for (const h of HINTS) {
      if (seen.has(h.id)) continue;
      if (h.when && !h.when()) continue;
      const el = h.el();
      if (el && visible(el)) { show(h); return; }
    }
  }

  function show(h) {
    active = { hint: h };
    root.style.setProperty("--tour-c", `var(${h.c})`);
    // vertalen pas nu: bij het laden van dit script is de taal nog niet bekend
    card.querySelector("#tour-title").textContent = t(h.title);
    card.querySelector("#tour-text").innerHTML = t(h.text);
    card.querySelector(".tour-off").textContent = t("Uitleg uitzetten");
    card.querySelector(".tour-ok").textContent = t("Snap ik");
    root.hidden = false;
    cue.classList.remove("drop"); void cue.offsetWidth; cue.classList.add("drop");
    place();
    lastFocus = document.activeElement;
    // niet de focus afpakken als je net iets aan het typen bent
    if (!lastFocus || !/^(INPUT|TEXTAREA|SELECT)$/.test(lastFocus.tagName)) card.querySelector(".tour-ok").focus({ preventScroll: true });
    loop();
  }

  function hide(markSeen) {
    if (!active) return;
    const id = active.hint.id;
    active = null;
    cancelAnimationFrame(raf);
    root.hidden = true;
    if (markSeen) { seen.add(id); save({ seen: id }); }
    // even ademruimte voor de volgende
    pauseUntil = Date.now() + 900;
    if (lastFocus && lastFocus.isConnected && card.contains(document.activeElement)) lastFocus.focus({ preventScroll: true });
  }

  // Meebewegen met scrollen en opnieuw tekenen: het onderdeel wordt bij elke
  // verversing opnieuw gemaakt, dus elke keer opnieuw opzoeken.
  function loop() {
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(() => { if (active) { place(); loop(); } });
  }

  function place() {
    const h = active.hint;
    const el = h.el();
    if (!el || !el.isConnected || document.querySelector("dialog[open]")) { hide(false); return; }
    const r = el.getBoundingClientRect();
    const out = r.bottom < 0 || r.top > innerHeight || !r.width;
    root.style.visibility = out ? "hidden" : "";
    if (out) return;
    const pad = 6;
    const round = parseFloat(getComputedStyle(el).borderRadius) >= Math.min(r.width, r.height) / 2;
    Object.assign(hole.style, {
      left: `${r.left - pad}px`, top: `${r.top - pad}px`, width: `${r.width + pad * 2}px`, height: `${r.height + pad * 2}px`,
      borderRadius: round ? "999px" : "14px",
    });
    const cw = card.offsetWidth, ch = card.offsetHeight, gap = 18;
    const below = innerHeight - (r.bottom + pad) >= ch + gap + 12 || r.top - pad < ch + gap + 12;
    // de cue hangt een stukje binnen de linkerrand van het onderdeel
    let x = r.left + Math.min(26, r.width / 2);
    const cx = Math.max(12, Math.min(x - 2, innerWidth - cw - 12));
    x = Math.max(cx + 2, Math.min(x, cx + cw - 12));
    const cy = below ? r.bottom + pad + gap : r.top - pad - gap - ch;
    card.style.left = `${cx}px`;
    const top = Math.max(8, Math.min(cy, innerHeight - ch - 8));
    card.style.top = `${top}px`;
    cue.className = `tour-cue ${below ? "down" : "up"}${cue.classList.contains("drop") ? " drop" : ""}`;
    Object.assign(cue.style, {
      left: `${x - 1}px`,
      top: `${below ? r.bottom + pad : top + ch}px`,
      height: `${gap}px`,
    });
  }

  card.querySelector(".tour-ok").onclick = () => hide(true);
  card.querySelector(".tour-off").onclick = () => {
    off = true;
    hide(true);
    save({ off: true });
  };
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && active) { e.preventDefault(); hide(true); } });
  // het onderdeel zelf gebruiken telt ook als begrepen
  document.addEventListener("click", (e) => {
    if (!active || card.contains(e.target)) return;
    const el = active.hint.el();
    if (el && el.contains(e.target)) hide(true);
  }, true);

  // uit de instellingen: alles opnieuw laten zien
  function reset() {
    seen.clear(); off = false;
    if (S.app) S.app.rondleiding = { seen: [], off: false };
    save({ reset: true });
    pauseUntil = Date.now() + 400;
  }

  setInterval(check, 700);
  return { reset, check, hints: HINTS.map((h) => h.id) };
})();

$("#set-tour-again").onclick = () => { $("#dlg-settings").close(); TOUR.reset(); };
