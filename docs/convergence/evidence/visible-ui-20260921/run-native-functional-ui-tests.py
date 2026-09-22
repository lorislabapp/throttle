import datetime, hashlib, json, os, pathlib, subprocess, time, sys, plistlib
repo = pathlib.Path('/Users/kevinnadjarian/GitHub/Throttle/build/convergence-recovery-20260920')
root = pathlib.Path('/Volumes/DeveloperStorage/BuildScratch/throttle-convergence-20260920')
label = 'functional-ui-tests-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
def snapshot():
    paths = subprocess.check_output(['/Applications/Xcode.app/Contents/Developer/usr/bin/git', 'ls-files', '-co', '--exclude-standard', '-z'], cwd=repo).decode().split('\0')
    paths += ['Throttle.xcodeproj/project.pbxproj', 'Throttle.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved']
    return {p: hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in sorted(set(paths)) if p and (repo/p).is_file() and not p.startswith(('docs/', 'audit-output/'))}
check = subprocess.run(['/usr/bin/pgrep','-x','xcodebuild'],capture_output=True,text=True)
if check.returncode != 1: raise SystemExit('Build admission refused: '+check.stdout+check.stderr)
config = ('unused', '', sys.argv[1], 'FR' if sys.argv[1] == 'fr' else 'US', 'light')
original = root/'DerivedData/Build/Products/Throttle_Throttle_macosx27.0-arm64.xctestrun'
review = original.with_name(label+'.xctestrun')
data = plistlib.loads(original.read_bytes())
for item in data['TestConfigurations']:
 for target in item['TestTargets']:
  target.setdefault('EnvironmentVariables', {}).pop('THROTTLE_REVIEW_SCENE', None)
  target['EnvironmentVariables'].pop('THROTTLE_REVIEW_APPEARANCE', None)
  target['TestLanguage'] = config[2]
  target['TestRegion'] = config[3]
  target['CommandLineArguments'] = target.get('CommandLineArguments', []) + ['-AppleLanguages', '('+config[2]+')', '-AppleLocale', config[2]+'_'+config[3]]
review.write_bytes(plistlib.dumps(data))
command = ['/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild', 'test-without-building',
 '-xctestrun', str(review), '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
 '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '300',
 '-maximum-test-execution-time-allowance', '360', '-resultBundlePath', str(root/(label+'.xcresult')),
 '-testLanguage', config[2], '-testRegion', config[3], '-only-testing:ThrottleTests/ProjectAssistantViewTests', '-only-testing:ThrottleTests/PlanIntegrationViewTests']
(root/(label+'-command.json')).write_text(json.dumps(command,indent=2))
before = snapshot()
expected_sources = json.loads((root/'build-20260921-072929-sources-after.json').read_text())
if before != expected_sources: raise SystemExit('Test admission refused: sources differ from built candidate')
app = root/'DerivedData/Build/Products/Debug/Throttle.app'
expected_files = json.loads((repo/'docs/convergence/evidence/visible-ui-20260921/candidate-files-072929.json').read_text())
actual_files = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(app.rglob('*')) if p.is_file() and not p.is_symlink()}
if actual_files != expected_files: raise SystemExit('Test admission refused: candidate bytes changed')
(root/(label+'-sources-before.json')).write_text(json.dumps(before,indent=2))
env = os.environ.copy(); env['TMPDIR'] = str(root/'tmp')+'/'
start = time.time(); status = 'running'; competing = []
with (root/(label+'.log')).open('w') as log:
    process = subprocess.Popen(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, env=env)
    while process.poll() is None:
        time.sleep(2)
        other = subprocess.run(['/usr/bin/pgrep','-x','xcodebuild'],capture_output=True,text=True)
        if other.returncode not in (0,1) or any(int(p)!=process.pid for p in other.stdout.split()):
            competing = [{'pid': int(pid), 'identity': subprocess.run(['/bin/ps', '-p', pid, '-o', 'pid=,ppid=,comm='], capture_output=True, text=True).stdout.strip()} for pid in other.stdout.split() if int(pid) != process.pid]
            status='interrupted-concurrency'; process.terminate(); break
        if time.time()-start > 600:
            status='interrupted-timeout'; process.terminate(); break
    try: code=process.wait(timeout=45)
    except subprocess.TimeoutExpired: process.kill(); code=process.wait(); status='interrupted-stop-timeout'
after=snapshot()
(root/(label+'-sources-after.json')).write_text(json.dumps(after,indent=2))
if status=='running': status='pass' if code==0 and before==after else 'failed'
receipt={'status':status,'exit_code':code,'duration_seconds':time.time()-start,'command':command,'cwd':str(repo),'log':str(root/(label+'.log')),'sources_match':before==after,'source_count':len(before),'app_launched':True,'launch_scope':'isolated XCTest host from DerivedData','installed_app_restarted':False,'signed':False,'competing_processes':competing,'review_scene':sys.argv[1],'review_configuration':config}
(root/(label+'-receipt.json')).write_text(json.dumps(receipt,indent=2))
print(json.dumps(receipt))
raise SystemExit(0 if status=='pass' else 1)
