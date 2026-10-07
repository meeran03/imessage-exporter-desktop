#!/usr/bin/env python3
"""Create relocatable universal tools, with no Homebrew runtime dependency."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "ThirdParty/iphone-tools"
TOOLS = ["idevice_id", "ideviceinfo", "idevicepair", "idevicebackup2"]

def run(*args):
    return subprocess.check_output(list(map(str,args)), text=True)

def dependencies(path):
    return [line.strip().split(' (',1)[0] for line in run('otool','-L',path).splitlines() if line.startswith('\t')]

def main():
    OUT.mkdir(exist_ok=True)
    files = {"bin/" + name for name in TOOLS}
    pending = list(files)
    arm = ROOT / ".build/iphone-arm64/prefix"
    while pending:
        relative = pending.pop()
        for dependency in dependencies(arm / relative):
            if dependency.startswith(str(arm)):
                name = "lib/" + Path(dependency).name
                if name not in files:
                    files.add(name); pending.append(name)
            elif not dependency.startswith(('/usr/lib/', '/System/Library/')):
                raise RuntimeError('Unexpected external dependency: ' + dependency)
    for relative in sorted(files):
        target = OUT / relative
        target.parent.mkdir(exist_ok=True)
        inputs = [ROOT / f'.build/iphone-{arch}/prefix' / relative for arch in ['arm64','x86_64']]
        run('lipo','-create',*inputs,'-output',target)
        for dependency in dependencies(target):
            if str(ROOT / '.build/iphone-') in dependency:
                replacement = ('@loader_path/../lib/' if relative.startswith('bin/') else '@loader_path/') + Path(dependency).name
                run('install_name_tool','-change',dependency,replacement,target)
        if relative.startswith('lib/'):
            run('install_name_tool','-id','@rpath/'+target.name,target)
        target.chmod(0o755)
        run('codesign','--force','--sign','-',target)
    for relative in files:
        for dependency in dependencies(OUT/relative):
            if not dependency.startswith(('/usr/lib/','/System/Library/','@loader_path/','@rpath/')):
                raise RuntimeError('Nonportable dependency: '+dependency)
    print(f'Packaged {len(files)} universal iPhone executables and libraries.')

if __name__ == '__main__':
    main()
