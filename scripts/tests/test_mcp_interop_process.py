import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import subprocess
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mcp_interop_process import run_probe

class MCPInteropProcessTests(unittest.TestCase):
    def run_owned(self, code, timeout=2):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Process-') as directory:
            with open(os.devnull,'w') as log:
                return run_probe([sys.executable,'-I','-S','-u','-c',code],cwd=directory,
                                 env={'PATH':'/usr/bin:/bin'},log=log,timeout=timeout)

    def test_normal_exit_needs_no_group_cleanup(self):
        result=self.run_owned('pass')
        self.assertEqual(result,{'exitCode':0,'timedOut':False,'requiredCleanup':False,'forcedTermination':False,'observationFailed':False,'signalFailed':False,'waitUnconfirmed':False,'groupGone':True})

    def test_probe_exit_with_live_child_is_failed_and_owned_group_is_closed(self):
        result=self.run_owned('import subprocess,sys; subprocess.Popen([sys.executable,"-I","-S","-c","import time;time.sleep(30)"])')
        self.assertEqual(result['exitCode'],0)
        self.assertTrue(result['requiredCleanup'])
        self.assertTrue(result['groupGone'])

    def test_timeout_and_ignored_term_remain_failed_even_after_forced_cleanup(self):
        result=self.run_owned('import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(30)',timeout=.3)
        self.assertTrue(result['timedOut'] and result['requiredCleanup'] and result['forcedTermination'] and result['groupGone'])
        self.assertNotEqual(result['exitCode'],0)

    def test_observation_failure_still_closes_owned_process_and_cannot_pass(self):
        with patch('mcp_interop_process.live_members',side_effect=subprocess.TimeoutExpired('/bin/ps',5)):
            result=self.run_owned('import time;time.sleep(30)')
        self.assertTrue(result['observationFailed'] and result['requiredCleanup'] and result['forcedTermination'] and result['groupGone'])
        self.assertNotEqual(result['exitCode'],0)
