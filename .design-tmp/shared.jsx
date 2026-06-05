/* Throttle — shared React primitives (exported to window) */
const { tone } = window.Throttle;

/* ---------- tiny inline glyphs (UI icons, kept minimal) ---------- */
function GaugeMark() {
  return (
    <svg className="mark" viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path d="M12 21a9 9 0 1 1 9-9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      <path d="M12 12l5.2-3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
      <circle cx="12" cy="12" r="1.7" fill="currentColor"/>
    </svg>
  );
}
function Icon({ name, className }) {
  const p = {
    person: <><circle cx="12" cy="8" r="3.4" stroke="currentColor" strokeWidth="1.6"/><path d="M5.5 19a6.5 6.5 0 0 1 13 0" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    ext: <><path d="M14 5h5v5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/><path d="M19 5l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/><path d="M18 14v4a1.5 1.5 0 0 1-1.5 1.5H6.5A1.5 1.5 0 0 1 5 18V7.5A1.5 1.5 0 0 1 6.5 6h4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    warn: <><path d="M12 4.5l8 14H4l8-14Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/><path d="M12 10v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/><circle cx="12" cy="16.5" r="0.4" fill="currentColor" stroke="currentColor" strokeWidth="1.1"/></>,
  }[name];
  return <svg className={className} viewBox="0 0 24 24" fill="none" aria-hidden="true">{p}</svg>;
}

/* ---------- pills ---------- */
function Pill({ kind, children }) {
  return <span className={"pill " + kind}>{children}</span>;
}

/* ---------- title row ---------- */
function TitleRow({ data }) {
  return (
    <div className="titlebar">
      <GaugeMark />
      <span className="wordmark">Throttle</span>
      <span className="title-spacer" />
      {data.tier === "pro"
        ? <Pill kind="pro">Pro</Pill>
        : <Pill kind="free">Free</Pill>}
      {data.exact && <Pill kind="exact"><span className="dot" />Exact</Pill>}
    </div>
  );
}

/* ---------- numbers ---------- */
function Pct({ pct, conf, className }) {
  // renders e.g.  ≈47%  with mono + tone class
  const approx = conf === "estimate";
  return (
    <span className={"num " + (className || "")}>
      {approx && <span className="approx">≈</span>}
      {pct}<span className="pct">%</span>
    </span>
  );
}

/* ---------- fill bar with threshold ticks ---------- */
function FillBar({ pct, conf, dimEmpty }) {
  const t = tone(pct);
  const cls = ["fill", t !== "neutral" ? t : "", conf === "estimate" ? "est" : ""].filter(Boolean).join(" ");
  return (
    <div className="bar">
      <span className="tick" style={{ left: "80%" }} />
      <span className="tick" style={{ left: "95%" }} />
      {pct != null && <span className={cls} style={{ width: Math.max(2, Math.min(100, pct)) + "%" }} />}
    </div>
  );
}

function EstTag() { return <span className="esttag">estimate</span>; }

/* ---------- warning strip ---------- */
function WarningStrip({ text }) {
  if (!text) return null;
  const dash = text.indexOf("—");
  const lead = dash > -1 ? text.slice(0, dash).trim() : null;
  const rest = dash > -1 ? text.slice(dash) : text;
  return (
    <div className="warnstrip">
      <Icon name="warn" className="wi" />
      <span>{lead && <b>{lead}</b>}{lead ? " " : ""}{rest}</span>
    </div>
  );
}

/* ---------- savings footnote ---------- */
function Savings({ data }) {
  return (
    <div className="savings">
      <span className="approx num">≈{data.savings.money}</span>
      <span>saved</span>
      <span className="s-sep">·</span>
      <span className="num">{data.savings.tokens}</span>
      <span>tokens this week</span>
      <span className="stats">Stats›</span>
    </div>
  );
}

/* ---------- free-tier upsell ---------- */
function Upsell() {
  return (
    <div className="upsell">
      Values are local <b>estimates</b>. <span className="link">Upgrade to Pro</span> for server-true exact readings.
    </div>
  );
}

/* ---------- actions cluster ---------- */
function Actions({ data }) {
  return (
    <div className="actions">
      {!data.signedIn && (
        <div className="act-row accent">
          <Icon name="person" className="ic" />
          <span>Sign in to claude.ai</span>
        </div>
      )}
      <div className="act-row">
        <Icon name="ext" className="ic" />
        <span>Open claude.ai/usage</span>
        <span className="ext">↗</span>
      </div>
      <div className="act-footer">
        <span className="act-mini">Stats</span>
        <span className="act-mini">Settings</span>
        <span className="act-mini quit">Quit</span>
      </div>
    </div>
  );
}

Object.assign(window, {
  GaugeMark, Icon, Pill, TitleRow, Pct, FillBar, EstTag,
  WarningStrip, Savings, Upsell, Actions,
});
