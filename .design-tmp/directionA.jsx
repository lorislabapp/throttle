/* Throttle — Direction A: equal telemetry rows */
const { tone: toneA } = window.Throttle;

function ARow({ w }) {
  if (w.status === "empty") {
    return (
      <div className="trow">
        <div className="tr-top">
          <div className="tr-label">
            <span className="tr-name">{w.name}</span>
            <span className="tr-sub">{w.sub}</span>
          </div>
        </div>
        <div className="statline">
          <span className="dash">— — —</span>
          <span>No sessions yet — start one in Claude Code.</span>
        </div>
      </div>
    );
  }
  if (w.status === "calibrate") {
    return (
      <div className="trow">
        <div className="tr-top">
          <div className="tr-label">
            <span className="tr-name">{w.name}</span>
            <span className="tr-sub">{w.sub}</span>
          </div>
          <span className="tr-pct muted num">—<span className="pct">%</span></span>
        </div>
        <FillBar pct={null} conf={w.conf} />
        <div className="tr-meta">
          <span className="statline">Not calibrated yet — <span className="act">tap to set your cap›</span></span>
        </div>
      </div>
    );
  }

  const t = toneA(w.pct);
  const pctCls = w.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  return (
    <div className="trow">
      <div className="tr-top">
        <div className="tr-label">
          <span className="tr-name">{w.name}</span>
          <span className="tr-sub">{w.sub}</span>
        </div>
        <Pct pct={w.pct} conf={w.conf} className={"tr-pct " + pctCls} />
      </div>
      <FillBar pct={w.pct} conf={w.conf} />
      <div className="tr-meta">
        <span className="tr-reset">resets <span className="num">{w.reset}</span></span>
        {w.conf === "estimate" && <EstTag />}
      </div>
    </div>
  );
}

function DirectionA({ data }) {
  return (
    <div className="pop A">
      <TitleRow data={data} />
      <div className="sep" />
      {data.warning && <div style={{ height: 12 }} />}
      <WarningStrip text={data.warning} />
      <div className="rows">
        {data.windows.map((w) => <ARow key={w.id} w={w} />)}
      </div>
      {data.tier === "free" && <Upsell />}
      <div className="sep" />
      <Savings data={data} />
      <div className="sep" />
      <Actions data={data} />
    </div>
  );
}

window.DirectionA = DirectionA;
