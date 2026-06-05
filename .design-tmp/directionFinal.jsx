/* Throttle — FINAL hybrid: binding hero + full secondary rows + danger ticks */
const { tone: toneF, bindingWindow: bindingF } = window.Throttle;

/* full secondary row (legible label + horizontal bar + reset underneath) */
function SecRow({ w }) {
  if (w.status === "empty") {
    return (
      <div className="srow">
        <div className="sr-top">
          <div className="sr-label">
            <span className="sr-name">{w.name}</span>
            <span className="sr-sub">{w.sub}</span>
          </div>
          <span className="sr-pct muted num">—<span className="pct">%</span></span>
        </div>
        <FillBar pct={null} conf={w.conf} />
        <div className="sr-meta">
          <span className="statline">No sessions yet — start one in Claude Code.</span>
        </div>
      </div>
    );
  }
  if (w.status === "calibrate") {
    return (
      <div className="srow">
        <div className="sr-top">
          <div className="sr-label">
            <span className="sr-name">{w.name}</span>
            <span className="sr-sub">{w.sub}</span>
          </div>
          <span className="sr-pct muted num">—<span className="pct">%</span></span>
        </div>
        <FillBar pct={null} conf={w.conf} />
        <div className="sr-meta">
          <span className="statline">Not calibrated yet — <span className="act">tap to set your cap›</span></span>
        </div>
      </div>
    );
  }

  const t = toneF(w.pct);
  const pctCls = w.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  return (
    <div className="srow">
      <div className="sr-top">
        <div className="sr-label">
          <span className="sr-name">{w.name}</span>
          <span className="sr-sub">{w.sub}</span>
        </div>
        <Pct pct={w.pct} conf={w.conf} className={"sr-pct " + pctCls} />
      </div>
      <FillBar pct={w.pct} conf={w.conf} />
      <div className="sr-meta">
        <span className="sr-reset">resets <span className="num">{w.reset}</span></span>
        {w.conf === "estimate" && <EstTag />}
      </div>
    </div>
  );
}

function DirectionFinal({ data }) {
  const hero = bindingF(data.windows);
  const rest = data.windows.filter((w) => !hero || w.id !== hero.id);

  let heroCls = "";
  if (hero) {
    const t = toneF(hero.pct);
    heroCls = hero.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  }
  const headroom = hero ? 100 - hero.pct : null;
  const heroEst = hero && hero.conf === "estimate";

  return (
    <div className="pop F">
      <TitleRow data={data} />
      <div className="sep" />
      {data.warning && <div style={{ height: 12 }} />}
      <WarningStrip text={data.warning} />

      {hero && (
        <div className="hero">
          <div className="hero-kick">
            <span>Binding now</span>·
            <span className="who">{hero.name}{hero.sub === "5-hour" ? " (5h)" : " · " + hero.sub}</span>
            {heroEst && <EstTag />}
          </div>
          <div className="hero-num">
            <span className={"hero-pct " + heroCls}>
              {heroEst && <span className="approx">≈</span>}
              {hero.pct}<span className="pct">%</span>
            </span>
            <span className="hero-side">
              used<br /><span className="num">{heroEst ? "≈" : ""}{headroom}%</span> headroom left
            </span>
          </div>
          <div className="herobar">
            <FillBar pct={hero.pct} conf={hero.conf} />
            <div className="tickrow">
              <span className="tlab" style={{ left: "80%" }}>80</span>
              <span className="tlab" style={{ left: "95%" }}>95</span>
            </div>
          </div>
          <div className="hero-reset">
            <span>resets <span className="num">{hero.reset}</span></span>
            <span>closest to cap</span>
          </div>
        </div>
      )}

      <div className="sep" />
      <div className="sec-kick">Other windows</div>
      <div className="seclist">
        {rest.map((w) => <SecRow key={w.id} w={w} />)}
      </div>

      {data.tier === "free" && <Upsell />}
      <div className="sep" />
      <Savings data={data} />
      <div className="sep" />
      <Actions data={data} />
    </div>
  );
}

window.DirectionFinal = DirectionFinal;
