/* Throttle — comparison page */
const { useState } = React;
const { STATE_LIST, SCENARIOS } = window.Throttle;

const DIRECTIONS = [
  {
    id: "A", comp: window.DirectionA,
    kicker: "Direction A",
    name: "Channel Strips",
    idea: "All three windows as equal-weight rows in one column — democratic telemetry, nothing shouts louder than its neighbour.",
    spec: [
      ["Signature", "Three identical rows in perfect vertical alignment; you read top-to-bottom like a mixing desk."],
      ["Optimizes", "Comparing all three at a glance; total predictability of where each number lives."],
      ["Trades off", "Won't tell you which window binds you — you scan all three to find the tightest."],
    ],
  },
  {
    id: "B", comp: window.DirectionB,
    kicker: "Direction B",
    name: "The Binding Number",
    idea: "Promotes the single window closest to its cap into one large readout; the other two recede to compact lines beneath.",
    spec: [
      ["Signature", "One oversized figure you read in under a second; emphasis follows whichever window is most at risk."],
      ["Optimizes", "The one-second \u201chow much headroom do I have right now\u201d glance."],
      ["Trades off", "De-emphasizes the non-binding windows; the hero figure moves as your usage shifts."],
    ],
  },
  {
    id: "C", comp: window.DirectionC,
    kicker: "Direction C",
    name: "Level Meters",
    idea: "Three vertical gauges read like a hardware VU meter, under a one-line status strip that names the binding window.",
    spec: [
      ["Signature", "Pressure is height — the tallest column shouts loudest, climbing into a shaded danger zone near the cap."],
      ["Optimizes", "Pre-attentive comparison of relative pressure; the most instrument-like of the three."],
      ["Trades off", "Vertical bars are harder to read to the exact percent, and the cluster needs more height."],
    ],
  },
];

function Frame({ theme, children }) {
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

function Column({ dir, data }) {
  const Comp = dir.comp;
  return (
    <div className="column">
      <div className="col-head">
        <div className="col-kicker">{dir.kicker}</div>
        <div className="col-name">{dir.name}</div>
        <div className="col-idea">{dir.idea}</div>
        <div className="spec">
          {dir.spec.map(([k, v]) => (
            <div className="row" key={k}>
              <span className="k">{k}</span>
              <span className="v">{v}</span>
            </div>
          ))}
        </div>
      </div>
      <div className="theme-stack">
        <Frame theme="theme-light"><Comp data={data} /></Frame>
        <Frame theme="theme-dark"><Comp data={data} /></Frame>
      </div>
    </div>
  );
}

function App() {
  const [stateKey, setStateKey] = useState("exact");
  const data = SCENARIOS[stateKey];
  return (
    <div className="page">
      <div className="masthead">
        <h1>Throttle — menu-bar popover</h1>
        <p>
          One question, answered in under a second: how much headroom is left before the next usage limit. Three
          structurally different readings of the same three windows, all in a precise-cockpit stance — and every state,
          not just the happy path. Switch the live state below; both light and dark are shown for each.
        </p>
      </div>

      <div className="controls">
        <span className="ctl-label">State</span>
        <div className="segmented">
          {STATE_LIST.map((s) => (
            <button key={s.key} data-on={stateKey === s.key} onClick={() => setStateKey(s.key)}>
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="grid">
        {DIRECTIONS.map((d) => <Column key={d.id} dir={d} data={data} />)}
      </div>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
