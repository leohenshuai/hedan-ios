#!/bin/sh
# 检查 hedan-ios 最新编译；成功则报告，排队超 25 分钟/失败/取消则重触发
H="Authorization: Bearer $GITHUB_TOKEN"; R=leohenshuai/hedan-ios
python3 - "$H" "$R" <<'PY'
import json,sys,urllib.request,datetime
H,R=sys.argv[1],sys.argv[2]
def api(path,method='GET',data=None):
    rq=urllib.request.Request('https://api.github.com/repos/'+R+path,method=method,data=data,headers={'Authorization':H.split(': ',1)[1],'Accept':'application/vnd.github+json'})
    try:
        r=urllib.request.urlopen(rq,timeout=30);b=r.read();return r.status,(json.loads(b) if b else {})
    except urllib.error.HTTPError as e: return e.code,{}
s,d=api('/actions/runs?per_page=1'); r=d['workflow_runs'][0]
age=(datetime.datetime.utcnow()-datetime.datetime.strptime(r['created_at'],'%Y-%m-%dT%H:%M:%SZ')).total_seconds()/60
print('latest',r['id'],r['status'],r['conclusion'],'age_min=%d'%age)
if r['conclusion']=='success':
    s,a=api('/actions/runs/%d/artifacts'%r['id']); print('SUCCESS',[x['name'] for x in a.get('artifacts',[])],r['html_url']); sys.exit()
if r['status']=='in_progress': print('building, wait'); sys.exit()
if r['status']=='queued' and age<25: print('queued, wait'); sys.exit()
if r['status']=='queued': print('cancel',api('/actions/runs/%d/cancel'%r['id'],'POST')[0])
import time; time.sleep(10)
print('dispatch',api('/actions/workflows/build.yml/dispatches','POST',json.dumps({'ref':'main','inputs':{'release':'false'}}).encode())[0])
PY
