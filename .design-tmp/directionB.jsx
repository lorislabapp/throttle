/* Throttle — Direction B: binding number hero + secondary lines */
const { tone: toneB, bindingWindow } = window.Throttle;

function BMiniRow({ w }) {
  if (w.status === "empty") {
    return (
      <div className="mrow">
        <div className="m-label">
          <span className="m-name">{w.name}</span>
          <span className="m-sub">{w.sub}</span>
        </div>
        <span className="m-sub">No sessions yet</span>
      </div>
    );
  }
  if (w.status === "calibrate") {
    return (
      <div className="mrow">
        <div className="m-label">
          <span className="m-name">{w.name}</span>
          <span className="m-sub">{w.sub}</span>
        </div>
        <span className="statline" style={{ fontSize: 11 }}>
          <span className="act">Set cap›</span>
        </span>
      </div>
    );
  }
  const t = toneB(w.pct);
  const pctCls = w.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  return (
    <div className="mrow">
      <div className="m-label">
        <span className="m-name">{w.name}</span>
        <span className="m-sub">{w.sub}</span>
        {w.conf === "estimate" && <EstTag />}
      </div>
      <div className="m-right">
        <span className="m-bar"><FillBar pct={w.pct} conf={w.conf} /></span>
        <Pct pct={w.pct} conf={w.conf} className={"m-pct " + pctCls} />
      </div>
    </div>
  );
}

function DirectionB({ data }) {
  const hero = bindingWindow(data.windows);
  const rest = data.windows.filter((w) => !hero || w.id !== hero.id);

  let heroCls = "";
  if (hero) {
    const t = toneB(hero.pct);
    heroCls = hero.conf === "estimate" ? "muted" : (t !== "neutral" ? t : "");
  }
  const headroom = hero ? 100 - hero.pct : null;

  return (
    <div className="pop B">
      <TitleRow data={data} />
      <div className="sep" />
      {data.warning && <div style={{ height: 12 }} />}
      <WarningStrip text={data.warning} />

      {hero && (
        <div className="hero">
          <div className="hero-kick">
            <span>Binding now</span>·
            <span className="who">{hero.name} {hero.sub === "5-hour" ? "(5h)" : "· " + hero.sub}</span>
            {hero.conf === "estimate" && <EstTag />}
          </div>
          <div className="hero-num">
            <span className={"hero-pct " + heroCls}>
              {hero.conf === "estimate" && <span className="approx">≈</span>}
              {hero.pct}<span className="pct">%</span>
            </span>
            <span className="hero-side">
              used<br /><span className="num">{headroom}%</span> headroom left
            </span>
          </div>
          <FillBar pct={hero.pct} conf={hero.conf} />
          <div className="hero-reset">
            <span>resets <span className="num">{hero.reset}</span></span>
            <span>closest to cap</span>
          </div>
        </div>
      )}

      <div className="sep" />
      <div className="mins">
        {rest.map((w) => <BMiniRow key={w.id} w={w} />)}
      </div>

      {data.tier === "free" && <Upsell />}
      <div className="sep" />
      <Savings data={data} />
      <div className="sep" />
      <Actions data={data} />
    </div>
  );
}

window.DirectionB = DirectionB;
