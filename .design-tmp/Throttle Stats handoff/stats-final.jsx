/* Throttle — Stats FINAL component: The Statement + pinned verdict headline */

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

window.StatsFinal = StatsFinal;
