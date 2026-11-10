// NFSU2 launcher window (adapted from ROTK's tools/launcher/launcher.js): game art, language
// (English default / Українська — text only, no voice), frame rate (30 / 60; 120 when a display can
// do it, ProMotion — a line says how to switch it on), gamma (Оригінал / Сучасна / Тепла), effects
// (SSAO + bloom on/off), Play / Quit. JXA + AppKit, run by Contents/MacOS/NFSU2 before the game:
//   osascript -l JavaScript launcher.js <settings.toml> [art.png]
// Play writes [launcher] language / fps / gamma / effects into settings.toml and prints "play";
// closing prints "quit". NFSU2_LAUNCHER_AUTO=play|quit answers without the window;
// NFSU2_LAUNCHER_SNAPSHOT=<png> draws it off screen; NFSU2_LAUNCHER_PAD_SCRIPT="up a" feeds gamepad
// presses; NFSU2_DISPLAY_HZ=cur,max fakes the display (tests). Gamepad: up/down picks a row,
// left/right changes it, A plays, B quits.
ObjC.import('AppKit');
ObjC.import('Foundation');
ObjC.import('GameController');

function readText(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? '' : s.js;
}
function writeText(path, text) {
  $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}
function getSetting(text, key, def) {
  const m = text.match(new RegExp('^\\s*' + key + '\\s*=\\s*"?([^"\\n]*)"?', 'm'));
  return m ? m[1].trim() : def;
}
function putSettings(text, kv) {
  let lines = text.split('\n');
  if (!lines.some(l => l.trim() === '[launcher]')) lines = ['[launcher]'].concat(lines);
  for (const k of Object.keys(kv)) {
    const line = k + ' = "' + kv[k] + '"';
    const i = lines.findIndex(l => new RegExp('^\\s*' + k + '\\s*=').test(l));
    if (i >= 0) lines[i] = line;
    else lines.splice(lines.findIndex(l => l.trim() === '[launcher]') + 1, 0, line);
  }
  return lines.join('\n').replace(/\n*$/, '\n');
}

function displayHz() {  // {cur, max}
  const env = $.NSProcessInfo.processInfo.environment.objectForKey('NFSU2_DISPLAY_HZ');
  if (!env.isNil()) {
    const [c, m] = env.js.split(',').map(v => parseInt(v, 10) || 60);
    return { cur: c, max: Math.max(c, m || c) };
  }
  let hz = 60;
  const screens = $.NSScreen.screens;
  for (let i = 0; i < screens.count; i++) {
    const s = screens.objectAtIndex(i);
    if (s.respondsToSelector('maximumFramesPerSecond')) hz = Math.max(hz, Number(s.maximumFramesPerSecond));
  }
  return { cur: hz, max: hz };
}
const GAMMAS = ['original', 'modern', 'warm'];

// Numbers from AppKit come back through the JXA bridge as strings ("1" !== 1, PIT-D02): the
// popups' selected index always goes through Number().
const sel = (popup) => Number(popup.indexOfSelectedItem);

function run(argv) {
  const settingsPath = argv[0], artPath = argv[1] || '';
  const text = readText(settingsPath);
  const dh = displayHz(), can120 = dh.max >= 120, hint = can120 && dh.cur < 120;
  // Owner 2026-11-07: no frame rate below 60 in the menu ("прибери менше 60 фпс").
  const FPS = can120 ? ['60', '120'] : ['60'];
  const g0 = getSetting(text, 'gamma', 'original');
  const DRAWS = ['1', '2'];   // v1.0.1 (Head 2026-11-07): draw distance 1/2, default 1
  const BLURS = ['off', 'on'];   // motion blur, off by default (owner 2026-11-10: "Додавай в лаунчер")
  const FXS = ['bloom', 'off'];   // SSAO left the menu with the sub-60 items (owner 2026-11-07)
  const st = {
    language: getSetting(text, 'language', 'en') === 'uk' ? 'uk' : 'en',
    fps: FPS.includes(getSetting(text, 'fps', '60')) ? getSetting(text, 'fps', '60') : '60',
    gamma: GAMMAS.includes(g0) ? g0 : 'original',
    // effects: bloom (default) / ssao (SSAO + bloom: over the 60 fps budget at 2.0x on an M1 Pro, owner
    // 2026-11-07 "залізні 60 fps") / off. The old "on" was the default, so it reads as the new default.
    effects: FXS.includes(getSetting(text, 'effects', 'bloom')) ? getSetting(text, 'effects', 'bloom') : 'bloom',
    // scenery draw distance x1 (original, default) / x2 (farther; over the 60 fps budget on some tracks at 4x)
    draw: DRAWS.includes(getSetting(text, 'draw', '1')) ? getSetting(text, 'draw', '1') : '1',
    blur: BLURS.includes(getSetting(text, 'blur', 'off')) ? getSetting(text, 'blur', 'off') : 'off',
  };
  const save = () => writeText(settingsPath, putSettings(text, st));
  const auto = $.NSProcessInfo.processInfo.environment.objectForKey('NFSU2_LAUNCHER_AUTO');
  if (!auto.isNil()) {
    if (auto.js === 'play') save();
    return auto.js === 'play' ? 'play' : 'quit';
  }

  const T = {
    uk: { lang: 'Мова', fps: 'Частота кадрів', gamma: 'Гамма', fx: 'Ефекти',
          gammas: ['Оригінал', 'Сучасна', 'Тепла'], fxs: ['Світіння', 'Вимкнено'],
          draw: 'Дальність промальовки', draws: ['×1 — оригінал', '×2 — далі, важче'],
          blur: 'Розмиття руху', blurs: ['Вимкнено', 'Увімкнено'],
          note: 'Українська — текст гри; озвучка англійська. Утримуйте A, щоб пропустити ролик.',
          hint: 'Для 120 fps увімкніть ProMotion: Системні параметри → Дисплеї → Частота оновлення.',
          play: 'Грати', quit: 'Вийти' },
    en: { lang: 'Language', fps: 'Frame rate', gamma: 'Gamma', fx: 'Effects',
          gammas: ['Original', 'Modern', 'Warm'], fxs: ['Bloom', 'Off'],
          draw: 'Draw distance', draws: ['×1 — original', '×2 — farther, heavier'],
          blur: 'Motion blur', blurs: ['Off', 'On'],
          note: 'Hold A to skip a movie.',
          hint: 'For 120 fps turn ProMotion on: System Settings → Displays → Refresh Rate.',
          play: 'Play', quit: 'Quit' },
  };
  const app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
  const W = 640, P = 252, H = 512 + P;  // art (the disc's title image, square-ish) above, controls below
  const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(
    $.NSMakeRect(0, 0, W, H), $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable,
    $.NSBackingStoreBuffered, false);
  win.title = 'Need for Speed Underground 2';
  win.center;
  const view = win.contentView;
  win.backgroundColor = $.NSColor.blackColor;  // (a CGColor through the JXA bridge kills osascript)

  let artInfo = 'art: none';
  if (artPath) {
    const img = $.NSImage.alloc.initWithContentsOfFile(artPath);
    if (!img.isNil()) {
      const iv = $.NSImageView.alloc.initWithFrame($.NSMakeRect(0, P, W, H - P));
      iv.image = img;
      iv.imageScaling = $.NSImageScaleProportionallyUpOrDown;  // never stretched
      view.addSubview(iv);
      artInfo = 'art: view ' + W + 'x' + (H - P) + ', image ' + img.size.width + 'x' + img.size.height;
    }
  }
  // bottom panel
  const panel = $.NSVisualEffectView.alloc.initWithFrame($.NSMakeRect(0, 0, W, P));
  panel.material = $.NSVisualEffectMaterialHUDWindow;
  panel.blendingMode = $.NSVisualEffectBlendingModeWithinWindow;
  panel.state = $.NSVisualEffectStateActive;
  view.addSubview(panel);

  const labels = [];
  const label = (x, y, w, h) => {
    const l = $.NSTextField.wrappingLabelWithString('');
    l.frame = $.NSMakeRect(x, y, w, h || 20);
    l.textColor = $.NSColor.whiteColor;
    panel.addSubview(l);
    labels.push(l);
    return l;
  };
  const popup = (x, y, items, i) => {
    const pu = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(x, y, 186, 26), false);
    pu.addItemsWithTitles($(items));
    pu.selectItemAtIndex(i);
    panel.addSubview(pu);
    return pu;
  };
  // two columns of rows: label above its popup
  const lLang = label(24, 228, 186), lFps = label(222, 228, 186);
  const pLang = popup(20, 200, ['Українська', 'English'], st.language === 'en' ? 1 : 0);
  const pFps = popup(218, 200, FPS.map(f => f + ' fps'), FPS.indexOf(st.fps));
  const lGamma = label(24, 172, 186), lFx = label(222, 172, 186);
  const pGamma = popup(20, 144, ['', '', ''], GAMMAS.indexOf(st.gamma));
  const pFx = popup(218, 144, FXS.map(() => ''), FXS.indexOf(st.effects));
  const lDraw = label(24, 116, 186);
  const pDraw = popup(20, 88, DRAWS.map(() => ''), DRAWS.indexOf(st.draw));
  const lBlur = label(222, 116, 186);
  const pBlur = popup(218, 88, BLURS.map(() => ''), BLURS.indexOf(st.blur));
  const lHint = label(24, 6, 400, 72);
  lHint.font = $.NSFont.systemFontOfSize(12);
  lHint.textColor = $.NSColor.colorWithWhiteAlpha(0.82, 1);

  // Buttons take the first click even while the window is not active (an inactive launcher window
  // swallowed the click on «Грати»: macOS 14 does not always let osascript become frontmost).
  ObjC.registerSubclass({
    name: 'Nfsu2Button', superclass: 'NSButton',
    methods: { 'acceptsFirstMouse:': { types: ['bool', ['id']], implementation: function () { return true; } } },
  });
  const bPlay = $.Nfsu2Button.buttonWithTitleTargetAction('', null, null);
  bPlay.frame = $.NSMakeRect(W - 212, 166, 190, 56);
  bPlay.bezelStyle = $.NSBezelStyleRegularSquare;
  bPlay.keyEquivalent = '\r';
  bPlay.font = $.NSFont.boldSystemFontOfSize(22);
  panel.addSubview(bPlay);
  const bQuit = $.Nfsu2Button.buttonWithTitleTargetAction('', null, null);
  bQuit.frame = $.NSMakeRect(W - 212, 126, 190, 28);
  bQuit.keyEquivalent = '\x1b';
  panel.addSubview(bQuit);

  const relabel = () => {
    const t = T[sel(pLang) === 1 ? 'en' : 'uk'];
    lLang.stringValue = t.lang;
    lFps.stringValue = t.fps;
    lGamma.stringValue = t.gamma;
    lFx.stringValue = t.fx;
    lDraw.stringValue = t.draw;
    t.draws.forEach((g, i) => pDraw.itemAtIndex(i).title = g);
    lBlur.stringValue = t.blur;
    t.blurs.forEach((g, i) => pBlur.itemAtIndex(i).title = g);
    t.gammas.forEach((g, i) => pGamma.itemAtIndex(i).title = g);
    t.fxs.forEach((g, i) => pFx.itemAtIndex(i).title = g);
    lHint.stringValue = t.note + (hint ? '\n' + t.hint : '');
    bPlay.title = t.play;
    bQuit.title = t.quit;
  };
  relabel();

  let choice = 'quit';
  // gamepad: rows of controls, the picked one is the first responder (focus ring)
  const rows = [pLang, pFps, pGamma, pFx, pDraw, pBlur, bPlay];
  let row = rows.length - 1;
  const pick = (r) => { row = Math.max(0, Math.min(rows.length - 1, r)); win.makeFirstResponder(rows[row]); };
  const press = (k) => {
    if (k === 'up') pick(row - 1);
    else if (k === 'down') pick(row + 1);
    else if ((k === 'left' || k === 'right') && row < rows.length - 1) {
      const pu = rows[row], n = Number(pu.numberOfItems);
      pu.selectItemAtIndex(Math.max(0, Math.min(n - 1, sel(pu) + (k === 'left' ? -1 : 1))));
      relabel();
    } else if (k === 'a') { choice = 'play'; app.stopModalWithCode(1); }
    else if (k === 'b') app.stopModalWithCode(0);
  };
  const env = $.NSProcessInfo.processInfo.environment;
  const scriptEnv = env.objectForKey('NFSU2_LAUNCHER_PAD_SCRIPT');
  const script = scriptEnv.isNil() ? null : scriptEnv.js.split(/\s+/).filter(Boolean);
  if ($.GCController.respondsToSelector('setShouldMonitorBackgroundEvents:')) $.GCController.shouldMonitorBackgroundEvents = true;
  const held = {};
  const tick = () => {
    if (script) { if (script.length) press(script.shift()); return; }
    const cs = $.GCController.controllers;
    const now = {};
    for (let i = 0; i < cs.count; i++) {
      const g = cs.objectAtIndex(i).extendedGamepad;
      if (g.isNil()) continue;
      const on = (b) => !b.isNil() && b.isPressed;
      if (on(g.buttonA)) now.a = 1;
      if (on(g.buttonB)) now.b = 1;
      if (on(g.dpad.up) || g.leftThumbstick.yAxis.value > 0.6) now.up = 1;
      if (on(g.dpad.down) || g.leftThumbstick.yAxis.value < -0.6) now.down = 1;
      if (on(g.dpad.left) || g.leftThumbstick.xAxis.value < -0.6) now.left = 1;
      if (on(g.dpad.right) || g.leftThumbstick.xAxis.value > 0.6) now.right = 1;
    }
    for (const k of ['up', 'down', 'left', 'right', 'b', 'a']) {
      if (now[k] && !held[k]) press(k);
      held[k] = now[k];
    }
  };
  // Controls report through one target; the modal session ends with Play (1) or Quit/close (0).
  ObjC.registerSubclass({
    name: 'Nfsu2LauncherTarget',
    methods: {
      'changed:': { types: ['void', ['id']], implementation: function () { relabel(); } },
      'tick:': { types: ['void', ['id']], implementation: function () { tick(); } },
      'play:': { types: ['void', ['id']], implementation: function () { choice = 'play'; app.stopModalWithCode(1); } },
      'quit:': { types: ['void', ['id']], implementation: function () { app.stopModalWithCode(0); } },
      'windowWillClose:': { types: ['void', ['id']], implementation: function () { app.stopModalWithCode(0); } },
    },
  });
  const tgt = $.Nfsu2LauncherTarget.alloc.init;
  for (const c of [pLang, pFps, pGamma, pFx, pDraw, pBlur]) { c.target = tgt; c.action = 'changed:'; }
  bPlay.target = tgt; bPlay.action = 'play:';
  bQuit.target = tgt; bQuit.action = 'quit:';
  win.delegate = tgt;

  // NFSU2_LAUNCHER_SNAPSHOT=<png>: draw the window off screen into a PNG and quit (tests)
  const snap = $.NSProcessInfo.processInfo.environment.objectForKey('NFSU2_LAUNCHER_SNAPSHOT');
  if (!snap.isNil()) {
    const rep = view.bitmapImageRepForCachingDisplayInRect(view.bounds);
    view.cacheDisplayInRectToBitmapImageRep(view.bounds, rep);
    rep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({})).writeToFileAtomically(snap.js, true);
    // a label is cut off when its text needs more height than its frame at the frame's width
    const clipped = labels.filter(l => !l.hidden && l.stringValue.js &&
      l.cell.cellSizeForBounds($.NSMakeRect(0, 0, l.frame.size.width, 10000)).height > l.frame.size.height + 0.5)
      .map(l => l.stringValue.js.slice(0, 24));
    const t = T[sel(pLang) === 1 ? 'en' : 'uk'];
    return ['snapshot', artInfo, 'language: ' + (sel(pLang) === 1 ? 'en' : 'uk'),
            'labels: ' + [t.lang, t.fps, t.gamma, t.fx, t.draw, t.blur, t.play, t.quit].join('|'), 'note: ' + t.note,
            'fps: ' + FPS.join(','), 'hint: ' + (hint ? 'yes' : 'no'), 'gamma: ' + t.gammas.join('|'), 'draw: ' + t.draws.join('|'), 'blur: ' + t.blurs.join('|'),
            'clipped: ' + (clipped.length ? clipped.join(' | ') : 'none')].join('\n');
  }
  app.activateIgnoringOtherApps(true);
  win.makeKeyAndOrderFront(null);
  pick(rows.length - 1);
  const timer = $.NSTimer.timerWithTimeIntervalTargetSelectorUserInfoRepeats(script ? 0.25 : 1 / 30, tgt, 'tick:', null, true);
  $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSRunLoopCommonModes);
  // The choice is kept in JS: runModalForWindow's NSModalResponse comes back through the JXA
  // bridge as a string ("1" !== 1 made every Play a quit, owner test 049f010).
  app.runModalForWindow(win);
  if (choice !== 'play') return 'quit';
  st.language = sel(pLang) === 1 ? 'en' : 'uk';
  st.fps = FPS[sel(pFps)] || '60';
  st.gamma = GAMMAS[sel(pGamma)] || 'original';
  st.effects = FXS[sel(pFx)] || 'bloom';
  st.draw = DRAWS[sel(pDraw)] || '1';
  st.blur = BLURS[sel(pBlur)] || 'off';
  save();
  win.orderOut(null);
  // macOS 14 cooperative activation: the game (Contents/MacOS/nfsu2-bin after execv) becomes the active
  // app only if this frontmost one yields to it (owner test dcb2fc2: pad dead in an unfocused game).
  const owner = $.NSProcessInfo.processInfo.environment.objectForKey('NFSU2_LAUNCHER_OWNER');
  if (!owner.isNil() && app.respondsToSelector('yieldActivationToApplication:')) {
    const ra = $.NSRunningApplication.runningApplicationWithProcessIdentifier(parseInt(owner.js, 10));
    if (!ra.isNil()) app.yieldActivationToApplication(ra);
  }
  return 'play';
}
