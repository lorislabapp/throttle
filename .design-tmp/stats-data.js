/* Throttle — Stats panel data (plain JS on window) */
(function () {
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const series = (n, fn) => Array.from({ length: n }, (_, i) => clamp(fn(i, n), 1, 99));
  const N = 30;

  const TREND_FULL = {
    session: series(N, (i) => 46 + 34 * Math.sin(i / 2.0) + 11 * Math.sin(i / 0.7)),
    weekly:  series(N, (i) => 3 + i * 0.40 + 2 * Math.sin(i / 3.2)),
    sonnet:  series(N, (i) => 1.5 + 2.4 * Math.abs(Math.sin(i / 3.4))),
  };
  const TREND_SPARSE = {
    session: series(7, (i) => 30 + 24 * Math.sin(i / 1.3)),
    weekly:  series(7, (i) => 1 + i * 0.7),
    sonnet:  series(7, (i) => 1 + 0.6 * i),
  };

  const PROJECTS = [
    { name: "throttle-app",   tokens: "84M", pct: 40 },
    { name: "api-gateway",    tokens: "52M", pct: 25 },
    { name: "design-system",  tokens: "33M", pct: 16 },
    { name: "infra/terraform", tokens: "21M", pct: 10 },
    { name: "dotfiles",       tokens: "19M", pct: 9 },
  ];

  const LADDER_FULL = [
    { id: "free",  name: "Free",    price: "€0",   fit: "throttled",   tone: "crit" },
    { id: "pro",   name: "Pro",     price: "€19",  fit: "throttles Thu", tone: "crit", current: true },
    { id: "max5",  name: "Max 5×",  price: "€90",  fit: "comfortable", tone: "ok", best: true },
    { id: "max20", name: "Max 20×", price: "€180", fit: "over-provisioned", tone: "muted" },
  ];
  const LADDER_FREE = [
    { id: "free",  name: "Free",    price: "€0",   fit: "tight", tone: "warn", current: true },
    { id: "pro",   name: "Pro",     price: "€19",  fit: "comfortable", tone: "ok", best: true },
    { id: "max5",  name: "Max 5×",  price: "€90",  fit: "over-provisioned", tone: "muted" },
    { id: "max20", name: "Max 20×", price: "€180", fit: "over-provisioned", tone: "muted" },
  ];

  const SPLIT_FULL = [
    { name: "Opus",   pct: 68, eur: "€312" },
    { name: "Sonnet", pct: 28, eur: "€78" },
    { name: "Haiku",  pct: 4,  eur: "€10" },
  ];
  const SPLIT_FREE = [
    { name: "Opus",   pct: 22, eur: "€41" },
    { name: "Sonnet", pct: 61, eur: "€33" },
    { name: "Haiku",  pct: 17, eur: "€6" },
  ];

  const SCENARIOS = {
    full: {
      key: "full", tier: "pro", exact: true, confident: true, warning: null,
      enough: true, signedIn: true,
      advisor: {
        recommend: { name: "Max 5×", price: "€90", per: "/mo", blurb: "best for your usage" },
        current: { name: "Pro", price: "€19", status: "throttles Thursday", tone: "crit" },
        apiEquiv: "€400", savings: "€310", burn: "210M",
        reasoning: "You burn 210M weighted tokens/wk, Opus-heavy (68%).",
      },
      runway: { capDay: "Thu", capTime: "3 PM", consumed: 62, capAt: 78, tone: "crit" },
      ladder: LADDER_FULL,
      split: SPLIT_FULL,
      period: { today: "32M", week: "210M", saved: "€310" },
      trend: TREND_FULL,
      projects: PROJECTS,
    },

    free: {
      key: "free", tier: "free", exact: false, confident: false, warning: null,
      enough: true, signedIn: false,
      advisor: {
        recommend: { name: "Pro", price: "€19", per: "/mo", blurb: "best for your usage" },
        current: { name: "Free", price: "€0", status: "hitting limits", tone: "warn" },
        apiEquiv: "€74", savings: "€55", burn: "38M",
        reasoning: "You burn ~38M weighted tokens/wk, Sonnet-heavy (61%).",
      },
      runway: { capDay: "Wed", capTime: "1 PM", consumed: 71, capAt: 64, tone: "warn" },
      ladder: LADDER_FREE,
      split: SPLIT_FREE,
      period: { today: "5M", week: "38M", saved: "€55" },
      trend: TREND_FULL,
      projects: PROJECTS,
    },

    notenough: {
      key: "notenough", tier: "pro", exact: true, confident: true, warning: null,
      enough: false, signedIn: true,
      collected: 4, needed: 6,
      advisor: null,
      runway: null,
      ladder: LADDER_FULL,
      split: null,
      period: { today: "8M", week: "8M", saved: "€2" },
      trend: TREND_SPARSE,
      projects: PROJECTS.slice(0, 2),
    },

    estimate: {
      key: "estimate", tier: "pro", exact: false, confident: false,
      warning: "Exact mode unavailable — figures are local estimates.",
      enough: true, signedIn: true,
      advisor: {
        recommend: { name: "Max 5×", price: "€90", per: "/mo", blurb: "best guess for your usage" },
        current: { name: "Pro", price: "€19", status: "likely throttles Thu", tone: "crit" },
        apiEquiv: "€400", savings: "€310", burn: "210M",
        reasoning: "Estimated 210M weighted tokens/wk, Opus-heavy (68%).",
      },
      runway: { capDay: "Thu", capTime: "3 PM", consumed: 62, capAt: 78, tone: "crit" },
      ladder: LADDER_FULL,
      split: SPLIT_FULL,
      period: { today: "32M", week: "210M", saved: "€310" },
      trend: TREND_FULL,
      projects: PROJECTS,
    },
  };

  const STATE_LIST = [
    { key: "full",      label: "Pro · full" },
    { key: "estimate",  label: "Estimate" },
    { key: "notenough", label: "Not enough data" },
    { key: "free",      label: "Free tier" },
  ];

  const RANGES = ["24h", "7d", "30d", "all"];

  window.ThrottleStats = { SCENARIOS, STATE_LIST, RANGES, clamp };
})();
