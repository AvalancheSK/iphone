# iPhone na MacBooku, ovládaný cez Claude Code

Pripojíš iPhone USB káblom k MacBooku a dostaneš:

- **živý obraz iPhonu** v prehliadači na MacBooku, ktorý vieš ovládať myšou
  (klik, potiahnutie, koliesko, písanie, tlačidlá),
- **Claude Code, ktorý iPhone ovláda sám**: robí screenshoty, číta prvky na obrazovke,
  ťuká, píše, posúva a spúšťa aplikácie. Stačí mu napísať, čo má urobiť.

```
Claude Code ──MCP──▶ mobile-mcp ──┐
                                  ├──▶ go-ios (tunel + porty 8100/9100) ──USB──▶ WebDriverAgent na iPhone
Prehliadač ◀── viewer (port 8200)─┘
```

> **Prečo nie Apple „iPhone Mirroring“?** Apple túto funkciu v EÚ (teda ani na Slovensku)
> stále neponúka. Navyše sa ňou nedá programovo ovládať iPhone. Toto riešenie používa
> [WebDriverAgent](https://github.com/appium/WebDriverAgent) (Appium) a
> [mobile-mcp](https://github.com/mobile-next/mobile-mcp). Funguje v EÚ a stačí naň
> bezplatný Apple ID.

## Čo potrebuješ

- MacBook s macOS a **Xcode** (zadarmo v App Store; raz ho spusti, nech dokončí inštaláciu),
- **Node.js 20+** (ak ho nemáš a máš [Homebrew](https://brew.sh), setup ho nainštaluje sám),
- **Claude Code** ([inštalácia](https://code.claude.com/docs)),
- iPhone a USB kábel,
- **Apple ID** prihlásené v Xcode (stačí bezplatné):
  Xcode → Settings → Accounts → **+** → Apple ID. Potom vyber svoj tím
  (Personal Team) → **Manage Certificates…** → **+** → **Apple Development**.

## Inštalácia (iba raz)

```bash
git clone https://github.com/avalanchesk/iphone.git
cd iphone
./scripts/setup.sh
```

Setup skontroluje nástroje, nainštaluje [go-ios](https://github.com/danielpaulus/go-ios),
stiahne a podpíše WebDriverAgent svojím Apple ID, nájde iPhone a všetko uloží do
`config.env`. Keď sa niečo pokazí, napíše, čo urobiť, a môžeš ho spustiť znova.

Na iPhone ešte raz:

1. **Režim vývojára**: Nastavenia → Súkromie a bezpečnosť → Režim vývojára → zapnúť
   (iPhone sa reštartuje). Ak túto položku nevidíš, spusti setup; zobrazí ju.
2. Po prvom `./scripts/start.sh`: Nastavenia → Všeobecné → **Správa VPN a zariadení** →
   Apple Development → **Dôverovať**. Potom spusti `./scripts/start.sh` znova.
3. Nastavenia → **Vývojár** → **Enable UI Automation** → zapnúť.

## Každodenné použitie

```bash
./scripts/start.sh     # spustí všetko a otvorí náhľad iPhonu v prehliadači
claude                 # Claude Code spusti v tomto priečinku
```

Pri prvom spustení sa Claude Code opýta, či povoliť MCP server `mobile-mcp`. Potvrď.
Potom mu napíš napríklad:

- „Odfoť obrazovku iPhonu a povedz mi, čo na nej je.“
- „Otvor Safari a nájdi zajtrajšie počasie v Bratislave.“
- „Otvor Nastavenia a zisti, koľko voľného miesta má iPhone.“
- „Prejdi v Poznámkach na poslednú poznámku a prečítaj mi ju.“

Hotovo? `./scripts/stop.sh`. Stav jednotlivých častí ukáže `./scripts/status.sh`.

iPhone nechaj počas práce odomknutý a pripojený káblom.

### Náhľad v prehliadači (http://127.0.0.1:8200)

| Akcia na MacBooku | Čo spraví na iPhone |
| --- | --- |
| klik | ťuknutie |
| podržanie myši | dlhé stlačenie |
| potiahnutie myšou | swipe |
| koliesko myši | posun hore alebo dole |
| textové pole + **Napísať** | napíše text do aktívneho poľa |
| tlačidlá pod obrazom | Domov, Zamknúť, Zobudiť, Hlasitosť |

Server náhľadu počúva iba na `127.0.0.1` a odmieta požiadavky z iných webových stránok.

### Iné spôsoby, ako vidieť obrazovku

- **QuickTime Player**: Súbor → Nový videozáznam → pri tlačidle nahrávania vyber
  svoj iPhone. Ukazuje obraz cez kábel, ovládať sa ním však nedá.
- **`/mobile-mirror`** priamo v Claude Code: nainštaluj plugin
  (`/plugin marketplace add mobile-next/mobile-mcp`, potom
  `/plugin install mobile-mcp@mobile-mcp`). Potrebuje terminál kitty alebo Ghostty.

## Povolenia v Claude Code

`.claude/settings.json` povoľuje bez pýtania iba **čítanie** (screenshot, zoznam prvkov,
zoznam aplikácií, stav). Pred každým ťuknutím, písaním alebo spustením aplikácie sa
Claude Code opýta. Ak chceš, aby sa už nepýtal, zvoľ pri otázke
„Yes, and don't ask again“, alebo pridaj do `.claude/settings.local.json`:

```json
{ "permissions": { "allow": ["mcp__mobile-mcp"] } }
```

`CLAUDE.md` Claudovi zakazuje platiť, odosielať správy, mazať dáta či zadávať heslá
bez tvojho výslovného súhlasu.

## Riešenie problémov

Logy sú v `.run/logs/` (`build.log`, `wda.log`, `tunnel.log`, `forward.log`, `viewer.log`).

| Problém | Riešenie |
| --- | --- |
| `Nevidím žiadny iPhone` | Kábel, odomknutý iPhone, „Dôverovať tomuto počítaču“. Pomôže aj `ios pair`. |
| `Chýba plný Xcode` | Nainštaluj Xcode a spusti `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| `Nenašiel som Apple Development certifikát` | Pozri „Čo potrebuješ“: Apple ID a certifikát v Xcode. |
| Untrusted Developer / `invalid code signature` | iPhone → Nastavenia → Všeobecné → Správa VPN a zariadení → Dôverovať. |
| `Enable UI Automation` / `automation mode` | iPhone → Nastavenia → Vývojár → Enable UI Automation. |
| Bundle ID je obsadené | Zmaž riadok `WDA_BUNDLE_ID` v `config.env` a spusti setup znova. |
| `maximum number of apps` | Bezplatný Apple ID dovolí max. 3 vlastné testovacie appky. Zmaž staré. |
| Po 7 dňoch prestane fungovať | Bezplatný podpis platí 7 dní. `./scripts/start.sh` ho pri štarte obnoví; ak nie, spusti `./scripts/setup.sh`. |
| `mobile-mcp`: „iOS tunnel is not running“ | `./scripts/start.sh` (tunel beží na porte 60105). |
| Claude nevidí nástroje `mobile_*` | Spusti `claude` v tomto priečinku a v `/mcp` povoľ `mobile-mcp`. |
| Viac iPhonov | `DEVICE_UDID=<udid> ./scripts/setup.sh` |

## Štruktúra

```
scripts/setup.sh    jednorazová príprava (nástroje, WebDriverAgent, podpis, config.env)
scripts/start.sh    spustí tunel, porty, WebDriverAgent a náhľad (dá sa spúšťať opakovane)
scripts/stop.sh     všetko zastaví
scripts/status.sh   stav jednotlivých vrstiev (návratový kód 0 = pripravené)
viewer/             náhľad a ovládanie v prehliadači (Python, iba štandardná knižnica)
.mcp.json           MCP server mobile-mcp pre Claude Code
CLAUDE.md           pokyny pre Clauda, ako iPhone bezpečne ovládať
tests/              testy servera náhľadu: python3 -m unittest discover -s tests
```
