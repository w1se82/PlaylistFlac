"use strict";
/* =====================================================================
   Twee talen: Nederlands en Engels.

   Nederlands is de brontekst, in de code en in index.html. Voor Engels
   zoekt t() de Nederlandse tekst op in PF_EN (ui/lang-en.js); staat hij er
   niet in, dan blijft hij Nederlands (en meldt de console welke).

   - t("Zoeken: {done} van {total} klaar", { done, total })
   - translateDom(): vertaalt de vaste teksten van index.html een keer bij
     het starten. Sleutel = de inhoud (innerHTML) van het element, met
     spaties samengevoegd. Komt er tekst bij in index.html, zet hem dan ook
     in lang-en.js; tests/Test-PlaylistFlac.ps1 en de console waarschuwen.

   Welke taal: de server zegt het (/api/state -> lang: instelling "taal",
   of automatisch de taal van je browser). Tot die er is: de browser.
   ===================================================================== */

let LANG = (navigator.languages && navigator.languages[0] || navigator.language || "en").toLowerCase().startsWith("nl") ? "nl" : "en";
const I18N_MISSING = new Set();

function setLang(l) {
  LANG = l === "nl" ? "nl" : "en";
  document.documentElement.lang = LANG;
}

function lookup(nl) {
  if (LANG === "nl" || !nl) return nl;
  const dict = window.PF_EN || {};
  if (Object.prototype.hasOwnProperty.call(dict, nl)) return dict[nl];
  for (const [re, en] of window.PF_EN_PATTERNS || []) if (re.test(nl)) return nl.replace(re, en);
  if (!I18N_MISSING.has(nl)) { I18N_MISSING.add(nl); console.warn("[i18n] geen Engels voor:", nl); }
  return nl;
}

function t(nl, vars) {
  const s = lookup(nl);
  return vars ? s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? vars[k] : m)) : s;
}

const norm = (s) => s.replace(/\s+/g, " ").trim();

// Vaste teksten in de pagina vertalen. Een element met eigen tekst wordt in
// zijn geheel vertaald (met de opmaak erin, zoals <b>); met een icoon (svg)
// erin alleen de losse tekst ernaast.
function translateDom(root = document.body) {
  if (LANG === "nl") return;
  const attrs = ["placeholder", "title", "aria-label"];
  const walk = (el) => {
    if (el.nodeType !== 1 || el.tagName === "SCRIPT" || el.tagName === "STYLE" || el.hasAttribute("data-no-t")) return;
    for (const a of attrs) if (el.hasAttribute(a) && /[a-z]/i.test(el.getAttribute(a))) el.setAttribute(a, t(el.getAttribute(a)));
    const own = [...el.childNodes].filter((n) => n.nodeType === 3 && /[a-z]/i.test(n.nodeValue));
    if (own.length && !el.querySelector("svg, input, select, textarea")) {
      el.innerHTML = t(norm(el.innerHTML));
      return;
    }
    for (const n of own) {
      const lead = n.nodeValue.match(/^\s*/)[0], tail = n.nodeValue.match(/\s*$/)[0];
      n.nodeValue = lead + t(norm(n.nodeValue)) + tail;
    }
    for (const c of [...el.children]) walk(c);
  };
  walk(root);
}

// zelfde als t(), voor plekken waar een variabele t al iets anders is (een track, een taak)
const tr = t;

// voor waarden uit de data ("Extended Mix", "(zonder aanduiding)"): vertalen als het
// een bekende tekst is, anders ongemoeid laten, zonder waarschuwing
function tx(nl) {
  if (LANG === "nl" || !nl) return nl;
  const dict = window.PF_EN || {};
  return Object.prototype.hasOwnProperty.call(dict, nl) ? dict[nl] : nl;
}
