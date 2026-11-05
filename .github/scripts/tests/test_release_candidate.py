#!/usr/bin/env python3
"""Exercise release-candidate.sh without signing, network, or a real Apple upload.

The script's orchestration, snapshots, archives, checksums, version gate, notes
extraction, and retry behavior run unchanged. External build/sign/notary tools
are deterministic fixtures. The sole script substitution redirects its absolute
PlistBuddy executable to a fixture so these tests also run outside macOS.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
VERSION, BUILD, TAG = "2.8.2", "274", "v2.8.2-preview.3"
SOURCE_NAME = f"HeyNotch-{VERSION}-{BUILD}-source.tar.gz"
NOTES_PATH = "docs/releases/2.8.2-preview.3.md"

TOOL = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,plistlib,shutil,sys,zipfile
name=pathlib.Path(sys.argv[0]).name;a=sys.argv[1:]
if name=='xcodebuild':
    root=pathlib.Path(a[a.index('-derivedDataPath')+1])/'Build/Products/Release/HeyNotch.app'
    for bundle,bid,executable in [(root,'com.wolfieeee.heynotch','HeyNotch'),(root/'Contents/XPCServices/HeyNotchXPCHelper.xpc','com.wolfieeee.heynotch.HeyNotchXPCHelper','HeyNotchXPCHelper')]:
        (bundle/'Contents/MacOS').mkdir(parents=True)
        info={'CFBundleIdentifier':bid,'CFBundleExecutable':executable,'CFBundleShortVersionString':os.getenv('FIXTURE_VERSION','2.8.2'),'CFBundleVersion':os.getenv('FIXTURE_BUILD','274'),'NSMicrophoneUsageDescription':'Fixture only','HeyNotchUpdatesEnabled':False}
        (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (bundle/'Contents/MacOS'/executable).write_bytes(b'fixture executable')
    (root/'Contents/Helpers').mkdir();(root/'Contents/Helpers/heynotch-mcp').write_bytes(b'fixture helper')
elif name=='codesign':
    if '-dv' in a:sys.stderr.write('Authority=Developer ID Application: Fixture\nTeamIdentifier=TVQX6QVQ7N\nflags=0x10000(runtime)\nTimestamp=Fixture\n')
elif name=='lipo':print('arm64 x86_64')
elif name=='PlistBuddy':
    key=a[a.index('-c')+1].split(':',1)[1]
    print(plistlib.loads(pathlib.Path(a[-1]).read_bytes())[key])
elif name=='ditto':
    src,dst=map(pathlib.Path,a[-2:])
    if '-c' in a:
        with zipfile.ZipFile(dst,'w') as z:
            for path in sorted(src.rglob('*')):
                if path.is_file():z.write(path,src.name+'/'+str(path.relative_to(src)))
    else:shutil.copytree(src,dst)
elif name=='xcrun':
    log=pathlib.Path(os.environ['FIXTURE_TOOL_LOG'])
    with log.open('a') as out:out.write(json.dumps(a)+'\n')
    if a[0]=='notarytool':
        action=a[1];submission='11111111-2222-4333-8444-555555555555'
        if action in ('submit','wait','info'):print(json.dumps({'id':submission,'status':'Accepted'}))
        elif action=='log':
            candidate=pathlib.Path(os.environ['FIXTURE_ROOT'])/'build/release-candidate/HeyNotch-CANDIDATE.zip'
            pathlib.Path(a[-1]).write_text(json.dumps({'status':'Accepted','sha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),'issues':[]}))
        else:raise SystemExit('Unexpected fake notary action')
    elif a[:2]==['stapler','staple']:(pathlib.Path(a[2])/'Contents/fixture-ticket').write_text('Fixture ticket')
    elif a[:2]!=['stapler','validate']:raise SystemExit('Unexpected fake xcrun action')
elif name!='spctl':raise SystemExit('Unexpected fixture tool')
'''


class ReleaseCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-fixture-", dir=ROOT.parent)
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        (self.root / "scripts").mkdir()
        tools = self.root / "fixture-tools"
        tools.mkdir()
        for name in ("xcodebuild", "codesign", "lipo", "PlistBuddy", "ditto", "xcrun", "spctl"):
            path = tools / name
            path.write_text(TOOL)
            path.chmod(0o755)
        script = (ROOT / "scripts/release-candidate.sh").read_text()
        script = script.replace("/usr/libexec/PlistBuddy", str(tools / "PlistBuddy"))
        self.script = self.root / "scripts/release-candidate.sh"
        self.script.write_text(script)
        # Deep signature verification has a separate real-app acceptance gate.
        (self.root / "scripts/release-signing.py").write_text("# Signature-tool fixture; no real signing.\n")
        (self.root / "docs/releases").mkdir(parents=True)
        shutil.copyfile(ROOT / NOTES_PATH, self.root / NOTES_PATH)
        shutil.copyfile(ROOT / "docs/INSTALL.md", self.root / "docs/INSTALL.md")
        (self.root / "LICENSE").write_text("GPL fixture\n")
        (self.root / "THIRD_PARTY_LICENSES").write_text("Notices fixture\n")
        (self.root / ".gitignore").write_text("build/\n")
        for args in (("init", "-q"), ("config", "user.name", "Release Fixture"), ("config", "user.email", "fixture@example.invalid"), ("remote", "add", "origin", "https://github.com/WOLFIEEEE/HeyNotch.git"), ("add", "."), ("-c", "commit.gpgsign=false", "commit", "-qm", "fixture")):
            subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)
        self.release = self.root / "build/release-candidate"
        self.log = self.root / "build/fake-tools.jsonl"
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        RELEASE_SIGNING_IDENTITY="Fixture only", RELEASE_TEAM_ID="TVQX6QVQ7N",
                        NOTARY_PROFILE="fixture-never-uploaded", FIXTURE_ROOT=str(self.root),
                        FIXTURE_TOOL_LOG=str(self.log), RELEASE_DERIVED_DATA=str(self.root / "build/derived"))
        for key in ("NOTARY_SUBMISSION_ID", "FIXTURE_VERSION", "FIXTURE_BUILD"):
            self.env.pop(key, None)

    def run_release(self, command, success=True, **env):
        result = subprocess.run(["bash", str(self.script), command], cwd=self.root,
                                env=dict(self.env, **env), text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def tool_calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_project_versions_match_release_identity(self):
        project = (ROOT / "HeyNotch.xcodeproj/project.pbxproj").read_text()
        versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
        builds = re.findall(r"CURRENT_PROJECT_VERSION = ([^;]+);", project)
        self.assertEqual(versions, [VERSION] * 4)
        self.assertEqual(builds, [BUILD] * 4)

    def test_build_packages_matching_source_separately_and_verify_is_offline(self):
        self.run_release("build")
        self.run_release("verify")
        readme = (self.release / "HeyNotch/READ-ME.txt").read_text()
        self.assertIn(f"https://github.com/WOLFIEEEE/HeyNotch/releases/download/{TAG}/{SOURCE_NAME}", readme)
        self.assertFalse((self.release / "HeyNotch/HeyNotch-source.tar.gz").exists())
        with tarfile.open(self.release / "source/HeyNotch-source.tar.gz") as archive:
            self.assertEqual(archive.extractfile("HeyNotch-source/" + NOTES_PATH).read(), (ROOT / NOTES_PATH).read_bytes())
        self.assertEqual(self.tool_calls(), [])

    def test_old_version_or_build_never_reaches_notary_upload(self):
        for version, build in (("2.8.0", "272"), ("2.8.1", "273"), (VERSION, "273"), ("2.8.1", BUILD)):
            with self.subTest(version=version, build=build):
                self.run_release("build", FIXTURE_VERSION=version, FIXTURE_BUILD=build)
                output = self.run_release("notarize", success=False)
                self.assertIn(f"requires app version {VERSION} ({BUILD})", output)
                self.assertEqual(self.tool_calls(), [])
                shutil.rmtree(self.root / "build")

    def test_notarization_uses_frozen_notes_and_source_and_retry_does_not_resubmit(self):
        self.run_release("build")
        original_notes = (self.root / NOTES_PATH).read_bytes()
        original_install = (self.root / "docs/INSTALL.md").read_bytes()
        (self.root / NOTES_PATH).write_text("Working notes changed after candidate build")
        (self.root / "docs/INSTALL.md").write_text("Working install changed after candidate build")
        self.run_release("notarize")
        final = self.release / "notarized"
        self.assertTrue((final / f"HeyNotch-{VERSION}-{BUILD}-notarized.zip").is_file())
        self.assertTrue((final / SOURCE_NAME).is_file())
        self.assertEqual((final / "RELEASE_NOTES.md").read_bytes(), original_notes)
        self.assertEqual((final / "INSTALL.md").read_bytes(), original_install)
        self.assertFalse((self.release / "HeyNotch/HeyNotch.app/Contents/fixture-ticket").exists())
        self.assertTrue((final / "HeyNotch/HeyNotch.app/Contents/fixture-ticket").is_file())
        self.run_release("notarize")
        self.assertEqual(sum(call[:2] == ["notarytool", "submit"] for call in self.tool_calls()), 1)
        self.run_release("verify")

    def test_changed_payload_is_rejected_before_upload(self):
        self.run_release("build")
        (self.release / "HeyNotch/READ-ME.txt").write_text("Changed after packaging")
        self.assertIn("Staged payload changed", self.run_release("notarize", success=False))
        self.assertEqual(self.tool_calls(), [])

    def test_changed_source_archive_is_rejected_before_upload(self):
        self.run_release("build")
        with tarfile.open(self.release / "source/HeyNotch-source.tar.gz", "w:gz"):
            pass
        self.assertIn("Source archive entries do not match", self.run_release("notarize", success=False))
        self.assertEqual(self.tool_calls(), [])


if __name__ == "__main__":
    unittest.main()
