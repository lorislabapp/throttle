/* Throttle — Stats FINAL: single-design app (light + dark, all states) */

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
