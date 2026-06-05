/* Throttle — FINAL single design page (light + dark, all states) */
const { useState: useStateF } = React;
const TF = window.Throttle;

function FFrame({ theme, children }) {
  return (
    <div>
      <div className="theme-tag">{theme === "theme-light" ? "Light" : "Dark"}</div>
      <div className={"pop-frame " + theme}>
        <div className="pop-caret" />
        {children}
      </div>
    </div>
  );
}

function FinalApp() {
  const [stateKey, setStateKey] = useStateF("exact");
  const data = TF.SCENARIOS[stateKey];
  return (
    <div className="page final-page">
      <div className="masthead">
        <h1>Throttle — The Binding Number</h1>
        <p>
          The hybrid, taken to hi-fi. The window closest to its cap owns the readout in one oversized monospaced figure,
          with faint danger ticks at 80% and 95% where pressure starts earning colour. The other two windows keep full,
          legible rows — label, bar, reset time. And the confidence rule holds all the way up: if the binding window is a
          local estimate, the giant number itself degrades. Switch states below.
        </p>
      </div>

      <div className="controls">
        <span className="ctl-label">State</span>
        <div className="segmented">
          {TF.STATE_LIST.map((s) => (
            <button key={s.key} data-on={stateKey === s.key} onClick={() => setStateKey(s.key)}>
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="final-stage">
        <FFrame theme="theme-light"><DirectionFinal data={data} /></FFrame>
        <FFrame theme="theme-dark"><DirectionFinal data={data} /></FFrame>
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<FinalApp />);
