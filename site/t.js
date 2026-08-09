/* Besties tracking — provider-agnostic event bus.
 *
 * To add a provider: append an object with init() and track(event, props)
 * to PROVIDERS below. Nothing else on the site changes.
 *
 * Pages call window.bt.track("event", {props}) — a stub in each page's
 * <head> queues calls made before this file loads. Elements marked
 * data-t="event_name" (plus optional data-t-<prop>="value" attributes)
 * are tracked automatically on click.
 */
(function () {
  "use strict";

  var PROVIDERS = [

    /* ---- PostHog: web analytics + custom events + funnels ---- */
    {
      init: function () {
        /* Official posthog-js loader snippet */
        !function(t,e){var o,n,p,r;e.__SV||(window.posthog=e,e._i=[],e.init=function(i,s,a){function g(t,e){var o=e.split(".");2==o.length&&(t=t[o[0]],e=o[1]),t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}}(p=t.createElement("script")).type="text/javascript",p.crossOrigin="anonymous",p.async=!0,p.src=s.api_host.replace(".i.posthog.com","-assets.i.posthog.com")+"/static/array.js",(r=t.getElementsByTagName("script")[0]).parentNode.insertBefore(p,r);var u=e;for(void 0!==a?u=e[a]=[]:a="posthog",u.people=u.people||[],u.toString=function(t){var e="posthog";return"posthog"!==a&&(e+="."+a),t||(e+=" (stub)"),e},u.people.toString=function(){return u.toString(1)+".people (stub)"},o="init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug".split(" "),n=0;n<o.length;n++)g(u,o[n]);e._i.push([i,s,a])},e.__SV=1)}(document,window.posthog||[]);
        window.posthog.init("phc_Cerf7iicDsqH3tYAWsRSjds9gNnjYp3Kqc99MaE7kCEx", {
          api_host: "https://us.i.posthog.com",
          persistence: "localStorage",       // no cookies → no consent banner
          person_profiles: "identified_only",
          autocapture: false,                // we track deliberately
          capture_pageview: false,           // captured explicitly below (deferred load
                                             // breaks the SDK's automatic pageview)
          capture_pageleave: true,           // bounce rate + duration for web analytics
          disable_session_recording: true,
          // Keep Stripe checkout session ids out of recorded URLs
          sanitize_properties: function (props) {
            ["$current_url", "$referrer"].forEach(function (k) {
              if (typeof props[k] === "string") {
                props[k] = props[k].replace(/session_id=[^&#]+/, "session_id=redacted");
              }
            });
            return props;
          }
        });
        window.posthog.capture("$pageview");   // exactly one per page load
      },
      track: function (event, props) {
        window.posthog.capture(event, props);
      }
    },

    /* ---- Reddit Ads: server-side conversions, first-party only ----
     * No Reddit script, no Reddit hostname — nothing for ad blockers to
     * match. Funnel events beacon to our own /api/e, which forwards them
     * to Reddit's Conversions API with IP + user agent for matching.
     * Attribution comes from the rdt_cid click id Reddit appends to ad
     * URLs, stashed in localStorage so it survives the Stripe round-trip
     * to the thanks page. Only the events in EVENTS are forwarded;
     * everything else (scroll depth, FAQ opens, …) stays PostHog-only.
     * Copy this shape for Meta/TikTok later — new endpoint, new map. */
    {
      EVENTS: {
        pageview:          "PageVisit",
        checkout_start:    "AddToCart",
        purchase_complete: "Purchase"
      },
      init: function () {
        try {
          /* Reddit requires an RFC-4122 UUID; regenerate anything else */
          var uid = localStorage.getItem("bt_uid");
          if ((!uid || uid.length !== 36) && window.crypto && crypto.randomUUID) {
            localStorage.setItem("bt_uid", crypto.randomUUID());
          }
          var cid = new URLSearchParams(location.search).get("rdt_cid");
          if (cid) localStorage.setItem("bt_rdt_cid", cid);
        } catch (e) {}
        this.track("pageview");
      },
      track: function (event, props) {
        var type = this.EVENTS[event];
        if (!type) return;
        var body = { t: type, sw: screen.width, sh: screen.height };
        try {
          body.id = localStorage.getItem("bt_uid");
          body.cid = localStorage.getItem("bt_rdt_cid");
        } catch (e) {}
        if (event === "purchase_complete") {
          /* Stripe session id → conversion_id so Reddit dedupes retries
           * even where the thanks page's localStorage guard can't. */
          body.conv = new URLSearchParams(location.search).get("session_id");
        }
        navigator.sendBeacon("/api/e",
          new Blob([JSON.stringify(body)], { type: "application/json" }));
      }
    }

  ];

  PROVIDERS.forEach(function (p) {
    try { p.init(); } catch (e) {}
  });

  function track(event, props) {
    PROVIDERS.forEach(function (p) {
      try { p.track(event, props || {}); } catch (e) {}
    });
  }

  /* Replace the head stub, drain anything it queued */
  var queued = (window.bt && window.bt.q) || [];
  window.bt = { track: track };
  queued.forEach(function (args) { track(args[0], args[1]); });

  /* ---------- declarative clicks: any [data-t] element ---------- */
  document.addEventListener("click", function (e) {
    var el = e.target.closest && e.target.closest("[data-t]");
    if (!el) return;
    var props = {};
    for (var i = 0; i < el.attributes.length; i++) {
      var a = el.attributes[i];
      if (a.name.indexOf("data-t-") === 0) props[a.name.slice(7)] = a.value;
    }
    track(el.getAttribute("data-t"), props);
  });

  /* ---------- section views (fires once per section) ---------- */
  var sections = document.querySelectorAll("#usecases, #features, #privacy, #get, #faq");
  if (sections.length && "IntersectionObserver" in window) {
    // Counts as viewed once 30% of the section is visible — or, for sections
    // taller than the viewport, once it covers half the screen.
    var seen = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var covers = entry.intersectionRect.height >= window.innerHeight * 0.5;
        if (entry.intersectionRatio < 0.3 && !covers) return;
        track("section_view", { section: entry.target.id });
        seen.unobserve(entry.target);
      });
    }, { threshold: [0.05, 0.1, 0.15, 0.2, 0.25, 0.3] });
    sections.forEach(function (s) { seen.observe(s); });
  }

  /* ---------- scroll depth: 25 / 50 / 75 / 100 ---------- */
  var depths = [25, 50, 75, 100];
  var ticking = false;
  window.addEventListener("scroll", function () {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      ticking = false;
      var max = document.documentElement.scrollHeight - window.innerHeight;
      if (max <= 0) return;
      var pct = (window.scrollY / max) * 100;
      if (max - window.scrollY < 2) pct = 100; // fractional positions at the bottom
      while (depths.length && pct >= depths[0]) {
        track("scroll_depth", { depth: depths.shift() });
      }
    });
  }, { passive: true });

  /* ---------- FAQ opens (toggle doesn't bubble; use capture) ---------- */
  document.addEventListener("toggle", function (e) {
    var d = e.target;
    if (!d.open || !d.closest || !d.closest("#faq")) return;
    var summary = d.querySelector("summary");
    if (summary) track("faq_open", { question: summary.textContent.trim() });
  }, true);
})();
