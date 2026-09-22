import datetime, hashlib, json, pathlib, subprocess, tempfile
root=pathlib.Path(__file__).resolve().parent
binary=pathlib.Path('/private/tmp/throttle-two-reader-build-20260921/debug')
fixtures=pathlib.Path(tempfile.mkdtemp(prefix='fixtures-', dir=root))
results=[]
def run(reader, action, path):
 p=subprocess.run([str(binary/reader),action,str(path)],capture_output=True,text=True,timeout=20)
 if p.returncode: raise RuntimeError(f'{reader}/{action} exit {p.returncode}: {p.stderr[:1000]}')
 return json.loads(p.stdout)
def check(condition, message):
 if not condition: raise AssertionError(message)
for scenario in ['legacy-upgrade','optional-fields','unknown-terminal','unknown-middle']:
 path=fixtures/scenario
 initial=run('Legacy','seed',path)
 check(initial['chain_valid'] and initial['status']=='done', 'legacy fixture')
 current=run('Current','read',path)
 check(current['journal_sha256']==initial['journal_sha256'] and current['journal_unchanged_by_read'] and current['chain_valid'] and not current['pending_verification'], 'upgrade must preserve legacy log')
 observations={'legacy_seed':initial,'current_upgrade':current}
 if scenario=='optional-fields':
  modified=run('Current','new-optional',path); old=run('Legacy','read',path)
  check(old['chain_valid'] and old['event_count']==4 and old['journal_sha256']==modified['journal_sha256'] and old['journal_unchanged_by_read'], 'optional fields must survive old reader')
  observations.update(current_optional=modified,legacy_read=old)
 elif scenario.startswith('unknown'):
  modified=run('Current','unknown-middle' if scenario.endswith('middle') else 'unknown',path)
  check(modified['chain_valid'] and modified['pending_verification'] and not modified['last_check_passed'], 'expired intent remains unresolved')
  old=run('Legacy','refuse-append',path)
  check(not old['chain_valid'] and old['append_refused'] and old['journal_unchanged_by_read'] and old['journal_sha256']==modified['journal_sha256'], 'old reader must preserve unsupported journal')
  recovered=run('Current','read',path)
  check(recovered['chain_valid'] and recovered['pending_verification'] and not recovered['last_check_passed'] and recovered['journal_sha256']==modified['journal_sha256'] and recovered['journal_unchanged_by_read'], 'current reader reconstructs UNKNOWN despite legacy derived cache')
  observations.update(current_intent=modified,legacy_refusal=old,current_recovery=recovered)
 results.append({'scenario':scenario,'status':'pass','observations':observations})
receipt={'observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'pass','scenario_count':len(results),'results':results,'fixtures':str(fixtures),'binary_hashes':{name:hashlib.sha256((binary/name).read_bytes()).hexdigest() for name in ['Current','Legacy']},'source_manifest_sha256':hashlib.sha256((root/'source-manifest.json').read_bytes()).hexdigest(),'limits':['No production data accessed','Actual source readers; no identity claim about public build 223 DMG','No historical Git integration executed','Old projection may show done despite invalid chain; downgrade remains prohibited','No SQLite schema change since source revision 223; no full production upgrade tested']}
(root/'receipt.json').write_text(json.dumps(receipt,indent=2)); print(json.dumps(receipt,indent=2))
