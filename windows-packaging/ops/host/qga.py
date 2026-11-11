import subprocess,json,base64,time,sys,pathlib
name=sys.argv[1];script=pathlib.Path(sys.argv[2]).read_text(encoding='utf-8-sig')
req={'execute':'guest-exec','arguments':{'path':'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe','arg':['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',"[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$ProgressPreference='SilentlyContinue';"+script],'capture-output':True}}
def call(q):
 r=subprocess.run(['virsh','qemu-agent-command',name,json.dumps(q),'--timeout','10'],capture_output=True,text=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return json.loads(r.stdout)['return']
pid=call(req)['pid'];print('GUEST_EXEC_PID',pid,flush=True)
for i in range(180):
 r=call({'execute':'guest-exec-status','arguments':{'pid':pid}})
 if r.get('exited'):
  for k in ['out-data','err-data']:
   if k in r: print(k,base64.b64decode(r[k]).decode('utf-8',errors='replace'),flush=True)
  print('GUEST_EXIT',r.get('exitcode'),flush=True);break
 time.sleep(1)
else:print('GUEST_EXEC_TIMEOUT: do not blindly repeat',flush=True)
