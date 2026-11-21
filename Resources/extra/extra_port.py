import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

FONTS_MAIN = ';(function(){\nvar M="__cdbFonts";\nif(globalThis[M])return;\nif(typeof process==="undefined")return;\nvar electron=require("electron"),fs=require("fs"),path=require("path");\nvar DEFAULTS={ui:"",code:""};\nvar UI_TAIL=\'"Anthropic Sans",sans-serif\';\nvar CODE_TAIL=\'"Anthropic Mono",ui-monospace,SFMono-Regular,Menlo,monospace\';\nvar UI_SELECTORS=\'html,body,body :is(p,h1,h2,h3,h4,h5,h6,li,blockquote,td,th,label,button,input,textarea,select,option,[class~="font-sans"],[class~="font-serif"],[class*="font-claude-response"],[class*="font-user-message"])\';\nvar CODE_SELECTORS=\'body pre,body code,body kbd,body samp,body pre *,body code *,body kbd *,body samp *,body .monaco-editor,body .monaco-editor *,body .xterm,body .xterm *,body .cm-editor,body .cm-editor *,body [class*="font-mono"],body [class*="font-mono"] *\';\nvar inserted=new Map();\nvar state=null;\nfunction log(level,event,fields){try{var line="[Barracks Fonts] "+JSON.stringify(Object.assign({event:event},fields||{}));if(level==="warn")console.warn(line);else console.log(line)}catch(e){}}\nfunction strip(src){var out="",i=0,n=src.length,inStr=false,q="";while(i<n){var c=src[i],d=src[i+1];if(inStr){out+=c;if(c==="\\\\"){out+=d||"";i+=2;continue}if(c===q)inStr=false;i++;continue}if(c===\'"\'||c==="\'"){inStr=true;q=c;out+=c;i++;continue}if(c==="/"&&d==="/"){while(i<n&&src[i]!=="\\n")i++;continue}if(c==="/"&&d==="*"){i+=2;while(i<n&&!(src[i]==="*"&&src[i+1]==="/"))i++;i+=2;continue}out+=c;i++}return out.replace(/,(\\s*[}\\]])/g,"$1")}\nfunction paths(){var ud=electron.app.getPath("userData");return{json:path.join(ud,"claude-desktop-extra.json"),jsonc:path.join(ud,"claude-desktop-extra.jsonc")}}\nfunction readKey(file,key){var text;try{text=fs.readFileSync(file,"utf8")}catch(e){return undefined}try{var body=strip(text).trim();if(!body)return undefined;var o=JSON.parse(body);return o&&typeof o==="object"&&!Array.isArray(o)?o[key]:undefined}catch(e){log("warn","fonts.config_unreadable",{file:path.basename(file),error:e.message});return undefined}}\nfunction families(raw){var list=[];String(raw).split(",").forEach(function(part){var name=part.trim().replace(/^["\']+|["\']+$/g,"").trim();if(!name)return;if(name.length>64||!/^[\\p{L}\\p{N} ._+\\-]+$/u.test(name))throw new Error("unsupported font name: "+name);list.push(name)});if(list.length>8)throw new Error("at most 8 fonts per list");return list.join(", ")}\nfunction normalize(value){if(value===null||value===undefined)return{ui:DEFAULTS.ui,code:DEFAULTS.code};if(typeof value!=="object"||Array.isArray(value))throw new Error("fonts must be an object with ui and code");return{ui:value.ui===undefined?DEFAULTS.ui:families(value.ui),code:value.code===undefined?DEFAULTS.code:families(value.code)}}\nfunction quoted(list){return list.split(",").map(function(s){return s.trim()}).filter(Boolean).map(function(n){return\'"\'+n+\'"\'}).join(",")}\nfunction css(f){var out="";if(f.ui)out+=UI_SELECTORS+"{font-family:"+quoted(f.ui)+","+UI_TAIL+"!important}";if(f.code)out+=CODE_SELECTORS+"{font-family:"+quoted(f.code)+","+CODE_TAIL+"!important}";return out}\nfunction resolve(){var p=paths();var fromJson=readKey(p.json,"fonts");var fromJsonc=readKey(p.jsonc,"fonts");var source=fromJsonc!==undefined?fromJsonc:fromJson;var fonts;try{fonts=normalize(source)}catch(e){log("warn","fonts.config_invalid",{error:e.message});fonts=normalize(null)}return{fonts:fonts,lockedByJsonc:fromJsonc!==undefined,css:css(fonts)}}\nfunction eligible(wc){try{if(!wc||wc.isDestroyed())return false;var t=wc.getType();return t==="window"||t==="browserView"||t==="webview"}catch(e){return false}}\nfunction apply(wc){if(!eligible(wc))return;var id=wc.id;var old=inserted.get(id);inserted.delete(id);if(old){wc.removeInsertedCSS(old).catch(function(){})}var text=state?state.css:"";if(!text)return;wc.insertCSS(text,{cssOrigin:"author"}).then(function(key){if(wc.isDestroyed())return;inserted.set(id,key)}).catch(function(e){log("warn","fonts.insert_failed",{error:e&&e.message})})}\nfunction applyAll(){var count=0;electron.webContents.getAllWebContents().forEach(function(wc){if(eligible(wc)){apply(wc);count++}});return count}\nfunction read(){if(!state)state=resolve();return{ok:true,ui:state.fonts.ui,code:state.fonts.code,defaults:{ui:DEFAULTS.ui,code:DEFAULTS.code},lockedByJsonc:state.lockedByJsonc}}\nfunction set(value){if(!state)state=resolve();if(state.lockedByJsonc)return{ok:false,error:"fonts are set in claude-desktop-extra.jsonc - edit that file instead"};var fonts;try{fonts=normalize(value)}catch(e){return{ok:false,error:e.message}}state={fonts:fonts,lockedByJsonc:false,css:css(fonts)};var windows=applyAll();log("info","fonts.applied",{ui:fonts.ui,code:fonts.code,windows:windows});return{ok:true,fonts:fonts,windows:windows}}\nglobalThis[M]={read:read,set:set};\nelectron.app.on("web-contents-created",function(_event,wc){var id=wc.id;wc.on("dom-ready",function(){if(!state)state=resolve();apply(wc)});wc.once("destroyed",function(){inserted.delete(id)})});\nelectron.app.whenReady().then(function(){state=resolve();log("info","fonts.loaded",{ui:state.fonts.ui,code:state.fonts.code,locked:state.lockedByJsonc})}).catch(function(){});\n})();'
FONTS_HANDLERS = '    "cdb-fonts:read": function () {\n      var f = globalThis.__cdbFonts;\n      if (!f) return { ok: false, error: "the fonts patch is not installed in this build" };\n      return f.read();\n    },\n\n    "cdb-fonts:set": function (ui, code) {\n      var f = globalThis.__cdbFonts;\n      if (!f) return { ok: false, error: "the fonts patch is not installed in this build" };\n      var value = ui === null && code === null ? null : { ui: String(ui == null ? "" : ui), code: String(code == null ? "" : code) };\n      var live = f.set(value);\n      if (!live || live.ok !== true) return live || { ok: false, error: "could not apply the fonts" };\n      var res = __cdbEx_writeCfg(function (cfg) {\n        if (value === null) delete cfg.fonts;\n        else cfg.fonts = { ui: live.fonts.ui, code: live.fonts.code };\n        return true;\n      });\n      if (!res.ok) return { ok: false, error: "applied to " + live.windows + " window(s) but could not save: " + res.error };\n      return { ok: true, ui: live.fonts.ui, code: live.fonts.code, windows: live.windows, path: res.path };\n    },\n\n'
FONTS_BRIDGE = '    fontsRead: function () {\n      return ipcRenderer.invoke("cdb-fonts:read");\n    },\n    fontsSet: function (ui, code) {\n      return ipcRenderer.invoke("cdb-fonts:set", ui === null ? null : String(ui || ""), code === null ? null : String(code || ""));\n    },\n'
FONTS_ROW = '  function renderFontsRow(panel) {\n    if (!api || typeof api.fontsRead !== "function" || typeof api.fontsSet !== "function") return;\n    var spec = { section: "Typography", title: "Fonts", note: "UI and code fonts. Comma-separated fallbacks. Empty keeps Claude\'s font. Applies live." };\n\n    var head = el("div", "cdbx-sec-h");\n    head.appendChild(el("span", "cdbx-sec-t", spec.section));\n    panel.appendChild(head);\n\n    var host = el("div", "cdbx-list");\n    var node = el("div", "cdbx-row");\n    var main = el("div", "cdbx-row-main");\n    main.appendChild(el("div", "cdbx-id", spec.title));\n    main.appendChild(el("div", "cdbx-note", spec.note));\n\n    function field(label) {\n      var wrap = el("div", "cdbx-state");\n      wrap.style.display = "flex";\n      wrap.style.alignItems = "center";\n      wrap.style.gap = "8px";\n      var caption = el("span", null, label);\n      caption.style.minWidth = "36px";\n      var input = el("input", "cdbx-input");\n      input.type = "text";\n      input.spellcheck = false;\n      input.autocomplete = "off";\n      input.style.flex = "1 1 auto";\n      input.style.maxWidth = "320px";\n      input.setAttribute("aria-label", label + " font");\n      input.disabled = true;\n      wrap.appendChild(caption);\n      wrap.appendChild(input);\n      main.appendChild(wrap);\n      return input;\n    }\n\n    var uiInput = field("UI");\n    var codeInput = field("Code");\n    var stateLine = el("div", "cdbx-state", "Loading...");\n    main.appendChild(stateLine);\n    node.appendChild(main);\n\n    var aside = el("div", "cdbx-row-aside");\n    var applyBtn = el("button", "cdbx-btn", "Apply");\n    applyBtn.type = "button";\n    applyBtn.disabled = true;\n    var resetBtn = el("button", "cdbx-btn", "Reset");\n    resetBtn.type = "button";\n    resetBtn.disabled = true;\n    aside.appendChild(applyBtn);\n    aside.appendChild(resetBtn);\n    node.appendChild(aside);\n    host.appendChild(node);\n    panel.appendChild(host);\n\n    var defaults = { ui: "", code: "" };\n\n    function describe(ui, code) {\n      return "UI: " + (ui || "Claude default") + " - Code: " + (code || "Claude default");\n    }\n\n    function show(res) {\n      uiInput.value = res.ui || "";\n      codeInput.value = res.code || "";\n      uiInput.placeholder = defaults.ui || "Claude default";\n      codeInput.placeholder = defaults.code || "Claude default";\n      stateLine.textContent = describe(res.ui, res.code);\n    }\n\n    function busy(on) {\n      uiInput.disabled = on;\n      codeInput.disabled = on;\n      applyBtn.disabled = on;\n      resetBtn.disabled = on;\n    }\n\n    function submit(ui, code) {\n      busy(true);\n      api.fontsSet(ui, code).then(function (r) {\n        busy(false);\n        if (failed(r)) { toast("Could not change the fonts: " + reason(r), true); return; }\n        show(r);\n        node.classList.add("cdbx-flash");\n        setTimeout(function () { node.classList.remove("cdbx-flash"); }, 700);\n        toast("Fonts applied in " + r.windows + " window(s)");\n      }, function (err) {\n        busy(false);\n        toast("Could not change the fonts: " + (err && err.message ? err.message : String(err)), true);\n      });\n    }\n\n    api.fontsRead().then(function (res) {\n      if (failed(res)) {\n        stateLine.textContent = "Unavailable: " + reason(res);\n        return;\n      }\n      defaults = res.defaults || defaults;\n      show(res);\n      if (res.lockedByJsonc) {\n        stateLine.textContent = describe(res.ui, res.code) + " - set in claude-desktop-extra.jsonc";\n        return;\n      }\n      busy(false);\n      applyBtn.addEventListener("click", function () { submit(uiInput.value, codeInput.value); });\n      resetBtn.addEventListener("click", function () { submit(null, null); });\n      [uiInput, codeInput].forEach(function (input) {\n        input.addEventListener("keydown", function (ev) {\n          if (ev.key === "Enter") { ev.preventDefault(); submit(uiInput.value, codeInput.value); }\n        });\n      });\n    }, function (err) {\n      stateLine.textContent = "Unavailable: " + (err && err.message ? err.message : String(err));\n    });\n\n    return { head: head, host: host, spec: spec };\n  }\n\n'

TITLE_PATCH_6_6395 = r'''# @patch-target: app.asar.contents/.vite/build/index.js
# @patch-type: nim

import std/[os, strformat, strutils]
import regex

const SENTINEL = "__cdb_titleHook"
const CONSTRUCTION_WINDOW = 12000
const PREVENT_HELPER =
  re2(r"function ([\w$]+)\(([\w$]+)\)\{([\w$]+)\.on\([""`]page-title-updated[""`],\(?([\w$]+)\)?=>\{?([\w$]+)\.preventDefault\(\)\}?\)\)\}")

proc isIdentChar(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}

proc assignedNear(s, win: string, a, b: int): bool =
  let needle = win & "="
  var i = s.find(needle, a)
  while i >= 0 and i < b:
    let before = i == 0 or not (isIdentChar(s[i - 1]) or s[i - 1] == '.')
    let after = i + needle.len < s.len and s[i + needle.len] notin {'=', '>'}
    if before and after:
      return true
    i = s.find(needle, i + 1)
  false

proc apply*(input: string): string =
  result = input
  if SENTINEL in result:
    echo "  [PASS] No changes needed (already patched)"
    return
  var helpers: seq[string]
  for m in result.findAll(PREVENT_HELPER):
    if result[m.group(1)] == result[m.group(2)] and result[m.group(3)] == result[m.group(4)]:
      helpers.add result[m.group(0)]
  if helpers.len != 1:
    echo &"  [FAIL] page-title-updated preventDefault helper: {helpers.len} matches, expected 1"
    quit(1)
  let call = re2(r"[^\w$.]" & escapeRe(helpers[0]) & r"\(([\w$]+)\)")
  var sites: seq[tuple[a, b: int, win: string]]
  for m in result.findAll(call):
    let a = m.boundaries.a
    if a >= 8 and result[a - 8 .. a] == "function ":
      continue
    sites.add (a: a + 1, b: m.boundaries.b, win: result[m.group(0)])
  if sites.len != 1:
    echo &"  [FAIL] main-window title lock call: {sites.len} matches, expected 1"
    quit(1)
  let site = sites[0]
  let floor = max(0, site.a - CONSTRUCTION_WINDOW)
  if result.find(".BrowserWindow(", floor, site.a) < 0 or not result.assignedNear(site.win, floor, site.a):
    echo "  [FAIL] main-window construction not found before the title lock call"
    quit(1)
  let hook =
    "(" & result[site.a .. site.b] & ",process.env.CLAUDE_PROFILE&&((globalThis." & SENTINEL &
    "=true),((__cdb_w,__cdb_s)=>{const __cdb_o=__cdb_w.setTitle.bind(__cdb_w);" &
    "__cdb_w.setTitle=(__cdb_t)=>{__cdb_t=String(__cdb_t??\"\");" &
    "return __cdb_o(__cdb_t.endsWith(__cdb_s)?__cdb_t:__cdb_t+__cdb_s)};" &
    "__cdb_w.setTitle(__cdb_w.getTitle())})(" & site.win &
    ",\" (\"+process.env.CLAUDE_PROFILE+\")\")),void 0)"
  result = result[0 ..< site.a] & hook & result[site.b + 1 .. ^1]
  echo "  [OK] Main window title hook injected at the title lock call"

when isMainModule:
  if paramCount() != 1:
    echo "Usage: fix_profile_window_title <file>"
    quit(1)
  let filePath = paramStr(1)
  echo "=== Patch: fix_profile_window_title ==="
  echo "  Target: " & filePath
  if not fileExists(filePath):
    echo "  [FAIL] File not found: " & filePath
    quit(1)
  let input = readFile(filePath)
  let output = apply(input)
  if output != input:
    writeFile(filePath, output)
    echo "  [PASS] Profile window title hook installed"
'''

UPSTREAM_URL = "https://github.com/patrickjaja/claude-desktop-extra.git"
WINDOW_CONTROLS_HOOK = ';(function(){var m="__cdbClaudeWorkMacWindowControls";if(globalThis[m])return;globalThis[m]=true;if(process.platform!=="darwin")return;try{var e=require("electron");e.app.on("browser-window-created",function(_event,w){try{w.webContents.once("did-finish-load",function(){try{if(w.webContents.getURL().indexOf("cdb-theme-picker")>=0)return;if(globalThis.__cdbNoWinCtl&&globalThis.__cdbNoWinCtl()&&typeof w.setWindowButtonVisibility==="function")w.setWindowButtonVisibility(false)}catch(x){console.warn("[Claude Work Extras] Window-control hook failed",x)}})}catch(x){console.warn("[Claude Work Extras] Window-control hook registration failed",x)}})}catch(x){console.warn("[Claude Work Extras] Window-control hook initialization failed",x)}})();'
DEPLOYMENT_TARGET = "14.0"


def log(level, message):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {level} {message}", file=sys.stderr)


def run(command, **options):
    return subprocess.run(command, check=True, text=True, **options)


def sync_repository(support_root):
    support_root = pathlib.Path(support_root).expanduser()
    support_root.mkdir(parents=True, exist_ok=True)
    repository = support_root / "claude-desktop-extra"
    if repository.exists():
        if not (repository / ".git").is_dir():
            raise RuntimeError(f"Refusing unmanaged source directory: {repository}")
        remote = subprocess.check_output(
            ["git", "-C", str(repository), "remote", "get-url", "origin"],
            text=True,
        ).strip()
        if remote != UPSTREAM_URL:
            raise RuntimeError(f"Unexpected upstream remote: {remote}")
    else:
        run(["git", "init", "--quiet", str(repository)])
        run(["git", "-C", str(repository), "remote", "add", "origin", UPSTREAM_URL])
        log("INFO", "Initialized claude-desktop-extra source directory.")
    commits = []
    for generation in GENERATIONS:
        pins = [("base", generation["commit"])] + [("overlay", overlay["commit"]) for overlay in generation.get("overlays", [])]
        for role, pinned in pins:
            present = subprocess.run(
                ["git", "-C", str(repository), "cat-file", "-e", f"{pinned}^{{commit}}"],
                capture_output=True,
            ).returncode == 0
            if not present:
                run(["git", "-C", str(repository), "fetch", "--quiet", "--depth=1", "origin", pinned], capture_output=True)
                log("INFO", f"Fetched pinned claude-desktop-extra {role} commit {pinned[:12]} for {generation['id']}.")
            resolved = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", f"{pinned}^{{commit}}"],
                text=True,
            ).strip()
            if resolved != pinned:
                raise RuntimeError(f"claude-desktop-extra resolved {pinned} to {resolved}")
            log("INFO", f"Using pinned claude-desktop-extra {role} {pinned[:12]} for {generation['id']}.")
            if resolved not in commits:
                commits.append(resolved)
    return commits


def replace_text(path, old, new, expected=None):
    content = path.read_text()
    count = content.count(old)
    if count == 0 or expected is not None and count != expected:
        raise RuntimeError(f"Expected {expected or 'at least one'} match in {path}: {old!r}; found {count}")
    path.write_text(content.replace(old, new))


def replace_regex(path, pattern, replacement, expected=1):
    content = path.read_text()
    updated, count = re.subn(pattern, replacement, content, count=expected, flags=re.DOTALL)
    if count != expected:
        raise RuntimeError(f"Expected {expected} structured match in {path}; found {count}")
    path.write_text(updated)


def adapt_claude_2_7032(source):
    replace_text(
        source / "patches/core/add_feature_custom_themes.nim",
        'if(process.platform!=="linux")return;',
        "",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        'if(process.platform!=="linux")return;',
        "",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        "if(!input.control||!input.shift||input.alt||input.meta)return;",
        "if((!input.control&&!input.meta)||!input.shift||input.alt)return;",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        "Ctrl+Shift+T",
        "Command+Shift+T",
    )
    replace_text(
        source / "js/theme_picker_page.html",
        "ev.ctrlKey && ev.shiftKey",
        "(ev.ctrlKey || ev.metaKey) && ev.shiftKey",
        1,
    )
    replace_text(
        source / "js/theme_picker_page.html",
        "<kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>T</kbd>",
        "<kbd>Command</kbd><kbd>Shift</kbd><kbd>T</kbd>",
        1,
    )
    replace_text(
        source / "js/files_quick_open_page.js",
        "if (!ev.ctrlKey || ev.altKey || ev.metaKey || ev.shiftKey) return;",
        "if (!(ev.ctrlKey || ev.metaKey) || ev.altKey || ev.shiftKey) return;",
        1,
    )
    replace_text(source / "js/files_quick_open_page.js", "Ctrl+P", "Command+P")
    replace_text(
        source / "js/panel_tabs_page.js",
        "if (!enabled || !ev.ctrlKey || ev.altKey || ev.metaKey) return false;",
        "if (!enabled || !(ev.ctrlKey || ev.metaKey) || ev.altKey) return false;",
        1,
    )
    replace_text(source / "js/panel_tabs_page.js", "Ctrl+", "Command+")
    for relative in (
        "diff_views_main.js",
        "extra_settings_main.js",
        "files_quick_open_main.js",
        "panel_tabs_main.js",
        "window_controls_main.js",
    ):
        replace_text(
            source / "js" / relative,
            'if (typeof process === "undefined" || process.platform !== "linux") return;',
            'if (typeof process === "undefined") return;',
            1,
        )
    settings = source / "js/extra_settings_page.js"
    replace_text(
        settings,
        'if (!window.claudeAppBindings || !api || typeof api.flagsCatalog !== "function") {',
        'if (!api || typeof api.flagsCatalog !== "function") {',
        1,
    )
    replace_text(settings, "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(settings, "Ctrl+P", "Command+P")
    replace_text(
        settings,
        "    renderWindowControlsRow,\n    renderNativeTitlebarRow,\n",
        "    renderWindowControlsRow,\n",
        1,
    )
    replace_regex(
        settings,
        r'      note: "Opens the main window with no frame.*?Desktop\.",\n      ariaLabel: "open the main window frameless, without window-control buttons or a shadow",',
        '      note: "Hides the three macOS traffic-light buttons. The standard macOS frame and shadow stay in place. " +\n        "Restart the app to apply the setting.",\n      ariaLabel: "hide the macOS window controls",',
    )
    replace_text(
        settings,
        'return on ? "on - no window buttons, no frame" : "off - window buttons, integrated titlebar";',
        'return on ? "on - traffic-light buttons hidden" : "off - standard macOS window controls shown";',
        1,
    )
    replace_text(
        settings,
        '"Window controls hidden - restart Claude Desktop to open the window frameless"',
        '"Window controls hidden - restart the app"',
        1,
    )
    replace_text(
        settings,
        '"Window controls back - restart Claude Desktop to get the titlebar back"',
        '"Window controls back - restart the app"',
        1,
    )
    replace_text(
        source / "js/extra_settings_main.js",
        '    "cdb-extra:paths": function () {',
        FONTS_HANDLERS + '    "cdb-extra:paths": function () {',
        1,
    )
    replace_text(
        source / "js/extra_settings_bridge.js",
        "    // __cdb_extra_bridge\n    version: 1,\n",
        "    // __cdb_extra_bridge\n    version: 1,\n" + FONTS_BRIDGE,
        1,
    )
    replace_text(
        settings,
        "  var FEATURE_ROWS = [\n",
        FONTS_ROW + "  var FEATURE_ROWS = [\n    renderFontsRow,\n",
        1,
    )
    replace_text(source / "js/extra_settings_main.js", "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(source / "js/extra_settings_bridge.js", "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(source / "js/extra_settings_bridge.js", "Ctrl+P", "Command+P")
    replace_text(source / "js/files_quick_open_main.js", "Ctrl+P", "Command+P")


def adapt_claude_4_16336(source):
    replace_text(
        source / "patches/core/add_feature_custom_themes.nim",
        'if(process.platform!=="linux")return;',
        "",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        'if(process.platform!=="linux")return;',
        "",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        "if(!input.control||!input.shift||input.alt||input.meta)return;",
        "if((!input.control&&!input.meta)||!input.shift||input.alt)return;",
        1,
    )
    replace_text(
        source / "patches/community/add_feature_theme_picker.nim",
        "Ctrl+Shift+T",
        "Command+Shift+T",
    )
    replace_text(
        source / "js/theme_picker_page.html",
        "ev.ctrlKey && ev.shiftKey",
        "(ev.ctrlKey || ev.metaKey) && ev.shiftKey",
        1,
    )
    replace_text(
        source / "js/theme_picker_page.html",
        "<kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>T</kbd>",
        "<kbd>Command</kbd><kbd>Shift</kbd><kbd>T</kbd>",
        1,
    )
    replace_text(
        source / "js/files_quick_open_page.js",
        "if (!ev.ctrlKey || ev.altKey || ev.metaKey || ev.shiftKey) return;",
        "if (!(ev.ctrlKey || ev.metaKey) || ev.altKey || ev.shiftKey) return;",
        1,
    )
    replace_text(source / "js/files_quick_open_page.js", "Ctrl+P", "Command+P")
    replace_text(
        source / "js/panel_tabs_page.js",
        "if (!enabled || !ev.ctrlKey || ev.altKey || ev.metaKey) return false;",
        "if (!enabled || !(ev.ctrlKey || ev.metaKey) || ev.altKey) return false;",
        1,
    )
    replace_text(source / "js/panel_tabs_page.js", "Ctrl+", "Command+")
    replace_text(
        source / "patches/core/fix_profile_window_title.nim",
        '  let ctor = re2(r"(?:^|[^\\w$.])([\\w$]+)=" & escapeRe(factory) & r"\\(\\{")\n'
        "  for m in s.findAll(ctor):\n"
        "    let win = s[m.group(0)]\n"
        "    let a = m.boundaries.b\n"
        "    let b = min(s.len, a + PREVENT_CALL_WINDOW)\n",
        '  let ctor = re2(r"(?:^|[^\\w$.])([\\w$]+)=([\\w$]+)\\(\\{")\n'
        '  let wrapped = "}," & factory & ")"\n'
        "  for m in s.findAll(ctor):\n"
        "    let win = s[m.group(0)]\n"
        "    let a = m.boundaries.b\n"
        "    let b = min(s.len, a + PREVENT_CALL_WINDOW)\n"
        "    if s[m.group(1)] != factory and s.find(wrapped, a, b - 1) < 0:\n"
        "      continue\n",
        1,
    )
    replace_text(
        source / "js/extra_settings_main.js",
        'if (typeof process === "undefined" || (process.platform !== "linux" && process.platform !== "win32")) return;',
        'if (typeof process === "undefined") return;',
        1,
    )
    for relative in (
        "diff_views_main.js",
        "files_quick_open_main.js",
        "panel_tabs_main.js",
        "window_controls_main.js",
    ):
        replace_text(
            source / "js" / relative,
            'if (typeof process === "undefined" || process.platform !== "linux") return;',
            'if (typeof process === "undefined") return;',
            1,
        )
    settings = source / "js/extra_settings_page.js"
    replace_text(
        settings,
        'if (!window.claudeAppBindings || !api || typeof api.flagsCatalog !== "function") {',
        'if (!api || typeof api.flagsCatalog !== "function") {',
        1,
    )
    replace_text(settings, "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(settings, "Ctrl+P", "Command+P")
    replace_text(
        settings,
        '  var WINDOWS_NAV = { models: true };\n'
        '  if (/^Win/.test((typeof navigator !== "undefined" && navigator.platform) || "")) {\n'
        '    NAV_ITEMS = NAV_ITEMS.filter(function (it) { return WINDOWS_NAV[it.kind] === true; });\n'
        '  }\n',
        '  var WINDOWS_NAV = { models: true };\n'
        '  var MAC_NAV = { themes: true, features: true, flags: true };\n'
        '  var NAV_PLATFORM = (typeof navigator !== "undefined" && navigator.platform) || "";\n'
        '  if (/^Win/.test(NAV_PLATFORM)) {\n'
        '    NAV_ITEMS = NAV_ITEMS.filter(function (it) { return WINDOWS_NAV[it.kind] === true; });\n'
        '  } else if (/^Mac/.test(NAV_PLATFORM)) {\n'
        '    NAV_ITEMS = NAV_ITEMS.filter(function (it) { return MAC_NAV[it.kind] === true; });\n'
        '  }\n',
        1,
    )
    replace_text(
        settings,
        "  var FEATURE_ROWS = [\n"
        "    renderDiffViewsRow,\n"
        "    renderPanelTabsRow,\n"
        "    renderFilesQuickOpenRow,\n"
        "    renderCustomModelsRow,\n"
        "    renderAllowNonAnthropicModelsRow,\n"
        "    renderAutoFixAuthorRow,\n"
        "    renderAutoFixMergeReadyRow,\n"
        "    renderAutoArchiveGraceRow,\n"
        "    renderSessionStartAlwaysAllowRow,\n"
        "    renderTranscriptLimitsRow,\n"
        "    renderWindowControlsRow,\n"
        "    renderNativeTitlebarRow,\n"
        "    renderWindowTransparencyRow,\n"
        "    renderTrayIconRow,\n"
        "    renderThemePickerRow,\n"
        "    renderDevToolsRow\n"
        "  ];\n",
        FONTS_ROW
        + "  var FEATURE_ROWS = [\n"
        "    renderFontsRow,\n"
        "    renderDiffViewsRow,\n"
        "    renderPanelTabsRow,\n"
        "    renderFilesQuickOpenRow,\n"
        "    renderWindowControlsRow,\n"
        "    renderThemePickerRow\n"
        "  ];\n",
        1,
    )
    replace_regex(
        settings,
        r'      note: "Opens the main window with no frame.*?Desktop\.",\n      ariaLabel: "open the main window frameless, without window-control buttons or a shadow",',
        '      note: "Hides the three macOS traffic-light buttons. The standard macOS frame and shadow stay in place. " +\n        "Restart the app to apply the setting.",\n      ariaLabel: "hide the macOS window controls",',
    )
    replace_text(
        settings,
        'return on ? "on - no window buttons, no frame" : "off - window buttons, integrated titlebar";',
        'return on ? "on - traffic-light buttons hidden" : "off - standard macOS window controls shown";',
        1,
    )
    replace_text(
        settings,
        '"Window controls hidden - restart Claude Desktop to open the window frameless"',
        '"Window controls hidden - restart the app"',
        1,
    )
    replace_text(
        settings,
        '"Window controls back - restart Claude Desktop to get the titlebar back"',
        '"Window controls back - restart the app"',
        1,
    )
    replace_text(
        settings,
        '    restart.title = "Relaunches the app directly, skipping your desktop launcher\'s systemd scope " +\n'
        '      "and environment - quitting and reopening from the launcher is the cleanest way";\n',
        '    restart.title = "Relaunches the app";\n',
        1,
    )
    replace_text(
        settings,
        '      "Quitting Claude Desktop and reopening it from your desktop launcher is the cleanest way: " +\n'
        '      "\\"Restart now\\" relaunches the app directly and so skips the launcher\'s systemd scope and environment."));\n',
        '      "Use \\"Restart now\\" or quit and reopen the app."));\n',
        1,
    )
    replace_text(
        source / "js/extra_settings_main.js",
        '    "cdb-extra:paths": function () {',
        FONTS_HANDLERS + '    "cdb-extra:paths": function () {',
        1,
    )
    replace_text(
        source / "js/extra_settings_bridge.js",
        "    // __cdb_extra_bridge\n    version: 1,\n",
        "    // __cdb_extra_bridge\n    version: 1,\n" + FONTS_BRIDGE,
        1,
    )
    replace_text(source / "js/extra_settings_main.js", "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(source / "js/extra_settings_bridge.js", "Ctrl+Shift+T", "Command+Shift+T")
    replace_text(source / "js/extra_settings_bridge.js", "Ctrl+P", "Command+P")
    replace_text(source / "js/files_quick_open_main.js", "Ctrl+P", "Command+P")


def adapt_claude_6_6395(source):
    adapt_claude_4_16336(source)
    replace_text(
        source / "patches/core/add_growthbook_overrides.nim",
        r"(function [\w$]+\(([\w$]+),[\w$]+\)\{[\w$]+=[\w$]+;(?:const|let|var) ",
        r"(function [\w$]+\(([\w$]+)(?:,[\w$]+(?:=[\w$]+)?)+\)\{[\w$]+=[\w$]+(?:,[\w$]+=[\w$]+)*;(?:const|let|var) ",
        1,
    )
    (source / "patches/core/fix_profile_window_title.nim").write_text(TITLE_PATCH_6_6395)


def compile_patches(source, patches):
    for executable in ("nim", "nimble", "make", "xcrun"):
        if shutil.which(executable) is None:
            raise RuntimeError(f"Required build tool is unavailable: {executable}")
    regex_path = subprocess.run(["nimble", "path", "regex"], text=True, capture_output=True)
    if regex_path.returncode != 0:
        run(["nimble", "install", "-y", "regex"])
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    targets = [str(path) for path in patches]
    build = subprocess.run(
        ["make", "-C", str(source / "patches"), "-j4", *targets],
        text=True,
        capture_output=True,
        env={**os.environ, "SDKROOT": sdk, "MACOSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET},
    )
    if build.returncode != 0:
        raise RuntimeError("Nim patch build failed:\n" + build.stdout + build.stderr)
    log("INFO", f"Compiled {len(patches)} feature patchers for macOS from {source.name}.")


HEADER_RE = re.compile(r"@patch-(target|type):\s*(\S+)")
BUNDLE_FORMAT = 2
GENERATIONS = [
    {
        "id": "claude-6.28899",
        "minimum_claude": "6.28899.0",
        "commit": "adc0509f90a37427911a0de2cafb61ca62d39804",
        "overlays": [
            {
                "commit": "87c821c4dffa77563202abd3b8589802ca0865de",
                "paths": [
                    "js/files_quick_open_worker.js",
                    "patches/community/add_feature_files_quick_open_worker.nim",
                ],
            },
        ],
        "adapt": adapt_claude_6_6395,
        "main_append": WINDOW_CONTROLS_HOOK + "\n" + FONTS_MAIN + "\n",
        "patches": [
            "core/add_feature_custom_themes",
            "core/add_feature_extra_settings",
            "core/add_feature_extra_settings_bridge",
            "core/add_growthbook_overrides",
            "core/fix_profile_window_title",
            "community/add_feature_theme_picker",
            "community/add_feature_diff_views",
            "community/add_feature_diff_views_bridge",
            "community/add_feature_files_quick_open",
            "community/add_feature_files_quick_open_bridge",
            "community/add_feature_files_quick_open_worker",
            "community/add_feature_panel_tabs",
            "community/add_feature_panel_tabs_bridge",
            "community/add_feature_window_controls",
        ],
    },
    {
        "id": "claude-6.6395",
        "minimum_claude": "6.6395.0",
        "commit": "adc0509f90a37427911a0de2cafb61ca62d39804",
        "adapt": adapt_claude_6_6395,
        "main_append": WINDOW_CONTROLS_HOOK + "\n" + FONTS_MAIN + "\n",
        "patches": [
            "core/add_feature_custom_themes",
            "core/add_feature_extra_settings",
            "core/add_feature_extra_settings_bridge",
            "core/add_growthbook_overrides",
            "core/fix_profile_window_title",
            "community/add_feature_theme_picker",
            "community/add_feature_diff_views",
            "community/add_feature_diff_views_bridge",
            "community/add_feature_files_quick_open",
            "community/add_feature_files_quick_open_bridge",
            "community/add_feature_files_quick_open_worker",
            "community/add_feature_panel_tabs",
            "community/add_feature_panel_tabs_bridge",
            "community/add_feature_window_controls",
        ],
    },
    {
        "id": "claude-4.16336",
        "minimum_claude": "4.16336.0",
        "commit": "adc0509f90a37427911a0de2cafb61ca62d39804",
        "adapt": adapt_claude_4_16336,
        "main_append": WINDOW_CONTROLS_HOOK + "\n" + FONTS_MAIN + "\n",
        "patches": [
            "core/add_feature_custom_themes",
            "core/add_feature_extra_settings",
            "core/add_feature_extra_settings_bridge",
            "core/add_growthbook_overrides",
            "core/fix_profile_window_title",
            "community/add_feature_theme_picker",
            "community/add_feature_diff_views",
            "community/add_feature_diff_views_bridge",
            "community/add_feature_files_quick_open",
            "community/add_feature_files_quick_open_bridge",
            "community/add_feature_files_quick_open_worker",
            "community/add_feature_panel_tabs",
            "community/add_feature_panel_tabs_bridge",
            "community/add_feature_window_controls",
        ],
    },
    {
        "id": "claude-2.7032",
        "minimum_claude": "0.0.0",
        "commit": "d5551098ceb87bf4effe8165f02e405a813a49ea",
        "adapt": adapt_claude_2_7032,
        "main_append": WINDOW_CONTROLS_HOOK + "\n" + FONTS_MAIN + "\n",
        "patches": [
            "core/add_feature_custom_themes",
            "core/add_feature_extra_settings",
            "core/add_feature_extra_settings_bridge",
            "core/add_growthbook_overrides",
            "core/fix_profile_window_title",
            "community/add_feature_theme_picker",
            "community/add_feature_cowork_glow",
            "community/add_feature_diff_views",
            "community/add_feature_diff_views_bridge",
            "community/add_feature_files_quick_open",
            "community/add_feature_files_quick_open_bridge",
            "community/add_feature_files_quick_open_worker",
            "community/add_feature_panel_tabs",
            "community/add_feature_panel_tabs_bridge",
            "community/add_feature_window_controls",
        ],
    },
]


def extract_source(repository, commit, workspace, name):
    archive = workspace / f"{name}.tar"
    source = workspace / name
    with archive.open("wb") as target:
        run(["git", "-C", str(repository), "archive", "--format=tar", commit], stdout=target)
    source.mkdir()
    with tarfile.open(archive) as contents:
        if hasattr(tarfile, "data_filter"):
            contents.extractall(source, filter="data")
        else:
            root = source.resolve()
            for member in contents.getmembers():
                target = (source / member.name).resolve()
                if not (member.isfile() or member.isdir()) or not str(target).startswith(str(root)):
                    raise RuntimeError(f"Refusing unsafe archive entry: {member.name}")
            contents.extractall(source)
    return source


def patch_headers(path):
    target = kind = None
    for key, value in HEADER_RE.findall(path.read_text(errors="ignore")):
        if key == "target" and target is None:
            target = value
        elif key == "type" and kind is None:
            kind = value
    if not target or not kind:
        raise RuntimeError(f"Patch {path.name} has no @patch-target/@patch-type header")
    if kind != "nim":
        raise RuntimeError(f"Patch {path.name} has unsupported type {kind}")
    if not target.startswith("app.asar.contents/"):
        raise RuntimeError(f"Patch {path.name} targets {target} outside app.asar.contents")
    return target


def apply_overlays(generation, repository, source):
    root = source.resolve()
    for overlay in generation.get("overlays", []):
        for relative in overlay["paths"]:
            target = (source / relative).resolve()
            if not str(target).startswith(str(root) + os.sep) or not target.is_file():
                raise RuntimeError(f"Overlay path {relative} for {generation['id']} is not an existing source file")
            content = subprocess.check_output(["git", "-C", str(repository), "show", f"{overlay['commit']}:{relative}"])
            target.write_bytes(content)
            log("INFO", f"Overlaid {relative} from {overlay['commit'][:12]} onto {generation['id']} ({len(content)} bytes).")


def build_generation(generation, repository, workspace, staging):
    started = datetime.datetime.now()
    name = f"claude-desktop-extra-{generation['id']}"
    source = extract_source(repository, generation["commit"], workspace, name)
    apply_overlays(generation, repository, source)
    generation["adapt"](source)
    compile_patches(source, generation["patches"])
    root = pathlib.PurePosixPath("generations") / generation["id"]
    identity = os.environ.get("BARRACKS_SIGN_IDENTITY", "-")
    flags = [] if identity == "-" else ["--options", "runtime", "--timestamp"]
    entries = []
    for relative in sorted(generation["patches"], key=lambda item: pathlib.PurePosixPath(item).name):
        base = source / "patches" / relative
        target = patch_headers(base.with_suffix(".nim"))
        binary = root / "patches" / relative
        destination = staging / binary
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(base, destination)
        os.chmod(destination, 0o755)
        run(["codesign", "--force", "--sign", identity, *flags, str(destination)], capture_output=True)
        entries.append({
            "name": pathlib.PurePosixPath(relative).name,
            "binary": str(binary),
            "target": target[len("app.asar.contents/"):],
            "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        })
    for entry in entries:
        build = subprocess.check_output(["vtool", "-show-build", str(staging / entry["binary"])], text=True)
        found = re.search(r"minos (\S+)", build)
        if not found or tuple(int(x) for x in found.group(1).split(".")) > tuple(int(x) for x in DEPLOYMENT_TARGET.split(".")):
            raise RuntimeError(f"{entry['name']} targets macOS {found.group(1) if found else 'unknown'}, expected {DEPLOYMENT_TARGET}")
    append = root / "main-append.js"
    (staging / append).write_text(generation["main_append"])
    seconds = (datetime.datetime.now() - started).total_seconds()
    log("INFO", f"Built generation {generation['id']} from {generation['commit'][:12]} with {len(entries)} patches in {seconds:.1f}s.")
    return {
        "id": generation["id"],
        "minimumClaudeVersion": generation["minimum_claude"],
        "commit": generation["commit"],
        "patches": entries,
        "mainAppend": str(append),
        "mainAppendSHA256": hashlib.sha256((staging / append).read_bytes()).hexdigest(),
    }


def bundle_mode(cache_root, out_dir):
    cache_root = pathlib.Path(cache_root).expanduser()
    out_dir = pathlib.Path(out_dir).expanduser()
    sync_repository(cache_root)
    workspace = pathlib.Path(tempfile.mkdtemp(prefix="barracks-extra-"))
    staging = out_dir.parent / f".{out_dir.name}.staging"
    try:
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True)
        generations = [build_generation(generation, cache_root / "claude-desktop-extra", workspace, staging) for generation in GENERATIONS]
        manifest = {
            "format": BUNDLE_FORMAT,
            "signedBy": "adhoc" if os.environ.get("BARRACKS_SIGN_IDENTITY", "-") == "-" else "developer-id",
            "upstream": UPSTREAM_URL,
            "script": hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
            "mainTarget": ".vite/build/index.js",
            "staleMarkers": ["__cdb", "__nav_spoof_applied"],
            "generations": generations,
        }
        (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        if out_dir.exists():
            shutil.rmtree(out_dir)
        staging.rename(out_dir)
        summary = ", ".join(f"{g['id']}@{g['commit'][:12]} ({len(g['patches'])} patches, Claude >= {g['minimumClaudeVersion']})" for g in generations)
        log("INFO", f"Wrote Extra bundle to {out_dir}: {summary}.")
    finally:
        shutil.rmtree(workspace, ignore_errors=True)
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "sync":
        print("\n".join(sync_repository(sys.argv[2])))
        return
    if len(sys.argv) == 4 and sys.argv[1] == "bundle":
        bundle_mode(sys.argv[2], sys.argv[3])
        return
    raise SystemExit("Usage: extra_port.py sync <cache-root> | bundle <cache-root> <out-dir>")


if __name__ == "__main__":
    main()
