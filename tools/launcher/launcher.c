// NFSU2.app's CFBundleExecutable (tools/install_app.sh; RULES R-I5, ROTK's launcher as the model).
// A bash script as a bundle's executable cannot read the app's files when the app is opened from
// Finder under ~/Desktop (macOS privacy, TCC). This Mach-O sets the environment, then execv()s the
// game (Contents/MacOS/nfsu2-bin) in the same process:
//   - player files in NFSU2_PLAYER_ROOT (baked at install: NFSU2Port/.cache/player), else
//     ~/Library/Application Support/NFSU2/player: HOME=<root>/home, saves XDG_DATA_HOME=<root>/saves
//     (the kernel's partitions: <saves>/xboxrecomp), XDG_CACHE_HOME=<root>/cache (shader cache),
//     the log <root>/logs/nfsu2.log, rotated to .1-.5 on every start (PIT-never-kill-running-game);
//   - game data: Contents/Resources/game/extracted, else <root>/../data/game/extracted (the DMG build:
//     the first run asks for the player's own disc image and imports it, Resources/import);
//   - no game code in the DMG: the first run lifts and compiles the player's default.xbe with Apple
//     Command Line Tools (Resources/build/build_game.sh) into ~/Desktop/NFSU2.app;
//   - the launcher window (Resources/launcher/launcher.js): language (English default, Українська —
//     text only, no voice), fps 30/60/120, gamma, effects and Play; settings.toml [launcher]
//     language / fps / gamma / effects / draw -> NFSU2_LANG, NFSU2_FPS_CAP, NFSU2_GAMMA, NFSU2_AO + NFSU2_BLOOM,
//     NFSU2_DRAW_DISTANCE;
//   - defaults (each only if not set): Metal, full screen, gamepad only (NFSU2_KEYBOARD=0, owner
//     2026-11-06: Xbox ports are gamepad only), fps log.
// Every variable already in the environment wins (open --env, tests). NFSU2_NO_UI=1: no windows.
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <sys/wait.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <unistd.h>

#ifndef NFSU2_PLAYER_ROOT
#define NFSU2_PLAYER_ROOT ""
#endif

static void mkdirs(const char* path) {
  char p[PATH_MAX];
  snprintf(p, sizeof p, "%s", path);
  for (char* s = p + 1; *s; s++)
    if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
  mkdir(p, 0755);
}
static void setdef(const char* k, const char* v) { setenv(k, v, 0); }
static int exists(const char* p) { struct stat st; return stat(p, &st) == 0; }

static char real_home[PATH_MAX] = "/tmp";

// settings.toml [launcher] <key> = "value"; 0 if absent.
static int read_setting(const char* file, const char* key, char* out, size_t n) {
  FILE* f = fopen(file, "r");
  if (!f) return 0;
  char line[512];
  int in = 0, found = 0;
  size_t kl = strlen(key);
  while (fgets(line, sizeof line, f)) {
    char* s = line;
    while (*s == ' ' || *s == '\t') s++;
    if (*s == '[') { in = strncmp(s, "[launcher]", 10) == 0; continue; }
    if (!in || strncmp(s, key, kl) || (s[kl] != ' ' && s[kl] != '=')) continue;
    char* v = strchr(s, '=');
    if (!v) continue;
    v++;
    while (*v == ' ' || *v == '"') v++;
    size_t i = 0;
    while (v[i] && v[i] != '"' && v[i] != ' ' && v[i] != '#' && v[i] != '\n' && i + 1 < n) out[i] = v[i], i++;
    out[i] = 0;
    found = 1;
  }
  fclose(f);
  return found;
}

static int ui_uk = 0;
#define TR(en, uk) (ui_uk ? (uk) : (en))

static void alert(const char* msg) {
  printf("launcher: alert: %s\n", msg);
  fflush(stdout);
  if (getenv("NFSU2_NO_UI")) return;
  char cmd[1024];
  snprintf(cmd, sizeof cmd, "/usr/bin/osascript -e 'display alert \"Need for Speed Underground 2\" message \"%s\"' >/dev/null 2>&1", msg);
  system(cmd);
}

// nfsu2.log -> nfsu2.log.1 ... .5 (the previous run's evidence survives the next start).
static void rotate(const char* log) {
  char a[PATH_MAX], b[PATH_MAX];
  for (int i = 5; i >= 1; i--) {
    snprintf(b, sizeof b, "%s.%d", log, i);
    if (i == 1) snprintf(a, sizeof a, "%s", log); else snprintf(a, sizeof a, "%s.%d", log, i - 1);
    rename(a, b);
  }
}

// DMG first run: copy this bundle to the target app, build the game code there (build_game.sh).
static int build_game(const char* res, const char* data, const char* target) {
  char cmd[PATH_MAX * 4], prog[PATH_MAX], self[PATH_MAX], work[PATH_MAX];
  snprintf(self, sizeof self, "%s/..", res);
  snprintf(cmd, sizeof cmd, "/bin/rm -rf '%s' && /usr/bin/ditto '%s/..' '%s' && /bin/rm -rf '%s/Contents/Resources/build' "
           "'%s/Contents/Resources/import'", target, self, target, target, target);
  if (system(cmd) != 0) { alert(TR("Could not create NFSU2.app.", "Не вдалося створити NFSU2.app.")); return 1; }
  snprintf(prog, sizeof prog, "%s/build-progress.txt", data);
  unlink(prog);
  snprintf(work, sizeof work, "%s/build-work", data);
  setdef("NFSU2_BUILD_WORK", work);
  if (!getenv("NFSU2_NO_UI")) {
    snprintf(cmd, sizeof cmd, "/usr/bin/osascript -l JavaScript '%s/build/progress.js' '%s' >/dev/null 2>&1 &", res, prog);
    system(cmd);
  }
  printf("launcher: building the game code -> %s\n", target);
  fflush(stdout);
  snprintf(cmd, sizeof cmd, "/bin/bash '%s/build/build_game.sh' '%s/build' '%s/game/extracted' '%s' '%s'",
           res, res, data, target, prog);
  if (system(cmd) != 0) {
    char msg[512] = "", line[512], a[700];
    FILE* f = fopen(prog, "r");
    while (f && fgets(line, sizeof line, f)) snprintf(msg, sizeof msg, "%s", line);
    if (f) fclose(f);
    msg[strcspn(msg, "\n\"'")] = 0;
    snprintf(a, sizeof a, TR("Build failed: %s", "Гру не зібрано: %s"), *msg ? msg : "?");
    alert(a);
    return 1;
  }
  snprintf(cmd, sizeof cmd, "/usr/bin/codesign --force --deep -s - '%s' >/dev/null 2>&1", target);
  system(cmd);
  return 0;
}

// DMG first run: the player's own disc image -> <data>/game/extracted.
static int import_disc(const char* res, const char* data) {
  char iso[PATH_MAX] = "", cmd[PATH_MAX * 3];
  if (getenv("NFSU2_IMPORT_ISO")) snprintf(iso, sizeof iso, "%s", getenv("NFSU2_IMPORT_ISO"));
  else {
    snprintf(cmd, sizeof cmd, "/usr/bin/osascript -e 'POSIX path of (choose file with prompt \"%s\")'",
             TR("Choose your Need for Speed Underground 2 disc image (Xbox, .iso)",
                "Оберіть образ диска Need for Speed Underground 2 (Xbox, .iso)"));
    FILE* p = popen(cmd, "r");
    if (p) { if (!fgets(iso, sizeof iso, p)) iso[0] = 0; pclose(p); }
    iso[strcspn(iso, "\n")] = 0;
  }
  if (!*iso) return 1;
  mkdirs(data);
  printf("launcher: importing the disc %s -> %s\n", iso, data);
  fflush(stdout);
  snprintf(cmd, sizeof cmd, "/usr/bin/python3 -I '%s/import/import_disc.py' '%s' '%s'", res, iso, data);
  int rc = system(cmd);
  rc = rc == -1 ? -1 : WEXITSTATUS(rc);
  if (rc == 5) {
    alert(TR("This is another edition of Need for Speed Underground 2 (Europe/PAL or Japan). It is not tested: the port runs the USA Xbox disc only.",
             "Це інше видання Need for Speed Underground 2 (Європа/PAL або Японія). Його не перевірено: порт працює лише з диском Xbox для США (USA)."));
    return 1;
  }
  if (rc != 0) {
    alert(TR("Disc import failed: this is not the Need for Speed Underground 2 (USA) Xbox disc, or python3 is missing.",
             "Не вдалося імпортувати диск: це не диск Need for Speed Underground 2 (USA) для Xbox або немає python3."));
    return 1;
  }
  return 0;
}

// The game writes its saves under partition1 (= the game dir): UDATA/TDATA. Under LaunchServices an
// unsigned app may not create files inside its own bundle on ~/Desktop (open() blocks), so the game runs
// from <root>/game: symlinks to the read-only disc files, real UDATA/TDATA seeded once from the disc.
static int overlay_game(const char* src, const char* dst) {
  char a[PATH_MAX], b[PATH_MAX], cmd[PATH_MAX * 3];
  mkdirs(dst);
  DIR* d = opendir(src);
  if (!d) return -1;
  struct dirent* e;
  while ((e = readdir(d))) {
    if (e->d_name[0] == '.') continue;
    snprintf(a, sizeof a, "%s/%s", src, e->d_name);
    snprintf(b, sizeof b, "%s/%s", dst, e->d_name);
    int save = !strcmp(e->d_name, "UDATA") || !strcmp(e->d_name, "TDATA");
    struct stat st;
    if (save) {
      if (lstat(b, &st) == 0 && S_ISDIR(st.st_mode)) continue;
      unlink(b);
      snprintf(cmd, sizeof cmd, "/bin/cp -R '%s' '%s'", a, b);
      if (system(cmd) != 0) mkdirs(b);
    } else {
      char cur[PATH_MAX];
      ssize_t n = readlink(b, cur, sizeof cur - 1);
      if (n > 0) { cur[n] = 0; if (!strcmp(cur, a)) continue; }
      unlink(b);
      if (symlink(a, b) != 0) { closedir(d); return -1; }
    }
  }
  closedir(d);
  snprintf(b, sizeof b, "%s/UDATA", dst); mkdirs(b);
  snprintf(b, sizeof b, "%s/TDATA", dst); mkdirs(b);
  return 0;
}

int main(int argc, char** argv) {
  char exe[PATH_MAX], real[PATH_MAX], here[PATH_MAX];
  uint32_t sz = sizeof exe;
  if (_NSGetExecutablePath(exe, &sz) != 0 || !realpath(exe, real)) return 70;
  snprintf(here, sizeof here, "%s", dirname(real));  // .../NFSU2.app/Contents/MacOS

  char root[PATH_MAX] = NFSU2_PLAYER_ROOT, parent[PATH_MAX];
  if (getenv("NFSU2_PLAYER_ROOT")) snprintf(root, sizeof root, "%s", getenv("NFSU2_PLAYER_ROOT"));
  snprintf(parent, sizeof parent, "%s", root);
  const char* h0 = getenv("HOME");
  if (h0) snprintf(real_home, sizeof real_home, "%s", h0);
  if (getenv("NFSU2_PLAYER_ROOT") && *root) mkdirs(root);  // an explicit folder (tests) is created
  if (!*root || !exists(dirname(parent)))  // baked folder gone (another Mac): the user library
    snprintf(root, sizeof root, "%s/Library/Application Support/NFSU2/player", real_home);

  char home[PATH_MAX], logs[PATH_MAX], log[PATH_MAX], buf[PATH_MAX];
  int fd = -1, denied = 0;
  for (int attempt = 0; attempt < 2 && fd < 0; attempt++) {
    if (attempt) {  // TCC may refuse the baked folder under ~/Desktop: the user library then
      denied = errno;
      snprintf(root, sizeof root, "%s/Library/Application Support/NFSU2/player", real_home);
    }
    snprintf(home, sizeof home, "%s/home", root);
    snprintf(logs, sizeof logs, "%s/logs", root);
    mkdirs(home);
    mkdirs(logs);
    snprintf(log, sizeof log, "%s/nfsu2.log", logs);
    rotate(log);
    fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  }
  setenv("HOME", home, 1);
  snprintf(buf, sizeof buf, "%s/saves", root); mkdirs(buf); setdef("XDG_DATA_HOME", buf);
  snprintf(buf, sizeof buf, "%s/cache", root); mkdirs(buf); setdef("XDG_CACHE_HOME", buf);
  setdef("NFSU2_LOG_DIR", logs);
  if (fd >= 0) {
    time_t t = time(NULL);
    dprintf(fd, "=== %s", ctime(&t));
    dprintf(fd, "launcher: %s, player files %s\n", real, root);
    if (denied) dprintf(fd, "launcher: baked player folder refused (%s): user library used\n", strerror(denied));
    dup2(fd, 1);
    dup2(fd, 2);
    close(fd);
  }
  char settings[PATH_MAX], lang[16] = "en";
  snprintf(settings, sizeof settings, "%s/settings.toml", home);
  if (getenv("NFSU2_LANG") && *getenv("NFSU2_LANG")) snprintf(lang, sizeof lang, "%s", getenv("NFSU2_LANG"));
  else read_setting(settings, "language", lang, sizeof lang);
  ui_uk = strcmp(lang, "uk") == 0;
  setenv("NFSU2_UI_LANG", ui_uk ? "uk" : "en", 1);

  // game data: in the bundle (the owner's install) or imported from the player's disc (DMG)
  char res[PATH_MAX], data[PATH_MAX];
  snprintf(res, sizeof res, "%s/../Resources", here);
  snprintf(data, sizeof data, "%s", res);
  snprintf(buf, sizeof buf, "%s/game/extracted/default.xbe", res);
  if (!getenv("NFSU2_GAME_DIR") && !exists(buf)) {
    snprintf(parent, sizeof parent, "%s", root);
    if (getenv("NFSU2_DATA_DIR")) snprintf(data, sizeof data, "%s", getenv("NFSU2_DATA_DIR"));
    else snprintf(data, sizeof data, "%s/data", dirname(parent));
    snprintf(buf, sizeof buf, "%s/game/extracted/default.xbe", data);
    if (!exists(buf)) {
      snprintf(buf, sizeof buf, "%s/build/clt.sh", res);
      if (exists(buf)) {
        char clt[PATH_MAX + 32];
        snprintf(clt, sizeof clt, "/bin/bash '%s'", buf);
        if (system(clt) != 0) {
          alert(TR("Command Line Tools are not installed (xcode-select --install).",
                   "Command Line Tools не встановлено (xcode-select --install)."));
          return 74;
        }
      }
      if (import_disc(res, data) != 0) return 72;
    }
  }
  if (!getenv("NFSU2_GAME_DIR")) {
    char src[PATH_MAX], ov[PATH_MAX];
    snprintf(buf, sizeof buf, "%s/game/extracted", data);
    if (!realpath(buf, src)) snprintf(src, sizeof src, "%s", buf);
    snprintf(ov, sizeof ov, "%s/game", root);
    setenv("NFSU2_GAME_DIR", overlay_game(src, ov) == 0 ? ov : src, 1);
  }

  // the launcher window: language, Play (not in test runs unless NFSU2_LAUNCHER_AUTO answers it)
  const char* lw = getenv("NFSU2_LAUNCHER");
  int ui = !getenv("NFSU2_NO_UI");
  if ((!lw || strcmp(lw, "0") != 0) && (ui || getenv("NFSU2_LAUNCHER_AUTO"))) {
    char js[PATH_MAX], art[PATH_MAX], cmd[PATH_MAX * 4], ans[64] = "", me[16];
    snprintf(js, sizeof js, "%s/../Resources/launcher/launcher.js", here);
    snprintf(art, sizeof art, "%s/../Resources/launcher/art.png", here);
    snprintf(me, sizeof me, "%d", (int)getpid());
    setenv("NFSU2_LAUNCHER_OWNER", me, 1);
    if (exists(js)) {
      snprintf(cmd, sizeof cmd, "/usr/bin/osascript -l JavaScript '%s' '%s' '%s'", js, settings, exists(art) ? art : "");
      FILE* p = popen(cmd, "r");
      if (p) { if (!fgets(ans, sizeof ans, p)) ans[0] = 0; pclose(p); }
      ans[strcspn(ans, "\n")] = 0;
      printf("launcher: window -> %s\n", *ans ? ans : "(no answer: play)");
      fflush(stdout);
      if (strcmp(ans, "quit") == 0) return 0;
      if (!(getenv("NFSU2_LANG") && *getenv("NFSU2_LANG"))) read_setting(settings, "language", lang, sizeof lang);
    }
  }
  if (strcmp(lang, "uk") != 0) snprintf(lang, sizeof lang, "en");
  ui_uk = strcmp(lang, "uk") == 0;
  setenv("NFSU2_LANG", lang, 1);
  setenv("NFSU2_UI_LANG", lang, 1);
  // launcher choices -> the game's env (an env set by hand wins)
  char fps[8] = "60", gamma[16] = "original", fx[8] = "bloom";
  read_setting(settings, "fps", fps, sizeof fps);
  read_setting(settings, "gamma", gamma, sizeof gamma);
  read_setting(settings, "effects", fx, sizeof fx);
  char draw[8] = "1";
  read_setting(settings, "draw", draw, sizeof draw);
  if (strcmp(draw, "2")) snprintf(draw, sizeof draw, "1");
  char blur[8] = "off";
  read_setting(settings, "blur", blur, sizeof blur);
  if (strcmp(fps, "30") && strcmp(fps, "120")) snprintf(fps, sizeof fps, "60");
  if (strcmp(gamma, "modern") && strcmp(gamma, "warm")) snprintf(gamma, sizeof gamma, "original");
  setdef("NFSU2_FPS_CAP", fps);
  setdef("NFSU2_GAMMA", gamma);
  // effects: bloom (default) / ssao / off; SSAO is over the 60 fps budget at 2.0x (owner 2026-11-07)
  setdef("NFSU2_AO", strcmp(fx, "ssao") ? "0" : "1");
  setdef("NFSU2_BLOOM", strcmp(fx, "off") ? "0.35" : "0");
  setdef("NFSU2_DRAW_DISTANCE", draw);   // scenery draw distance x1 (default) / x2 (v1.0.1)
  setdef("NFSU2_BLUR_OFF", strcmp(blur, "on") ? "1" : "0");   // motion blur: off by default (owner 2026-11-10)
  setdef("NFSU2_RENDERER", "metal");
  setdef("NFSU2_FULLSCREEN", "1");
  setdef("NFSU2_KEYBOARD", "0");
  setdef("RECOMP_FPS_LOG", "1");
  printf("launcher: language %s, fps %s, gamma %s, effects %s, draw x%s, blur %s, game %s, renderer %s, fullscreen %s\n", lang,
         getenv("NFSU2_FPS_CAP"), getenv("NFSU2_GAMMA"), strcmp(getenv("NFSU2_AO"), "0") ? "ssao" : strcmp(getenv("NFSU2_BLOOM"), "0") ? "bloom" : "off", getenv("NFSU2_DRAW_DISTANCE"), strcmp(getenv("NFSU2_BLUR_OFF"), "0") ? "off" : "on",
         getenv("NFSU2_GAME_DIR"), getenv("NFSU2_RENDERER"), getenv("NFSU2_FULLSCREEN"));
  fflush(stdout);

  char game[PATH_MAX];
  snprintf(game, sizeof game, "%s/nfsu2-bin", here);
  snprintf(buf, sizeof buf, "%s/../Resources/build/build_game.sh", here);
  if (!exists(game) && exists(buf)) {  // the DMG installer: no game code inside
    char target[PATH_MAX];
    if (getenv("NFSU2_INSTALL_APP")) snprintf(target, sizeof target, "%s", getenv("NFSU2_INSTALL_APP"));
    else snprintf(target, sizeof target, "%s/Desktop/NFSU2.app", real_home);
    snprintf(game, sizeof game, "%s/Contents/MacOS/nfsu2-bin", target);
    if (!exists(game) && build_game(res, data, target) != 0) return 73;
  }
  if (chdir(logs) != 0) { /* the game writes nothing relative; logs is a safe cwd */ }
  argv[0] = game;
  execv(game, argv);
  fprintf(stderr, "launcher: cannot start %s: %s\n", game, strerror(errno));
  alert(TR("The game could not start (see the log).", "Гру не вдалося запустити (див. лог)."));
  return 71;
}
