/* Throttle — Stats shared sub-components (Fig, charts, ladder, sections, helpers) */

/* Throttle — Stats shared sub-components (exported to window) */
const SS = window.ThrottleStats;

/* number with confidence */
function Fig({ est, className, children }) {
  return (
    <span className={"mono " + (est ? "est-tone " : "") + (className || "")}>
      {est && <span className="approx">≈</span>}{children}
    </span>
  );
}

/* range selector */
function RangeBar({ range, setRange }) {
  return (
    <div className="rangebar">
      <div className="s-seg">
        {SS.RANGES.map((r) => (
          <button key={r} data-on={range === r} onClick={() => setRange(r)}>{r}</button>
        ))}
      </div>
      <span className="upd">updated <span className="num mono">2m</span> ago</span>
    </div>
  );
}

function SecHeader({ label, link }) {
  return (
    <div className="s-sec-h">
      <span className="s-label">{label}</span>
      {link && <span className="s-link">{link}</span>}
    </div>
  );
}

/* plan ladder */
function PlanLadder({ ladder }) {
  return (
    <div className="ladder">
      {ladder.map((p) => (
        <div className="rung" key={p.id} data-best={!!p.best} data-current={!!p.current}>
          <div className="rn">{p.name}</div>
          <div className="rp mono">{p.price}</div>
          {p.best && <span className="bestpill">best</span>}
        </div>
      ))}
    </div>
  );
}

/* trend chart — three neutral series */
function TrendChart({ trend, est }) {
  const toPath = (arr) => {
    const n = arr.length;
    return arr.map((v, i) => {
      const x = (i / (n - 1)) * 100;
      const y = 29 - (v / 100) * 27;
      return (i === 0 ? "M" : "L") + x.toFixed(1) + " " + y.toFixed(1);
    }).join(" ");
  };
  return (
    <div className="trend">
      <svg viewBox="0 0 100 30" preserveAspectRatio="none" aria-hidden="true">
        <line className="axis" x1="0" y1="29.5" x2="100" y2="29.5" />
        <path className="ln s3" d={toPath(trend.sonnet)} vectorEffect="non-scaling-stroke" />
        <path className="ln s2" d={toPath(trend.weekly)} vectorEffect="non-scaling-stroke" />
        <path className="ln s1" d={toPath(trend.session)} vectorEffect="non-scaling-stroke" />
      </svg>
      <div className="trend-legend">
        <span className="tl"><span className="sw s1" /> Session 5h</span>
        <span className="tl"><span className="sw s2" /> Weekly all</span>
        <span className="tl"><span className="sw s3" /> Weekly Sonnet</span>
        {est && <EstTag />}
      </div>
    </div>
  );
}

/* model split */
function ModelSplit({ split, est }) {
  const cls = ["m1", "m2", "m3"];
  return (
    <div className="split">
      <div className={"split-bar" + (est ? " est" : "")}>
        {split.map((m, i) => (
          <div key={m.name} className={"seg " + cls[i]} style={{ width: m.pct + "%" }} />
        ))}
      </div>
      <div className="split-legend">
        {split.map((m, i) => (
          <div className="sl" key={m.name}>
            <div className="sl-top"><span className={"dot " + cls[i]} /><span className="nm">{m.name}</span></div>
            <div className="pc"><Fig est={est}>{m.pct}%</Fig></div>
            <div className="eu">{est ? "≈" : ""}{m.eur}/mo API</div>
          </div>
        ))}
      </div>
    </div>
  );
}

/* period strip */
function PeriodStrip({ period, est }) {
  return (
    <div className="period">
      <div className="pcell">
        <span className="pk">Today</span>
        <span className="pv"><Fig est={est}>{period.today}</Fig></span>
      </div>
      <div className="pcell">
        <span className="pk">This week</span>
        <span className="pv"><Fig est={est}>{period.week}</Fig></span>
      </div>
      <div className="pcell">
        <span className="pk">Saved</span>
        <span className="pv muted"><span className="mono est-tone"><span className="approx">≈</span>{period.saved}</span></span>
      </div>
    </div>
  );
}

/* heatmap (Pro) */
function Heatmap() {
  const days = ["M", "T", "W", "T", "F", "S", "S"];
  const intensity = (d, h) => {
    let base = (h >= 9 && h <= 19) ? 0.72 : (h >= 20 && h <= 23) ? 0.34 : 0.07;
    const wk = d < 5 ? 1 : 0.42;
    const noise = 0.6 + 0.55 * Math.abs(Math.sin(d * 6.7 + h * 1.27));
    return SS.clamp(base * wk * noise, 0, 1);
  };
  return (
    <div className="heat">
      <div className="heat-wrap">
        {days.map((dl, d) => (
          <div className="heat-row" key={d}>
            <span className="dl">{dl}</span>
            <div className="heat-cells">
              {Array.from({ length: 24 }, (_, h) => {
                const v = intensity(d, h);
                return <div key={h} className="heat-cell"
                  style={{ background: v > 0.06 ? `color-mix(in srgb, var(--ink) ${Math.round(v * 70)}%, transparent)` : undefined }} />;
              })}
            </div>
          </div>
        ))}
      </div>
      <div className="heat-foot"><span>12a</span><span>6a</span><span>12p</span><span>6p</span><span>11p</span></div>
    </div>
  );
}

/* top projects (Pro) */
function TopProjects({ projects }) {
  return (
    <div className="proj">
      {projects.map((p) => (
        <div className="proj-row" key={p.name}>
          <div className="proj-top">
            <span className="proj-name">{p.name}</span>
            <span className="proj-tok mono">{p.tokens}</span>
          </div>
          <div className="proj-bar"><div className="pf" style={{ width: p.pct + "%" }} /></div>
        </div>
      ))}
    </div>
  );
}

/* pro lock (free) */
function ProLock() {
  return (
    <div className="pro-lock">
      <svg className="lk" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        <rect x="5" y="10.5" width="14" height="9" rx="2" stroke="currentColor" strokeWidth="1.6"/>
        <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" strokeWidth="1.6"/>
      </svg>
      <div className="lt">Activity heatmap & top projects</div>
      <div className="ls">See where your tokens go, hour by hour and project by project.</div>
      <span className="upl">Upgrade to Pro</span>
    </div>
  );
}

/* advisor empty (not-enough-data) */
function AdvisorEmpty({ collected, needed }) {
  return (
    <div className="adv-empty">
      <svg className="ai" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.6"/>
        <path d="M12 7.5v5l3 2" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
      <div>
        <div className="at">Need more usage to advise</div>
        <div className="as"><span className="mono">{collected}h</span> of <span className="mono">{needed}h</span> collected in this range.</div>
        <div className="prog"><div className="pf" style={{ width: (collected / needed * 100) + "%" }} /></div>
      </div>
    </div>
  );
}

function Reasoning({ text }) {
  return <div className="reasoning">{text}</div>;
}

Object.assign(window, {
  Fig, RangeBar, SecHeader, PlanLadder, TrendChart, ModelSplit,
  PeriodStrip, Heatmap, TopProjects, ProLock, AdvisorEmpty, Reasoning,
});

/* ---- layout helpers (advisor-agnostic, shared by every direction) ---- */
function toneColor(t) {
  return t === "crit" ? "var(--crit)" : t === "warn" ? "var(--warn)" : "var(--ink)";
}
function ProExtras({ data }) {
  if (data.tier === "free") {
    return (<><div className="sep" /><ProLock /></>);
  }
  return (
    <>
      <div className="sep" />
      <SecHeader label="Activity · last 7 days" />
      <Heatmap />
      <div className="sep" />
      <SecHeader label="Top projects" link="All›" />
      <TopProjects projects={data.projects} />
    </>
  );
}
function StatsTail({ data }) {
  return (<><div className="sep" /><Actions data={data} /></>);
}
function StatsHead({ data, range, setRange }) {
  return (
    <>
      <TitleRow data={data} />
      <div className="sep" />
      <RangeBar range={range} setRange={setRange} />
      <div className="sep" />
      {data.warning && <div style={{ height: 12 }} />}
      <WarningStrip text={data.warning} />
    </>
  );
}
Object.assign(window, { toneColor, ProExtras, StatsTail, StatsHead });
