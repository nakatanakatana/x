#!/usr/bin/env python3
import os
import sys
import subprocess
import yaml

def render_all(output_file):
    manifests = []
    helm_repos = {}
    helm_releases = []

    # 1. Run flux build on all Kustomization files
    for root, dirs, files in os.walk("clusters"):
        for f in files:
            if f.endswith(".yaml") or f.endswith(".yml"):
                p = os.path.join(root, f)
                try:
                    with open(p, "r", encoding="utf-8") as fp:
                        content = fp.read()
                        if "kind: Kustomization" in content and "kustomize.toolkit.fluxcd.io" in content:
                            dir_path = os.path.dirname(p)
                            cmd = ["flux", "build", "kustomization", os.path.basename(dir_path), "--path", dir_path, "--dry-run"]
                            res = subprocess.run(cmd, capture_output=True, text=True)
                            if res.returncode == 0 and res.stdout.strip():
                                manifests.append(res.stdout.strip())
                except Exception:
                    pass

    full_yaml = "\n---\n".join(manifests)
    try:
        docs = list(yaml.safe_load_all(full_yaml))
    except Exception:
        docs = []

    clean_manifests = []
    for d in docs:
        if not isinstance(d, dict):
            continue
        kind = d.get("kind")
        if kind == "HelmRepository":
            name = d.get("metadata", {}).get("name")
            url = d.get("spec", {}).get("url")
            if name and url:
                helm_repos[name] = url
        elif kind == "HelmRelease":
            helm_releases.append(d)
        else:
            clean_manifests.append(yaml.dump(d))

    for r_name, r_url in helm_repos.items():
        subprocess.run(["helm", "repo", "add", r_name, r_url], capture_output=True)
    if helm_repos:
        subprocess.run(["helm", "repo", "update"], capture_output=True)

    for hr in helm_releases:
        hr_name = hr.get("metadata", {}).get("name", "release")
        hr_ns = hr.get("metadata", {}).get("namespace", "default")
        chart_spec = hr.get("spec", {}).get("chart", {}).get("spec", {})
        chart_name = chart_spec.get("chart")
        chart_version = chart_spec.get("version")
        source_ref = chart_spec.get("sourceRef", {}).get("name")
        values = hr.get("spec", {}).get("values", {})

        if chart_name and source_ref in helm_repos:
            repo_chart = f"{source_ref}/{chart_name}"
            cmd = ["helm", "template", hr_name, repo_chart, "--namespace", hr_ns]
            if chart_version:
                cmd.extend(["--version", str(chart_version)])
            if values:
                val_file = f"/tmp/values_{hr_name}.yaml"
                with open(val_file, "w", encoding="utf-8") as vf:
                    yaml.dump(values, vf)
                cmd.extend(["-f", val_file])
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0 and res.stdout.strip():
                clean_manifests.append(res.stdout.strip())
            else:
                clean_manifests.append(yaml.dump(hr))
        else:
            clean_manifests.append(yaml.dump(hr))

    with open(output_file, "w", encoding="utf-8") as out:
        out.write("\n---\n".join(clean_manifests))

if __name__ == "__main__":
    out_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/manifests/rendered.yaml"
    render_all(out_path)
