#!/usr/bin/env python3
"""Type-checks the Metal shaders with clang++ through metal_shim.h (no Metal compiler needed).

Each shader file is checked the way ShaderLibrary.swift compiles it at runtime: Common.metal
prepended. Vector/matrix constructors are rewritten to template calls that verify the
component count."""
import os, re, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
shaders = os.path.join(here, "..", "..", "Sources", "BladeRush", "Shaders")
clang = os.environ.get("CLANGXX", "clang++")

VEC = re.compile(r"\b((?:float|int|uint|uchar|ushort|half)[234])\s*\(")
MAT = re.compile(r"\b(float[234]x[234])\s*\(")
# Metal has no double type: unsuffixed floating literals are float. Mimic that for clang.
FLT = re.compile(r"(?<![\w.])((?:\d+\.\d*|\.\d+)(?:[eE][+-]?\d+)?|\d+[eE][+-]?\d+)(?![\w.])")

def convert(src):
    src = src.replace("#include <metal_stdlib>", '#include "metal_shim.h"')
    src = src.replace("using namespace metal;", "")
    src = FLT.sub(r"\1f", src)
    src = MAT.sub(r"mkm<\1>(", src)
    src = VEC.sub(r"mk<\1>(", src)
    return src

def main():
    common = open(os.path.join(shaders, "Common.metal")).read()
    files = sorted(f for f in os.listdir(shaders) if f.endswith(".metal") and f != "Common.metal")
    if len(sys.argv) > 1:
        files = [f for f in files if any(a in f for a in sys.argv[1:])]
    failed = 0
    for f in files:
        body = open(os.path.join(shaders, f)).read()
        src = convert(common + "\n#line 1 \"" + f + "\"\n" + body)
        with tempfile.NamedTemporaryFile("w", suffix=".cpp", dir=here, delete=False) as t:
            t.write(src)
            path = t.name
        r = subprocess.run([clang, "-fsyntax-only", "-std=c++17", "-Wno-unknown-attributes", "-Wno-c++11-narrowing",
                            "-ferror-limit=40", "-I", here, path], capture_output=True, text=True)
        os.unlink(path)
        out = (r.stdout + r.stderr).replace(path, "Common.metal")
        if r.returncode != 0:
            failed += 1
            print(f"FAIL {f}\n{out}")
        else:
            print(f"ok   {f}" + (f"\n{out}" if out.strip() else ""))
    sys.exit(1 if failed else 0)

main()
