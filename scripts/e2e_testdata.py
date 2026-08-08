"""
e2e_testdata.py — seed / mutate / cleanup the Sprint 10 E2E test corpus in S3.

Generates ~100 deterministic documents (mix of 1/2/3-page PDFs, a few txt/docx) and manages them in
the S3 bucket that the Fabric OneLake shortcut (Files/s3_mmx_bucket) points at. Generated docs live
under an `e2e/` subfolder INSIDE each ACL folder so they inherit the correct groups from config/acls.json
and are purely ADDITIVE to any pre-existing testset/ objects (those are never touched).

Commands:
  seed     Reconcile the canonical corpus in S3: upload/overwrite every generated key AND delete any
           stale generated key (re-creates prior deletions, resets prior modifications). After seed,
           the generated set in S3 is byte-for-content-identical to the manifest => repeatable runs.
  mutate   Apply the incremental change set: modify 2 files, add 1, delete 1. Writes manifest_after.json.
  cleanup  Delete only the generated (e2e/) keys. Leaves pre-existing testset/ objects intact.

A manifest (manifest.json) is written to --out describing every generated file: key, rel_path (the
src_key = object path relative to the bucket root, which nb_pipeline_02 stamps as file_path in both source
modes), folder, ext, pages, ACL groups, and whether it should be ingested (engineering/* is no_acl ->
skipped). nb_ops_03_e2e_verify uses it as ground truth.

Usage:
  python scripts/e2e_testdata.py seed   [--dry-run] [--out .e2e]
  python scripts/e2e_testdata.py mutate [--dry-run] [--out .e2e]
  python scripts/e2e_testdata.py cleanup [--dry-run]

Requires the boto3 profile 's3-bucket' (same as Sprint 7). Run with the repo .venv:
  .venv\\Scripts\\python.exe scripts\\e2e_testdata.py seed
"""
import argparse
import io
import json
import os
import shutil
import sys
from datetime import datetime, timezone

import boto3

# Reuse the deterministic doc builders (page markers, "Page p of N" headers) from gen_testdocs.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_testdocs import (multipage_pdf, make_docx, make_txt, make_md,  # noqa: E402
                          make_pptx, make_xlsx, make_html, AUTHOR)

BUCKET = "mmx-amazon-s3-bucket"
PROFILE = "s3-bucket"
PREFIX = "testset/"                       # existing test root (added to, never wiped)
E2E = "e2e"                                # marker subfolder placed inside each ACL folder
SHORTCUT_ROOT = "Files/s3_mmx_bucket/"     # OneLake shortcut root => rel_path prefix the pipeline sees

# Folder -> ACL groups (must mirror config/acls.json nearest-ancestor resolution).
G111 = ["11111111-1111-1111-1111-111111111111"]
G222 = ["22222222-2222-2222-2222-222222222222"]
G333 = ["33333333-3333-3333-3333-333333333333"]
G334 = ["33333333-3333-3333-3333-333333333333", "44444444-4444-4444-4444-444444444444"]

# Office formats carry an author in docProps/core.xml; the pipeline extracts it into the index.
OFFICE_EXTS = {"docx", "pptx", "xlsx"}

# Corpus layout: (folder_under_testset, groups, ingested?, {ext: count}).
# finance/policies exercises EVERY Doc-Intelligence-supported type so the E2E verifies extraction
# quality per file type (pdf, docx, pptx, xlsx, html, htm, md) under an ACL; finance/reports covers txt.
LAYOUT = [
    ("finance/reports",   G111, True,  {"pdf": 45, "txt": 5}),                                  # 50
    ("finance/policies",  G222, True,  {"pdf": 6, "docx": 2, "pptx": 1, "xlsx": 1,              # 13
                                        "html": 1, "htm": 1, "md": 1}),
    ("hr",                G333, True,  {"pdf": 20}),                                            # 20
    ("hr/onboarding",     G334, True,  {"pdf": 12}),                                            # 12
    ("engineering",       [],   False, {"pdf": 8}),                                             # 8 no_acl skip
]

TITLE = {
    "finance/reports": "Finance Report",
    "finance/policies": "Finance Policy",
    "hr": "HR Document",
    "hr/onboarding": "Onboarding Guide",
    "engineering": "Engineering Spec",
}


def _slug(folder):
    return folder.replace("/", "-")


def _name(slug, ext, i):
    if ext == "pdf":
        return f"{slug}-{i:03d}.pdf"
    if ext == "txt":
        return f"{slug}-note-{i:03d}.txt"
    if ext == "docx":
        return f"{slug}-policy-{i:03d}.docx"
    return f"{slug}-{ext}-{i:03d}.{ext}"


def _pages(ext, i):
    # PDFs cycle 1/2/3 pages; text-read types are one page; DI-decided types are not asserted (None).
    if ext == "pdf":
        return (i % 3) + 1
    if ext in ("txt", "md"):
        return 1
    return None


def canonical_manifest():
    """Deterministic description of every generated file (no I/O)."""
    items = []
    for folder, groups, ingested, counts in LAYOUT:
        slug = _slug(folder)
        key_dir = f"{PREFIX}{folder}/{E2E}/"
        for ext, n in counts.items():
            for i in range(n):
                name = _name(slug, ext, i)
                items.append(_item(key_dir + name, folder, groups, ingested, ext, _pages(ext, i)))
    return items


def _item(key, folder, groups, ingested, ext, pages):
    # rel_path is the src_key (object path relative to the bucket root) = the identity nb_pipeline_02 stamps
    # as file_path in both source modes. nb_ops_03 matches on it directly.
    # content_marker: the token embedded in the file body (see gen_testdocs.marker) so the verify
    # step can prove correct per-file-type extraction reached AI Search.
    return {
        "key": key,
        "rel_path": key,
        "folder": folder,
        "ext": ext,
        "pages": pages,
        "groups": groups,
        "ingested": bool(ingested),
        "author": (AUTHOR if ext in OFFICE_EXTS else None),
        "content_marker": f"CONTENTMARKER-{ext.upper()}",
    }


def _build_local(item, stage):
    """Materialize one file locally under `stage`, return its local path."""
    local = os.path.join(stage, item["key"].replace("/", os.sep))
    os.makedirs(os.path.dirname(local), exist_ok=True)
    title = f'{TITLE[item["folder"]]} {os.path.basename(item["key"])}'
    ext = item["ext"]
    if ext == "pdf":
        multipage_pdf(local, title, item["pages"])
    elif ext == "txt":
        make_txt(local, title, 12)
    elif ext == "md":
        make_md(local, title, 12)
    elif ext == "docx":
        make_docx(local, title, 6)
    elif ext == "pptx":
        make_pptx(local, title, 3)
    elif ext == "xlsx":
        make_xlsx(local, title)
    elif ext in ("html", "htm"):
        make_html(local, title)
    else:
        raise ValueError(f"no generator for ext {ext!r}")
    return local


def _s3():
    return boto3.Session(profile_name=PROFILE).client("s3")


def _list_generated_keys(s3):
    """All keys under any .../e2e/ folder in testset/ (the generated set)."""
    keys = []
    token = None
    while True:
        kw = {"Bucket": BUCKET, "Prefix": PREFIX}
        if token:
            kw["ContinuationToken"] = token
        resp = s3.list_objects_v2(**kw)
        for o in resp.get("Contents", []):
            if f"/{E2E}/" in o["Key"]:
                keys.append(o["Key"])
        if resp.get("IsTruncated"):
            token = resp["NextContinuationToken"]
        else:
            break
    return set(keys)


def _write_manifest(items, out, name="manifest.json"):
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, name)
    payload = {
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "bucket": BUCKET,
        "prefix": PREFIX,
        "e2e_marker": E2E,
        "shortcut_root": SHORTCUT_ROOT,
        "counts": _counts(items),
        "generated": items,
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    print(f"manifest -> {path}")
    return path


def _counts(items):
    ing = [i for i in items if i["ingested"]]
    return {
        "total": len(items),
        "ingested": len(ing),
        "skipped_no_acl": len(items) - len(ing),
        "pages_expected": sum(i["pages"] for i in ing if i["pages"]),
    }


def seed(args):
    items = canonical_manifest()
    c = _counts(items)
    print(f"canonical corpus: {c['total']} files "
          f"({c['ingested']} ingested, {c['skipped_no_acl']} no_acl-skip, "
          f"{c['pages_expected']} PDF/txt pages)")
    _write_manifest(items, args.out)

    if args.dry_run:
        for it in items[:10]:
            print("  would upload", it["key"], f"({it['ext']}, pages={it['pages']})")
        print(f"  ... ({len(items)} total)  [dry-run: no S3 writes]")
        return

    stage = os.path.join(args.out, "_stage")
    if os.path.exists(stage):
        shutil.rmtree(stage)
    s3 = _s3()

    canonical_keys = {it["key"] for it in items}
    existing = _list_generated_keys(s3)
    stale = existing - canonical_keys
    for k in sorted(stale):
        s3.delete_object(Bucket=BUCKET, Key=k)
        print("  deleted stale", k)

    for it in items:
        local = _build_local(it, stage)
        s3.upload_file(local, BUCKET, it["key"])
    print(f"uploaded/reconciled {len(items)} generated objects to s3://{BUCKET}/{PREFIX}")
    print(f"stale removed: {len(stale)}")
    shutil.rmtree(stage, ignore_errors=True)


# ---- mutation set (must reference files that exist in the canonical corpus) ---------------------
MOD_PDF = f"{PREFIX}finance/reports/{E2E}/finance-reports-000.pdf"   # 1 -> 2 pages
MOD_TXT = f"{PREFIX}finance/reports/{E2E}/finance-reports-note-000.txt"
ADD_PDF = f"{PREFIX}finance/reports/{E2E}/finance-reports-added.pdf"  # new, 2 pages
DEL_PDF = f"{PREFIX}finance/reports/{E2E}/finance-reports-001.pdf"    # existed (2 pages) -> deleted


def mutate(args):
    changes = {
        "modified": [
            {"key": MOD_PDF, "rel_path": MOD_PDF, "ext": "pdf",
             "pages_before": 1, "pages_after": 2, "expected_status": "reingest", "groups": G111},
            {"key": MOD_TXT, "rel_path": MOD_TXT, "ext": "txt",
             "pages_before": 1, "pages_after": 1, "expected_status": "reingest", "groups": G111},
        ],
        "added": [
            {"key": ADD_PDF, "rel_path": ADD_PDF, "ext": "pdf",
             "pages_before": 0, "pages_after": 2, "expected_status": "new", "groups": G111},
        ],
        "deleted": [
            {"key": DEL_PDF, "rel_path": DEL_PDF, "ext": "pdf",
             "expected_status": "deleted", "groups": G111},
        ],
    }
    print("mutation set:")
    for kind, lst in changes.items():
        for c in lst:
            print(f"  {kind:9s} {c['key']}")

    _write_manifest_after(changes, args.out)

    if args.dry_run:
        print("  [dry-run: no S3 writes]")
        return

    stage = os.path.join(args.out, "_mut")
    if os.path.exists(stage):
        shutil.rmtree(stage)
    s3 = _s3()

    # modify: PDF grows a page; txt gets an extra line (both change size+mtime => change_hash flips)
    p = os.path.join(stage, "mod.pdf")
    os.makedirs(stage, exist_ok=True)
    multipage_pdf(p, "Finance Report finance-reports-000 (MODIFIED)", 2)
    s3.upload_file(p, BUCKET, MOD_PDF)
    t = os.path.join(stage, "mod.txt")
    make_txt(t, "Finance Report finance-reports-note-000 (MODIFIED)", 18)
    s3.upload_file(t, BUCKET, MOD_TXT)

    # add
    a = os.path.join(stage, "add.pdf")
    multipage_pdf(a, "Finance Report finance-reports-added", 2)
    s3.upload_file(a, BUCKET, ADD_PDF)

    # delete
    s3.delete_object(Bucket=BUCKET, Key=DEL_PDF)

    print("mutation applied to S3.")
    shutil.rmtree(stage, ignore_errors=True)


def _write_manifest_after(changes, out):
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "manifest_after.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"generated_utc": datetime.now(timezone.utc).isoformat(),
                   "changes": changes}, f, indent=2)
    print(f"manifest_after -> {path}")


def cleanup(args):
    if args.dry_run:
        s3 = _s3()
        keys = _list_generated_keys(s3)
        print(f"  would delete {len(keys)} generated keys  [dry-run]")
        return
    s3 = _s3()
    keys = _list_generated_keys(s3)
    for k in sorted(keys):
        s3.delete_object(Bucket=BUCKET, Key=k)
    print(f"deleted {len(keys)} generated (e2e/) keys; pre-existing testset/ objects untouched.")


def main():
    ap = argparse.ArgumentParser(description="Seed/mutate/cleanup the Sprint 10 E2E S3 corpus.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("seed", "mutate", "cleanup"):
        sp = sub.add_parser(name)
        sp.add_argument("--dry-run", action="store_true")
        sp.add_argument("--out", default=".e2e", help="local dir for manifests/staging")
    args = ap.parse_args()
    {"seed": seed, "mutate": mutate, "cleanup": cleanup}[args.cmd](args)


if __name__ == "__main__":
    main()
