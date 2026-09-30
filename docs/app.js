(function () {
  "use strict";

  var REPO = "ssut/Barracks";
  var REPO_URL = "https://github.com/" + REPO;
  var RELEASES_URL = REPO_URL + "/releases";
  var LANGS = ["en", "ko", "ja"];
  var TINTS = ["#e0a33a", "#d9774b", "#8e6bdb", "#2ba59d", "#5b6ee0"];
  var ROTATE_MS = 2400;
  var TABLE = window.BARRACKS_I18N || {};

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
  var systemLight = window.matchMedia("(prefers-color-scheme: light)");
  var lang = "en";
  var releaseState = null;

  function log(event, fields) {
    var parts = ["event=" + event];
    Object.keys(fields || {}).forEach(function (key) { parts.push(key + "=" + fields[key]); });
    console.info(parts.join(" "));
  }

  function t(key, vars) {
    var entry = TABLE[key];
    var value = entry ? (entry[lang] !== undefined ? entry[lang] : entry.en) : key;
    if (!vars || typeof value !== "string") return value;
    return value.replace(/\{(\w+)\}/g, function (whole, name) { return name in vars ? vars[name] : whole; });
  }

  function words() {
    var list = t("hero.words");
    return Array.isArray(list) && list.length ? list : ["Work"];
  }

  var rotator = document.getElementById("rotator");
  var headlineSr = document.getElementById("headline-sr");
  var rotateTimer = null;
  var rotateIndex = 0;

  function syncWidth(target) {
    var shown = target instanceof HTMLElement ? target : rotator.querySelector(".word:not(.out)");
    if (shown) rotator.style.width = Math.ceil(shown.scrollWidth) + "px";
  }

  function paintGlow(tint) {
    document.documentElement.style.setProperty("--glow", tint + "2e");
  }

  function showWord(index, animate) {
    var list = words();
    var tint = TINTS[index % TINTS.length];
    var current = rotator.querySelector(".word.in");
    var next = document.createElement("span");
    next.className = "word";
    next.style.setProperty("--tint", tint);
    next.textContent = list[index % list.length];
    rotator.appendChild(next);
    paintGlow(tint);
    if (!animate) {
      Array.prototype.slice.call(rotator.querySelectorAll(".word")).forEach(function (el) {
        if (el !== next) el.remove();
      });
      next.classList.add("in");
      syncWidth(next);
      return;
    }
    next.offsetHeight;
    next.classList.add("in");
    syncWidth(next);
    if (current) {
      current.classList.remove("in");
      current.classList.add("out");
      setTimeout(function () { current.remove(); }, 700);
    }
  }

  function stopRotation() {
    clearInterval(rotateTimer);
    rotateTimer = null;
  }

  function resumeRotation() {
    stopRotation();
    rotateTimer = setInterval(function () {
      rotateIndex += 1;
      showWord(rotateIndex, true);
    }, reduced.matches ? ROTATE_MS * 1.5 : ROTATE_MS);
  }

  function startRotation() {
    rotateIndex = 0;
    showWord(0, false);
    headlineSr.textContent = (t("hero.before") + " " + words().join(", ") + " " + t("hero.after")).replace(/\s+/g, " ").trim();
    resumeRotation();
    log("rotator.started", { lang: lang, words: words().length, reduced: reduced.matches });
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) stopRotation();
    else if (!rotateTimer) resumeRotation();
  });
  window.addEventListener("resize", function () { syncWidth(); });
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(function () { syncWidth(); });

  function paintDownload() {
    var label = document.getElementById("download-label");
    label.textContent = releaseState ? t("hero.download.versioned", { version: releaseState.version }) : t("hero.download");
  }

  function paintLanguage() {
    document.documentElement.setAttribute("lang", lang);
    document.title = t("meta.title");
    var description = document.querySelector('meta[name="description"]');
    if (description) description.setAttribute("content", t("meta.description"));
    Array.prototype.slice.call(document.querySelectorAll("[data-i18n]")).forEach(function (el) {
      el.textContent = t(el.getAttribute("data-i18n"));
    });
    Array.prototype.slice.call(document.querySelectorAll("[data-i18n-alt]")).forEach(function (el) {
      el.setAttribute("alt", t(el.getAttribute("data-i18n-alt")));
    });
    document.getElementById("ghstar").setAttribute("aria-label", t("a11y.ghstar"));
    labelTheme();
    paintDownload();
    startRotation();
  }

  function setLanguage(next, persist) {
    lang = LANGS.indexOf(next) === -1 ? "en" : next;
    Array.prototype.slice.call(document.querySelectorAll(".lang button")).forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-lang") === lang));
    });
    if (persist) {
      try { localStorage.setItem("barracks-lang", lang); } catch (error) { void error; }
      var url = new URL(window.location.href);
      url.searchParams.delete("lang");
      history.replaceState(null, "", url);
    }
    paintLanguage();
    log("i18n.applied", { lang: lang, persist: Boolean(persist) });
  }

  function initialLanguage() {
    var fromUrl = new URL(window.location.href).searchParams.get("lang");
    if (LANGS.indexOf(fromUrl) !== -1) return fromUrl;
    var stored = null;
    try { stored = localStorage.getItem("barracks-lang"); } catch (error) { void error; }
    if (LANGS.indexOf(stored) !== -1) return stored;
    var preferred = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en"];
    for (var i = 0; i < preferred.length; i += 1) {
      var code = String(preferred[i]).toLowerCase().split("-")[0];
      if (LANGS.indexOf(code) !== -1) return code;
    }
    return "en";
  }

  var themeButton = document.getElementById("theme");

  function effectiveTheme() {
    return document.documentElement.getAttribute("data-theme") || (systemLight.matches ? "light" : "dark");
  }

  function labelTheme() {
    themeButton.setAttribute("aria-label", t(effectiveTheme() === "dark" ? "a11y.theme.toLight" : "a11y.theme.toDark"));
  }

  function applyTheme(value, persist) {
    if (value) document.documentElement.setAttribute("data-theme", value);
    else document.documentElement.removeAttribute("data-theme");
    if (persist) {
      try { localStorage.setItem("barracks-theme", value || ""); } catch (error) { void error; }
    }
    labelTheme();
    log("theme.applied", { value: value || "system" });
  }

  var storedTheme = null;
  try { storedTheme = localStorage.getItem("barracks-theme"); } catch (error) { void error; }
  if (storedTheme === "light" || storedTheme === "dark") applyTheme(storedTheme, false);
  themeButton.addEventListener("click", function () {
    applyTheme(effectiveTheme() === "dark" ? "light" : "dark", true);
  });
  systemLight.addEventListener("change", labelTheme);

  var tabs = Array.prototype.slice.call(document.querySelectorAll(".tabs button"));
  var shots = Array.prototype.slice.call(document.querySelectorAll(".swap .shot"));
  var tabTimer = null;

  function selectShot(name) {
    tabs.forEach(function (tab) { tab.setAttribute("aria-selected", String(tab.getAttribute("data-shot") === name)); });
    shots.forEach(function (shot) { shot.classList.toggle("on", shot.getAttribute("data-name") === name); });
  }

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      clearInterval(tabTimer);
      tabTimer = null;
      selectShot(tab.getAttribute("data-shot"));
      log("tabs.selected", { shot: tab.getAttribute("data-shot"), auto: false });
    });
  });

  if (!reduced.matches && tabs.length > 1) {
    tabTimer = setInterval(function () {
      var index = tabs.findIndex(function (tab) { return tab.getAttribute("aria-selected") === "true"; });
      selectShot(tabs[(index + 1) % tabs.length].getAttribute("data-shot"));
    }, 5200);
  }

  var reveals = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  if ("IntersectionObserver" in window && !reduced.matches) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("shown");
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    reveals.forEach(function (el) { observer.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("shown"); });
  }

  document.getElementById("ghstar").href = REPO_URL;
  document.getElementById("source-link").href = REPO_URL;
  document.getElementById("releases-link").href = RELEASES_URL;
  document.getElementById("download").href = RELEASES_URL;

  function fallback(reason) {
    document.getElementById("download").href = RELEASES_URL;
    releaseState = null;
    paintDownload();
    log("release.fallback", { reason: reason });
  }

  function loadRelease() {
    if (!("fetch" in window)) { fallback("fetch_unsupported"); return; }
    fetch("https://api.github.com/repos/" + REPO + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then(function (response) {
        if (!response.ok) { fallback(response.status === 404 ? "no_release" : "http_" + response.status); return null; }
        return response.json();
      })
      .then(function (data) {
        if (!data) return;
        var version = String(data.tag_name || "").replace(/^v/, "");
        if (!version) { fallback("tag_missing"); return; }
        var asset = (Array.isArray(data.assets) ? data.assets : []).filter(function (item) { return /\.(dmg|zip)$/i.test(item.name || ""); })[0];
        document.getElementById("download").href = asset ? asset.browser_download_url : (data.html_url || RELEASES_URL);
        releaseState = { kind: "version", version: version };
        paintDownload();
        log("release.resolved", { version: version, asset: asset ? asset.name : "none" });
      })
      .catch(function () { fallback("network_error"); });
  }

  function loadStars() {
    if (!("fetch" in window)) return;
    fetch("https://api.github.com/repos/" + REPO, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (response) { return response.ok ? response.json() : null; })
      .then(function (data) {
        if (!data || typeof data.stargazers_count !== "number") return;
        var count = data.stargazers_count;
        var el = document.getElementById("ghstar-count");
        el.textContent = count >= 1000 ? (count / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(count);
        el.hidden = false;
        log("stars.resolved", { count: count });
      })
      .catch(function () { log("stars.unavailable", {}); });
  }

  Array.prototype.slice.call(document.querySelectorAll(".lang button")).forEach(function (button) {
    button.addEventListener("click", function () { setLanguage(button.getAttribute("data-lang"), true); });
  });

  setLanguage(initialLanguage(), false);
  loadStars();
  loadRelease();
})();
