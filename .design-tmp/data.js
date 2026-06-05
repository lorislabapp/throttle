/* Throttle — scenario data + helpers (plain JS, attached to window) */
(function () {
  // pressure tone from a percentage
  function tone(pct) {
    if (pct == null) return "neutral";
    if (pct >= 95) return "crit";
    if (pct >= 80) return "warn";
    return "neutral";
  }

  // Each scenario returns the full popover model.
  // window: { id, name, sub, pct, reset, conf:'exact'|'estimate', status:'ok'|'calibrate'|'empty' }
  const SCENARIOS = {
    exact: {
      key: "exact",
      tier: "pro",
      exact: true,            // EXACT pill visible
      warning: null,
      signedIn: true,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: 47, reset: "9:00 PM", resetShort: "9 PM", conf: "exact", status: "ok" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 12, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "exact", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: 3, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
      ],
      savings: { money: "€6.00", tokens: "1.2M" },
    },

    pressure: {
      key: "pressure",
      tier: "pro",
      exact: true,
      warning: null,
      signedIn: true,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: 88, reset: "9:00 PM", resetShort: "9 PM", conf: "exact", status: "ok" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 61, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "exact", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: 96, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "exact", status: "ok" },
      ],
      savings: { money: "€6.00", tokens: "1.2M" },
    },

    estimate: {
      key: "estimate",
      tier: "pro",
      exact: false,
      warning: "Exact mode unavailable — showing local estimates.",
      signedIn: true,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: 47, reset: "9:00 PM", resetShort: "9 PM", conf: "estimate", status: "ok" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 12, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: 3, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
      ],
      savings: { money: "€6.00", tokens: "1.2M" },
    },

    calibrate: {
      key: "calibrate",
      tier: "pro",
      exact: true,
      warning: null,
      signedIn: true,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: 47, reset: "9:00 PM", resetShort: "9 PM", conf: "exact", status: "ok" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 12, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "exact", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: null, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "calibrate" },
      ],
      savings: { money: "€6.00", tokens: "1.2M" },
    },

    empty: {
      key: "empty",
      tier: "pro",
      exact: true,
      warning: null,
      signedIn: true,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: null, reset: null, resetShort: null, conf: "exact", status: "empty" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 12, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "exact", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: 3, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
      ],
      savings: { money: "€0.00", tokens: "0" },
    },

    free: {
      key: "free",
      tier: "free",
      exact: false,
      warning: null,
      signedIn: false,
      windows: [
        { id: "session", name: "Session", sub: "5-hour", pct: 47, reset: "9:00 PM", resetShort: "9 PM", conf: "estimate", status: "ok" },
        { id: "weekly",  name: "Weekly",  sub: "all models", pct: 12, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
        { id: "sonnet",  name: "Weekly",  sub: "Sonnet only", pct: 3, reset: "Mon 4:00 PM", resetShort: "Mon", conf: "estimate", status: "ok" },
      ],
      savings: { money: "€6.00", tokens: "1.2M" },
    },
  };

  const STATE_LIST = [
    { key: "exact",     label: "Exact (live)" },
    { key: "pressure",  label: "Near limit" },
    { key: "estimate",  label: "Estimate mode" },
    { key: "calibrate", label: "Not calibrated" },
    { key: "empty",     label: "Empty" },
    { key: "free",      label: "Free tier" },
  ];

  // Which window is "binding" = the active (non-empty/calibrate) window closest to cap.
  function bindingWindow(windows) {
    let best = null;
    for (const w of windows) {
      if (w.status !== "ok" || w.pct == null) continue;
      if (!best || w.pct > best.pct) best = w;
    }
    return best;
  }

  window.Throttle = { SCENARIOS, STATE_LIST, tone, bindingWindow };
})();
