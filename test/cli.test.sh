#!/usr/bin/env bash
# Tests for the lidswitch CLI. Everything runs against a throwaway state
# directory and a fake ACPI lid, so no real lid has to move.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
LIDSWITCH="$HERE/../bin/lidswitch"

PASS=0
FAIL=0

ok() { printf '  \033[32mok\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
no() {
  printf '  \033[31mFAIL\033[0m %s\n' "$*"
  printf '       %s\n' "${2:-}"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local want=$1 got=$2 name=$3
  if [[ $want == "$got" ]]; then ok "$name"; else no "$name" "wil: '$want'  kreeg: '$got'"; fi
}

assert_contains() {
  local haystack=$1 needle=$2 name=$3
  if [[ $haystack == *"$needle"* ]]; then ok "$name"; else no "$name" "'$needle' ontbreekt in: $haystack"; fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export LIDSWITCH_HOME="$WORK/state"
export LIDSWITCH_CONFIG="$WORK/config.json"
export LIDSWITCH_ACPI_DIR="$WORK/acpi"
printf '{"notify":false,"awayInClamshell":true}\n' >"$LIDSWITCH_CONFIG"
mkdir -p "$LIDSWITCH_HOME/sessions" "$LIDSWITCH_ACPI_DIR/lid/LID0"

lid() { printf 'state:      %s\n' "$1" >"$LIDSWITCH_HOME_ACPI_STATE"; }
LIDSWITCH_HOME_ACPI_STATE="$LIDSWITCH_ACPI_DIR/lid/LID0/state"

jq_field() { jq -r "$1" "$LIDSWITCH_HOME/lid.json"; }

echo "dekselstand uitlezen"
lid open
assert_eq open "$("$LIDSWITCH" status | awk '/^hardware/{print $3}')" "leest de ACPI-status"
lid closed
assert_eq closed "$("$LIDSWITCH" status | awk '/^hardware/{print $3}')" "leest 'closed'"

echo "handmatige overstap"
"$LIDSWITCH" override closed >/dev/null
assert_eq true "$(jq_field .away)" "override closed zet away"
assert_eq closed "$(jq_field .lid)" "override closed zet de dekselstatus"
assert_eq true "$(jq_field .clamshell)" "clamshell wordt meegelezen uit de hardware"
assert_eq "true" "$(jq_field '.awaySince | type == "string"')" "er komt een awaySince"

lid open
"$LIDSWITCH" override open >/dev/null
assert_eq false "$(jq_field .away)" "override open haalt away weg"
assert_eq "null" "$(jq_field '.awaySince')" "awaySince wordt weer leeg"

echo "sessie-aggregatie"
assert_eq "[]" "$("$LIDSWITCH" status --json | jq -c '.sessions')" "geen sessies geeft een lege lijst"

printf '{"pid":%d,"directory":"/tmp/a","busy":true,"deferred":[{"at":"x","type":"bash","title":"git push","reason":"vereist de gebruiker"}]}\n' "$$" \
  >"$LIDSWITCH_HOME/sessions/instance-$$.json"
assert_eq "1" "$("$LIDSWITCH" status --json | jq '.sessions | length')" "een sessie wordt gevonden"
assert_eq true "$("$LIDSWITCH" status --json | jq '.sessions[0].busy')" "bezige sessie wordt gelezen"

printf '{"pid":999999,"directory":"/tmp/dood","busy":true}\n' >"$LIDSWITCH_HOME/sessions/instance-dood.json"
assert_eq "1" "$("$LIDSWITCH" status --json | jq '.sessions | length')" "sessie van een dood proces wordt opgeruimd"

printf '{"pid":%d,"directory":"/tmp/b","busy":false,"deferred":[{"at":"x","type":"bash","title":"sudo rm -rf /","reason":"vereist de gebruiker"}]}\n' "$$" \
  >"$LIDSWITCH_HOME/sessions/instance-b.json"
deferred=$("$LIDSWITCH" deferred)
assert_contains "$deferred" "sudo rm -rf /" "uitgesteld item wordt getoond"
assert_contains "$deferred" "/tmp/b" "uitgesteld item toont de map"
assert_contains "$deferred" "vereist de gebruiker" "uitgesteld item toont de reden"

echo "een kapotte sessie mag niets breken"
printf 'dit is geen json\n' >"$LIDSWITCH_HOME/sessions/instance-kapot.json"
status_out=$("$LIDSWITCH" status 2>&1)
rc=$?
assert_eq 0 "$rc" "status overleeft een kapot bestand"
assert_contains "$status_out" "afwezig" "status geeft toch de stand"

echo "watch-loop"
lid open
# De standaardinterval is 1s, wat precies hetzelfde is als de wachttijd hieronder:
# dat is een race. Met een korte interval is de test deterministisch.
LIDSWITCH_POLL_INTERVAL=0.1 "$LIDSWITCH" watch >/dev/null 2>&1 &
watch_pid=$!
sleep 0.4
assert_eq open "$(jq_field .lid)" "watch zet de beginstand open"

lid closed
sleep 0.4
assert_eq true "$(jq_field .away)" "watch ziet het deksel gaan dicht"

lid open
sleep 0.4
assert_eq false "$(jq_field .away)" "watch ziet het deksel weer open gaan"

kill "$watch_pid" 2>/dev/null
wait "$watch_pid" 2>/dev/null

echo "onbekende dekselstand"
rm -f "$LIDSWITCH_HOME_ACPI_STATE"
assert_eq unknown "$("$LIDSWITCH" status | awk '/^hardware/{print $3}')" "geen ACPI-lid geeft 'unknown'"
assert_contains "$("$LIDSWITCH" check 2>&1)" "geen ACPI-lidknop" "check wijst op het ontbreken van een dekselstand"

# ------------------------------------------------------------- logind-drop-in ---

# De draaiende logind draagt de oude waarde in het geheugen tot een herstart. Een
# geplaatste drop-in is dus geen fout, en dat onderscheid moet check maken.
printf '[Login]\n# HandleLidSwitch=poweroff\nHandleLidSwitch=ignore\n' >"$WORK/logind.conf"
check_with_logind_config() {
  LIDSWITCH_LOGIND_CONFIG_FILE="$1" "$LIDSWITCH" check 2>&1
}

lid open   # de vorige test haalt de schijnbare dekselstand weg; check heeft hem nodig
out=$(check_with_logind_config "$WORK/logind.conf")
assert_contains "$out" "het bestand staat goed" "geplaatste drop-in is geen fout"
assert_contains "$out" "herstart de laptop" "check zegt dat alleen een herstart nodig is"
check_with_logind_config "$WORK/logind.conf" >/dev/null
assert_eq 0 "$?" "een geplaatste drop-in geeft geen fout terug"

printf '[Login]\nHandleLidSwitch=suspend\n' >"$WORK/logind-bad.conf"
out=$(check_with_logind_config "$WORK/logind-bad.conf")
assert_contains "$out" "NIET \"ignore\"" "zonder drop-in blijft het een fout"
assert_contains "$out" "sudo install" "check noemt dan het sudo-commando"
check_with_logind_config "$WORK/logind-bad.conf" >/dev/null
assert_eq 1 "$?" "een ontbrekende drop-in geeft een fout terug"

# ---------------------------------------------------------------- slaapstand ---

STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/systemctl" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LIDSWITCH_STUB_LOG:-/dev/null}"
exit 0
STUBEOF
chmod +x "$STUB/systemctl"

session() {
  printf '{"pid":1,"sessionID":"ses_test","busy":%s,"openTodos":%s,"deferred":[]}\n' "$1" "$2" \
    >"$LIDSWITCH_HOME/sessions/instance-1.json"
}

set_away() {
  local since=${1:-2020-01-01T00:00:00Z} away=${2:-true}
  printf '{"lid":"closed","away":%s,"clamshell":false,"awaySince":%s,"changedAt":null,"updatedAt":"%s"}\n' \
    "$away" "$([[ $away == true ]] && printf '"%s"' "$since" || printf 'null')" "$(date -Is)" \
    >"$LIDSWITCH_HOME/lid.json"
}

# Draait `watch` kort met een nagebootste systemctl en geeft terug of er
# gesuspend is. Zo wordt het echte codepad getest, inclusief de poort tussen
# sessiebestanden en de beslissing.
suspends() {
  local seconds=${1:-2} cfg=$2 log="$WORK/suspend.log"
  : >"$log"
  printf '%s\n' "$cfg" >"$LIDSWITCH_CONFIG"
  LIDSWITCH_STUB_LOG="$log" LIDSWITCH_POLL_INTERVAL=0.1 LIDSWITCH_SLEEP_CHECK_INTERVAL=0 \
    PATH="$STUB:$PATH" "$LIDSWITCH" watch >/dev/null 2>&1 &
  local pid=$!
  sleep "$seconds"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -q '^suspend$' "$log" && echo true || echo false
}

SLEEP_ON='{"notify":false,"sleepWhenDone":{"enabled":true,"afterMinutes":0,"minAwayMinutes":0,"dryRun":false}}'
SLEEP_DRY='{"notify":false,"sleepWhenDone":{"enabled":true,"afterMinutes":0,"minAwayMinutes":0,"dryRun":true}}'
SLEEP_OFF='{"notify":false,"sleepWhenDone":{"enabled":false}}'
SLEEP_GUARD='{"notify":false,"sleepWhenDone":{"enabled":true,"afterMinutes":0,"minAwayMinutes":30,"dryRun":false}}'

# Deze tests zetten lid.json met set_away, inclusief een awaySince van uren geleden.
# De watch-loop zou dat meteen overschrijven zodra de schijnbare hardware "open"
# zegt, dus die wordt hier weggenomen: het gaat om de beslissing, niet om het pollen.
# De watch-loop zelf heeft hierboven een eigen test.
rm -f "$LIDSWITCH_HOME_ACPI_STATE"

rm -f "$LIDSWITCH_HOME"/sessions/*.json
session false 0
assert_eq false "$(set_away 2020-01-01T00:00:00Z false; suspends 1.5 "$SLEEP_ON")" "slaapt niet terwijl je nog aanwezig bent"

session true 3
assert_eq false "$(set_away; suspends 1.5 "$SLEEP_ON")" "slaapt niet terwijl een sessie nog bezig is"

session false 2
assert_eq false "$(set_away; suspends 1.5 "$SLEEP_ON")" "slaapt niet terwijl er open todo's staan"

session false 0
assert_eq true "$(set_away; suspends 2 "$SLEEP_ON")" "slaapt zodra alles klaar is"

session false 0
assert_eq false "$(set_away; suspends 1.5 "$SLEEP_DRY")" "dryRun suspendeert niet"

session false 0
assert_eq false "$(set_away; suspends 1.5 "$SLEEP_OFF")" "uitgeschakeld suspendeert nooit"

session false 0
assert_eq false "$(set_away "$(date -Is)"; suspends 1.5 "$SLEEP_GUARD")" "slaapt niet meteen na het sluiten"
assert_eq true "$(set_away; suspends 2 "$SLEEP_GUARD")" "slaapt wel als de afwezigheidsdrempel voorbij is"

rm -f "$LIDSWITCH_HOME"/sessions/*.json
assert_contains "$("$LIDSWITCH" check 2>&1)" "slaapstand als klaar" "check noemt de slaapstand-instelling"
printf '%s\n' '{"notify":false,"sleepWhenDone":{"enabled":true,"afterMinutes":25,"minAwayMinutes":7}}' >"$LIDSWITCH_CONFIG"
assert_contains "$("$LIDSWITCH" check 2>&1)" "na 25 min rust, vanaf 7 min afwezig" "check toont de daadwerkelijke waarden"

# ------------------------------------------------------------------ logbegrenzing ---

echo "logbegrenzing"
printf '%s\n' '{"notify":false}' >"$LIDSWITCH_CONFIG"
lid open
export LIDSWITCH_LOG_MAX_BYTES=500 LIDSWITCH_LOG_KEEP=2
for _ in $(seq 1 60); do "$LIDSWITCH" lid closed >/dev/null; lid open; done
unset LIDSWITCH_LOG_MAX_BYTES LIDSWITCH_LOG_KEEP
assert_eq true "$([[ -f $LIDSWITCH_HOME/lidswitch.log.1 ]] && echo true || echo false)" "log wordt gedraaid"
assert_eq true "$([[ -f $LIDSWITCH_HOME/lidswitch.log.2 ]] && echo true || echo false)" "de vorige rotatie blijft bewaard"
assert_eq true "$([[ $(stat -c %s "$LIDSWITCH_HOME/lidswitch.log") -le 500 ]] && echo true || echo false)" "het actieve log blijft klein"
assert_eq false "$([[ -f $LIDSWITCH_HOME/lidswitch.log.3 ]] && echo true || echo false)" "rotaties daarboven worden weggegooid"

echo "meldingen"
cat >"$STUB/notify-send" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LIDSWITCH_STUB_LOG:-/dev/null}"
exit 0
STUBEOF
chmod +x "$STUB/notify-send"
printf '{"notify":true}\n' >"$LIDSWITCH_CONFIG"
# Vaste beginstand: de vorige test liet het deksel dicht staan, en een overgang
# naar de stand die er al is hoort geen melding te geven.
printf '{"lid":"open","away":false,"clamshell":false,"awaySince":null,"changedAt":null,"updatedAt":"%s"}\n' \
  "$(date -Is)" >"$LIDSWITCH_HOME/lid.json"
: >"$WORK/notify.log"
LIDSWITCH_STUB_LOG="$WORK/notify.log" PATH="$STUB:$PATH" lidswitch lid closed >/dev/null
LIDSWITCH_STUB_LOG="$WORK/notify.log" PATH="$STUB:$PATH" lidswitch lid open >/dev/null
assert_eq 2 "$(grep -c lidswitch "$WORK/notify.log")" "bij overgangen gaat er een melding"

: >"$WORK/notify.log"
printf '{"lid":"closed","away":true,"clamshell":false,"awaySince":null,"changedAt":null,"updatedAt":"%s"}\n' \
  "$(date -Is)" >"$LIDSWITCH_HOME/lid.json"
LIDSWITCH_STUB_LOG="$WORK/notify.log" PATH="$STUB:$PATH" lidswitch lid closed >/dev/null
assert_eq 0 "$(grep -c lidswitch "$WORK/notify.log")" "een onveranderde stand geeft geen melding"

: >"$WORK/notify.log"
LIDSWITCH_QUIET=1 LIDSWITCH_STUB_LOG="$WORK/notify.log" PATH="$STUB:$PATH" lidswitch lid open >/dev/null
assert_eq 0 "$(grep -c lidswitch "$WORK/notify.log")" "LIDSWITCH_QUIET=1 dempt de meldingen"

echo
printf '%d geslaagd, %d mislukt\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
