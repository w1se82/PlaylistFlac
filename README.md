# PlaylistFlac

Versie 1.4.1-beta

Je Spotify-playlists als mappen met FLAC-bestanden (of mp3 320), gedownload
via Soulseek.

Spotify levert alleen de lijst met nummers; de muziek komt van Soulseek. Per
nummer zie je welke **versies** er te vinden zijn (Extended Mix, Original Mix,
Radio Edit, remixes) en kies jij welke je wilt. Handig, want Spotify heeft vaak
alleen de korte radio-versie. Komen er nummers bij op de playlist, dan staan ze
de volgende keer klaar.

![PlaylistFlac: per nummer de versies, met een lengtebalk en de Spotify-lengte als cyaan streep](docs/screenshot.png)

## Nieuw in 1.4.1-beta

- **Duidelijker uitleg voor Traktor**: de stappen staan nu in de juiste
  volgorde. Eerst de bestanden zelf in Traktor slepen, dan Traktor afsluiten
  zodat hij de collectie opslaat, en pas daarna de `.nml` importeren. Anders
  raakt Traktor de covers kwijt. Zie [In Traktor](#in-traktor). Ook de melding
  na een analyse herinnert je aan die volgorde.

## Nieuw in 1.4.0-beta

- **Uitleg op het moment zelf**: zie je een onderdeel voor het eerst (zoeken,
  versies kiezen, de lengtebalk, downloaden, niet gevonden, analyseren), dan
  licht PlaylistFlac het uit met een korte uitleg erbij. Elk onderdeel een
  keer. Weer allemaal zien: tandwiel, *Uitleg opnieuw*. Helemaal uitzetten kan
  op het kaartje zelf.
- **Demo**: open `index.html?demo` in je browser om de interface te proberen
  met verzonnen playlists, zonder Soulseek. Er wordt niets gedownload.
- Onder de motorkap opgeruimd: het programma staat in losse onderdelen in
  `app\lib`, de interface in `ui\`. Voor jou verandert er verder niets.
- Bij de meldingen in de sectie *Analyse* staat weer een gewoon
  opsommingsteken in plaats van een onleesbaar teken.

## Nieuw in 1.3.5-beta

- **Alleen nieuwe tracks naar Traktor**: de `.nml` op je bureaublad bevat
  standaard alleen de tracks die net geanalyseerd zijn, als playlist
  `<playlist> (nieuw)`. Een import overschrijft dus niet meer de cues en grids
  die je zelf in Traktor hebt aangepast. Wil je toch alles, vink dan *Hele
  playlist naar Traktor* aan.
- **Analyseren & exporteren zit nu in het scherm van de playlist**, als
  uitklapblok. Het aparte venster en de knop linksonder zijn weg.

## Nieuw in 1.3.4-beta

- **Updateknop**: linksonder bij het versienummer. PlaylistFlac kijkt op GitHub
  of er een nieuwere versie is en werkt zichzelf bij; je instellingen, je
  wachtwoord en je muziek blijven staan. Deze versie moet je nog een keer met de
  hand installeren, daarna kan het met de knop.
- **Alleen nog analyseren wat nodig is**: tracks die al geanalyseerd zijn slaat
  hij over, dus een nieuwe track in de playlist kost nog maar een minuut. Wil je
  ze toch opnieuw, vink dan *Tracks die al geanalyseerd zijn opnieuw doen* aan.
  Eerdere analyses tellen mee. Stop je een analyse halverwege, dan gaat hij de
  volgende keer verder waar hij was.
- **De `.nml` staat op je bureaublad** als `<playlist> (PlaylistFlac).nml`, want
  daar opent Traktor zijn importvenster. De kopie wordt mee bijgewerkt.
- **Belangrijk voor Traktor:** vraagt Traktor bij het inladen *File tags may
  differ from playlist tags*, kies dan **Playlist**. Bij File komen de cues en
  het grid niet binnen. Zie [In Traktor](#in-traktor).

## Nieuw in 1.3.3-beta

- **Belangrijk voor Traktor:** zet in de voorkeuren van Traktor het schrijven
  van tags naar bestanden uit voordat je een `.nml` inlaadt. Staat dat aan, dan
  herschrijft Traktor je muziekbestanden bij het inladen en kunnen bijvoorbeeld
  album en genre verdwijnen. Zie [In Traktor](#in-traktor).
- De knop uit 1.3.2-beta is weg: PlaylistFlac werkt de `.nml` nu vanzelf bij
  zodra Traktor heeft opgeslagen.

## Nieuw in 1.3.2-beta

- **Covers blijven staan in Traktor**: de `.nml` neemt nu de cover-verwijzing,
  het album, het genre en dergelijke mee, uit je Traktor-collectie of uit de
  tags van het bestand. Zie [In Traktor](#in-traktor) voor de volgorde.
- Heb je de tracks na de analyse aan Traktor toegevoegd, dan werkt PlaylistFlac
  de `.nml` vanzelf bij zodra Traktor heeft opgeslagen, zonder opnieuw te
  analyseren.

## Nieuw in 1.3.1-beta

- Zoeken liep op Windows vast als een bestand op Soulseek tekens als `"` of `|`
  in de naam had; dat is opgelost. Gaat er bij een nummer iets mis, dan blijft
  de rest van de zoekronde bewaard.
- Bestanden met `+`, `%` of `"` in de naam kunnen nu gedownload worden.
- Staat hetzelfde nummer twee keer op de playlist, dan haalt hij het een keer
  op. Lukt het opslaan van een bestand niet, dan gaat de rest gewoon door.

## Nieuw in 1.3.0-beta

- **Werkt ook op een Mac** (beta: nog niet op een echte Mac getest). Zie
  [Op een Mac](#op-een-mac). Op Windows verandert er niets.

## Nieuw in 1.2.0

- **Tim Selector** (tandwieltje): download mp3 in plaats van FLAC, en dan
  altijd 320 kbps. Zie [Tim Selector](#tim-selector-mp3-in-plaats-van-flac).
- **Energy-kleur** bij *Analyseren & exporteren*: energy 1-10 als kleur van
  de track in Traktor en rekordbox.
- **Betere cues**: het laadpunt staat op de eerste maat waarin de muziek
  begint, en breaks en drops vallen ook goed als de frases halverwege een
  track verspringen.
- **Exact beatgrid**: het grid staat nu op de aanslag van de beat, meestal
  binnen 2 ms van een met de hand gezet grid, en de BPM klopt tot op 0,001.
  Bij mp3's stond het grid vaak zo'n 50 ms te vroeg door een leeg infoblokje
  aan het begin; daar wordt nu voor gecorrigeerd.
- **Sectie Analyse** bij elke geanalyseerde playlist: per track BPM, key,
  energy en cues, met bovenaan wat je even moet nalopen. Zie [Na de
  analyse](#na-de-analyse-de-sectie-analyse).
- **Snelkoppeling op je bureaublad**: die zet PlaylistFlac er de eerste keer
  zelf neer.

## Nieuw in 1.1.0

- **Analyseren & exporteren** (linksonder, vervangt *Exporteren voor
  rekordbox*): PlaylistFlac bepaalt zelf BPM, beatgrid, cues en key, zonder
  Traktor, en schrijft per playlist een Traktor-playlist (`.nml`) en een
  `rekordbox.xml`. Je vinkt aan wat je wilt. Optioneel: het vraagt een
  eenmalige installatie met Python. Zie [Analyseren en
  exporteren](#analyseren-en-exporteren).
- De oude export, de analyse uit je Traktor-collectie meenemen naar
  rekordbox, zit in hetzelfde venster onder *Traktor-collectie → rekordbox*.

## Nieuw in 1.0.1

- Tijdens het downloaden zie je weer de bestandsgrootte (bijvoorbeeld
  "12,3 / 38,5 MB") in plaats van "0,0 MB".

## Nieuw in 1.0.0

De eerste versie om te delen:

- Interface in je browser: `index.html` openen start de tool. Een korte
  introductie bij de eerste keer; instellingen via het tandwieltje.
- Per nummer de versies op Soulseek kiezen, met lengtebalk, fragment van 30
  seconden, en meerdere versies tegelijk.
- Wachtrij voor zoeken en downloaden, over playlists heen, met een logboek van
  wat er gebeurt.
- Herkent wat al in de playlistmap staat en downloadt dat niet opnieuw.
- Per playlist een `.m3u8` voor elke DJ-software, en een export voor rekordbox
  (met de analyse van Traktor, als je dat hebt).
- Optioneel: Spotify koppelen voor playlists van meer dan 100 nummers.

## Wat heb je nodig

- Windows 10 of 11. Niets installeren: de tool draait op PowerShell (zit in
  Windows) en haalt bij de eerste start zelf
  [sockseek](https://github.com/fiso64/sockseek) op, het programma dat op
  Soulseek zoekt en downloadt (~115 MB).
- Of een **Mac** met macOS 13 of nieuwer, met PowerShell 7 erop (gratis, zie
  [Op een Mac](#op-een-mac)).
- Een **Soulseek-account**. Aanmaken hoeft niet apart: een nieuwe naam met
  wachtwoord wordt bij de eerste keer inloggen vanzelf een account. De tool
  bedenkt er ook een voor je. Gebruik je al SoulseekQt of Nicotine+, neem dan
  een **apart** account, anders gooien ze elkaar eruit.
- **Openbare** Spotify-playlists.
- Een netwerk dat Soulseek doorlaat. Op werk- en schoolnetwerken is het vaak
  geblokkeerd; thuis of via je telefoon werkt het meestal wel.

## Installeren en starten

1. Pak de zip uit naar een vaste plek, bijv. `C:\Users\<jij>\PlaylistFlac`.
2. **De allereerste keer:** dubbelklik op `app\Start.cmd`. Dat koppelt
   PlaylistFlac aan Windows en opent de interface in je browser.
3. **Daarna:** open de snelkoppeling **PlaylistFlac** op je bureaublad (die
   zet de tool er de eerste keer zelf neer) of gewoon `index.html`. De pagina
   start PlaylistFlac zelf. Je browser vraagt dan of hij
   PlaylistFlac mag openen; kies *Openen* en vink *Altijd toestaan* aan.

Er komt een geminimaliseerd venster *PlaylistFlac* in je taakbalk. Dat is de
motor: zolang dat open is, werkt de pagina. Stoppen kan met **Afsluiten** in de
pagina, of door dat venster te sluiten.

Bij de eerste start loop je in vier stappen door de instellingen: account,
muziekmap, voorkeuren en je eerste playlist. Later wijzigen kan via het
**tandwieltje** linksboven.

### Op een Mac

*Beta: deze versie is gebouwd en getest op Windows en Linux, nog niet op een
echte Mac. Loopt er iets mis, geef dan door wat je ziet (een schermfoto van
het Terminal-venster helpt het meest).*

1. **PowerShell 7 installeren** (eenmalig, gratis, van Microsoft). Download
   het `.pkg`-bestand voor macOS via
   [deze pagina](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos)
   en installeer het. Met Homebrew kan ook: `brew install powershell`.
2. Pak de zip uit naar een vaste plek, bijv. je thuismap
   (`/Users/<jij>/PlaylistFlac`). Niet in *Downloads* laten staan als je die
   map vaak opruimt.
3. **De allereerste keer:** dubbelklik op `app/Start.command`. macOS zegt
   waarschijnlijk dat het van een *onbekende ontwikkelaar* komt:
   - klik op *Gereed* (of *Annuleer*);
   - ga naar **Systeeminstellingen → Privacy en beveiliging**, scroll naar
     beneden en klik bij *Start.command* op **Open toch**;
   - dubbelklik nog een keer op `Start.command` en kies **Open**.

   Er opent een Terminal-venster: dat is de motor, laat het open. Je browser
   opent PlaylistFlac. De eerste keer haalt hij sockseek op (~110 MB).
4. **Daarna:** dubbelklik op **PlaylistFlac** op je bureaublad (die zet de
   tool er de eerste keer zelf neer), of open `index.html`. Dan draait de
   motor op de achtergrond, zonder Terminal-venster; stoppen doe je met
   **Afsluiten** in de pagina.

Verschillen met Windows:

- Je muziek komt standaard in `~/Music/<playlist>`; Traktor op een Mac zoekt
  zijn collectie in `~/Documents/Native Instruments`.
- Voor *Analyseren & exporteren* installeer je Python 3.13 van
  [python.org](https://www.python.org/downloads/macos/) (de macOS-installer).
  De Python die al op een Mac staat is te oud. Op een Mac met Apple-chip (M1
  en later) is de analyse waarschijnlijk sneller dan op een gemiddelde
  Windows-laptop.
- In plaats van `app\Start.cmd -...` voor de opties hieronder typ je in
  Terminal, in de map `app`: `./Start.command -...`.

## Gebruiken

- **Playlist toevoegen** (linksonder): plak de Spotify-link. In Spotify: drie
  puntjes bij de playlist, *Delen*, *Link naar playlist kopiëren*.
- **Zoek nieuwe nummers op Soulseek**: zoekt alles wat nog niet binnen is. Je
  ziet live hoe ver hij is.
- **Kies je versies**: per nummer een lijstje versies. Elke versie heeft een
  balk die laat zien hoe lang hij is; de **cyaan streep** is de lengte op
  Spotify. Zo zie je meteen welke de lange versie is. De aanrader (ster) staat
  al aangevinkt; meerdere versies aanvinken mag, elk wordt een eigen bestand.
  Met de afspeelknop hoor je 30 seconden van het nummer op Spotify.
- **Download**: de knop onderin haalt alles op wat aangevinkt is. Hij probeert
  alle bestanden tegelijk; lukt een bron niet, dan neemt hij een volgende
  ronde een andere bron voor dezelfde versie.
- **Wachtrij**: zoeken en downloaden gaan achter elkaar, ook over playlists
  heen. Kies je versies in playlist A, klik Download, ga naar playlist B en doe
  daar hetzelfde: B komt in de wachtrij en start vanzelf als A klaar is.
  Onder *Hierna in de wachtrij* zie je wat er nog komt; *Uit wachtrij* haalt
  iets eraf, *Alles stoppen* stopt de huidige taak en leegt de wachtrij.
- **Wat er gebeurt**: tijdens en na elke taak staat er een logboek met tijden:
  inloggen, welk nummer hij zoekt, bij wie hij downloadt, wat binnenkomt en wat
  mislukt (en waarom).
- **Overslaan**: wordt niet meer gevraagd. Terughalen kan onder *Overgeslagen*.
- **Opnieuw kiezen** (onder *Binnen*): wil je toch een andere versie, dan zet
  dit het nummer terug in de lijst.

### Welke versie is de aanrader?

1. Is het nummer op Spotify een remix (*Domino - Space 92 Remix*), dan blijft
   het die remix, bij voorkeur de extended versie ervan.
2. Daarbinnen wint wat het eerst in *Voorkeur bij versies* staat. Standaard:
   `extended, original, club`.
3. Is het nummer geen remix, dan komen remixes van anderen onderaan.
4. Bij gelijke stand wint de versie met de meeste vrije bronnen.

Herkennen gaat op de bestandsnaam op Soulseek, en die zijn niet altijd netjes.
Kijk bij twijfel naar de lengtebalk.

### Waarom lukken sommige downloads niet?

Soulseek is van gewone mensen die hun muziek delen. Een bron kan offline zijn,
of je in een wachtrij zetten. Nieuwe accounts die zelf niets delen, staan bij
sommige mensen achteraan. PlaylistFlac kiest daarom eerst bronnen met een vrij
uploadslot ("vrij" bij een versie). Via een mobiele hotspot kunnen anderen geen
verbinding met jou maken, wat ook bronnen kost. Wat niet lukt blijft staan;
later opnieuw proberen levert vaak nog wat op.

### Tim Selector: mp3 in plaats van FLAC

Standaard haalt PlaylistFlac FLAC: verliesvrij, maar zo'n 30 tot 60 MB per
nummer. Zet je bij het tandwieltje de **Tim Selector** aan, dan downloadt hij
mp3's, met deze regels:

- **Altijd 320 kbps.** Een mp3 met een lagere bitrate, of waarvan de bitrate
  niet bekend is, wordt overgeslagen. Liever even geen nummer dan een slechte
  mp3; de volgende keer zoekt hij opnieuw.
- **Alleen mp3.** FLAC-bronnen tellen dan niet mee, en *Alleen FLAC* doet niet
  mee zolang de Tim Selector aan staat.
- **Wat al binnen is, blijft staan.** Een nummer dat al als FLAC in de map
  staat, wordt niet nog eens als mp3 gehaald.

Een mp3 van 320 kbps is ongeveer 12 MB voor een track van vijf minuten.
Handig bij weinig schijfruimte, of als je speler of USB-stick geen FLAC
speelt. Je kunt hem op elk moment aan of uit zetten; dat geldt voor de
volgende downloads.

## Staat het al in de map?

Bij elke playlist kijkt PlaylistFlac ook in de map zelf. Een bestand met de
artiest en de titel van een nummer erin telt als binnen ("stond al in de map").
Dat geldt ook voor een `_index.csv` die sockseek daar eerder achterliet. Een
andere versie van hetzelfde nummer telt ook. Is het Spotify-nummer een remix van
iemand (*Opal - Four Tet Remix*), dan moet die naam ook in het bestand staan.
Wil je toch een andere versie: *Opnieuw kiezen* bij dat nummer.

## In je DJ-software zetten

In elke playlistmap zet PlaylistFlac een **`<playlist>.m3u8`**, op dezelfde
volgorde als op Spotify. Dat playlistformaat lezen rekordbox, Serato, Engine DJ,
VirtualDJ, djay, Mixxx en Traktor allemaal: sleep het bestand (of de map) erin,
en je software analyseert BPM, key en beatgrid zelf. Het bestand wordt
bijgewerkt na elke download en als je de playlist opent.

## Analyseren en exporteren

*Beta.* Het beatgrid is meestal heel nauwkeurig, maar loop de tracks na voor
je ermee draait. De cues zijn een vertrekpunt dat je zelf bijschaaft.

**Analyseren & exporteren** (uitklapblok in het scherm van een playlist) zet
die playlist klaar voor je DJ-software, met:

- **BPM en beatgrid.** De BPM tot op 0,001, het grid op de aanslag van de
  beat. De gridmarker staat op de eerste beat van een frase van 32 beats.
- **Cues**, maximaal 8 hot cues:
  - het laadpunt, op de eerste maat waarin de muziek begint;
  - twee breaks, waar de bas wegvalt;
  - twee drops, waar de bas terugkomt;
  - uitmixen 64 en 32 beats voor het einde.

  Alleen de laatste uitmix-cue is een *fade-out*; in automode stopt Traktor op
  de eerste fade-out die hij tegenkomt.
- **Key**: uit de tags als het bestand er al een heeft (van de winkel of Mixed
  In Key). Zelf schatten kan ook, maar is nog onbetrouwbaar en staat daarom
  standaard uit; dan bepaalt Traktor of rekordbox de key.
- **Energy-kleur** (optie): energy 1-10 in de geest van Mixed In Key, als
  kleur van de track: 1-3 blauw, 4-5 violet, 6-7 groen, 8-9 oranje, 10 rood.
  Staat er al een energy in de tags (`ENERGYLEVEL`), dan geldt die. Kost zo'n
  halve minuut extra per track.

Je vinkt aan wat je wilt en voor welke software: Traktor, rekordbox of
allebei. Het resultaat komt in `data\export`:

- `<playlist>.nml`, voor Traktor, met de hele playlist;
- `<playlist> (nieuw).nml`, met alleen de tracks die deze keer geanalyseerd
  zijn. **Deze** staat op je bureaublad als `<playlist> (PlaylistFlac).nml`, met
  in Traktor de playlist `<playlist> (nieuw)`. Zo blijven grids en cues die je
  zelf in Traktor hebt aangepast staan. Wil je toch de hele playlist naar
  Traktor, vink dan *Hele playlist naar Traktor* aan; dan staat de volledige
  `.nml` op je bureaublad. Was er niets nieuws, dan haalt hij de oude kopie van
  je bureaublad weg, zodat je niet per ongeluk de vorige keer opnieuw inlaadt;
- `<playlist> (rekordbox).xml`, voor rekordbox, met de cues als hot cues én
  memory cues.

Tracks die al geanalyseerd zijn slaat hij over, tenzij je *Tracks die al
geanalyseerd zijn opnieuw doen* aanvinkt. Is een bestand veranderd, of wil je
iets analyseren dat de vorige keer niet aanstond, dan doet hij die track gewoon
opnieuw. Mislukte tracks probeert hij elke keer weer.

**Je muziekbestanden worden alleen gelezen, nooit aangepast.** Reken op
ongeveer een minuut per track. Het loopt via de wachtrij, dus je kunt
intussen verder.

### Eenmalig installeren: "Analyse? Installeer dan Python!"

De analyse draait op Python met een neuraal netwerk dat beats en de eerste
beat van de maat vindt
([Beat This!](https://github.com/CPJKU/beat_this) van de Johannes Kepler
Universiteit Linz). De eerste keer:

1. Installeer **Python 3.13** van [python.org](https://www.python.org/downloads/).
   Op Windows: vink in het eerste scherm *Add python.exe to PATH* aan. Op een
   Mac: kies de macOS-installer.
2. Klik in PlaylistFlac op *Analyseren & exporteren* → *Analyse installeren*.

Dat downloadt ruim 1 GB (vooral PyTorch) naar `data\analyse` en duurt een paar
minuten. Daarna werkt de analyse ook zonder internet. Weggooien kan altijd:
verwijder `data\analyse`.

### In Traktor

Een `.nml` inladen overschrijft de gegevens van een track in Traktor. Een
`.nml` kan geen plaatje bevatten, alleen een verwijzing naar de cover die
Traktor al heeft. De volgorde is dus belangrijk: eerst de bestanden zelf in
Traktor, pas daarna de playlist.

0. **Eenmalig:** zet in de voorkeuren van Traktor het schrijven van tags naar
   bestanden uit. Anders herschrijft Traktor je muziekbestanden bij het
   importeren en kunnen bijvoorbeeld album en genre verdwijnen.
1. **Bestanden inladen:** sleep de map van de playlist in Traktor, op de
   *Track Collection*. Traktor leest dan de tracks en hun covers uit de
   bestanden.
2. **Traktor afsluiten:** dan slaat hij de collectie op. Pas dan staan de
   covers in het bestand dat PlaylistFlac kan lezen.
3. **Even wachten:** laat PlaylistFlac openstaan, of start hem. Binnen een
   halve minuut werkt hij de `.nml` op je bureaublad vanzelf bij.
4. **Playlist importeren:** start Traktor, klik met rechts op *Playlists* →
   *Import Playlist* en kies op je bureaublad `<playlist> (PlaylistFlac).nml`.
5. Vraagt Traktor *File tags may differ from playlist tags*, kies dan
   **Playlist**. Bij File leest hij alleen het bestand en komen de cues en het
   grid niet binnen.

Komen er later tracks bij, doe dan hetzelfde: eerst de nieuwe bestanden in
Traktor, afsluiten, dan importeren.

Titel, artiest, album en genre komen uit de collectie of anders uit de tags van
het bestand. Staat een track al in je collectie, dan kan Traktor bij het
importeren je eigen grid en cues vervangen. Gebruik dit dus vooral voor
nieuwe tracks.

### In rekordbox

Zie de stappen hieronder; kies alleen het `.xml`-bestand uit `data\export`.

### Hoe goed is het?

Gemeten tegen 20 tracks waarvan het grid in Traktor met de hand exact is
gezet:

- **BPM** is bij alle 20 gelijk, tot op 0,001.
- **Beatgrid** zit bij 18 van de 20 binnen 2 ms, ook bij mp3's. De
  uitzondering: een track met een klik vlak vóór de kick, daar staat het grid
  op die klik (14 ms te vroeg). Zoiets hoor je bij het nalopen meteen.
- **Eerste beat van de maat** is bij alle 20 goed; op een grotere collectie
  ruim 90%.
- **Cues** zijn een vertrekpunt. Waar een break of opbouw precies hoort, is
  een kwestie van gevoel; schuif ze waar nodig zelf.

### Na de analyse: de sectie Analyse

Bij de playlist verschijnt een sectie **Analyse** met per track de BPM, key,
energy (met kleurbolletje) en het aantal cues. Bovenaan, geel gemarkeerd,
staan de tracks om even na te lopen:

- **Begin van de frase onzeker**: kijk of de cues op de goede maat staan.
- **Eerste tel van de maat onzeker**: kijk waar de maat begint.
- **Grid twijfelachtig**: er zit een tweede aanslag vlak naast de kick.

In grijs staat wat ter info is: een BPM die geen heel getal is, een mp3
waarvan het grid is verschoven voor het infoblokje, geen key in de tags.
Het eindbericht van de analyse zegt ook hoeveel tracks je moet nalopen. Het
rapport staat als `<playlist>.analyse.json` in `data\export`.

## Traktor-collectie naar rekordbox

Heb je Traktor en wil je de analyse **van Traktor** meenemen, gebruik dan
*Traktor-collectie → rekordbox* in hetzelfde venster. Dat maakt een bestand
dat rekordbox in één keer inleest, met je playlists in mappen.

Wat er meegaat: de analyse van Traktor (BPM, key, beatgrid, hotcues, loops,
sterren en kleuren), je Traktor-playlists en je PlaylistFlac-playlists op
Spotify-volgorde. Nummers die Traktor nog niet kent, gaan mee zonder analyse;
rekordbox analyseert die dan zelf. Deze knop zie je alleen als Traktor op de
pc staat.

Het resultaat is `data\rekordbox.xml`, het officiële importformaat van
rekordbox. Traktors `collection.nml` wordt alleen gelezen, nooit aangepast.

In rekordbox, één keer instellen:

1. *Voorkeuren → Geavanceerd → Database* (Preferences → Advanced → Database):
   kies bij *rekordbox xml* het bestand `data\rekordbox.xml`.
2. *Voorkeuren → Weergave → Lay-out* (View → Layout): vink *rekordbox xml* aan.
3. Links in de boom staat nu *rekordbox xml*. Rechtsklik op een playlist of
   map, *Importeren* (Import Playlist).

Goed om te weten:

- rekordbox bewaart BPM met twee decimalen. Aan het eind van een nummer kan
  het grid daardoor hooguit enkele tientallen milliseconden van Traktor
  afwijken.
- Bij **mp3's** decoderen Traktor en rekordbox het begin soms net anders,
  waardoor het grid een fractie kan verschuiven. Check bij een paar mp3's of
  het klopt. Bij FLAC en WAV speelt dit niet.
- Vanaf de opdrachtregel kan het ook: `app\Start.cmd -Rekordbox`.

## Playlists met meer dan 100 nummers

Standaard ziet PlaylistFlac de **eerste 100 nummers** van een playlist; daar
krijg je een melding van. Twee manieren om de hele lijst te krijgen:

### Spotify koppelen (optioneel, vereist Premium)

Daarmee haalt PlaylistFlac je playlists helemaal op, ook als er later nummers
bij komen. Spotify eist een eigen "developer app", en dat het account van die
app **Premium** heeft. Het werkt alleen voor playlists die **van jou** zijn of
waar je aan meewerkt; die van anderen blijven op 100.

1. Ga naar <https://developer.spotify.com/dashboard> en log in met je
   Spotify-account.
2. Klik **Create app**. Naam en beschrijving maken niet uit.
3. Vul bij **Redirect URIs** precies `http://127.0.0.1:48721/callback` in en
   klik *Add*.
4. Vink bij de API's **Web API** aan, ga akkoord en klik **Save**.
5. Open de app, ga naar **Settings** en kopieer de **Client ID** en (via
   *View client secret*) het **Client secret**.
6. In PlaylistFlac: tandwieltje, plak ze bij *Spotify koppelen*, **Opslaan**,
   en dan **Inloggen met Spotify**. Geef in het Spotify-tabblad toestemming
   (PlaylistFlac vraagt alleen om je playlists te lezen).

Wil een vriend jouw app gebruiken, voeg dan zijn Spotify-e-mail toe onder
**User Management** van de app; anders maakt hij zijn eigen app. Uitloggen kan
via het tandwieltje. De koppeling wordt bewaard in `data\spotify-token.json`.

### CSV-export (zonder Premium)

Exporteer de playlist als CSV, bijv. met
[exportify.app](https://exportify.app), en zet het pad in
`data\instellingen.ini` onder `[playlists]`:

```ini
Grote Playlist = C:\Users\jij\Downloads\grote_playlist.csv
```

Bij nieuwe nummers moet je dan opnieuw exporteren.

## Hoe weet hij wat je al hebt?

In `data\status` staat per playlist een `<id>.keuzes.json`: welk nummer binnen
is (en in welke versie), en welke je hebt overgeslagen. Daardoor:

- worden nummers die je **zelf weggooit niet opnieuw** gedownload. Wil je ze
  terug, gebruik dan *Opnieuw kiezen*.
- wordt een nummer dat je van de playlist haalt **niet** uit je map verwijderd.
  De tool voegt alleen toe.

## Delen met iemand anders

Open een opdrachtvenster in de map `app` en typ:

```
Start.cmd -Inpakken
```

Dat maakt `release\PlaylistFlac-<versie>.zip` in de map PlaylistFlac. Elke
versie krijgt een eigen zip, dus oudere blijven bewaard. Je map `data` (met je
wachtwoord en je status) en de 115 MB aan sockseek gaan **niet** mee.

## Problemen

| wat je ziet | wat het is |
|---|---|
| index.html blijft op *PlaylistFlac starten...* | de koppeling is er nog niet: dubbelklik eenmalig op `app\Start.cmd` (Mac: `app/Start.command`) |
| Mac: *Start.command kan niet worden geopend* | zie [Op een Mac](#op-een-mac), stap 3: *Open toch* in Privacy en beveiliging |
| Mac: Terminal zegt *PowerShell 7 nodig* | installeer PowerShell 7 (stap 1 bij [Op een Mac](#op-een-mac)) en dubbelklik opnieuw |
| *Kan de Soulseek-server niet bereiken* | geen internet, of het netwerk blokkeert Soulseek (werk, school, soms een VPN) |
| *Inloggen op Soulseek lukt niet* | verkeerd wachtwoord, of de naam is al van iemand anders: kies via het tandwieltje een andere |
| *Playlist niet te lezen* | de playlist is privé, of de link klopt niet |
| Spotify zegt *INVALID_CLIENT: Invalid redirect URI* | de Redirect URI in je Spotify-app is niet precies `http://127.0.0.1:48721/callback` |
| *Poort 48721 is bezet* bij inloggen | een ander programma (zoals sockseek) wacht ook op Spotify; sluit dat en probeer opnieuw |
| *Geen verbinding met PlaylistFlac* | het venster *PlaylistFlac* is gesloten; open index.html opnieuw |
| een verkeerde versie gedownload | gooi het bestand weg en kies onder *Binnen* bij dat nummer *Opnieuw kiezen* |
| *Python niet gevonden* bij Analyse installeren | installeer Python 3.13 van python.org (Windows: met *Add python.exe to PATH* aangevinkt), en open index.html opnieuw |
| *Analyse installeren* mislukt halverwege | meestal de internetverbinding; klik nog eens, hij gaat verder waar hij was |

Alle details van de laatste taak staan in `data\status\laatste-run.log`.

## Voor gevorderden

- `app\Start.cmd -Console` werkt zonder browser, met vragen in het venster.
  `-Console -Proef` zoekt en laat de versies zien zonder te downloaden.
- `app\Start.cmd -Afmelden` haalt de `playlistflac://`-koppeling weer uit
  Windows (alleen voor jouw gebruiker; er waren geen adminrechten nodig). Op
  een Mac haalt `./Start.command -Afmelden` het app'je `PlaylistFlac.app` weg.
- Alle instellingen staan ook als tekst in `data\instellingen.ini`, met uitleg
  erbij. Daar staat ook `versie-kiezen = uit` voor het oude gedrag: geen keuze,
  sockseek pakt de versie met dezelfde lengte als op Spotify.
- `app\Start.cmd -Stil` start de interface zonder `playlistflac://`-koppeling,
  snelkoppeling of browser. Handig om een kopie te testen.

## Mappen

| map / bestand | |
|---|---|
| `index.html` | de interface; openen = starten. Met `?demo` erachter: proberen met verzonnen playlists |
| `ui\` | opmaak en scripts van de interface, ook de uitleg per onderdeel (`rondleiding.js`) en de demo (`demo.js`) |
| `docs\` | de screenshot voor deze README |
| `release\` | de zips om te delen, een per versie (alleen bij jou, niet in de zip) |
| `tests\` | controles voor wie aan PlaylistFlac werkt: `powershell -File tests\Test-PlaylistFlac.ps1` (niet in de zip) |
| `app\` | het programma: `PlaylistFlac.ps1` met zijn onderdelen in `app\lib`, `Start.cmd` (Windows), `Start.command` (Mac), de analyse in `app\analyse`, en sockseek in `app\bin` |
| `PlaylistFlac.app` | alleen op een Mac: het app'je dat de tool start en `playlistflac://` afhandelt; maakt de tool zelf |
| `data\` | jouw instellingen en status. Niet delen, er staat je wachtwoord in. Een nieuwe versie haal je met de updateknop linksonder; die laat `data\` staan. |
| `data\export` | de geanalyseerde playlists voor Traktor en rekordbox |
| `data\analyse` | Python met PyTorch voor de analyse (ruim 1 GB, alleen als je die installeert) |

Gebruik het voor muziek waar je het recht toe hebt.

## Copyright

Copyright (c) 2026 WiWi Audio.

Gebruikt werk van anderen:

- [sockseek](https://github.com/fiso64/sockseek) van fiso64 (GPL-3.0) doet het
  zoeken en downloaden op Soulseek. Het zit niet in deze zip; PlaylistFlac
  haalt het bij de eerste start van GitHub.
- De lettertypes Unbounded en Figtree (SIL Open Font License) komen van Google
  Fonts.
- Het tandwiel-icoon komt uit Material Icons van Google (Apache-licentie 2.0).
- De analyse gebruikt [Beat This!](https://github.com/CPJKU/beat_this) van
  het Institute of Computational Perception, JKU Linz (MIT-licentie), plus
  [PyTorch](https://pytorch.org) (BSD) en [librosa](https://librosa.org)
  (ISC). Die zitten niet in deze zip; ze worden geïnstalleerd als je de
  analyse aanzet.
