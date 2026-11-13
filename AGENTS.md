# AGENTS.md

Werken aan lidswitch. Lees eerst `README.md` voor de werking.

## Bouwen en testen

Na elke wijziging beide suites draaien, en geen van beide mag falen:

```bash
node --test test/plugin.test.ts
bash test/cli.test.sh
```

De CLI-test gebruikt een schijnbare dekselstand via `LIDSWITCH_ACPI_DIR`. Doe
dat ook bij handmatig testen; het echte deksel hoeft niet dicht.

## Uitgangspunten

- **Omarchy beheert het deksel.** Lidswitch leest alleen de stand en laat
  vergrendelen en het scherm aan Omarchy. Die taak niet overnemen.
- **Eén schrijver per bestand.** `lid.json` wordt alleen door de CLI geschreven,
  elk sessiebestand alleen door zijn eigen plugin. Geen gedeelde lock nodig, en
  dus ook niet introduceren.
- **Toestemmingen worden beantwoord, niet omzeild.** `permission.ask` zet
  `output.status`; er wordt geen ander pad gezocht.
- **Weigeringen moeten terug naar de gebruiker.** Elk geweigerd item gaat in
  `blocked`, anders is het werk stilletjes verdwenen.

## Stijl

- Comments verklaren waarom, niet wat. Vooral bij de beslissingen die niet
  vanzelfsprekend zijn: waarom er geen Hyprland-binding is, waarom een geweigerde
  aanvraag naar de laatste todo gaat.
- Nederlands voor de CLI-uitvoer en README, Engels voor de code.
- Geen nieuwe dependencies. De CLI gebruikt alleen `jq`, `busctl`, `notify-send`
  en `systemctl`, die allemaal al aanwezig zijn.
- Bash strict: `set -euo pipefail`, alle variabelen gequote.

## Wat je niet zomaar doet

- `/usr/share/omarchy/` wijzigen. Dat is pakketbroncode en wordt overschreven bij
  een update.
- `~/.config/hypr/bindings.lua` herschrijven. Hyprland accepteert één binding per
  switch; een tweede op `Lid Switch` zou Omarchy's verdringen.
- Het deksel openen of sluiten om te testen. Gebruik `lidswitch override` of de
  schijnbare ACPI-map.
- Nooit `lidswitch lid closed|open` draaien tegen de state-dir van de gebruiker.
  Elke overgang stuurt een desktopmelding, dus een lusje daarvan vult het scherm
  met meldingen. De testsuite draait in een tijdelijke `LIDSWITCH_HOME` en is
  veilig; een losse controle buiten de suite is dat niet. Zet `LIDSWITCH_QUIET=1`
  als je toch de echte state-dir moet raken.

## Installeren

Verandert je iets aan `install.sh` of aan de systemd-bestanden, dan is
`./install.sh` idempotent en mag je hem gewoon opnieuw draaien. De logind-drop-in
kan hij niet zonder jouw wachtwoord plaatsen; die staat op het einde als commando
om zelf te draaien.
