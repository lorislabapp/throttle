/* Throttle — Settings shared components + group renderers */
const { useState: useStateSet } = React;
const SD = window.ThrottleSettings;

/* ---------------- icons ---------------- */
function SIcon({ n, className, style }) {
  const p = {
    gear: <><circle cx="12" cy="12" r="3.2" stroke="currentColor" strokeWidth="1.6"/><path d="M12 4v2.2M12 17.8V20M4 12h2.2M17.8 12H20M6.3 6.3l1.6 1.6M16.1 16.1l1.6 1.6M17.7 6.3l-1.6 1.6M7.9 16.1l-1.6 1.6" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    key: <><circle cx="8" cy="14" r="3.4" stroke="currentColor" strokeWidth="1.6"/><path d="M10.4 11.6L19 3M16 6l2.5 2.5M14 8l2 2" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/></>,
    spark: <><path d="M12 3.5l1.7 4.4 4.4 1.7-4.4 1.7L12 15.7l-1.7-4.4L5.9 9.6l4.4-1.7L12 3.5Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round"/><path d="M17.5 15l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8 .8-2Z" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round"/></>,
    target: <><circle cx="12" cy="12" r="8" stroke="currentColor" strokeWidth="1.6"/><circle cx="12" cy="12" r="3.4" stroke="currentColor" strokeWidth="1.6"/></>,
    plug: <><path d="M9 3v5M15 3v5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/><path d="M6 8h12v3a6 6 0 0 1-12 0V8Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/><path d="M12 17v4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    info: <><circle cx="12" cy="12" r="8.5" stroke="currentColor" strokeWidth="1.6"/><path d="M12 11v5" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/><circle cx="12" cy="7.8" r="0.5" fill="currentColor" stroke="currentColor" strokeWidth="1.1"/></>,
    search: <><circle cx="11" cy="11" r="6.2" stroke="currentColor" strokeWidth="1.7"/><path d="M15.6 15.6L20 20" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round"/></>,
    check: <path d="M5 12.5l4.2 4.2L19 7" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round"/>,
    dash: <path d="M6 12h12" stroke="currentColor" strokeWidth="2" strokeLinecap="round"/>,
    ext: <><path d="M14 5h5v5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round"/><path d="M19 5l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/><path d="M18 14v4a1.4 1.4 0 0 1-1.4 1.4H6.4A1.4 1.4 0 0 1 5 18V7.4A1.4 1.4 0 0 1 6.4 6h4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    cal: <><rect x="4.5" y="5.5" width="15" height="14" rx="2" stroke="currentColor" strokeWidth="1.6"/><path d="M4.5 9.5h15M8.5 3.5v3M15.5 3.5v3" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round"/></>,
    bolt: <path d="M13 3L5.5 13H11l-1 8 7.5-10H12l1-8Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" fill="none"/>,
    doc: <><path d="M7 4h7l4 4v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1Z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/><path d="M14 4v4h4" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round"/></>,
  }[n];
  return <svg className={className} style={style} viewBox="0 0 24 24" fill="none" aria-hidden="true">{p}</svg>;
}

/* ---------------- switch ---------------- */
function Toggle({ on, setOn, disabled }) {
  return (
    <button className="sw" data-on={!!on} data-disabled={!!disabled}
      onClick={() => !disabled && setOn(!on)} aria-pressed={!!on}>
      <span className="knob" />
    </button>
  );
}
function ToggleRow({ title, sub, defaultOn, disabled }) {
  const [on, setOn] = useStateSet(!!defaultOn);
  return (
    <div className="set-row">
      <div className="rl"><div className="t">{title}</div>{sub && <div className="s">{sub}</div>}</div>
      <div className="rc"><Toggle on={on} setOn={setOn} disabled={disabled} /></div>
    </div>
  );
}
function SegRow({ title, sub, options, defaultIndex }) {
  const [i, setI] = useStateSet(defaultIndex || 0);
  return (
    <div className="set-row">
      <div className="rl"><div className="t">{title}</div>{sub && <div className="s">{sub}</div>}</div>
      <div className="rc">
        <div className="set-seg">
          {options.map((o, k) => <button key={o} data-on={i === k} onClick={() => setI(k)}>{o}</button>)}
        </div>
      </div>
    </div>
  );
}
function ButtonRow({ title, sub, children }) {
  return (
    <div className="set-row">
      <div className="rl"><div className="t">{title}</div>{sub && <div className="s">{sub}</div>}</div>
      <div className="rc">{children}</div>
    </div>
  );
}

/* ---------------- title ---------------- */
function SettingsTitle({ state }) {
  return (
    <div className="titlebar">
      <svg className="mark" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        <path d="M12 21a9 9 0 1 1 9-9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        <path d="M12 12l5.2-3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/>
        <circle cx="12" cy="12" r="1.7" fill="currentColor"/>
      </svg>
      <span className="wordmark">Throttle</span>
      <span className="row-val" style={{ marginLeft: 6, fontSize: 12, color: "var(--ink-3)" }}>Settings</span>
      <span className="title-spacer" />
      {state.tier === "free" && <span className="pill free">Free</span>}
      {state.tier === "trial" && <span className="pill pro">Trial</span>}
      {state.tier === "pro" && <span className="pill pro">Pro</span>}
      {state.exact === "working" && <span className="pill exact"><span className="dot" />Exact</span>}
    </div>
  );
}

/* ================= GROUP: General ================= */
function GeneralGroup() {
  return (
    <div>
      <ToggleRow title="Launch at login" defaultOn={true} />
      <ToggleRow title="Notify at 80% and 95%" sub="A quiet banner as each window nears its cap." defaultOn={true} />
      <ButtonRow title="Weekly-reset reminder" sub="Add a Monday 4 PM event to Calendar.">
        <button className="set-btn"><span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}><SIcon n="cal" style={{ width: 14, height: 14 }} />Add to Calendar</span></button>
      </ButtonRow>
      <div className="set-row">
        <div className="rl"><div className="t">Software updates</div><div className="s">Auto-check weekly · last checked <span className="row-val" style={{ fontFamily: "var(--ff-mono)" }}>2m</span> ago</div></div>
        <div className="rc"><button className="set-btn">Check now</button></div>
      </div>
    </div>
  );
}

/* ================= GROUP: Pro (license + Exact mode) ================= */
function LicenseBlock({ state }) {
  if (state.license === "free") {
    return (
      <div className="lic">
        <div className="lic-row">
          <div className="lic-info">
            <div className="lic-title">Throttle <span className="pill free">Free</span></div>
            <div className="lic-sub">Upgrade to unlock Exact mode, stats history and projections.</div>
          </div>
        </div>
        <div className="lic-actions">
          <button className="set-btn primary">Buy Pro · €19</button>
          <span className="set-link">Paste license key</span>
        </div>
      </div>
    );
  }
  if (state.license === "trial") {
    return (
      <>
        <div className="trial-banner">
          <SIcon n="bolt" className="" style={{ width: 14, height: 14, color: "var(--ink-2)" }} />
          <span><span className="num">11</span> days left in your Pro trial.</span>
        </div>
        <div className="lic">
          <div className="lic-actions" style={{ marginTop: 0 }}>
            <button className="set-btn primary">Buy Pro · €19</button>
            <span className="set-link">Paste license key</span>
          </div>
        </div>
      </>
    );
  }
  // activated
  return (
    <div className="lic">
      <div className="lic-row">
        <div className="lic-info">
          <div className="lic-title">Throttle Pro <span className="pill pro">Pro</span></div>
          <div className="lic-sub">Key <span className="num">••••··3F9A</span> · Renews <span className="num">12 May 2027</span></div>
        </div>
      </div>
      <div className="lic-actions">
        <button className="set-btn quiet">Deactivate this Mac</button>
      </div>
    </div>
  );
}
function ExactStep({ done, todo, idx, children, action }) {
  return (
    <div className={"estep " + (done ? "done" : todo ? "todo" : "")}>
      <span className="idx">{done ? <SIcon n="check" className="" style={{ width: 12, height: 12 }} /> : idx}</span>
      <span className="et">{children}</span>
      {action}
    </div>
  );
}
function ExactBlock({ state }) {
  // hook must run unconditionally, before any early return (Rules of Hooks)
  const [on, setOn] = useStateSet(state.exact !== "off" && state.exact !== "locked");
  if (state.exact === "locked") {
    return (
      <>
        <div className="set-gh"><span className="lbl">Exact mode</span></div>
        <div className="exact-locked">
          <div className="lt">Exact mode is a Pro feature</div>
          <div className="ls">Read server-true usage straight from claude.ai instead of local estimates.</div>
          <button className="set-btn primary upl">Buy Pro · €19</button>
        </div>
      </>
    );
  }
  const working = state.exact === "working";
  const error = state.exact === "error";
  const needsignin = state.exact === "needsignin";
  const signedIn = state.signedIn;
  return (
    <>
      <div className="set-gh"><span className="lbl">Exact mode</span><span className="desc">Pro</span></div>
      <div className="exact-head">
        <div className="rl"><div className="t">Read server-true usage</div><div className="s">Polls claude.ai so figures aren't local estimates.</div></div>
        <div className="rc"><Toggle on={on} setOn={setOn} /></div>
      </div>
      {on && (
        <>
          <div className="exact-steps">
            <ExactStep done idx="1">Open claude.ai in Safari</ExactStep>
            <ExactStep done={signedIn} todo={!signedIn} idx="2"
              action={!signedIn ? <button className="set-btn">Sign in</button> : null}>
              Sign in to claude.ai
            </ExactStep>
            <ExactStep done={working} todo={!working} idx="3"
              action={!working && signedIn ? <button className="set-btn">Test</button> : null}>
              Test connection
            </ExactStep>
          </div>
          {working && (
            <div className="exact-status ok">
              <span className="lamp" /><span className="st">Working</span>
              <span className="meta">last poll <span className="num">14s</span> ago</span>
            </div>
          )}
          {error && (
            <div className="exact-status err">
              <span className="lamp" /><span className="st">Can't reach claude.ai</span>
              <span className="meta"><button className="set-btn">Sign in</button></span>
            </div>
          )}
          {needsignin && (
            <div className="exact-status err">
              <span className="lamp" /><span className="st">Signed out of claude.ai</span>
              <span className="meta"><button className="set-btn">Sign in</button></span>
            </div>
          )}
        </>
      )}
    </>
  );
}
function ProGroup({ state }) {
  return (
    <div>
      <LicenseBlock state={state} />
      <div className="sep" />
      <ExactBlock key={state.key} state={state} />
    </div>
  );
}

/* ================= GROUP: AI Assistant ================= */
function AssistantGroup() {
  const [prov, setProv] = useStateSet(1);
  return (
    <div>
      <div className="set-row">
        <div className="rl"><div className="t">Provider</div><div className="s">Who answers “why am I burning tokens?”</div></div>
        <div className="rc">
          <div className="set-seg">
            {SD.PROVIDERS.map((o, k) => <button key={o} data-on={prov === k} onClick={() => setProv(k)}>{o === "Apple Intelligence" ? "Apple" : o === "Claude subscription" ? "Claude" : "API"}</button>)}
          </div>
        </div>
      </div>
      {prov === 2 && (
        <div className="set-row">
          <div className="rl"><div className="t">API key</div><div className="s row-val" style={{ fontFamily: "var(--ff-mono)" }}>sk-ant-••••····7Qd</div></div>
          <div className="rc"><span className="set-link">Edit</span></div>
        </div>
      )}
      <SegRow title="Model quality" sub="Higher quality costs more per reply." options={SD.MODELS} defaultIndex={1} />
      <ToggleRow title="Caveman mode" sub="Terse, no-frills replies. Ug." defaultOn={false} />
    </div>
  );
}

/* ================= GROUP: Calibration ================= */
function CalWindow({ win }) {
  const [sel, setSel] = useStateSet(win.sel);
  return (
    <div className="cal-win">
      <div className="cal-head">
        <span className="nm">{win.name}</span><span className="sb">{win.sub}</span>
        <span className="cur">cap <span className="num">{win.presets[sel].val}</span></span>
      </div>
      <div className="chips">
        {win.presets.map((p, k) => (
          <button key={k} className="chip" data-on={sel === k} onClick={() => setSel(k)}>
            <span className="cv">{p.val}</span><span className="cp">{p.plan}</span>
          </button>
        ))}
      </div>
    </div>
  );
}
function CalibrationGroup() {
  return (
    <div>
      <CalWindow win={SD.CAPS.session} />
      <CalWindow win={SD.CAPS.weekly} />
      <CalWindow win={SD.CAPS.sonnet} />
      <div className="recal" style={{ borderTop: "1px solid var(--sep)" }}>
        <span>Recalibrate — I'm at</span>
        <span className="field"><span className="num">62</span><span className="pct">%</span></span>
        <span>on claude.ai right now</span>
        <span className="set-link" style={{ marginLeft: "auto" }}>Apply</span>
      </div>
    </div>
  );
}

/* ================= GROUP: Hooks ================= */
function HooksGroup() {
  return (
    <div>
      {SD.HOOKS.map((h) => (
        <div className="set-row" key={h.id}>
          <span className={"stat-dot " + (h.status === "ok" ? "ok" : "missing")}>
            <SIcon n={h.status === "ok" ? "check" : "dash"} className="" />
          </span>
          <div className="rl"><div className="t">{h.name}</div><div className="s">{h.desc}</div></div>
          <div className="rc"><span className="hook-tag">{h.status === "ok" ? "detected" : "not installed"}</span></div>
        </div>
      ))}
      <div className="set-note">Hooks are managed by the Claude Code CLI. Throttle reads their status — it never edits your shell config.</div>
    </div>
  );
}

/* ================= GROUP: Privacy & About ================= */
function AboutGroup() {
  return (
    <div>
      <div className="set-row tap"><div className="rl"><div className="t">Reveal log file</div><div className="s">~/Library/Logs/Throttle</div></div><div className="rc"><span className="chev">›</span></div></div>
      <div className="set-row tap"><div className="rl"><div className="t">Privacy policy</div></div><div className="rc"><SIcon n="ext" className="" style={{ width: 14, height: 14, color: "var(--ink-3)" }} /></div></div>
      <div className="sep" />
      <div className="about">
        <span className="appicon"><svg viewBox="0 0 24 24" fill="none"><path d="M12 21a9 9 0 1 1 9-9" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"/><path d="M12 12l5.2-3" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round"/><circle cx="12" cy="12" r="1.8" fill="currentColor"/></svg></span>
        <div className="ai-meta">
          <div className="ai-name">Throttle</div>
          <div className="ai-ver">Version <span className="num">1.4.2</span> <span style={{ color: "var(--ink-3)" }}>(118)</span></div>
        </div>
      </div>
      <div className="set-row tap"><div className="rl"><div className="t">Support</div></div><div className="rc"><SIcon n="ext" className="" style={{ width: 14, height: 14, color: "var(--ink-3)" }} /></div></div>
      <div className="set-row tap"><div className="rl"><div className="t">throttle.app</div></div><div className="rc"><SIcon n="ext" className="" style={{ width: 14, height: 14, color: "var(--ink-3)" }} /></div></div>
    </div>
  );
}

const GROUP_COMPONENTS = {
  general: GeneralGroup, pro: ProGroup, assistant: AssistantGroup,
  calibration: CalibrationGroup, hooks: HooksGroup, about: AboutGroup,
};

/* flat search index for Dir C */
const SEARCH_INDEX = [
  { label: "Launch at login", g: "general" },
  { label: "Notify at 80% and 95%", g: "general" },
  { label: "Weekly-reset reminder", g: "general" },
  { label: "Software updates · Check now", g: "general" },
  { label: "Buy Pro / License key", g: "pro" },
  { label: "Deactivate this Mac", g: "pro" },
  { label: "Exact mode", g: "pro" },
  { label: "Test connection", g: "pro" },
  { label: "AI provider", g: "assistant" },
  { label: "API key", g: "assistant" },
  { label: "Model quality", g: "assistant" },
  { label: "Caveman mode", g: "assistant" },
  { label: "Session cap (5h)", g: "calibration" },
  { label: "Weekly cap (all models)", g: "calibration" },
  { label: "Weekly cap (Sonnet)", g: "calibration" },
  { label: "Recalibrate", g: "calibration" },
  { label: "session-start router", g: "hooks" },
  { label: "pre-compact hook", g: "hooks" },
  { label: "kill-switch", g: "hooks" },
  { label: "Reveal log file", g: "about" },
  { label: "Privacy policy", g: "about" },
  { label: "Version", g: "about" },
];

Object.assign(window, {
  SIcon, Toggle, ToggleRow, SegRow, ButtonRow, SettingsTitle,
  GROUP_COMPONENTS, SEARCH_INDEX,
});
