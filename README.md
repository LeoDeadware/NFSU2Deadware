# NFSU2 for Mac

*Need for Speed: Underground 2* (original Xbox), running natively on macOS: Apple silicon (M1 and newer), macOS 26 or later.
You need your own copy of the game: this repository and the DMG contain **no game data and no game code**
(only our tools, our patches and the HD texture pack).
[Українською нижче.](#українською)

## Install
1. Download `NFSU2-players.dmg` from [Releases](../../releases), open it and drag **NFSU2** to Applications.
2. The app is not signed by Apple: the first time, **right-click NFSU2 → Open → Open** (Gatekeeper).
3. Pick your own disc image (Xbox, `.iso`, USA) when asked. NFSU2 imports it to
   `~/Library/Application Support/NFSU2/data`, then builds the game from your disc on your Mac with Apple's
   Command Line Tools (macOS offers to install them if they are missing). This takes a few minutes, once;
   the ready `NFSU2.app` is put on the Desktop.
4. The launcher opens: choose the **language**, the frame rate, the gamma, the effects, the draw distance
   and the motion blur, then **Play**. Your choice is remembered.

**Two versions in one app:** the English version (the original text) and the Ukrainian version (all menus
and in-game text translated by us; the voices stay original). Pick English or Українська in the launcher.

What the port adds: 60 fps (120 on ProMotion displays), 16:10 full screen without black bars, 4x render
scale, anisotropic filtering, anti-aliasing, car reflections, HD textures (ours plus community packs, see
credits), a farther car draw distance. Controls: a gamepad only (Xbox, PlayStation or another MFi
controller). Discs: the US (NTSC) disc is tested; EU (PAL): untested.

## Building from source
```
tools/fetch_community.sh            # the community base (myUdav4iik/nfsu2-ios @ 85d2cbf) + patches/ -> community/
# your extracted disc in game/extracted (default.xbe, NFSUNDER/...); a Python venv with capstone in work/nfsu2-venv
NFSU2_XBE=game/extracted/default.xbe NFSU2_GEN_DIR=$PWD/community/gen community/tools/regen.sh   # lift (minutes)
./BUILD_NATIVE.sh                   # Metal build: community/build-metal/nfsu2_recomp (-j2; JOBS=n)
tools/install_app.sh community/build-metal && tools/app_smoke.sh
tools/make_dmg.sh players           # the players' DMG: no game data, no game code
python3 tools/loc_nfsu2/build_uk.py --inc-only   # Ukrainian text: tools/loc_nfsu2/uk.tsv -> community/src/text_uk.inc
```

## Credits and licences
- Our code (tools, launcher, patches in `patches/`) — MIT, see `LICENSE`.
- The port is built on the community work this repository does not copy: **nfsu2-sw** by Anton Artemov
  (antoxa2584x; the Xbox recompilation of NFSU2) and **nfsu2-ios** by myUdav4iik (Apple host), fetched by
  `tools/fetch_community.sh` from their repositories. Thank you!
- **xboxrecomp** (MIT, sp00nz) runtime; APU code derived from **xemu** (LGPL-2.1); **SDL3 / sdl2-compat**
  (zlib); **Capstone** (BSD).
- Community HD textures (NFSU2 PC mods mapped onto the Xbox textures): instanity (Remastered Underground 2),
  Awesome Mods (Redux HD Textures, Next-Gen Textures, 8K Realistic Night Skyboxes), QTmodz (Project
  Revitalized) — [nexusmods.com/needforspeedunderground2](https://www.nexusmods.com/needforspeedunderground2);
  details in `docs/COMMUNITY_ASSETS.md`.
- Any author or rights holder may ask us to remove their work: we do it within 24 hours (open an issue).

Unofficial fan project, not affiliated with or endorsed by Electronic Arts or Microsoft.
Need for Speed and Underground are trademarks of Electronic Arts.

---

## Українською

*Need for Speed: Underground 2* (оригінальний Xbox) нативно на macOS: Apple Silicon (M1 і новіші), macOS 26 і новіші.
Потрібна ваша власна копія гри: у цьому репозиторії й у DMG **немає ні даних, ні коду гри** (лише наші
інструменти, наші патчі й HD-пак текстур).

### Встановлення
1. Завантажте `NFSU2-players.dmg` з [Releases](../../releases), відкрийте й перетягніть **NFSU2** у «Програми».
2. Застосунок не підписаний Apple: першого разу **правий клік на NFSU2 → Відкрити → Відкрити** (Gatekeeper).
3. Оберіть образ свого диска (Xbox, `.iso`, США). NFSU2 імпортує його в `~/Library/Application Support/NFSU2/data`
   і збирає гру з вашого диска на вашому Mac інструментами Apple Command Line Tools (якщо їх нема, macOS
   запропонує встановити). Це кілька хвилин, один раз; готова `NFSU2.app` з'являється на робочому столі.
4. Відкриється лаунчер: оберіть **мову**, частоту кадрів, гаму, ефекти, дальність промальовки й розмиття
   руху, тоді **Грати**. Вибір запам'ятовується.

**Дві версії в одному застосунку:** англійська версія (оригінальний текст) і українська версія (усі меню й
текст у грі — наш переклад; озвучка оригінальна). Оберіть English або Українська в лаунчері.

Що додає порт: 60 fps (120 на дисплеях ProMotion), 16:10 на весь екран без чорних смуг, рендер 4x,
анізотропна фільтрація, згладжування, відбиття на авто, HD-текстури (наші й паки спільноти, див. подяки),
більша дальність промальовки авто. Керування: лише геймпад (Xbox, PlayStation або інший MFi). Диски:
американський (NTSC) перевірено; європейський (PAL) — не перевірено.

### Подяки
Порт зроблено на основі праці спільноти, яку цей репозиторій не копіює: **nfsu2-sw** (Anton Artemov,
рекомпіляція Xbox-версії) і **nfsu2-ios** (myUdav4iik, хост для Apple); `tools/fetch_community.sh` бере їх
з їхніх репозиторіїв. HD-текстури спільноти — instanity, Awesome Mods, QTmodz (Nexus Mods). Наш код — MIT.
Автор чи правовласник може попросити прибрати свою роботу — приберемо за 24 години (відкрийте issue).

Неофіційний фанатський проєкт, не пов'язаний з Electronic Arts чи Microsoft.
