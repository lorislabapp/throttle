/* Throttle — Settings data + scenarios (plain JS on window) */
(function () {
  // license:  free | trial | activated
  // exact:    locked (free) | off | working | error | needsignin
  const SCENARIOS = {
    activated: {
      key: "activated", tier: "pro", license: "activated", signedIn: true, exact: "working",
      trialDays: null,
    },
    trial: {
      key: "trial", tier: "trial", license: "trial", signedIn: true, exact: "off",
      trialDays: 11,
    },
    free: {
      key: "free", tier: "free", license: "free", signedIn: true, exact: "locked",
      trialDays: null,
    },
    exacterror: {
      key: "exacterror", tier: "pro", license: "activated", signedIn: true, exact: "error",
      trialDays: null,
    },
    signedout: {
      key: "signedout", tier: "pro", license: "activated", signedIn: false, exact: "needsignin",
      trialDays: null,
    },
  };

  const STATE_LIST = [
    { key: "activated", label: "Pro · activated" },
    { key: "trial",     label: "Trial" },
    { key: "free",      label: "Free" },
    { key: "exacterror",label: "Exact error" },
    { key: "signedout", label: "Signed out" },
  ];

  // calibration presets per window
  const CAPS = {
    session: { name: "Session", sub: "5-hour", presets: [
      { plan: "Pro", val: "4M" }, { plan: "Max 5×", val: "8M" }, { plan: "Max 20×", val: "20M" },
    ], sel: 1 },
    weekly: { name: "Weekly", sub: "all models", presets: [
      { plan: "Pro", val: "25M" }, { plan: "Max 5×", val: "50M" }, { plan: "Max 20×", val: "120M" },
    ], sel: 1 },
    sonnet: { name: "Weekly", sub: "Sonnet only", presets: [
      { plan: "Pro", val: "8M" }, { plan: "Max 5×", val: "16M" }, { plan: "Max 20×", val: "40M" },
    ], sel: 1 },
  };

  const HOOKS = [
    { id: "router",    name: "session-start router", desc: "routes new sessions through Throttle", status: "ok" },
    { id: "precompact", name: "pre-compact",          desc: "snapshots usage before context compaction", status: "ok" },
    { id: "kill",      name: "kill-switch",           desc: "halts runs at your hard cap", status: "missing" },
  ];

  const PROVIDERS = ["Apple Intelligence", "Claude subscription", "API key"];
  const MODELS = ["Opus", "Sonnet", "Haiku"];

  // group registry — id, label (full), short (for tab bar), icon key, one-line summary
  const GROUPS = [
    { id: "general",     label: "General",       short: "General", icon: "gear",   summary: "Launch, notifications, updates" },
    { id: "pro",         label: "Throttle Pro",  short: "Pro",     icon: "key",    summary: "License & Exact mode" },
    { id: "assistant",   label: "AI Assistant",  short: "AI",      icon: "spark",  summary: "Provider, model, caveman mode" },
    { id: "calibration", label: "Calibration",   short: "Caps",    icon: "target", summary: "Set your three usage caps" },
    { id: "hooks",       label: "Hooks",         short: "Hooks",   icon: "plug",   summary: "Shell integration status" },
    { id: "about",       label: "Privacy & About", short: "About", icon: "info",   summary: "Logs, privacy, version" },
  ];

  window.ThrottleSettings = { SCENARIOS, STATE_LIST, CAPS, HOOKS, PROVIDERS, MODELS, GROUPS };
})();
