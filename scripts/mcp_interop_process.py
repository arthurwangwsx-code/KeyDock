"""只收口本脚本新建的独占探针进程组；异常清理绝不能作为互通通过。"""
import os
import signal
import subprocess
import time

def group_exists(group):
    try: os.killpg(group, 0); return True
    except ProcessLookupError: return False
    except PermissionError: return True # 未能确认消失，不能记作退出。

def live_members(group):
    # 仅读取pid／pgid／状态，不读取命令、环境或个人进程正文。
    snapshot = subprocess.check_output(['/bin/ps','-g',str(group),'-o','pid=,pgid=,stat='],text=True,timeout=5)
    members = set()
    for row in snapshot.splitlines():
        fields = row.split()
        if len(fields)==3 and int(fields[1])==group and not fields[2].startswith('Z'):
            members.add(int(fields[0]))
    return members

def run_probe(command, *, cwd, env, log, timeout=60):
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise ValueError('Owned probe requires default child reaping')
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    timed_out = False
    forced = False
    observation_failed = False
    observation_error = None
    signal_failed = False
    wait_unconfirmed = False
    def signal_group(value):
        nonlocal signal_failed
        try: os.killpg(process.pid, value)
        except ProcessLookupError: pass
        except OSError: signal_failed = True
    def observe():
        nonlocal observation_failed, observation_error
        if observation_failed: return None
        try: return live_members(process.pid)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            observation_failed = True
            observation_error = type(error).__name__
            return None
    try:
        deadline = time.monotonic()+timeout
        while True:
            members = observe()
            if members is None or process.pid not in members: break
            if time.monotonic()>=deadline: timed_out = True; break
            time.sleep(.05)
    finally:
        # 组由这次Popen独占创建，包含stdio服务；不用按名称查找或接触其他工程进程。
        # 所有信号发完前绝不wait/poll回收组长；即使已退出，zombie也保留pid不被复用。
        members = observe()
        required_cleanup = observation_failed or bool(members)
        if required_cleanup:
            signal_group(signal.SIGTERM)
            deadline = time.monotonic()+2
            while time.monotonic()<deadline:
                members = observe()
                if members is not None and not members: break
                time.sleep(.05)
            members = observe()
            if observation_failed or members:
                forced = True
                signal_group(signal.SIGKILL)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: wait_unconfirmed = True
        deadline = time.monotonic()+2
        while group_exists(process.pid) and time.monotonic()<deadline: time.sleep(.01)
    return {"exitCode":process.returncode,"timedOut":timed_out,"requiredCleanup":required_cleanup,
            "forcedTermination":forced,"observationFailed":observation_failed,"signalFailed":signal_failed,
            "observationError":observation_error,"waitUnconfirmed":wait_unconfirmed,"groupGone":not group_exists(process.pid)}
