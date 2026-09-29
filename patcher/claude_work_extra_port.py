import datetime
import os
import pathlib
import re
import runpy
import shutil
import subprocess
import sys
import tarfile

FONTS_MAIN = ';(function(){\nvar M="__cdbFonts";\nif(globalThis[M])return;\nif(typeof process==="undefined")return;\nvar electron=require("electron"),fs=require("fs"),path=require("path");\nvar DEFAULTS={ui:"Wanted Sans",code:"Monoplex KR Wide Nerd"};\nvar UI_TAIL=\'"Anthropic Sans",sans-serif\';\nvar CODE_TAIL=\'"Anthropic Mono",ui-monospace,SFMono-Regular,Menlo,monospace\';\nvar UI_SELECTORS=\'html,body,body :is(p,h1,h2,h3,h4,h5,h6,li,blockquote,td,th,label,button,input,textarea,select,option,[class~="font-sans"],[class~="font-serif"],[class*="font-claude-response"],[class*="font-user-message"])\';\nvar CODE_SELECTORS=\'body pre,body code,body kbd,body samp,body pre *,body code *,body kbd *,body samp *,body .monaco-editor,body .monaco-editor *,body .xterm,body .xterm *,body .cm-editor,body .cm-editor *,body [class*="font-mono"],body [class*="font-mono"] *\';\nvar inserted=new Map();\nvar state=null;\nfunction log(level,event,fields){try{var line="[Barracks Fonts] "+JSON.stringify(Object.assign({event:event},fields||{}));if(level==="warn")console.warn(line);else console.log(line)}catch(e){}}\nfunction strip(src){var out="",i=0,n=src.length,inStr=false,q="";while(i<n){var c=src[i],d=src[i+1];if(inStr){out+=c;if(c==="\\\\"){out+=d||"";i+=2;continue}if(c===q)inStr=false;i++;continue}if(c===\'"\'||c==="\'"){inStr=true;q=c;out+=c;i++;continue}if(c==="/"&&d==="/"){while(i<n&&src[i]!=="\\n")i++;continue}if(c==="/"&&d==="*"){i+=2;while(i<n&&!(src[i]==="*"&&src[i+1]==="/"))i++;i+=2;continue}out+=c;i++}return out.replace(/,(\\s*[}\\]])/g,"$1")}\nfunction paths(){var ud=electron.app.getPath("userData");return{json:path.join(ud,"claude-desktop-extra.json"),jsonc:path.join(ud,"claude-desktop-extra.jsonc")}}\nfunction readKey(file,key){var text;try{text=fs.readFileSync(file,"utf8")}catch(e){return undefined}try{var body=strip(text).trim();if(!body)return undefined;var o=JSON.parse(body);return o&&typeof o==="object"&&!Array.isArray(o)?o[key]:undefined}catch(e){log("warn","fonts.config_unreadable",{file:path.basename(file),error:e.message});return undefined}}\nfunction families(raw){var list=[];String(raw).split(",").forEach(function(part){var name=part.trim().replace(/^["\']+|["\']+$/g,"").trim();if(!name)return;if(name.length>64||!/^[\\p{L}\\p{N} ._+\\-]+$/u.test(name))throw new Error("unsupported font name: "+name);list.push(name)});if(list.length>8)throw new Error("at most 8 fonts per list");return list.join(", ")}\nfunction normalize(value){if(value===null||value===undefined)return{ui:DEFAULTS.ui,code:DEFAULTS.code};if(typeof value!=="object"||Array.isArray(value))throw new Error("fonts must be an object with ui and code");return{ui:value.ui===undefined?DEFAULTS.ui:families(value.ui),code:value.code===undefined?DEFAULTS.code:families(value.code)}}\nfunction quoted(list){return list.split(",").map(function(s){return s.trim()}).filter(Boolean).map(function(n){return\'"\'+n+\'"\'}).join(",")}\nfunction css(f){var out="";if(f.ui)out+=UI_SELECTORS+"{font-family:"+quoted(f.ui)+","+UI_TAIL+"!important}";if(f.code)out+=CODE_SELECTORS+"{font-family:"+quoted(f.code)+","+CODE_TAIL+"!important}";return out}\nfunction resolve(){var p=paths();var fromJson=readKey(p.json,"fonts");var fromJsonc=readKey(p.jsonc,"fonts");var source=fromJsonc!==undefined?fromJsonc:fromJson;var fonts;try{fonts=normalize(source)}catch(e){log("warn","fonts.config_invalid",{error:e.message});fonts=normalize(null)}return{fonts:fonts,lockedByJsonc:fromJsonc!==undefined,css:css(fonts)}}\nfunction eligible(wc){try{if(!wc||wc.isDestroyed())return false;var t=wc.getType();return t==="window"||t==="browserView"||t==="webview"}catch(e){return false}}\nfunction apply(wc){if(!eligible(wc))return;var id=wc.id;var old=inserted.get(id);inserted.delete(id);if(old){wc.removeInsertedCSS(old).catch(function(){})}var text=state?state.css:"";if(!text)return;wc.insertCSS(text,{cssOrigin:"author"}).then(function(key){if(wc.isDestroyed())return;inserted.set(id,key)}).catch(function(e){log("warn","fonts.insert_failed",{error:e&&e.message})})}\nfunction applyAll(){var count=0;electron.webContents.getAllWebContents().forEach(function(wc){if(eligible(wc)){apply(wc);count++}});return count}\nfunction read(){if(!state)state=resolve();return{ok:true,ui:state.fonts.ui,code:state.fonts.code,defaults:{ui:DEFAULTS.ui,code:DEFAULTS.code},lockedByJsonc:state.lockedByJsonc}}\nfunction set(value){if(!state)state=resolve();if(state.lockedByJsonc)return{ok:false,error:"fonts are set in claude-desktop-extra.jsonc - edit that file instead"};var fonts;try{fonts=normalize(value)}catch(e){return{ok:false,error:e.message}}state={fonts:fonts,lockedByJsonc:false,css:css(fonts)};var windows=applyAll();log("info","fonts.applied",{ui:fonts.ui,code:fonts.code,windows:windows});return{ok:true,fonts:fonts,windows:windows}}\nglobalThis[M]={read:read,set:set};\nelectron.app.on("web-contents-created",function(_event,wc){var id=wc.id;wc.on("dom-ready",function(){if(!state)state=resolve();apply(wc)});wc.once("destroyed",function(){inserted.delete(id)})});\nelectron.app.whenReady().then(function(){state=resolve();log("info","fonts.loaded",{ui:state.fonts.ui,code:state.fonts.code,locked:state.lockedByJsonc})}).catch(function(){});\n})();'
FONTS_HANDLERS = '    "cdb-fonts:read": function () {\n      var f = globalThis.__cdbFonts;\n      if (!f) return { ok: false, error: "the fonts patch is not installed in this build" };\n      return f.read();\n    },\n\n    "cdb-fonts:set": function (ui, code) {\n      var f = globalThis.__cdbFonts;\n      if (!f) return { ok: false, error: "the fonts patch is not installed in this build" };\n      var value = ui === null && code === null ? null : { ui: String(ui == null ? "" : ui), code: String(code == null ? "" : code) };\n      var live = f.set(value);\n      if (!live || live.ok !== true) return live || { ok: false, error: "could not apply the fonts" };\n      var res = __cdbEx_writeCfg(function (cfg) {\n        if (value === null) delete cfg.fonts;\n        else cfg.fonts = { ui: live.fonts.ui, code: live.fonts.code };\n        return true;\n      });\n      if (!res.ok) return { ok: false, error: "applied to " + live.windows + " window(s) but could not save: " + res.error };\n      return { ok: true, ui: live.fonts.ui, code: live.fonts.code, windows: live.windows, path: res.path };\n    },\n\n'
FONTS_BRIDGE = '    fontsRead: function () {\n      return ipcRenderer.invoke("cdb-fonts:read");\n    },\n    fontsSet: function (ui, code) {\n      return ipcRenderer.invoke("cdb-fonts:set", ui === null ? null : String(ui || ""), code === null ? null : String(code || ""));\n    },\n'
FONTS_ROW = '  function renderFontsRow(panel) {\n    if (!api || typeof api.fontsRead !== "function" || typeof api.fontsSet !== "function") return;\n    var spec = { section: "Typography", title: "Fonts", note: "UI and code fonts. Comma-separated fallbacks. Empty keeps Claude\'s font. Applies live." };\n\n    var head = el("div", "cdbx-sec-h");\n    head.appendChild(el("span", "cdbx-sec-t", spec.section));\n    panel.appendChild(head);\n\n    var host = el("div", "cdbx-list");\n    var node = el("div", "cdbx-row");\n    var main = el("div", "cdbx-row-main");\n    main.appendChild(el("div", "cdbx-id", spec.title));\n    main.appendChild(el("div", "cdbx-note", spec.note));\n\n    function field(label) {\n      var wrap = el("div", "cdbx-state");\n      wrap.style.display = "flex";\n      wrap.style.alignItems = "center";\n      wrap.style.gap = "8px";\n      var caption = el("span", null, label);\n      caption.style.minWidth = "36px";\n      var input = el("input", "cdbx-input");\n      input.type = "text";\n      input.spellcheck = false;\n      input.autocomplete = "off";\n      input.style.flex = "1 1 auto";\n      input.style.maxWidth = "320px";\n      input.setAttribute("aria-label", label + " font");\n      input.disabled = true;\n      wrap.appendChild(caption);\n      wrap.appendChild(input);\n      main.appendChild(wrap);\n      return input;\n    }\n\n    var uiInput = field("UI");\n    var codeInput = field("Code");\n    var stateLine = el("div", "cdbx-state", "Loading...");\n    main.appendChild(stateLine);\n    node.appendChild(main);\n\n    var aside = el("div", "cdbx-row-aside");\n    var applyBtn = el("button", "cdbx-btn", "Apply");\n    applyBtn.type = "button";\n    applyBtn.disabled = true;\n    var resetBtn = el("button", "cdbx-btn", "Reset");\n    resetBtn.type = "button";\n    resetBtn.disabled = true;\n    aside.appendChild(applyBtn);\n    aside.appendChild(resetBtn);\n    node.appendChild(aside);\n    host.appendChild(node);\n    panel.appendChild(host);\n\n    var defaults = { ui: "", code: "" };\n\n    function describe(ui, code) {\n      return "UI: " + (ui || "Claude default") + " - Code: " + (code || "Claude default");\n    }\n\n    function show(res) {\n      uiInput.value = res.ui || "";\n      codeInput.value = res.code || "";\n      uiInput.placeholder = defaults.ui || "Claude default";\n      codeInput.placeholder = defaults.code || "Claude default";\n      stateLine.textContent = describe(res.ui, res.code);\n    }\n\n    function busy(on) {\n      uiInput.disabled = on;\n      codeInput.disabled = on;\n      applyBtn.disabled = on;\n      resetBtn.disabled = on;\n    }\n\n    function submit(ui, code) {\n      busy(true);\n      api.fontsSet(ui, code).then(function (r) {\n        busy(false);\n        if (failed(r)) { toast("Could not change the fonts: " + reason(r), true); return; }\n        show(r);\n        node.classList.add("cdbx-flash");\n        setTimeout(function () { node.classList.remove("cdbx-flash"); }, 700);\n        toast("Fonts applied in " + r.windows + " window(s)");\n      }, function (err) {\n        busy(false);\n        toast("Could not change the fonts: " + (err && err.message ? err.message : String(err)), true);\n      });\n    }\n\n    api.fontsRead().then(function (res) {\n      if (failed(res)) {\n        stateLine.textContent = "Unavailable: " + reason(res);\n        return;\n      }\n      defaults = res.defaults || defaults;\n      show(res);\n      if (res.lockedByJsonc) {\n        stateLine.textContent = describe(res.ui, res.code) + " - set in claude-desktop-extra.jsonc";\n        return;\n      }\n      busy(false);\n      applyBtn.addEventListener("click", function () { submit(uiInput.value, codeInput.value); });\n      resetBtn.addEventListener("click", function () { submit(null, null); });\n      [uiInput, codeInput].forEach(function (input) {\n        input.addEventListener("keydown", function (ev) {\n          if (ev.key === "Enter") { ev.preventDefault(); submit(uiInput.value, codeInput.value); }\n        });\n      });\n    }, function (err) {\n      stateLine.textContent = "Unavailable: " + (err && err.message ? err.message : String(err));\n    });\n\n    return { head: head, host: host, spec: spec };\n  }\n\n'

UPSTREAM_URL = "https://github.com/patrickjaja/claude-desktop-extra.git"
PATCHES = [
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
]


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
        fetched = subprocess.run(
            ["git", "-C", str(repository), "fetch", "--quiet", "--depth=1", "origin", "master"],
            text=True,
            capture_output=True,
        )
        if fetched.returncode == 0:
            run(["git", "-C", str(repository), "reset", "--hard", "FETCH_HEAD"], capture_output=True)
            log("INFO", "Updated claude-desktop-extra from origin/master.")
        else:
            log("WARN", "Could not fetch the feature source; using its last local commit.")
    else:
        run(["git", "clone", "--quiet", "--depth=1", "--branch", "master", UPSTREAM_URL, str(repository)])
        log("INFO", "Cloned claude-desktop-extra master.")
    commit = subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        text=True,
    ).strip()
    print(commit)


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


def adapt_sources(source):
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
        '      note: "Hides the three macOS traffic-light buttons. The standard macOS frame and shadow stay in place. " +\n        "Restart Claude Work to apply the setting.",\n      ariaLabel: "hide the macOS window controls",',
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
        '"Window controls hidden - restart Claude Work"',
        1,
    )
    replace_text(
        settings,
        '"Window controls back - restart Claude Desktop to get the titlebar back"',
        '"Window controls back - restart Claude Work"',
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


def compile_patches(source):
    for executable in ("nim", "nimble", "make", "xcrun"):
        if shutil.which(executable) is None:
            raise RuntimeError(f"Required build tool is unavailable: {executable}")
    regex_path = subprocess.run(["nimble", "path", "regex"], text=True, capture_output=True)
    if regex_path.returncode != 0:
        run(["nimble", "install", "-y", "regex"])
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    targets = [str(path) for path in PATCHES]
    build = subprocess.run(
        ["make", "-C", str(source / "patches"), "-j4", *targets],
        text=True,
        capture_output=True,
        env={**os.environ, "SDKROOT": sdk},
    )
    if build.returncode != 0:
        raise RuntimeError("Nim patch build failed:\n" + build.stdout + build.stderr)
    log("INFO", f"Compiled {len(PATCHES)} feature patchers for macOS.")


def apply_patches(source, app_contents, workspace):
    patchset = pathlib.Path(workspace) / "port-patches"
    (patchset / "linux").mkdir(parents=True, exist_ok=True)
    for relative in PATCHES:
        relative_path = pathlib.Path(relative)
        destination = patchset / relative_path.parent
        destination.mkdir(parents=True, exist_ok=True)
        base = source / "patches" / relative_path
        shutil.copy2(base.with_suffix(".nim"), destination / base.with_suffix(".nim").name)
        shutil.copy2(base, destination / base.name)
    script = source / "scripts/apply_patches.py"
    namespace = runpy.run_path(str(script), run_name="claude_work_patch_runner")
    namespace["main"].__globals__["EXPECTED_PATCH_COUNT"] = len(PATCHES)
    sys.argv = [str(script), str(patchset), str(pathlib.Path(app_contents).parent)]
    namespace["main"]()
    main_bundle = pathlib.Path(app_contents) / ".vite/build/index.js"
    text = main_bundle.read_text()
    if 'require("./index.chunk-' not in text or "__cdbClaudeWorkMacWindowControls" in text:
        raise RuntimeError("Claude's main loader changed or already contains the macOS window-control hook.")
    hook = ';(function(){var m="__cdbClaudeWorkMacWindowControls";if(globalThis[m])return;globalThis[m]=true;if(process.platform!=="darwin")return;try{var e=require("electron");e.app.on("browser-window-created",function(_event,w){try{w.webContents.once("did-finish-load",function(){try{if(w.webContents.getURL().indexOf("cdb-theme-picker")>=0)return;if(globalThis.__cdbNoWinCtl&&globalThis.__cdbNoWinCtl()&&typeof w.setWindowButtonVisibility==="function")w.setWindowButtonVisibility(false)}catch(x){console.warn("[Claude Work Extras] Window-control hook failed",x)}})}catch(x){console.warn("[Claude Work Extras] Window-control hook registration failed",x)}})}catch(x){console.warn("[Claude Work Extras] Window-control hook initialization failed",x)}})();'
    if 'var M="__cdbFonts"' in text:
        raise RuntimeError("Claude's main loader already contains the fonts module.")
    main_bundle.write_text(text + hook + "\n" + FONTS_MAIN + "\n")
    log("INFO", "Added the macOS window-control behavior to the standard feature setting.")
    log("INFO", "Added the configurable UI and code font setting to Extra.")


def apply_mode(repository, app_contents, workspace):
    repository = pathlib.Path(repository).expanduser()
    workspace = pathlib.Path(workspace).expanduser()
    archive = workspace / "claude-desktop-extra.tar"
    source = workspace / "claude-desktop-extra-macos"
    with archive.open("wb") as target:
        run(["git", "-C", str(repository), "archive", "--format=tar", "HEAD"], stdout=target)
    source.mkdir()
    with tarfile.open(archive) as contents:
        contents.extractall(source, filter="data")
    commit = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
    adapt_sources(source)
    compile_patches(source)
    apply_patches(source, app_contents, workspace)
    log("INFO", f"Applied macOS-compatible extras from upstream {commit}.")


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: claude_work_extra_port.py sync|apply ...")
    mode = sys.argv[1]
    if mode == "sync" and len(sys.argv) == 3:
        sync_repository(sys.argv[2])
        return
    if mode == "apply" and len(sys.argv) == 5:
        apply_mode(sys.argv[2], sys.argv[3], sys.argv[4])
        return
    raise SystemExit("Usage: claude_work_extra_port.py sync <support-root> | apply <repo> <app-asar-contents> <workspace>")


if __name__ == "__main__":
    main()
