/* Throttle — Direction C: vertical gauge cluster + status strip */
const { tone: toneC, bindingWindow: bindingC } = window.Throttle;

function CGauge({ w }) {
  // ghost states
  if (w.status === "empty" || w.status === "calibrate") {
    const txt = w.status === "empty"
      ? "No sessions yet"
      : "Not calibrated";
    return (
      <div className="gauge">
        <div className="g-pct muted num">—<span className="pct">%</span></div>
        <div className="g-track ghost">
          <div className="g-grid" style={{ bottom: "80%" }} />
          <div className="g-grid" style={{ bottom: "95%" }} />
          <div className="g-ghost-txt">{txt}</div>
        </div>
        <div className="g-label">{w.name}<span className="sub">{w.sub}</span></div>
        <div className="g-reset">{w.status === "calibrate"
          ? <span className="num" style={{ color: "var(--accent)" }}>Set cap›</span>
          : "in Claude Code"}</div>
      </div>
    );
  }

  const t = toneC(w.pct);
  const fillCls = ["g-fill", t !== "neutral" ? t : "", w.conf === "estimate" ? "est" : ""].filter(Boolean).join(" ");
  const pctCls = w.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  return (
    <div className="gauge">
      <div className={"g-pct num " + pctCls}>
        {w.conf === "estimate" && <span className="approx">≈</span>}
        {w.pct}<span className="pct">%</span>
      </div>
      <div className="g-track">
        {t === "warn" && <div className="g-zone warn" />}
        {t === "crit" && <div className="g-zone crit" />}
        <div className="g-grid" style={{ bottom: "80%" }} />
        <div className="g-grid" style={{ bottom: "95%" }} />
        <div className={fillCls} style={{ height: Math.max(2, Math.min(100, w.pct)) + "%" }} />
      </div>
      <div className="g-label">{w.name}<span className="sub">{w.sub}</span></div>
      <div className="g-reset">resets <span className="num">{w.resetShort}</span></div>
      {w.conf === "estimate" && <div className="g-est"><EstTag /></div>}
    </div>
  );
}

function DirectionC({ data }) {
  const b = bindingC(data.windows);
  const bt = b ? toneC(b.pct) : "neutral";
  const lampCls = b && bt !== "neutral" ? bt : "";

  return (
    <div className="pop C">
      <TitleRow data={data} />
      <div className="sep" />
      {data.warning && <div style={{ height: 12 }} />}
      <WarningStrip text={data.warning} />

      <div className="status">
        <span className={"lamp " + lampCls} />
        <span className="stxt">
          {b ? <>
            <b>{b.name}{b.sub === "5-hour" ? "" : " " + b.sub}</b>{" "}
            <span className="num">{b.conf === "estimate" ? "≈" : ""}{b.pct}%</span> used · closest to cap
          </> : "No active windows"}
        </span>
        {b && <span className="right">resets {b.resetShort}</span>}
      </div>

      <div className="gauges">
        {data.windows.map((w) => <CGauge key={w.id} w={w} />)}
      </div>

      {data.tier === "free" && <Upsell />}
      <div className="sep" />
      <Savings data={data} />
      <div className="sep" />
      <Actions data={data} />
    </div>
  );
}

window.DirectionC = DirectionC;
