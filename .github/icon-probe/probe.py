import json, os, shutil, subprocess, sys
src = "PulseDeck/AppIcon.icon"
base = json.load(open(os.path.join(src, "icon.json")))
pulse = {"image-name": "Pulse.svg", "name": "Pulse"}
variants = {
  "A_minimal": {"groups": [{"layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "B_noplatforms": {"groups": [{"layers": [pulse]}]},
  "C_solidfill": {"fill": {"solid": "srgb:0.25098,0.35294,0.96078,1.00000"}, "groups": [{"layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "D_gradient": {"fill": {"linear-gradient": base["fill"]["linear-gradient"]}, "groups": [{"layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "E_gradient_orient": {"fill": base["fill"], "groups": [{"layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "F_glass": {"groups": [{"layers": [dict(pulse, glass=True)]}], "supported-platforms": {"squares": "shared"}},
  "G_shadow_transl": {"groups": [{"layers": [pulse], "shadow": {"kind": "neutral", "opacity": 0.5}, "translucency": {"enabled": True, "value": 0.2}}], "supported-platforms": {"squares": "shared"}},
  "H_specular": {"groups": [{"layers": [pulse], "specular": True}], "supported-platforms": {"squares": "shared"}},
  "I_opacity": {"groups": [{"layers": [dict(pulse, opacity=0.5)]}], "supported-platforms": {"squares": "shared"}},
  "J_colorspace": {"color-space-for-untagged-svg-colors": "srgb", "groups": [{"layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "K_groupname": {"groups": [{"name": "Pulse", "layers": [pulse]}], "supported-platforms": {"squares": "shared"}},
  "Z_full": base,
}
os.makedirs("probe", exist_ok=True)
for name, doc in variants.items():
    d = os.path.join("probe", name, "AppIcon.icon")
    shutil.copytree(os.path.join(src, "Assets"), os.path.join(d, "Assets"))
    json.dump(doc, open(os.path.join(d, "icon.json"), "w"), indent=2)
    out = os.path.join("probe", name, "out"); os.makedirs(out)
    r = subprocess.run(["xcrun", "actool", d, "--compile", out, "--platform", "macosx",
                        "--minimum-deployment-target", "26.0", "--app-icon", "AppIcon",
                        "--output-partial-info-plist", os.path.join(out, "partial.plist"),
                        "--errors", "--warnings"], capture_output=True, text=True)
    ok = "error" not in (r.stdout + r.stderr).lower() and r.returncode == 0
    print(f"### {name}: {'OK' if ok else 'FAIL'} rc={r.returncode} files={sorted(os.listdir(out))}")
    if not ok:
        print((r.stdout + r.stderr)[:600])
