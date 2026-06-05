/* Throttle — onboarding shared primitives (exported to window) */
const { useState: useStateOb } = React;
const OB = window.ThrottleOnb;

/* ---------- icons ---------- */
function ObIcon({ n, className, style }) {
  const p = {
    gauge: <><path d="M12 21a9 9 0 1 1 9-9" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><path d="M12 12l5.2-3" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round"/><circle cx="12" cy="12" r="1.7" fill="currentColor"/></>,
    lock: <><rect x="5" y="10.5" width="14" height="9" rx="2" stroke="currentColor" strokeWidth="1.6"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" strokeWidth="1.6"/></>,
    check: <path d="M5 12.5l4.2 4.2L19 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round"/>,
    spark: <><path d="M12 3.5l1.7 4.4 4.4 1.7-4.4 1.7L12 15.7l-1.7-4.4L5.9 9.6l4.4-1.7L12 3.5Z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round"/></>,
  }[n];
  return <svg className={className} style={style} viewBox="0 0 24 24" fill="none" aria-hidden="true">{p}</svg>;
}

/* ---------- brand lockup ---------- */
function BrandHero({ compact }) {
  return (
    <div className={"ob-hero" + (compact ? " compact" : "")}>
      <ObIcon n="gauge" className="ob-mark" />
      <div className="ob-word">Throttle</div>
      <div className="ob-what">{compact ? OB.COPY.whatShort : OB.COPY.what}</div>
    </div>
  );
}

/* ---------- privacy line ---------- */
function PrivacyLine({ long, inline }) {
  return (
    <div className={"ob-priv" + (inline ? " inline" : "")}>
      <ObIcon n="lock" className="lk" />
      {long ? (
        <div className="pt">Throttle reads <code>~/.claude/projects</code> locally. <b>Nothing leaves this Mac</b> — unless you turn on Exact mode (Pro), and even then only Safari talks to claude.ai.</div>
      ) : (
        <div className="pt">Reads <code>~/.claude/projects</code> on this Mac. <b>Nothing leaves it.</b></div>
      )}
    </div>
  );
}

/* ---------- toggle ---------- */
function ObToggle({ on, setOn }) {
  return (
    <button className="ob-sw" data-on={!!on} onClick={() => setOn(!on)} aria-pressed={!!on}><span className="knob" /></button>
  );
}
function LaunchRow({ on, setOn }) {
  return (
    <div className="ob-toggle-row">
      <div className="rl"><div className="t">Launch at login</div><div className="s">Keep the meter in your menu bar.</div></div>
      <ObToggle on={on} setOn={setOn} />
    </div>
  );
}

/* ---------- exact teaser ---------- */
function ExactTeaser() {
  return (
    <div className="ob-teaser">
      <ObIcon n="spark" className="sp" />
      <span>Want server-true numbers? Turn on <b>Exact mode</b> later in Settings.</span>
    </div>
  );
}

/* ---------- plan picker ---------- */
function PlanPicker({ pick, setPick }) {
  return (
    <div className="plans">
      {OB.PLANS.map((p) => {
        const on = pick === p.id;
        const isSkip = p.id === "skip";
        return (
          <button key={p.id} className={"plan" + (isSkip ? " skip" : "")} data-on={on} onClick={() => setPick(p.id)}>
            <span className="radio"><ObIcon n="check" /></span>
            <span className="pmain">
              <span className="pname">{p.name}{p.price && <span className="pprice">{p.price}</span>}</span>
              <span className="pblurb">{p.blurb}</span>
            </span>
            {!isSkip && (
              <span className="pcaps">
                <span className="cap">{p.session} · {p.weekly}</span>
                <span className="caplab">session · weekly</span>
              </span>
            )}
          </button>
        );
      })}
    </div>
  );
}

/* plan helper */
function planById(id) { return OB.PLANS.find((p) => p.id === id) || null; }

Object.assign(window, {
  ObIcon, BrandHero, PrivacyLine, ObToggle, LaunchRow, ExactTeaser, PlanPicker, planById,
});
