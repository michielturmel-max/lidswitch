# lidswitch

Als het deksel van de laptop dichtgaat, gaat het scherm op zwart, gaat de laptop
**niet** in slaapstand, en hoort opencode dat je niet aanwezig bent. Het model
werkt dan zelfstandig door en stelt alles wat jouw beslissing nodig heeft uit
tot de laatste todo. Bij het openen van het deksel krijg je de stand van zaken
en de vragen die op je wachten.

## Hoe het werkt

Omarchy doet het meeste werk zelf al. Het bindt beide dekselranden in Hyprland:

| gebeurtenis | Omarchy | lidswitch |
| --- | --- | --- |
| `switch:on:Lid Switch` | `omarchy-system-lid-close`: vergrendelt het scherm en haalt het interne display weg | leest de stand en zet `away: true` |
| `switch:off:Lid Switch` | `omarchy-hyprland-monitor-clamshell`: zet het interne display weer aan | zet `away: false` en vat de sessies samen |

Eén ding blokkeert dat: logind zet `HandleLidSwitch` standaard op `suspend`, dus
de laptop zou toch in slaapstand gaan. Daar staat één privileged wijziging voor.

lidswitch leest de dekselstand daarom zelf, in plaats van een tweede
Hyprland-binding te maken. Hyprland accepteert maar één binding per switch, dus
lidswitch zou Omarchy's binding moeten verdringen en dan zelf
`omarchy-system-lid-close` moeten nadoen. Door hetzelfde ACPI-bestand te lezen
dat Omarchy ook leest, blijft het deelsysteem de baas over vergrendelen en
scherm, en blijft lidswitch los daarvan. Het werkt ook zonder draaiende
compositor.

```
/proc/acpi/button/lid/*/state        lezen, 1x per seconde
        │
        ▼
   lidswitch watch  (systemd --user)          ~/.local/state/lidswitch/lid.json
        │                                          (away: true/false)
        ├── desktopmelding bij weg- en terugkomen
        │
        ▼
   opencode-plugin  ── leest lid.json, en:
        ├── injecteert "werk zelfstandig door" in de lopende sessie
        ├── beantwoordt elke rechtenvraag zelf
        │     normaal werk   -> allow
        │     onomkeerbaar   -> deny + noteren als uitgesteld
        └── injecteert bij terugkomen een samenvatting + de uitgestelde vragen
```

## Wat je nodig hebt

- Linux met een dekselschakelaar in `/proc/acpi/button/lid/`.
- [opencode](https://opencode.ai) en de Omarchy-shell met Hyprland voor de
  plugin en de balkwidget.
- systemd (user) voor de watch-daemon.

## Downloaden en installeren

```bash
git clone https://github.com/michielturmel-max/lidswitch.git
cd lidswitch
./install.sh
```

`install.sh` zet de CLI in `~/.local/bin`, de opencode-plugin in
`~/.config/opencode/plugin`, de balkwidget in
`~/.config/omarchy/plugins/lidswitch` en de systemd-user-service. Voor de
logind-instelling vraagt het één keer om je sudo-wachtwoord; kan dat niet, dan
drukt het de regel af die je zelf moet uitvoeren.

Daarna twee keer herstarten, want beide worden maar één keer geladen:

```bash
# 1. herstart je opencode-sessie (of start een nieuwe)

# 2. herstart de laptop, zodat de logind-instelling actief wordt
```

Wil je de logind-wijziging overslaan (dan blijft de laptop in slaapstand gaan
bij een dicht deksel), gebruik dan:

```bash
./install.sh --no-logind
```

Controleer of alles staat zoals het hoort:

```bash
lidswitch check
```

## Gebruik

```bash
lidswitch status          # deksel, sessies, wat er openstaat
lidswitch status --json   # hetzelfde voor scripts
lidswitch deferred        # alles wat is uitgesteld tot je terug bent
lidswitch check           # is het goed ingericht?
lidswitch override closed # afwezig simuleren, zonder het deksel te sluiten
lidswitch override open   # weer aanwezig
```

## Beleid

`~/.config/lidswitch/policy.json` bepaalt wat het model mag terwijl je weg bent.
Alles wat **lokaal en omkeerbaar** is mag het zelf doen. Alles wat **het
machine af verlaat of niet terug te draaien is** wordt geweigerd en aan jou
teruggegeven:

```jsonc
{
  "deny": {
    "reason": "vereist de gebruiker",   // verschijnt in de samenvatting
    "tools": ["question"],             // niet aan je vragen terwijl je weg bent
    "bash": ["sudo *", "rm -rf *", "git push*", "gh pr create*", "..."]
  },
  "autonomy": {
    "nudgeAfterSeconds": 300,   // 0 = nooit aansporen
    "maxNudges": 3
  }
}
```

Alles wat niet in `deny` staat wordt toegestaan. Voeg iets toe aan `bash` om het
model meer vrijheid te geven; haal iets weg om het strenger te maken. De lijst
ondersteunt `*` als wildcard, alle andere tekens zijn letterlijk.

De plugin staat ook op de `question`-aanvraag: als het model je een vraag zou
stellen, wordt die geweigerd en genoteerd. Zo kiest het zelf en werkt het
verder, in plaats van vast te lopen op een scherm dat niemand leest.

`~/.config/lidswitch/config.json` heeft twee schakelaars:

```json
{ "notify": true, "awayInClamshell": true }
```

`awayInClamshell` bepaalt of een dicht deksel met een externe monitor ook als
afwezigheid telt. In clamshell-gebruik kijk je vaak gewoon verder naar het
externe scherm, dus `false` kan handiger zijn.

## Slaapstand zodra het klaar is

Het doel is niet dat de laptop de hele nacht door blijft draaien. Zodra er
niets meer te doen is, mag hij in slaapstand. Dat kan niet via logind, want
`HandleLidSwitch` is globaal: dat zou bij élk dekselsluiten suspenderen, ook
als er nog aan de gang is. Daarom beslist de daemon er zelf over, op basis van
wat de sessiebestanden zeggen.

De laptop gaat pas in slaapstand als **alle** geregistreerde sessies het volgende
zijn: niet bezig, en nul openstaande todo's. Pas dan begint de rust-timer.

```json
"sleepWhenDone": {
  "enabled": true,
  "afterMinutes": 20,     // rust met niets te doen voordat hij slaapt
  "minAwayMinutes": 10,   // nooit kort na het sluiten
  "dryRun": false         // true = alleen loggen, nooit echt suspenderen
}
```

De twee drempels hebben elk een reden. `minAwayMinutes` vangt de klap-en-weer-open
op: zonder die timer zou de laptop kunnen gaan slapen terwijl je nog bij de tafel
zit. `afterMinutes` is de ruimte voor het model om zelf nog iets te vinden — de
autonome nudges zitten op 5 minuten, dus die hebben al kunnen werken voordat de
klok begint te lopen.

Zet `"dryRun": true` als je eerst wilt zien wat er zou gebeuren; er staat dan elke
keer in het log wat er wanneer zou zijn gebeurd.

Let op: dit weet niets van werk dat je buiten opencode draait. Een lange build in
een losse terminal telt niet als "bezig" en kan dus worden afgebroken.

## Logbegrenzing

`lidswitch.log` is een gewoon bestand en niet het journal, want CLI-aanroepen van
uit een terminal moeten daar ook in terechtkomen. Niemand anders begrenst het dus,
en daarom gekapt lidswitch zelf: bij 1 MB gaat het naar `.log.1`, en de vorige
rotaties schuiven op tot `.log.2`. Oudere rotaties worden weggegooid. Dat is
bewust zonder `logrotate`, want dat zou root plus een timer vragen voor een bestand
dat hoogstens één regel per seconde binnenkomt.

Overschrijven kan met omgevingsvariabelen, wat handig is voor testen:

```bash
LIDSWITCH_LOG_MAX_BYTES=4096 lidswitch status   # lage drempel
LIDSWITCH_LOG_KEEP=5 lidswitch status          # vijf rotaties bewaren
```

## Waarom een todo-item naar het einde gaat

Het model krijgt geen toestemming meer voor de dingen die op de denylijst
staan. Dat is geen fout maar een instructie: de geweigerde toolcall komt bij het
model binnen als een weigering, en de geïnjecteerde opdracht zegt expliciet dat
zoiets op de **laatste** plek van de todo-lijst hoort. Het model legt het daar
neer en gaat verder met alles wat erachter zou zijn geblokkeerd.

## Tests

```bash
node --test test/plugin.test.ts   # 11 tests: injectie, rechten, terugkomst
bash test/cli.test.sh             # 45 tests: status, watch-loop, slaapstand, logbegrenzing
```

De CLI-test draait tegen een schijnbare ACPI-deksel
(`LIDSWITCH_ACPI_DIR`), dus er hoeft geen echt deksel dicht. De logind-tests
lezen hun waarden uit `LIDSWITCH_LOGIND_RUNNING_VALUE` en
`LIDSWITCH_LOGIND_CONFIG_FILE`, zodat ze niet van de logind van deze machine
afhangen. Wie de suites buiten die waarden draait, meet de laptop waarop hij
zit.

## Bestanden

```
bin/lidswitch              CLI en de watch-loop
plugin/lidswitch.ts        de opencode-plugin
omarchy-plugin/lidswitch/  balkwidget voor Quickshell
systemd/lidswitch.service  user-service die de watch-loop draait
systemd/50-lidswitch-logind.conf   de privileged drop-in
config/policy.json         wat mag het model zelf doen
config/config.json         meldingen en clamshell-beleid
install.sh / uninstall.sh  inrichting en terugdraaien
```

## Balkwidget

De Quickshell-widget in `omarchy-plugin/lidswitch/` laat in de bar zien of je weg
bent, hoeveel sessies draaien en hoeveel vragen zijn uitgesteld. Linksklik
wisselt tussen aanwezig en afwezig, rechtsklik opent het overzicht, midden
ververst. `install.sh` zet hem in `~/.config/omarchy/plugins/lidswitch/`.

De widget staat ook als losse plugin in
[lidswitch-omarchy](https://github.com/michielturmel-max/lidswitch-omarchy), met
een eigen README en de marketplace-manifest in de root:

```bash
omarchy plugin add https://github.com/michielturmel-max/lidswitch-omarchy --enable
```

## Weghalen

```bash
lidswitch-uninstall
sudo rm /etc/systemd/logind.conf.d/50-lidswitch.conf
```

## Bekende schaduwen

- **Het deksel-bedrag wordt niet gelezen.** Tussen twee slagen van de watch-loop
  zit tot `LIDSWITCH_POLL_INTERVAL` (standaard 1) seconde. Een klap en een
  meteen open deksel kan dus helemaal niets doen.
- **Werk buiten opencode telt niet mee.** De slaapstand-beslissing leest alleen
  de sessiebestanden van het model. Een build of test die je zelf in een losse
  terminal draait, is onzichtbaar en kan worden onderbroken.
- **`~/.config/hypr/bindings.lua` wordt niet aangeraakt.** Alleen als daar een
  blok uit een eerdere proefversie instond, haalt `install.sh` dat weg.
- **`--auto` in opencode** is los hiervan. Lidswitch bepaalt per toestemming wat
  er gebeurt; `--auto` is een grove noodrem voor als je sessie toch blijft
  hangen.

## Licentie

MIT, zie [LICENSE](LICENSE).
