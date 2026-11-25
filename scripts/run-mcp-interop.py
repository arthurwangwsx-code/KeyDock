#!/usr/bin/env python3
"""用生产Swift adapter验证未修改的官方Time服务；四格各自新建连接和进程。"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from mcp_interop_integrity import verify_environment
from mcp_interop_process import run_probe

ROOT = Path(__file__).resolve().parents[1]

def source_snapshot():
    commit = subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip()
    names = subprocess.check_output(["git","ls-files","-co","--exclude-standard","-z"],cwd=ROOT).decode().split("\0")
    entries = {name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in sorted(set(names)) if name and (ROOT/name).is_file()}
    return {"commit":commit,"filesSHA256":hashlib.sha256(json.dumps(entries,sort_keys=True).encode()).hexdigest(),"dirty":bool(subprocess.check_output(["git","status","--porcelain"],cwd=ROOT,text=True).strip())}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment",required=True,type=Path)
    parser.add_argument("--probe",required=True,type=Path)
    parser.add_argument("--run-name",required=True)
    parser.add_argument("--scenario",choices=["time","sdk-lifecycle"],default="time")
    args = parser.parse_args()
    environment_path = args.environment.resolve(strict=True)
    root = environment_path.parent
    allowed = (ROOT/".local/interop").resolve()
    if not allowed.is_relative_to(ROOT) or not root.is_relative_to(allowed) or not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}",args.run_name): raise ValueError("Use an owned environment and unique run name")
    env = json.loads(environment_path.read_text())
    dependency_before = verify_environment(root,env)
    probe = args.probe.resolve(strict=True)
    if not probe.is_relative_to((ROOT/".build").resolve()) or not os.access(probe,os.X_OK): raise ValueError("Use this checkout's compiled probe")
    output = root/"runs"/args.run_name; output.mkdir(parents=True,exist_ok=False,mode=0o700)
    before = source_snapshot()
    binary_hash = hashlib.sha256(probe.read_bytes()).hexdigest()
    service_root = root/"venv/lib"
    service_files = list(service_root.glob("python*/site-packages/mcp_server_time/*.py"))
    if not service_files: raise ValueError("Official server is missing")
    code_before = {str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in service_files}
    process_env = {"PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","HOST":"127.0.0.1","PORT":"0"}
    results = []
    for kind in ("stdio","http"):
        for version in ("2025-11-25","2026-07-28"):
            name = kind+"-"+version
            report = output/(name+".json")
            server, server_stream, forced, exited = None,None,False,None
            server_log = output/(name+"-server.log")
            started = time.monotonic()
            error = None
            try:
                marker=output/(name+'-markers')
                host_script=ROOT/'Tools/Fixtures/mcp_sdk_lifecycle.py'
                command = [probe,"--environment",environment_path,"--transport",kind,"--protocol",version,"--report",report,"--scenario",args.scenario]
                if args.scenario=='sdk-lifecycle':command += ['--host-script',host_script,'--marker-dir',marker]
                if kind == "http":
                    server_stream = server_log.open("wb")
                    launch=[env['python'],'-I','-B','-u','-X','pycache_prefix='+str(output/(name+'-uncached'))]
                    launch += [host_script,'--transport','http','--marker-dir',marker] if args.scenario=='sdk-lifecycle' else ['-m','mcp_server_time','--local-timezone=UTC','--transport=streamable-http']
                    server = subprocess.Popen([str(value) for value in launch],cwd=env["workingDirectory"],env=process_env,stdout=server_stream,stderr=subprocess.STDOUT,start_new_session=True)
                    deadline = time.monotonic()+30
                    while True:
                        text = server_log.read_text(errors="replace")
                        if len(text)>1_048_576: raise ValueError("Server startup log exceeds budget")
                        found = re.search(r"Uvicorn running on http://127\.0\.0\.1:(\d+)",text)
                        if found:
                            port = int(found.group(1))
                            if not 1 <= port <= 65535: raise ValueError("Invalid owned port")
                            command += ["--endpoint","http://127.0.0.1:"+str(port)+"/mcp"]
                            break
                        if server.poll() is not None or time.monotonic()>=deadline: raise ValueError("Owned HTTP server did not become ready")
                        time.sleep(.05)
                with (output/(name+"-probe.log")).open("w") as log:
                    probe_exit = run_probe([str(value) for value in command],cwd=ROOT,env=process_env,log=log)
                result = json.loads(report.read_text()) if report.is_file() else {"status":"FAIL","error":"Probe left no report"}
                result = {key:result[key] for key in ("status","error","acceptedTools","rejectedTools","oldCatalogRejected","processExited","forcedTermination","httpCleanup","lifecycle") if key in result}
                result["exitCode"] = probe_exit["exitCode"]
                result["probeExit"] = probe_exit
                if probe_exit["exitCode"] != 0 or probe_exit["timedOut"] or probe_exit["requiredCleanup"] or probe_exit["observationFailed"] or probe_exit["signalFailed"] or probe_exit["waitUnconfirmed"] or not probe_exit["groupGone"]: result["status"]="FAIL"
                if args.scenario=='sdk-lifecycle' and kind=='http' and result['status']=='PASS':
                    cleanup=result.get('httpCleanup',{})
                    if version=='2025-11-25':
                        if cleanup.get('cancellationAccepted')!=1 or cleanup.get('sessionsDeleted')!=1 or cleanup.get('cancellationUnconfirmed')!=0 or cleanup.get('deleteUnconfirmed')!=0 or cleanup.get('initializationUnconfirmed')!=0:result['status']='FAIL'
                    elif any(cleanup.get(key,-1)!=0 for key in ['cancellationAccepted','cancellationUnconfirmed','sessionsDeleted','sessionsAlreadyGone','deleteUnconfirmed','deleteUnsupported','initializationUnconfirmed']):result['status']='FAIL'
            except (ValueError,OSError,subprocess.SubprocessError) as caught:
                error = str(caught); result = {"status":"FAIL","error":error}
            finally:
                if server is not None:
                    if server.poll() is None: server.terminate()
                    try: server.wait(timeout=10)
                    except subprocess.TimeoutExpired: forced=True; server.kill(); server.wait(timeout=5)
                    exited = server.poll() is not None
                if server_stream is not None: server_stream.close()
            result.update(transport=kind,protocol=version,seconds=round(time.monotonic()-started,3))
            if kind == "http":
                result.update(serverExited=exited,serverForcedTermination=forced)
                if not exited or forced: result["status"]="FAIL"
            results.append(result)
            print(json.dumps(result),flush=True)
    after = source_snapshot()
    dependency_after = verify_environment(root,env)
    code_after = {str(path.relative_to(root)):hashlib.sha256(path.read_bytes()).hexdigest() for path in service_files}
    passed = all(item["status"]=="PASS" for item in results) and before==after and code_before==code_after and dependency_before==dependency_after
    summary = {"status":"PASS" if passed else "FAIL","scenario":args.scenario,"source":before,"sourceUnchanged":before==after,"probeSHA256":binary_hash,"environment":str(environment_path),
               "lockSHA256":env["lockSHA256"],"serviceVersion":env["serviceVersion"],"sdkVersion":env["sdkVersion"],"serviceCodeUnchanged":code_before==code_after,"serviceCodeSHA256":code_before,"dependenciesVerified":dependency_after,"cases":results,
               "notQualified":["actual resources/prompts","slow cancellation of independent third-party services","all third-party servers","real AI provider","full product acceptance"]}
    (output/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps({"status":summary["status"],"summary":str(output/"summary.json")}))
    return 0 if passed else 1

if __name__ == "__main__":
    try: sys.exit(main())
    except (ValueError,OSError,KeyError,subprocess.SubprocessError) as error:
        print("FAIL: "+str(error),file=sys.stderr);sys.exit(1)
