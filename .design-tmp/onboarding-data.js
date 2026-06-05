/* Throttle — first-run onboarding data (plain JS on window) */
(function () {
  // The one real choice. Caps are pre-filled per plan and written on finish.
  const PLANS = [
    { id: "pro",   name: "Pro",     price: "€19/mo",  session: "4M",  weekly: "60M",  blurb: "Most solo developers" },
    { id: "max5",  name: "Max 5×",  price: "€90/mo",  session: "20M", weekly: "300M", blurb: "Heavy daily Claude Code" },
    { id: "max20", name: "Max 20×", price: "€180/mo", session: "80M", weekly: "1.2B", blurb: "All-day, multi-agent" },
    { id: "skip",  name: "Skip — auto-calibrate", price: null, session: null, weekly: null,
      blurb: "Throttle learns your caps from real usage over a few days." },
  ];

  // demo snapshot the Living Meter shows once caps exist (believable first-glance)
  const DEMO_FILL = { session: 47, weekly: 12, sonnet: 3 };

  const COPY = {
    what: "The accurate Claude Code usage meter for your menu bar.",
    whatShort: "Accurate Claude Code usage, in your menu bar.",
    privacyShort: "Reads ~/.claude/projects on this Mac. Nothing leaves it.",
    privacyLong: "Throttle reads ~/.claude/projects locally. Nothing leaves this Mac — unless you turn on Exact mode (Pro), and even then only Safari talks to claude.ai.",
    exactTeaser: "Want server-true numbers? Turn on Exact mode later in Settings.",
    planPrompt: "Which Claude plan are you on?",
    planSub: "We'll pre-fill your usage caps. You can change them anytime.",
  };

  // Moments drive the comparison selector. Each direction interprets them.
  // pick: null | 'pro' | 'max5' | 'max20' | 'skip'
  const MOMENTS = [
    { key: "welcome",  label: "Welcome",      pick: null,   step: 0 },
    { key: "picked",   label: "Plan picked",  pick: "pro",  step: 1 },
    { key: "skip",     label: "Skip path",    pick: "skip", step: 1 },
    { key: "ready",    label: "Ready",        pick: "pro",  step: 2 },
  ];

  window.ThrottleOnb = { PLANS, DEMO_FILL, COPY, MOMENTS };
})();
