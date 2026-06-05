/* Throttle — Stats FINAL: The Statement + pinned verdict headline */

function StatsFinal({ data, range, setRange }) {
  const est = !data.confident;
  const a = data.advisor;
  return (
    <div className="pop S SB SF">
      <StatsHead data={data} range={range} setRange={setRange} />

      {!data.enough || !a ? (
        <AdvisorEmpty collected={data.collected} needed={data.needed} />
      ) : (
        <>
          {/* pinned one-line verdict — the instant answer */}
          <div className="verdict-hero">
            <div className="vh-kick">Plan advisor · recommendation</div>
            <div className="vh-line">
              <span className="vh-plan">{a.recommend.name}</span>
              <span className="vh-price">
                {est && <span className="approx">≈</span>}{a.recommend.price}<span className="per">{a.recommend.per}</span>
              </span>
              <span className="vh-rest">
                <span>— <b>{a.recommend.blurb}</b></span>
                <span className="vh-sep">·</span>
                <span>saves <Fig est={est} className="num">{a.savings}</Fig>/mo vs API</span>
                {est && <EstTag />}
              </span>
            </div>
          </div>

          {/* the statement table that justifies it */}
          <div className="s-sec-h"><span className="s-label">Plan statement · vs API</span></div>
          <div className="stmt">
            <div className="stmt-h">
              <span>Plan</span>
              <span className="r">€/mo</span>
              <span className="r">fit to your burn</span>
            </div>
            {data.ladder.map((p) => (
              <div className={"stmt-row" + (p.best ? " best" : "")} key={p.id}>
                <span className="stmt-plan">
                  {p.name}
                  {p.current && <span className="tag">now</span>}
                  {p.best && <span className="bestpill">best</span>}
                </span>
                <span className="stmt-eur mono">{p.price}</span>
                <span className={"stmt-fit" + (p.best ? " ok" : "")}>{p.fit}</span>
              </div>
            ))}
            <div className="stmt-row api">
              <span className="stmt-plan">API equivalent <span className="tag">upper bound</span></span>
              <span className="stmt-eur mono muted">{est ? "≈" : ""}{a.apiEquiv}</span>
              <span className="stmt-fit">pay per token</span>
            </div>
          </div>
          <div className="v-reason">
            <Reasoning text={a.reasoning} />
          </div>
        </>
      )}

      <div className="sep" />
      <SecHeader label={"Usage trend · " + range} />
      <TrendChart trend={data.trend} est={est} />

      {data.split && (
        <>
          <div className="sep" />
          <SecHeader label="Model split · weighted" link="API rates" />
          <ModelSplit split={data.split} est={est} />
        </>
      )}

      <div className="sep" />
      <PeriodStrip period={data.period} est={est} />

      <ProExtras data={data} />
      <StatsTail data={data} />
    </div>
  );
}

/* ---------- single-design app: light + dark, all states ---------- */
const { useState: useStateSF } = React;
const TSF = window.ThrottleStats;
const SF_STATES = TSF.STATE_LIST;

function SFCard({ theme, data }) {
  const [range, setRange] = useStateSF("7d");
  return (
    <div>
      <div className="theme-tag">{theme === "theme-light" ? "Light" : "Dark"}</div>
      <div className={"pop-frame " + theme}>
        <div className="pop-caret" />
        <StatsFinal data={data} range={range} setRange={setRange} />
      </div>
    </div>
  );
}

function StatsFinalApp() {
  const [stateKey, setStateKey] = useStateSF("full");
  const data = TSF.SCENARIOS[stateKey];
  return (
    <div className="page final-page">
      <div className="masthead">
        <h1>Throttle — Stats · The Statement</h1>
        <p>
          The hybrid, taken to hi-fi. One bold verdict line answers the question up front — <em>which plan, what it
          costs, what it saves</em> — and the plan statement beneath justifies it, every option mapped to a quiet
          consequence word. Throttle never shows a confident number that might be wrong, so the throttle-day reads as a
          hedged label in the FIT column, not a red banner; red stays reserved for genuine at-limit pressure. Switch
          states below — both themes shown.
        </p>
      </div>

      <div className="controls">
        <span className="ctl-label">State</span>
        <div className="segmented">
          {SF_STATES.map((s) => (
            <button key={s.key} data-on={stateKey === s.key} onClick={() => setStateKey(s.key)}>
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="final-stage">
        <SFCard theme="theme-light" data={data} />
        <SFCard theme="theme-dark" data={data} />
      </div>
    </div>
  );
}

function mountStatsFinal() {
  const ready = window.Fig && window.TrendChart && window.PlanLadder && window.Actions && window.StatsHead;
  if (!ready) { setTimeout(mountStatsFinal, 12); return; }
  ReactDOM.createRoot(document.getElementById("root")).render(<StatsFinalApp />);
}
mountStatsFinal();
