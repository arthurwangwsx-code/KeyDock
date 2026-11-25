import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from mcp_interop_integrity import verify_environment,capture_installation

class MCPInteropIntegrityTests(unittest.TestCase):
    def fixture(self,root):
        site = root/'venv/lib/python3.13/site-packages';site.mkdir(parents=True)
        wheels = root/'wheelhouse';wheels.mkdir()
        lock = root/'requirements.lock';lock.write_text('synthetic lock\n')
        rows=[]
        for name in ['first','second']:
            data=('synthetic '+name+'\n').encode()
            (site/(name+'.py')).write_bytes(data)
            wheel=wheels/(name+'-1.0-py3-none-any.whl')
            with zipfile.ZipFile(wheel,'w') as archive: archive.writestr(name+'.py',data)
            rows.append({'name':name,'file':wheel.name,'sha256':hashlib.sha256(wheel.read_bytes()).hexdigest()})
        (root/'venv/bin').mkdir();(root/'venv/bin/python3').write_bytes(b'synthetic interpreter')
        (root/'venv/pyvenv.cfg').write_text('include-system-site-packages = false\n')
        (root/'work').mkdir()
        installation=root/'installation.json';installation.write_text(json.dumps(capture_installation(root)))
        return site,{'lockSHA256':hashlib.sha256(lock.read_bytes()).hexdigest(),'dependencies':rows,'python':str(root/'venv/bin/python3'),'pythonVersion':[3,13,12],'workingDirectory':str(root/'work'),'installationSHA256':hashlib.sha256(installation.read_bytes()).hexdigest()}

    def test_package_version_cannot_replace_interpreter_version_evidence(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root);env['pythonVersion']=3.12
            with self.assertRaises(ValueError):verify_environment(root,env)

    def test_unchanged_but_previously_modified_service_is_not_an_official_artifact(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            self.assertEqual(verify_environment(root,env)['files'],2)
            (site/'first.py').write_text('unchanged during run but not from the wheel\n')
            with self.assertRaises(ValueError):verify_environment(root,env)

    def test_lock_and_wheel_mutation_cannot_claim_a_verified_dependency(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            lock=root/'requirements.lock';lock.write_text('replaced lock\n')
            with self.assertRaises(ValueError):verify_environment(root,env)
            lock.write_text('synthetic lock\n')
            (root/'wheelhouse'/env['dependencies'][0]['file']).write_bytes(b'changed')
            with self.assertRaises(ValueError):verify_environment(root,env)

    def test_installed_symlink_cannot_read_outside_owned_site_packages(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            target=site/'first.py';data=target.read_bytes();target.unlink()
            outside=root/'outside.py';outside.write_bytes(data);target.symlink_to(outside)
            with self.assertRaises(ValueError):verify_environment(root,env)

    def test_wheel_parent_traversal_cannot_be_used_as_an_installation_proof(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            wheel=root/'wheelhouse'/env['dependencies'][0]['file']
            with zipfile.ZipFile(wheel,'a') as archive:archive.writestr('../outside.py','synthetic')
            env['dependencies'][0]['sha256']=hashlib.sha256(wheel.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):verify_environment(root,env)

    def test_execution_cannot_choose_a_different_interpreter_or_working_directory(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            for key in ['python','workingDirectory']:
                replaced=dict(env);replaced[key]=str(root/'different')
                with self.assertRaises(ValueError):verify_environment(root,replaced)

    def test_new_startup_hooks_and_pyvenv_configuration_drift_are_rejected(self):
        for name in ['sitecustomize.py','injection.pth','pyvenv.cfg']:
            with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
                root=Path(temporary);site,env=self.fixture(root)
                path=root/'venv/pyvenv.cfg' if name=='pyvenv.cfg' else site/name
                path.write_text('include-system-site-packages = true\n' if name=='pyvenv.cfg' else 'synthetic hook\n')
                with self.assertRaises(ValueError):verify_environment(root,env)

    def test_working_directory_symlink_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory(prefix='KeyDock-Interop-Integrity-') as temporary:
            root=Path(temporary);site,env=self.fixture(root)
            outside=root/'outside-work';outside.mkdir()
            work=root/'work';work.rmdir();work.symlink_to(outside,target_is_directory=True)
            with self.assertRaises(ValueError):verify_environment(root,env)
