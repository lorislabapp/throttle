/* Throttle — Settings: 3 navigation directions + comparison app */
const { useState: useStateSA } = React;
const SDX = window.ThrottleSettings;

/* ---------- DIR A: segmented tab bar, one pane scrolls ---------- */
function SettingsA({ state }) {
  const [tab, setTab] = useStateSA("general");
  const Group = GROUP_COMPONENTS[tab];
  return (
    <div className="pop ST">
      <SettingsTitle state={state} />
      <div className="SA-tabs">
        {SDX.GROUPS.map((g) => (
          <button key={g.id} className="SA-tab" data-on={tab === g.id} onClick={() => setTab(g.id)}>{g.short}</button>
        ))}
      </div>
      <div className="SA-pane"><Group state={state} /></div>
    </div>
  );
}

/* ---------- DIR B: one grouped scroll (System Settings) ---------- */
function SettingsB({ state }) {
  return (
    <div className="pop ST">
      <SettingsTitle state={state} />
      {SDX.GROUPS.map((g) => {
        const Group = GROUP_COMPONENTS[g.id];
        return (
          <React.Fragment key={g.id}>
            <div className="sep" />
            <div className="set-gh"><span className="lbl">{g.label}</span><span className="desc">{g.summary}</span></div>
            <Group state={state} />
          </React.Fragment>
        );
      })}
    </div>
  );
}

/* ---------- DIR C: find-a-setting (search + drill) ---------- */
function SettingsC({ state }) {
  const [q, setQ] = useStateSA("");
  const [drill, setDrill] = useStateSA(null);

  if (drill) {
    const g = SDX.GROUPS.find((x) => x.id === drill);
    const Group = GROUP_COMPONENTS[drill];
    return (
      <div className="pop ST">
        <SettingsTitle state={state} />
        <div className="drill-head">
          <button className="drill-back" onClick={() => setDrill(null)}>‹ Settings</button>
          <span className="drill-title">{g.label}</span>
        </div>
        <Group state={state} />
      </div>
    );
  }

  const query = q.trim().toLowerCase();
  const results = query ? SEARCH_INDEX.filter((r) => r.label.toLowerCase().includes(query)) : null;

  return (
    <div className="pop ST">
      <SettingsTitle state={state} />
      <div className="find-search">
        <div className="find-field">
          <SIcon n="search" />
          <input placeholder="Find a setting…" value={q} onChange={(e) => setQ(e.target.value)} />
        </div>
      </div>
      {results ? (
        results.length ? (
          <div className="find-results">
            {results.map((r, i) => {
              const g = SDX.GROUPS.find((x) => x.id === r.g);
              return (
                <div key={i} className="res-row" onClick={() => { setDrill(r.g); setQ(""); }}>
                  <div className="res-info"><div className="res-label">{r.label}</div><div className="res-group">{g.label}</div></div>
                  <span className="chev">›</span>
                </div>
              );
            })}
          </div>
        ) : <div className="find-empty">No setting matches “{q}”.</div>
      ) : (
        <div className="cat-list">
          {SDX.GROUPS.map((g) => (
            <div key={g.id} className="cat-row" onClick={() => setDrill(g.id)}>
              <span className="cat-ic"><SIcon n={g.icon} /></span>
              <div className="cat-info"><div className="cat-name">{g.label}</div><div className="cat-sum">{g.summary}</div></div>
              <span className="chev">›</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

window.SettingsA = SettingsA; window.SettingsB = SettingsB; window.SettingsC = SettingsC;

/* ---------- comparison page ---------- */
const SET_DIRS = [
  {
    id: "A", comp: "SettingsA", kicker: "Direction A", name: "Console Tabs",
    idea: "A segmented tab bar pins all six groups across the top; one calm pane scrolls beneath. You never scroll past what you didn't come for.",
    spec: [
      ["Signature", "Six tabs always visible — one tap lands you in the right group, no hunting."],
      ["Optimizes", "Get-in-get-out: the group you want is one tap, never a scroll."],
      ["Trades off", "Six labels must stay terse to fit 440pt; only one group is on screen at a time."],
    ],
  },
  {
    id: "B", comp: "SettingsB", kicker: "Direction B", name: "The Long Bench",
    idea: "One continuous grouped scroll, System-Settings style — every group under a bold hairline header, scannable top to bottom with nothing hidden.",
    spec: [
      ["Signature", "Everything is present; you skim headers and stop at the one you need."],
      ["Optimizes", "Discoverability and muscle memory — a control always lives in the same place."],
      ["Trades off", "The longest surface; the control you want may be a flick or two away."],
    ],
  },
  {
    id: "C", comp: "SettingsC", kicker: "Direction C", name: "Find a Setting",
    idea: "Search-first. A field up top and a six-row category index; type to filter every control across all groups, or tap a category to drill in with a back chevron.",
    spec: [
      ["Signature", "Type “exact” → the control surfaces instantly. The one job, made literal."],
      ["Optimizes", "The developer who knows exactly what they came to change."],
      ["Trades off", "Browsing adds one tap (drill in); search has to be forgiving."],
    ],
  },
];

function SetCard({ theme, comp, state }) {
  const Comp = window[comp];
  return (
    <div>
      <div className="theme-tag">{theme === "theme-light" ? "Light" : "Dark"}</div>
      <div className={"pop-frame " + theme}>
        <div className="pop-caret" />
        <Comp state={state} />
      </div>
    </div>
  );
}

function SetColumn({ dir, state }) {
  return (
    <div className="column">
      <div className="col-head">
        <div className="col-kicker">{dir.kicker}</div>
        <div className="col-name">{dir.name}</div>
        <div className="col-idea">{dir.idea}</div>
        <div className="spec">
          {dir.spec.map(([k, v]) => (
            <div className="row" key={k}><span className="k">{k}</span><span className="v">{v}</span></div>
          ))}
        </div>
      </div>
      <div className="theme-stack">
        <SetCard theme="theme-light" comp={dir.comp} state={state} />
        <SetCard theme="theme-dark" comp={dir.comp} state={state} />
      </div>
    </div>
  );
}

function SettingsApp() {
  const [stateKey, setStateKey] = useStateSA("activated");
  const state = SDX.SCENARIOS[stateKey];
  return (
    <div className="page">
      <div className="masthead">
        <h1>Throttle — Settings</h1>
        <p>
          Settings lives inside the same 440pt popover as the meter and Stats — no separate window. The job is narrow:
          find the one control you came for, across six groups, and change it without hunting. Three structurally
          different ways to navigate those groups — every key state, both themes. The tabs, scroll, search and drill are
          all live.
        </p>
      </div>
      <div className="controls">
        <span className="ctl-label">State</span>
        <div className="segmented">
          {SDX.STATE_LIST.map((s) => (
            <button key={s.key} data-on={stateKey === s.key} onClick={() => setStateKey(s.key)}>{s.label}</button>
          ))}
        </div>
      </div>
      <div className="grid stats-grid">
        {SET_DIRS.map((d) => <SetColumn key={d.id} dir={d} state={state} />)}
      </div>
    </div>
  );
}

function mountSettings() {
  const ready = window.SettingsA && window.SettingsB && window.SettingsC && window.GROUP_COMPONENTS && window.SettingsTitle;
  if (!ready) { setTimeout(mountSettings, 12); return; }
  ReactDOM.createRoot(document.getElementById("root")).render(<SettingsApp />);
}
mountSettings();
